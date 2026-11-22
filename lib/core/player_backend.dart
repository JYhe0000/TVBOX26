import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mv;
import 'package:video_player/video_player.dart';

import '../data/network_policy.dart';
import 'stream_proxy_server.dart';

/// 播放后端工厂：网络策略（代理 / DoH）接入原生解码链路的唯一 seam。
///
/// - video_player（ExoPlayer）在插件内部创建播放器，无法替换其
///   DataSource，URL 经 [StreamProxyServer] 本地流代理改写；
/// - media_kit（mpv）代理场景优先设 mpv 原生 `http-proxy` 属性（原生栈
///   直连代理，吞吐与 TLS 兼容性更好，无需本地改写）；DoH-only 场景
///   mpv 吃不到 Dart 侧 DoH，回退本地流代理改写。
/// - 策略未配置（代理与 DoH 均为空）时 URL 原样透传，行为与未接入时
///   完全一致。
///
/// 诚实边界：
/// - mpv 没有原生 JSON DoH 选项（无对应命令行参数），DoH 无法在 mpv
///   原生栈生效，只能靠本地流代理改写让 Dart 侧 DoH 间接生效；
/// - 局域网初始地址不设置 mpv 原生代理，改经本地流代理旁路；公网地址
///   重定向至私网时仍受 mpv 自身代理行为限制。
Future<PlayerBackend> createPlayerBackend({
  required bool useMediaKit,
  required String url,
  Map<String, String> headers = const {},
}) async {
  if (useMediaKit) {
    final proxy = NetworkPolicy.proxy;
    if (proxy.isNotEmpty &&
        !NetworkPolicy.isDirectHost(Uri.tryParse(url)?.host ?? '')) {
      return MediaKitBackend(url, headers, httpProxy: proxy);
    }
    return MediaKitBackend(
      await StreamProxyServer.urlFor(url, headers),
      headers,
    );
  }
  return VideoPlayerBackend(
    await StreamProxyServer.urlFor(url, headers),
    headers,
    formatHint: Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') == true
        ? VideoFormat.hls
        : null,
  );
}

class PlaybackTrack {
  const PlaybackTrack(this.id, this.label);
  final String id;
  final String label;
}

abstract class PlayerBackend extends ValueNotifier<VideoPlayerValue> {
  PlayerBackend() : super(VideoPlayerValue.uninitialized());
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setPlaybackSpeed(double speed);
  Future<void> setLooping(bool looping);
  Future<void> close();
  Widget buildVideo(BuildContext context);
  List<PlaybackTrack> get audioTracks => const [];
  List<PlaybackTrack> get subtitleTracks => const [];
  Future<void> selectAudio(String id) async {}
  Future<void> selectSubtitle(String id) async {}
  Future<void> loadSubtitle(String url) async {}
  Future<void> setSubtitleDelay(double seconds) async {}
  double subtitleSize = 24;
}

class VideoPlayerBackend extends PlayerBackend {
  VideoPlayerBackend(String url, Map<String, String> headers, {VideoFormat? formatHint})
    : controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
         httpHeaders: headers,
         formatHint: formatHint,
        // 页面统一管理离后台暂停；插件必须允许 PiP 和后台音频继续播放。
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
          allowBackgroundPlayback: true,
        ),
      ) {
    controller.addListener(_sync);
  }
  final VideoPlayerController controller;
  void _sync() => value = controller.value;
  @override
  Future<void> initialize() => controller.initialize();
  @override
  Future<void> play() => controller.play();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> seekTo(Duration position) => controller.seekTo(position);
  @override
  Future<void> setPlaybackSpeed(double speed) =>
      controller.setPlaybackSpeed(speed);
  @override
  Future<void> setLooping(bool looping) => controller.setLooping(looping);
  @override
  Widget buildVideo(BuildContext context) => VideoPlayer(controller);
  @override
  Future<void> close() async {
    controller.removeListener(_sync);
    await controller.dispose();
    super.dispose();
  }
}

class MediaKitBackend extends PlayerBackend {
  MediaKitBackend(this.url, this.headers, {this.httpProxy}) {
    mk.MediaKit.ensureInitialized();
    player = mk.Player();
    controller = mv.VideoController(player);
    _subscriptions.addAll([
      player.stream.position.listen((_) => _sync()),
      player.stream.duration.listen((_) => _sync()),
      player.stream.playing.listen((_) => _sync()),
      player.stream.buffering.listen((_) => _sync()),
      player.stream.width.listen((_) => _sync()),
      player.stream.height.listen((_) => _sync()),
      player.stream.tracks.listen((_) => _sync()),
      player.stream.error.listen((error) {
        if (!_closed) value = value.copyWith(errorDescription: error);
      }),
    ]);
  }

  final String url;
  final Map<String, String> headers;

  /// mpv 原生 `http-proxy` 属性值（代理场景直连代理，跳过本地流代理）。
  final String? httpProxy;
  late final mk.Player player;
  late final mv.VideoController controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _closed = false;
  bool _ready = false;

  void _sync() {
    if (_closed) return;
    final state = player.state;
    value = value.copyWith(
      isInitialized: _ready,
      duration: state.duration,
      position: state.position,
      isPlaying: state.playing,
      isBuffering: state.buffering,
      size: Size(
        (state.width ?? 1280).toDouble(),
        (state.height ?? 720).toDouble(),
      ),
    );
  }

  @override
  Future<void> initialize() async {
    final proxy = _normalizedHttpProxy();
    if (proxy != null) {
      // mpv 的 http-proxy 属性在 open 之前设置，作用于本次打开的流。
      final native = player.platform;
      if (native is mk.NativePlayer) {
        await native.setProperty('http-proxy', proxy);
      }
    }
    await player.open(mk.Media(url, httpHeaders: headers), play: false);
    _ready = true;
    _sync();
  }

  /// NetworkPolicy.proxy 允许 `host:port` 或 `http://host:port`；mpv 需要
  /// 带协议前缀，缺省按 http 代理补全。
  String? _normalizedHttpProxy() {
    final proxy = httpProxy;
    if (proxy == null || proxy.trim().isEmpty) return null;
    if (proxy.contains('://')) return proxy;
    return 'http://$proxy';
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seekTo(Duration position) => player.seek(position);
  @override
  Future<void> setPlaybackSpeed(double speed) => player.setRate(speed);
  @override
  Future<void> setLooping(bool looping) => player.setPlaylistMode(
    looping ? mk.PlaylistMode.single : mk.PlaylistMode.none,
  );
  @override
  List<PlaybackTrack> get audioTracks => player.state.tracks.audio
      .map(
        (track) => PlaybackTrack(
          track.id,
          _label(track.id, track.title, track.language),
        ),
      )
      .toList();
  @override
  List<PlaybackTrack> get subtitleTracks => player.state.tracks.subtitle
      .map(
        (track) => PlaybackTrack(
          track.id,
          _label(track.id, track.title, track.language),
        ),
      )
      .toList();
  String _label(String id, String? title, String? language) => switch (id) {
    'auto' => '自动选择',
    'no' => '关闭',
    _ => [
      title,
      language,
      '轨道 $id',
    ].whereType<String>().where((v) => v.isNotEmpty).join(' · '),
  };
  @override
  Future<void> selectAudio(String id) =>
      player.setAudioTrack(mk.AudioTrack(id, null, null));
  @override
  Future<void> selectSubtitle(String id) =>
      player.setSubtitleTrack(mk.SubtitleTrack(id, null, null));
  @override
  Future<void> loadSubtitle(String url) =>
      player.setSubtitleTrack(mk.SubtitleTrack.uri(url));
  @override
  Future<void> setSubtitleDelay(double seconds) async {
    final native = player.platform;
    if (native is mk.NativePlayer) {
      await native.setProperty('sub-delay', '$seconds');
    }
  }

  @override
  Widget buildVideo(BuildContext context) => mv.Video(
    controller: controller,
    controls: mv.NoVideoControls,
    fit: BoxFit.fill,
    subtitleViewConfiguration: mv.SubtitleViewConfiguration(
      // 字幕覆盖视频，保持黑底白字；字幕字号由用户单独选择，不影响界面字号。
      style: Theme.of(context).textTheme.titleLarge!.copyWith(
        fontSize: subtitleSize,
        color: Colors.white,
        backgroundColor: Colors.black.withValues(alpha: 0.65),
      ),
    ),
  );
  @override
  Future<void> close() async {
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    super.dispose();
  }
}
