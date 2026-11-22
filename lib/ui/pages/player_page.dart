import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/app_controller.dart';
import '../../core/library_store.dart';
import '../../core/playback_preferences.dart';
import '../../core/player_backend.dart';
import '../../core/skip_preferences.dart';
import '../../core/android_playback.dart';
import '../../core/background_playback.dart';
import '../../core/config_url_server.dart';
import '../../core/dlna/dlna_control.dart';
import '../../core/dlna/dlna_discovery.dart';
import '../../core/stream_proxy_server.dart';
import '../../core/utils.dart';
import '../../data/models.dart';
import '../../data/playback_error.dart';
import '../../data/play_resolver.dart';
import '../../data/danmaku_service.dart';
import '../../data/danmaku_match.dart';
import '../../data/danmaku_store.dart';
import '../widgets/danmaku_overlay.dart';
import '../../theme/ui.dart';
import '../tv_canvas.dart';
import '../widgets/common.dart';
import '../widgets/episode_selector.dart';
import '../widgets/player_focus.dart';
import '../widgets/tv_sheet.dart';
import '../widgets/cast_dialog.dart';
import '../widgets/config_url_dialog.dart';
import '../widgets/network_speed.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.vod,
    required this.site,
    this.lineIndex = 0,
    this.episodeIndex = 0,
    this.startPositionMs = 0,
  });

  final VodItem vod;
  final SiteConfig site;
  final int lineIndex;
  final int episodeIndex;
  final int startPositionMs;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with WidgetsBindingObserver, RouteAware {
  AppController? _controller;
  LibraryStore? _library;
  PlayerBackend? _video;
  Timer? _hideTimer;
  late int _lineIndex = _lineCount == 0
      ? 0
      : widget.lineIndex.clamp(0, _lineCount - 1);
  late int _episodeIndex;
  int _startPositionMs = 0;
  int _requestToken = 0;
  bool _loading = true;
  bool _controlsVisible = true;
  bool _episodesOpen = false;
  bool _handledEnd = false;
  String? _error;
  bool _errorVisible = false;
  bool _optionsOpen = false;
  ParseConfig? _selectedParse;
  SkipPreference _skip = const SkipPreference();
  Timer? _clockTimer;
  DateTime _clock = DateTime.now();
  ResolvedPlayUrl? _resolvedMedia;
  bool _pip = false;
  List<DanmakuComment> _danmaku = [];
  bool _danmakuEnabled = true;
  double _danmakuOpacity = 0.8;
  bool _danmakuLarge = false;
  final FocusNode _retryFocus = FocusNode(debugLabel: 'playerRetry');
  final FocusScopeNode _errorScope = FocusScopeNode(debugLabel: 'playerError');
  int _lastSavedPosition = 0;
  int _lastSavedAt = 0;
  bool _booted = false;
  bool _routeSubscribed = false;
  bool _routeCovered = false;

  bool get _isCurrentRoute =>
      mounted && !_routeCovered && ModalRoute.of(context)?.isCurrent == true;

  /// 播放页焦点节点集合（页面根 / 播放键 / 选集面板作用域 / 选集触发键
  /// + 开面板前的落点记忆）。状态机（控制层可见 = 焦点在胶囊、隐藏 = 焦点
  /// 在页面根、侧栏开 = 焦点在面板、关闭回触发键）与帧后投焦统一见
  /// player_focus.dart 头注；debugLabel（playerRoot / playerPlay /
  /// episodePanel / episodeTrigger）是测试与真机探针锚点，不要重命名。
  late final PlayerFocusNodes _focus = PlayerFocusNodes();

  /// 选集面板工具行（画中画/弹幕/…/关闭）的焦点节点：DOWN 进面板主体、
  /// UP 是面板顶（显式吞）。行内 LEFT/RIGHT 走几何（Wrap 布局）。
  final Map<int, FocusNode> _toolNodes = {};
  FocusNode _toolNode(int index) => _toolNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'panelTool-$index'),
  );

  /// 选集面板线路胶囊的焦点节点（多线路时存在）：UP 回工具行、DOWN 进
  /// 字幕行/网格。行内 LEFT/RIGHT 走几何（胶囊少且全挂载）。
  final Map<int, FocusNode> _panelLineNodes = {};
  FocusNode _panelLineNode(int index) => _panelLineNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'panelLine-$index'),
  );

  /// 选集面板字幕/音轨工具行（仅 MediaKit 内核时存在）的焦点节点。
  final Map<int, FocusNode> _extraNodes = {};
  FocusNode _extraNode(int index) => _extraNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'panelExtra-$index'),
  );

  /// DLNA 投屏状态（选集面板「投屏」入口）。投屏中本机播放暂停、
  /// 控制层隐藏，遥控器焦点交给 [CastControlPanel]。
  DlnaDevice? _castDevice;
  DlnaControl? _castControl;
  int _castPositionMs = 0;
  bool _castPlaying = false;

  /// 「投屏」触发按钮：弹窗关闭后焦点归还（FOCUS-07）。
  final FocusNode _castTrigger = FocusNode(debugLabel: 'castTrigger');

  /// 投屏控制面板的焦点作用域：焦点飘出面板时由页面重投回来。
  final FocusScopeNode _castScope = FocusScopeNode(debugLabel: 'castPanel');

  /// 长驻后台播放会话（前台服务 + 媒体通知的状态入口，见 dispose 收尾）。
  late final BackgroundPlayback _bg;

  int get _lineCount => widget.vod.lines.length;

  PlayLine? get _line {
    if (widget.vod.lines.isEmpty) return null;
    return widget.vod.lines[_lineIndex.clamp(0, _lineCount - 1)];
  }

  Episode? get _episode {
    final line = _line;
    if (line == null || line.episodes.isEmpty) return null;
    return line.episodes[_episodeIndex.clamp(0, line.episodes.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _controlsVisible) setState(() => _clock = DateTime.now());
    });
    _episodeIndex = widget.episodeIndex;
    _startPositionMs = widget.startPositionMs;
    final line = _line;
    if (line != null && line.episodes.isNotEmpty) {
      _episodeIndex = widget.episodeIndex.clamp(0, line.episodes.length - 1);
    } else {
      _episodeIndex = 0;
    }
    _enterFullscreen();
    // 硬件级唤醒兜底（见 [_rawKeyWake]）。
    HardwareKeyboard.instance.addHandler(_rawKeyWake);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prepare(startPositionMs: widget.startPositionMs);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 字幕/弹幕扫码等子路由 pop 后焦点会停在路由 scope（AGENTS.md §3 规则 9）。
    // 路由要在 didChangeDependencies 之后才能安全读取，不能放 initState。
    final route = ModalRoute.of(context);
    if (route != null && !_routeSubscribed) {
      _routeSubscribed = true;
      kRouteObserver.subscribe(this, route);
    }
    if (!_booted) {
      _booted = true;
      _controller = context.read<AppController>();
      _bg = BackgroundPlayback(storage: _controller!.storage);
      _library = context.read<LibraryStore>();
      _skip = SkipPreferences(_controller!.storage)
          .read(widget.site.key, widget.vod.id);
      // 通知栏按钮 / 音频焦点丢失等原生动作回放到本页处理
      // （单一真相在 Dart，见 background_playback.dart 头注）。
      BackgroundPlayback.onAction = _handleBackgroundAction;
    }
  }

  @override
  void didPushNext() {
    // 路由覆盖时取消自动隐藏；即使 timer 回调已排队，回调中的当前路由守卫
    // 也会阻止底层页面请求焦点。
    _routeCovered = true;
    _hideTimer?.cancel();
  }

  Future<void> _enterFullscreen() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> _leaveFullscreen() async {
    try {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await WakelockPlus.disable();
    } catch (_) {}
  }

  Future<void> _prepare({
    int? lineIndex,
    int? episodeIndex,
    int startPositionMs = 0,
  }) async {
    if (lineIndex != null && _lineCount > 0) {
      _lineIndex = lineIndex.clamp(0, _lineCount - 1);
    }
    if (episodeIndex != null) {
      final line = _line;
      if (line != null && line.episodes.isNotEmpty) {
        _episodeIndex = episodeIndex.clamp(0, line.episodes.length - 1);
      }
    }
    _startPositionMs = startPositionMs;
    // 新播放器的监听在下面创建控制器时挂上；进度/缓冲/播放态的重建全部
    // 走 `ValueListenableBuilder`，这里不再整页 setState（AGENTS.md §5.5）。
    final episode = _episode;
    final controller = _controller;
    if (episode == null) {
      setState(() {
        _loading = false;
        _error = '没有可播放的剧集';
        _controlsVisible = true;
      });
      _focusError();
      return;
    }
    if (controller == null) {
      setState(() {
        _loading = false;
        _error = '播放器尚未初始化';
        _controlsVisible = true;
      });
      _focusError();
      return;
    }

    final token = ++_requestToken;
    _resolvedMedia = null;
    _danmaku = [];
    // 弹幕自动匹配：按归一化片名 + 集号试探弹幕站模板，记忆命中免网络；
    // 失败静默，用户仍可手动导入（选集面板扫码入口）。
    _autoMatchDanmaku(episode, token).ignore();
    _hideTimer?.cancel();
    final previous = _video;
    _video = null;
    previous
      ?..removeListener(_onVideoStateChanged)
      ..removeListener(_onVideoTick)
      ..close();
    _lastSavedPosition = 0;
    setState(() {
      _loading = true;
      _error = null;
      _errorVisible = false;
      _controlsVisible = false;
      _handledEnd = false;
    });
    if (_isCurrentRoute &&
        !_episodesOpen &&
        !_optionsOpen &&
        _castDevice == null) {
      _focus.root.requestFocus();
    }
    var stage = '站点取址';
    try {
      final spider = controller.siteApi.usesPluginPlayback(widget.site)
          ? await controller.siteApi.spiderPlay(
              widget.site,
              _line?.name ?? '',
              episode.url,
              controller.config.flags,
            )
          : null;
      if (!mounted || token != _requestToken) return;
      final headersForPlayback = {...widget.site.headers, ...?spider?.headers};
      stage = '线路解析';
      final resolved = spider != null && spider.sniff && _selectedParse == null
          ? await controller.playResolver.sniffPage(
              spider.url,
              headersForPlayback,
            )
          : spider != null && !spider.parse && _selectedParse == null
          ? ResolvedPlayUrl(url: spider.url, headers: headersForPlayback)
          : await controller.playResolver.resolve(
              spider?.url ?? episode.url,
              parses: controller.config.parses,
              headers: headersForPlayback,
              selectedParse: _selectedParse,
              forceParse:
                  spider?.parse ??
                  controller.config.flags.contains(_line?.name),
              flag: _line?.name ?? '',
              bindProxy: widget.site.isSpider
                  ? (url) =>
                        controller.siteApi.bindSpiderProxy(widget.site, url)
                  : null,
            );
      if (!mounted || token != _requestToken) return;
      final headers = <String, String>{
        if (resolved.headers.isNotEmpty) ...resolved.headers,
      };
      headers.putIfAbsent('User-Agent', () => 'okhttp/3.15');
      _resolvedMedia = ResolvedPlayUrl(url: resolved.url, headers: headers);
      // 网络策略（代理/DoH）在工厂内接入：改写 URL 或 mpv http-proxy。
      // `_resolvedMedia` 保留原始直链供外部播放器使用。
      stage = controller.useMediaKit ? 'mpv 初始化' : '播放器初始化';
      final PlayerBackend video = await createPlayerBackend(
        useMediaKit: controller.useMediaKit,
        url: resolved.url,
        headers: headers,
      );
      if (!mounted || token != _requestToken) {
        await video.close();
        return;
      }
      _video = video;
      // 位置 / 缓冲 / 播放态的监听一律走 ValueListenableBuilder 的局部重建，
      // 只有解码失败这种需要换整屏状态的事才回到 setState（AGENTS.md §5.5）。
      video.addListener(_onVideoStateChanged);
      await video.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || token != _requestToken) {
        await video.close();
        return;
      }
      video.addListener(_onVideoTick);
      stage = '启动播放';
      await video.setLooping(false);
      await video.setPlaybackSpeed(controller.playbackSpeed);
      final historyStart = _skip.startPosition(
        _startPositionMs,
        video.value.duration.inMilliseconds,
      );
      // 后台会话恢复：进程被杀时的位置可能比历史记忆新，同 url 且较新才采用。
      // 仅在开启「后台继续播放」时尝试（未开启时恢复无意义，且测试/桌面
      // 环境没有原生通道，restore 的原生兜底分支不应被触发）。
      final start = await _resumePositionMs(resolved.url, historyStart);
      if (start > 0) {
        await video.seekTo(Duration(milliseconds: start));
      }
      if (controller.autoPlay) await video.play();
      _bgStart(
        resolved.url,
        '${widget.vod.name} · ${episode.name}',
        video.value,
      ).ignore();
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _controlsVisible = true;
      });
      _focusPlay();
      _scheduleHide();
      await _saveHistory();
    } catch (error) {
      if (!mounted || token != _requestToken) return;
      final failed = _video;
      _video = null;
      failed
        ?..removeListener(_onVideoStateChanged)
        ..removeListener(_onVideoTick)
        ..close();
      setState(() {
        _loading = false;
        _error = '$stage · ${_friendlyPlayError(error)}';
        // 与解码失败路径对齐，挂载错误层后由 _focusError 聚焦「重试」。
        _controlsVisible = true;
      });
      _focusError();
    }
  }

  String _friendlyPlayError(Object error) {
    return friendlyPlaybackError(error);
  }

  void _focusError() {
    _hideTimer?.cancel();
    _errorVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _errorVisible &&
          !_episodesOpen &&
          !_optionsOpen &&
          _castDevice == null &&
          _isCurrentRoute &&
          (!_errorScope.hasFocus || _errorScope.hasPrimaryFocus) &&
          _retryFocus.context != null &&
          _retryFocus.canRequestFocus) {
        _retryFocus.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _dismissError() {
    setState(() {
      _errorVisible = false;
      _controlsVisible = false;
    });
    _focus.root.requestFocus();
  }

  /// 子路由（字幕/弹幕扫码、投屏面板、倍速等 sheet）返回后重投焦点。
  ///
  /// sheet 类覆盖层（showTvSheet）在 pop 后会自己还焦触发键（微任务里
  /// 执行，晚于本回调），所以这里只同步收根兜底；帧末再检查一次——若
  /// 焦点仍停在页面根（没有覆盖层还焦的其它子路由），按状态机收归：
  /// 控制层可见 → 播放键；隐藏 → 页面根（AGENTS.md §3 规则 9）。
  @override
  void didPopNext() {
    _routeCovered = false;
    if (!mounted || !_isCurrentRoute || _episodesOpen || _optionsOpen) {
      return;
    }
    if (_errorVisible) {
      _focusError();
      return;
    }
    if (_castDevice != null) {
      // 投屏时控制层被 ExcludeFocus 排除，焦点交给投屏面板自己的作用域。
      _castScope.requestFocus();
      return;
    }
    _focus.root.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrentRoute) return;
      if (_errorVisible || _castDevice != null) return;
      final primary = FocusManager.instance.primaryFocus;
      // 已被覆盖层还焦（primary 是活着的别的节点）→ 不抢；primary 为空
      // 或挂在已销毁的路由节点上（context == null）都算「没人还焦」。
      if (primary != null &&
          primary != _focus.root &&
          primary.context != null) {
        return;
      }
      if (_controlsVisible && !_episodesOpen && !_loading) {
        if (_focus.play.canRequestFocus) {
          _focus.play.requestFocus();
        } else {
          _focus.root.requestFocus();
        }
      }
      if (_controlsVisible) _scheduleHide();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _buildVideo(PlayerBackend video) {
    final scale = _controller!.playbackScale;
    final ratio = switch (scale) {
      PlaybackScale.wide => 16 / 9,
      PlaybackScale.classic => 4 / 3,
      _ => video.value.aspectRatio > 0 ? video.value.aspectRatio : 16 / 9,
    };
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: switch (scale) {
            PlaybackScale.cover => BoxFit.cover,
            PlaybackScale.stretch => BoxFit.fill,
            _ => BoxFit.contain,
          },
          child: SizedBox(
            width: ratio * 720,
            height: 720,
            child: video.buildVideo(context),
          ),
        ),
      ),
    );
  }

  Future<void> _chooseOption<T>(
    String title,
    List<T> values,
    String Function(T) label,
    Future<void> Function(T) apply,
  ) async {
    _hideTimer?.cancel();
    _optionsOpen = true;
    final selected = await showTvSheet<T>(
      context,
      title: title,
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        return ListView.separated(
          padding: EdgeInsets.all(skin.spaceLg),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          itemCount: values.length,
          separatorBuilder: (_, _) => SizedBox(height: skin.spaceSm),
          itemBuilder: (_, index) => TvFocusable(
            autofocus: index == 0,
            semanticLabel: label(values[index]),
            onTap: () => Navigator.pop(sheetContext, values[index]),
            child: Padding(
              padding: EdgeInsets.all(skin.spaceMd),
              // 侧栏压在视频上，前景恒白。
              child: Text(
                label(values[index]),
                style: AppText.of(sheetContext).bodyLarge
                    .copyWith(color: Colors.white),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    _optionsOpen = false;
    if (selected != null) await apply(selected);
    if (!mounted) return;
    if (_errorVisible) _focusError();
    _scheduleHide();
  }

  Future<void> _chooseSkip() => _chooseOption<int>(
    '片头片尾 · 本剧保存',
    const [0, 1, 2],
    (action) => switch (action) {
      0 => '片头到此（已设 ${_skip.introMs ~/ 1000} 秒）',
      1 => '片尾从此（已设 ${_skip.outroMs ~/ 1000} 秒）',
      _ => '清除本剧跳过点',
    },
    (action) async {
      final value = _video?.value;
      if (value == null || !value.isInitialized) return;
      final intro = action == 0 ? value.position.inMilliseconds : _skip.introMs;
      final outro = action == 1
          ? (value.duration - value.position).inMilliseconds
          : _skip.outroMs;
      if (action != 2 &&
          (intro < 0 ||
              outro < 0 ||
              intro > 600000 ||
              outro > 600000 ||
              intro + outro >= value.duration.inMilliseconds)) {
        showAppSnack(context, '跳过点无效，请在片头结束或片尾开始时设置（单段不超过10分钟）');
        return;
      }
      _skip = action == 2
          ? const SkipPreference()
          : SkipPreference(introMs: intro, outroMs: outro);
      await SkipPreferences(_controller!.storage)
          .save(widget.site.key, widget.vod.id, _skip);
      if (mounted) {
        showAppSnack(context, action == 2 ? '已清除本剧跳过点' : '已保存，下次播放或换集生效');
      }
    },
  );

  Future<void> _openExternal() async {
    final media = _resolvedMedia;
    if (media == null) return;
    try {
      final opened = await AndroidPlayback.openExternal(
        media.url,
        media.headers,
        widget.vod.name,
        _video?.value.position.inMilliseconds ?? 0,
      );
      if (opened) {
        await _video?.pause();
      } else if (mounted) {
        showAppSnack(context, '未找到外部播放器，请先安装支持视频的应用');
      }
    } catch (_) {
      if (mounted) showAppSnack(context, '外部播放器不可用，请使用内置播放');
    }
  }

  // ———————— DLNA 投屏（设备发现弹窗 + 投屏中控制面板）———————

  /// 选集面板「投屏」入口：打开设备选择弹窗（发现/连接由弹窗负责），
  /// 选中设备后 [showCastDialog] 已完成 SetAVTransportURI → Seek → Play。
  Future<void> _castOpenDevices() async {
    final media = _resolvedMedia;
    final video = _video;
    if (media == null || video == null || !video.value.isInitialized) {
      showAppSnack(context, '视频尚未就绪，请稍后再试投屏');
      return;
    }
    _hideTimer?.cancel();
    _optionsOpen = true;
    try {
      final device = await showCastDialog(
        context,
        target: CastTarget(
          url: media.url,
          title: widget.vod.name,
          positionMs: video.value.position.inMilliseconds,
        ),
        returnFocus: _castTrigger,
      );
      if (!mounted) return;
      if (device != null) {
        await _castBegin(device);
        return;
      }
    } finally {
      _optionsOpen = false;
    }
    if (!mounted) return;
    _scheduleHide();
  }

  /// 投屏开始：本机让位（暂停 + 压住控制层 + 关选集面板），焦点交给
  /// [CastControlPanel]（其首项 autofocus 接管，无需手动投焦）。
  Future<void> _castBegin(DlnaDevice device) async {
    final control = DlnaControl();
    await _video?.pause();
    if (!mounted) return;
    _focus.focusBeforePanel = null;
    _hideTimer?.cancel();
    setState(() {
      _castDevice = device;
      _castControl = control;
      _castPositionMs = _video?.value.position.inMilliseconds ?? 0;
      _castPlaying = true;
      _episodesOpen = false;
      _controlsVisible = false;
    });
  }

  /// 投屏中媒体播放/暂停键兜底（焦点意外不在面板时从页面根转发）。
  Future<void> _castTogglePlay() async {
    final control = _castControl;
    final device = _castDevice;
    if (control == null || device == null) return;
    final next = !_castPlaying;
    _castPlaying = next;
    try {
      if (next) {
        await control.play(device);
      } else {
        await control.pause(device);
      }
    } catch (_) {
      _castPlaying = !next;
    }
  }

  /// 向设备发 Stop 并清空投屏状态（设备已离线时失败不影响本地恢复）。
  Future<void> _castStopRemote() async {
    final control = _castControl;
    final device = _castDevice;
    _castControl = null;
    _castDevice = null;
    if (control == null || device == null) return;
    try {
      await control.stop(device);
    } catch (_) {}
  }

  /// 回到本机播放：结束投屏并按投屏进度续播（面板 onExitLocal / 返回键）。
  Future<void> _castExitLocal() async {
    if (_castDevice == null) return;
    final resumeMs = _castPositionMs;
    await _castStopRemote();
    if (!mounted) return;
    final video = _video;
    if (video != null && video.value.isInitialized) {
      try {
        await video.seekTo(Duration(milliseconds: resumeMs));
        await video.play();
      } catch (_) {}
    }
    setState(() => _controlsVisible = true);
    _focusPlay();
    _scheduleHide();
    await _saveHistory();
  }

  /// 结束投屏：本机保持暂停，焦点回本机控制层（面板「结束投屏」）。
  Future<void> _castStopped() async {
    if (_castDevice == null) return;
    await _castStopRemote();
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _focusPlay();
    await _saveHistory();
  }

  Future<void> _enterPip() async {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    _pip = true;
    try {
      final entered = await AndroidPlayback.enterPip(video.value.aspectRatio);
      if (!mounted) return;
      _pip = entered;
      if (entered) {
        _closeEpisodes();
        _hideControls();
      } else {
        showAppSnack(context, '当前设备不支持画中画');
      }
    } catch (_) {
      _pip = false;
      if (mounted) showAppSnack(context, '当前设备无法进入画中画');
    }
  }

  Future<void> _chooseParse() => _chooseOption<int>(
    '解析源',
    [-1, ...List.generate(_controller!.config.parses.length, (i) => i)],
    (index) => index == -1 ? '自动选择' : _controller!.config.parses[index].name,
    (index) async {
      final position = _video?.value.position.inMilliseconds ?? 0;
      _selectedParse = index == -1 ? null : _controller!.config.parses[index];
      await _prepare(startPositionMs: position);
    },
  );

  Future<void> _chooseTracks(bool subtitles) async {
    final video = _video;
    if (video is! MediaKitBackend) {
      showAppSnack(context, '请在设置 → 播放中启用字幕与音轨增强内核');
      return;
    }
    final tracks = subtitles ? video.subtitleTracks : video.audioTracks;
    await _chooseOption<PlaybackTrack>(
      subtitles ? '字幕' : '音轨',
      tracks,
      (track) => track.label,
      (track) async {
        if (subtitles) {
          await video.selectSubtitle(track.id);
        } else {
          await video.selectAudio(track.id);
        }
      },
    );
  }

  Future<void> _externalSubtitle() async {
    final video = _video;
    if (video is! MediaKitBackend) return;
    _hideTimer?.cancel();
    _optionsOpen = true;
    String? subtitleUrl;
    var dialogOpen = false;
    final server = ConfigUrlServer(
      onUrl: (url) {
        subtitleUrl = url;
        if (mounted && dialogOpen) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      },
    );
    try {
      final address = await server.start();
      if (!mounted) return;
      dialogOpen = true;
      await showConfigUrlDialog(context, address, '扫码添加字幕地址');
      dialogOpen = false;
      if (subtitleUrl != null && mounted && identical(video, _video)) {
        await video.loadSubtitle(subtitleUrl!);
      }
    } catch (_) {
      if (mounted) showAppSnack(context, '字幕加载失败，请检查字幕地址', error: true);
    } finally {
      await server.stop();
      _optionsOpen = false;
      if (mounted) _scheduleHide();
    }
  }

  Future<void> _danmakuOptions() => _chooseOption<int>(
    '弹幕',
    const [0, 1, 2, 3],
    (action) => switch (action) {
      0 => '扫码导入 XML / JSON 弹幕',
      1 => _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
      2 => '透明度 ${(_danmakuOpacity * 100).round()}%（点击切换）',
      _ => _danmakuLarge ? '字号：大（点击切换）' : '字号：标准（点击切换）',
    },
    (action) async {
      if (action != 0) {
        setState(() {
          if (action == 1) _danmakuEnabled = !_danmakuEnabled;
          if (action == 2) {
            _danmakuOpacity = _danmakuOpacity == 0.8
                ? 0.5
                : _danmakuOpacity == 0.5
                ? 1
                : 0.8;
          }
          if (action == 3) _danmakuLarge = !_danmakuLarge;
        });
        return;
      }
      String? received;
      var open = false;
      final token = _requestToken;
      final server = ConfigUrlServer(
        onUrl: (url) {
          received = url;
          if (mounted && open) {
            open = false;
            Navigator.of(context, rootNavigator: true).pop();
          }
        },
      );
      try {
        final address = await server.start();
        if (!mounted) return;
        _optionsOpen = true;
        open = true;
        await showConfigUrlDialog(context, address, '扫码输入弹幕 XML / JSON 地址');
        open = false;
        if (received == null) return;
        final comments = await DanmakuService().load(received!);
        if (!mounted || token != _requestToken) return;
        await DanmakuStore(_controller!.storage).remember(
          widget.site.key,
          widget.vod.id,
          parseEpisode(_episode?.name ?? ''),
          received!,
        );
        if (!mounted || token != _requestToken) return;
        setState(() {
          _danmaku = comments;
          _danmakuEnabled = true;
        });
        showAppSnack(context, '已加载 ${comments.length} 条弹幕');
      } catch (_) {
        if (mounted) {
          showAppSnack(context, '弹幕加载失败，请检查 XML / JSON 地址', error: true);
        }
      } finally {
        await server.stop();
        _optionsOpen = false;
      }
    },
  );

  /// 控制器级监听：只处理「必须整屏换状态」的事件（解码失败），进度与缓冲
  /// 交给 `video` 的 [ValueListenableBuilder] 局部重建，这里绝不整页 setState。
  void _onVideoStateChanged() {
    final video = _video;
    if (video == null || !mounted) return;
    if (video.value.hasError && _error == null) {
      _hideTimer?.cancel();
      setState(() {
        _loading = false;
        _error = friendlyPlaybackError(video.value.errorDescription ?? '');
        _controlsVisible = true;
      });
      _focusError();
      return;
    }
    // 播放已经恢复（重新缓冲成功 / 换线路后正常起播）时清掉上一次的错误。
    // 否则 `_error != null` 会让控制层一直被 ExcludeFocus 排除：
    // 画面在播、控制层可见，但方向键/OK 都落不到任何按钮（真机丢焦点）。
    if (!video.value.hasError &&
        _error != null &&
        video.value.isInitialized &&
        (video.value.isPlaying || video.value.position > Duration.zero)) {
      setState(() {
        _error = null;
        _errorVisible = false;
      });
      if (_controlsVisible) _focusPlay();
    }
  }

  // ———————— 长驻后台播放（前台服务 + 媒体通知）———————

  /// 原生动作回放：通知栏播放/暂停、音频焦点丢失 → 本机播放器；
  /// 停止 → 撤会话。动作发起在原生、状态回归在本页。
  void _handleBackgroundAction(String action) {
    if (!mounted) return;
    final video = _video;
    if (video == null) return;
    if (action == 'play' && !video.value.isPlaying) {
      video.play();
    } else if (action == 'pause' || action == 'audioFocusLost') {
      if (video.value.isPlaying) video.pause();
    } else if (action == 'stop') {
      video.pause();
      _bgStop();
      _hideControls();
    }
    if (action != 'stop') _bgSync().ignore();
  }

  /// 起播后拉起前台服务 + 媒体通知；通道异常（桌面/测试环境无原生）静默。
  Future<void> _bgStart(
    String url,
    String title,
    VideoPlayerValue value,
  ) async {
    if (_controller?.backgroundPlayback != true ||
        defaultTargetPlatform != TargetPlatform.android ||
        !mounted) {
      return;
    }
    try {
      await _bg.start(
        url: url,
        title: title,
        positionMs: value.position.inMilliseconds,
        playing: value.isPlaying,
      );
    } catch (_) {
      // 非 Android 或测试环境无原生通道：后台服务不可用但不阻断播放。
    }
  }

  /// 播放态/进度同步给前台服务通知（与历史落盘同节流，不整页重建）。
  Future<void> _bgSync() async {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    try {
      await _bg.update(
        playing: video.value.isPlaying,
        positionMs: video.value.position.inMilliseconds,
      );
    } catch (_) {}
  }

  /// 退出播放时停服务 + 撤通知 + 清持久化（通道异常静默）。
  void _bgStop() {
    _bg.stop().catchError((Object _) {});
  }

  /// 后台会话位置：同 url 且比历史记忆新才采用，避免回退进度。
  Future<int> _resumePositionMs(String url, int historyStart) async {
    if (_controller?.backgroundPlayback != true) return historyStart;
    try {
      final state = await _bg.restore().timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      if (state != null &&
          state.url == url &&
          state.positionMs > 5000 &&
          state.positionMs > historyStart) {
        return state.positionMs;
      }
    } catch (_) {}
    return historyStart;
  }

  // ———————— 弹幕自动匹配（片名归一化 + 集号 + 模板试探 + 记忆）———————

  /// 进播时自动匹配当前集弹幕；未配置弹幕站或失败均静默。
  Future<void> _autoMatchDanmaku(Episode episode, int token) async {
    final controller = _controller;
    if (controller == null || !controller.danmakuAutoMatch) {
      return;
    }
    if (controller.danmakuBaseUrl.trim().isEmpty) {
      final cached = await DanmakuStore(controller.storage)
          .lookup(widget.site.key, widget.vod.id, parseEpisode(episode.name));
      if (cached == null) return;
    }
    try {
      final result =
          await DanmakuMatcher(
            store: DanmakuStore(controller.storage),
            baseUrl: controller.danmakuBaseUrl,
          ).match(
            title: widget.vod.name,
            episode: parseEpisode(episode.name),
            season: parseSeason(widget.vod.name),
            siteKey: widget.site.key,
            vodId: widget.vod.id,
          );
      if (!mounted || token != _requestToken || !result.matched) return;
      final comments = await DanmakuService().load(result.url!);
      if (!mounted || token != _requestToken) return;
      setState(() {
        _danmaku = comments;
        if (comments.isNotEmpty) _danmakuEnabled = true;
      });
    } catch (_) {
      // 自动匹配失败不阻断播放：手动导入入口仍在选集面板。
    }
  }

  /// 时间轴监听：只做节流的历史记忆与自动下一集判断，不做任何 UI 重建。
  void _onVideoTick() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    final position = video.value.position.inMilliseconds;
    final duration = video.value.duration.inMilliseconds;
    // 写盘节流（P0-6 / AGENTS.md §5.5）：只有「距上次保存 ≥15s 且位置变化
    // ≥1%（下限 1s）」才落盘，避免原来每 5s 全量重写历史。暂停/退出/切线路/
    // 播完等关键节点仍会强制保存一次（见 `_togglePlay`/`dispose`/`_switchEpisode`）。
    final now = DateTime.now().millisecondsSinceEpoch;
    final deltaMs = (position - _lastSavedPosition).abs();
    final pct = duration > 0 ? (duration * 0.01).round() : 0;
    final minDelta = pct < 1000 ? 1000 : pct;
    if (now - _lastSavedAt >= 15000 && deltaMs >= minDelta) {
      _lastSavedPosition = position;
      _lastSavedAt = now;
      _saveHistory();
      // 与历史落盘同节流：顺带刷新前台服务通知的位置。
      _bgSync().ignore();
    }
    if (!_handledEnd &&
        video.value.duration > Duration.zero &&
        (position >= duration - 500 ||
            (video.value.isPlaying &&
                _skip.reachesOutro(position, duration)))) {
      _handledEnd = true;
      _onEpisodeEnded();
    }
  }

  Future<void> _onEpisodeEnded() async {
    final controller = _controller;
    if (controller?.autoNext == true && _hasNextEpisode) {
      await _saveHistory();
      await _prepare(lineIndex: _lineIndex, episodeIndex: _episodeIndex + 1);
      return;
    }
    if (mounted) {
      await _video?.pause();
      if (!mounted) return;
      setState(() => _controlsVisible = true);
      _focusPlay();
    }
  }

  bool get _hasNextEpisode {
    final line = _line;
    if (line == null) return false;
    return _episodeIndex + 1 < line.episodes.length;
  }

  bool get _hasPreviousEpisode => _episodeIndex > 0;

  void _scheduleHide() {
    _hideTimer?.cancel();
    final video = _video;
    if (video == null ||
        !video.value.isPlaying ||
        _castDevice != null ||
        _episodesOpen ||
        _optionsOpen ||
        _error != null ||
        !_controlsVisible ||
        !_isCurrentRoute) {
      return;
    }
    _hideTimer = Timer(kControlsAutoHide, () {
      if (mounted &&
          _isCurrentRoute &&
          !_episodesOpen &&
          !_optionsOpen &&
          _castDevice == null &&
          _error == null &&
          !_loading) {
        _hideControls();
      }
    });
  }

  /// 硬件级唤醒兜底：控制层隐藏后，若焦点落到被本页盖住的下一路由节点上
  /// （「焦点在暗处」），方向键根本送不到 `_focus.root._handleKey`，控制层
  /// 永远唤不醒（真机复现：播放器内连按方向键控制层不醒）。这里直接订阅
  /// 全局硬件键盘流。控制层隐藏时唤醒它，错误层丢焦时恢复「重试」焦点。
  /// 选集面板或弹窗打开时由各自的焦点作用域处理（AGENTS.md §3 规则 3）。
  bool _rawKeyWake(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted ||
        !_isCurrentRoute ||
        _castDevice != null ||
        _episodesOpen ||
        _optionsOpen ||
        _loading) {
      return false;
    }
    final key = event.logicalKey;
    if (_error != null) {
      // 焦点已经在错误按钮上时，交给按钮处理，避免方向键反复跳回「重试」。
      if (_errorScope.hasFocus && !_errorScope.hasPrimaryFocus) return false;
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _showControls();
        return true;
      }
      return false;
    }
    if (_controlsVisible) return false;
    // 返回键交给页面/路由；媒体键仍执行播放操作，不被唤醒兜底吞掉。
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return true;
    }
    _showControls();
    return true;
  }

  void _hideControls() {
    if (!_isCurrentRoute) return;
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
    // 所有隐藏入口都在 ExcludeFocus 生效前归还根节点，避免焦点落到下层路由。
    _focus.root.requestFocus();
  }

  void _showControls() {
    // 投屏中控制层被投屏面板接管，唤醒播放控制会抢走面板焦点、方向键被吞。
    if (_castDevice != null) return;
    if (_error != null) {
      setState(() => _controlsVisible = true);
      _focusError();
      return;
    }
    if (!_controlsVisible) {
      // 唤醒的第一帧就把焦点移到播放/暂停按钮（AGENTS.md §3 规则 4）：
      // 控制层隐藏时整棵子树被 ExcludeFocus 排除，不接管焦点的话
      // 焦点会停在页面根，方向键与 OK 都落不到控件上。
      setState(() => _controlsVisible = true);
      _focusPlay();
    } else {
      setState(() => _controlsVisible = true);
      // 已经可见但焦点掉在页面根（抢焦失败 / 错误恢复瞬间）也收回来。
      final primary = FocusManager.instance.primaryFocus;
      if (_error == null &&
          (primary == null || primary == _focus.root || !primary.hasFocus)) {
        _focusPlay();
      }
    }
    _scheduleHide();
  }

  /// 把焦点显式移到播放/暂停按钮（控制层可见态的默认落点）。控制层刚被
  /// 挂回/解除 `ExcludeFocus` 时节点可能还没进焦点树，所以走
  /// [PlayerFocusNodes.focusPlayAfterFrame] 等一帧再请求。
  void _focusPlay() => _focus.focusPlayAfterFrame(
    allow: () =>
        mounted &&
        _controlsVisible &&
        !_episodesOpen &&
        !_optionsOpen &&
        !_loading &&
        _error == null &&
        _castDevice == null &&
        _isCurrentRoute,
  );

  void _openEpisodes() {
    // AGENTS.md §3 规则 3：关闭侧栏后焦点回到触发按钮，而不是页面根。
    _focus.focusBeforePanel ??= FocusManager.instance.primaryFocus;
    setState(() {
      _episodesOpen = true;
      _controlsVisible = true;
    });
    _hideTimer?.cancel();
    _focusPanel();
  }

  void _closeEpisodes() {
    setState(() => _episodesOpen = false);
    if (_error != null) {
      _focusError();
      return;
    }
    _restorePanelFocus();
    _scheduleHide();
  }

  /// 焦点归还：优先给开面板前的落点，拿不到就退回「选集」触发按钮，
  /// 最后才是页面根（AGENTS.md §3 规则 3）。`_switchEpisode` 也走这条路，
  /// 但它在 `await _prepare` 之后才调用，避免节点悬在隐藏的控制层上。
  /// 统一走 [PlayerFocusNodes.restorePanelFocusAfterFrame]（帧后执行：
  /// 等面板撤下且控制层的 ExcludeFocus 恢复）。
  void _restorePanelFocus() => _focus.restorePanelFocusAfterFrame(
    allow: () =>
        mounted &&
        _controlsVisible &&
        !_episodesOpen &&
        !_optionsOpen &&
        !_loading &&
        _error == null &&
        _castDevice == null &&
        _isCurrentRoute,
  );

  void _toggleControls() {
    if (_episodesOpen) {
      _closeEpisodes();
      return;
    }
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  Future<void> _togglePlay() async {
    if (_error != null) {
      _showControls();
      return;
    }
    final video = _video;
    if (video == null) return;
    if (video.value.isPlaying) {
      await video.pause();
      _hideTimer?.cancel();
      // 暂停是「强制保存」节点（P0-6）：立即落盘一次进度，而不是等节流。
      await _saveHistory();
    } else {
      await video.play();
      _scheduleHide();
    }
    // 播放/暂停图标走 video 的监听局部重建，这里不再整页 setState。
    _bgSync().ignore();
    if (mounted) _showControls();
  }

  Future<void> _seekRelative(int seconds) async {
    final video = _video;
    if (video == null) return;
    final target = video.value.position + Duration(seconds: seconds);
    await video.seekTo(target);
    _showControls();
  }

  Future<void> _seekTo(double ms) async {
    final video = _video;
    if (video == null) return;
    await video.seekTo(Duration(milliseconds: ms.round()));
    _showControls();
  }

  Future<void> _switchEpisode(int lineIndex, int episodeIndex) async {
    await _saveHistory();
    // 换集可能是从错误层的「换线路/下一集」进来的，此时控制层没获焦，
    // `primaryFocus` 多半是页面根，直接用它会让焦点落到根而不是触发按钮。
    // 所以只在「选集面板当时确实开着」时才记录来源焦点。
    if (_episodesOpen) {
      _focus.focusBeforePanel ??= FocusManager.instance.primaryFocus;
    }
    setState(() => _episodesOpen = false);
    // `_prepare` 里有 await，且会把 `_controlsVisible` 置为 false；此刻立刻
    // requestFocus 会让刚获焦的列表项悬空。等画面就绪、控制层回来之后再
    // 归还焦点（AGENTS.md §3 规则 3 + 任务 5）。
    await _prepare(lineIndex: lineIndex, episodeIndex: episodeIndex);
    if (!mounted) return;
    // 只有「面板当时开着」才记了来源焦点；从错误层进来时没记，此时焦点本来
    // 就不在控制层上，别硬塞回触发按钮（会抢掉错误层按钮的焦点）。
    if (_focus.focusBeforePanel != null) {
      _restorePanelFocus();
    }
    _scheduleHide();
  }

  Future<void> _saveHistory() async {
    // 历史写入失败不能影响播放本身（例如存储不可用时，_prepare 不应把它当播放失败）。
    try {
      final video = _video;
      final episode = _episode;
      final line = _line;
      final library = _library;
      if (library == null || episode == null || line == null) return;
      final durationMs = video?.value.duration.inMilliseconds ?? 0;
      final positionMs = video?.value.position.inMilliseconds ?? 0;
      if (durationMs > 0 && positionMs > durationMs - 1000) return;
      // 记录本次保存的位置与时间，作为 `_onVideoTick` 节流的基线。
      _lastSavedPosition = positionMs;
      _lastSavedAt = DateTime.now().millisecondsSinceEpoch;
      await library.addHistory(
        HistoryEntry(
          vod: widget.vod.copyWith(lines: const []),
          sourceKey: widget.site.key,
          sourceName: widget.site.name,
          lineName: line.name,
          lineIndex: _lineIndex,
          episodeName: episode.name,
          episodeUrl: episode.url,
          episodeIndex: _episodeIndex,
          positionMs: positionMs,
          durationMs: durationMs,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      // 保存失败忽略：播放流程继续。
    }
  }

  Future<void> _toggleFavorite() async {
    final library = _library;
    if (library == null) return;
    final added = await library.toggleFavorite(widget.vod);
    if (!mounted) return;
    showAppSnack(context, added ? '已加入收藏' : '已取消收藏');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _hideTimer?.cancel();
      if (!_pip && _controller?.backgroundPlayback != true) {
        _video?.pause();
        // 未开后台播放：离开即停服务，撤通知并清会话持久化。
        _bgStop();
      }
      _saveHistory();
    }
    if (state == AppLifecycleState.resumed) {
      if (!_isCurrentRoute) return;
      if (_pip) {
        _pip = false;
        _showControls();
      }
      // 回到前台时若焦点掉在页面根，把焦点收回播放键（避免「能用但按键没反应」）。
      if (_controlsVisible && _error == null && _errorVisible == false) {
        final primary = FocusManager.instance.primaryFocus;
        if (primary == null || primary == _focus.root || !primary.hasFocus) {
          _focusPlay();
        }
      }
    }
  }

  @override
  void dispose() {
    kRouteObserver.unsubscribe(this);
    _clockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_rawKeyWake);
    _focus.dispose();
    for (final node in [
      ..._toolNodes.values,
      ..._panelLineNodes.values,
      ..._extraNodes.values,
    ]) {
      node.dispose();
    }
    _castScope.dispose();
    _retryFocus.dispose();
    _errorScope.dispose();
    _castTrigger.dispose();
    // 投屏中退出页面：向设备发 Stop 防黑屏挂着（异步失败忽略）。
    final castDevice = _castDevice;
    if (castDevice != null) {
      _castControl?.stop(castDevice).ignore();
    }
    _castDevice = null;
    _castControl = null;
    // 动作回调解绑防泄漏 + 后台会话收尾（撤通知、清持久化）。
    BackgroundPlayback.onAction = null;
    _bgStop();
    _saveHistory();
    _hideTimer?.cancel();
    _video
      ?..removeListener(_onVideoStateChanged)
      ..removeListener(_onVideoTick)
      ..close();
    _leaveFullscreen();
    super.dispose();
  }

  /// 控制层顶行（返回/倍速/画面比例）的方向键：UP = 回画面（隐藏控制层，
  /// 「控制层可见 → 隐藏」的显式上行出口，与「任意方向键唤醒」互逆）；
  /// DOWN = 进中部播放胶囊（默认落播放/暂停键）。LEFT/RIGHT 行内走几何。
  KeyEventResult _handlePlayerTopRowKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _hideControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focus.play.canRequestFocus) _focus.play.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 控制层功能行（上一集/下一集/选集/收藏，页面最下沿）的方向键：
  /// DOWN = 回画面（隐藏控制层，「控制层可见 → 隐藏」的显式下行出口）。
  /// UP 放行几何（回进度行）；LEFT/RIGHT 行内走几何。
  KeyEventResult _handlePlayerBottomRowKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _hideControls();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // 面板开着时焦点被关在面板作用域里（`_focus.panelScope`），方向键只会在这棵子树
    // 里走，页面根收不到——这里不用特判。
    //
    // 返回键语义优先级链（AGENTS.md §3 硬性规则 5）：选集面板 → 关面板；
    // 否则控制层可见 → 只隐藏控制层（不是退出页面）；否则 → `Navigator.maybePop`。
    // escape 与 `PopScope` 不重复处理：遥控器返回键走 `onPopInvokedWithResult`
    // （`canPop:false` 时页面不退出、只关面板），escape 只在这里兜底。
    if (key == LogicalKeyboardKey.escape) {
      if (_castDevice != null) {
        // 投屏中：返回 = 结束投屏并回到本机续播。面板自身也拦 escape，
        // 这里兜底焦点意外飘出面板的情况。
        _castExitLocal();
        return KeyEventResult.handled;
      }
      if (_episodesOpen) {
        // 统一走清理方法，别绕过焦点归还与 `_scheduleHide`（AGENTS.md §3）。
        _closeEpisodes();
        return KeyEventResult.handled;
      }
      if (_errorVisible) {
        _dismissError();
        return KeyEventResult.handled;
      }
      if (_controlsVisible) {
        _hideControls();
        return KeyEventResult.handled;
      }
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }
    // REMOTE-03（a11y P1-1）：遥控器媒体播放/暂停键在控制层隐藏时也必须切换
    // 播放，不能被下面的「唤醒控制层」分支吞掉。投屏中则转发给 DLNA 设备。
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (_castDevice != null) {
        _castTogglePlay();
        return KeyEventResult.handled;
      }
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (_castDevice != null) {
      // 投屏中方向键留给投屏面板，不唤醒本机控制层。
      return KeyEventResult.ignored;
    }
    if (!_controlsVisible) {
      // 控制层隐藏时任何方向键都只负责唤醒，唤醒后焦点落在播放/暂停按钮上
      // （§3 硬性规则 4）。这里把按键吞掉，避免「左右键既唤醒又移焦点」。
      _showControls();
      return KeyEventResult.handled;
    }
    _scheduleHide();
    // 控制层可见但焦点掉在页面根（抢焦失败 / 错误恢复瞬间）：方向键与 OK
    // 直接把焦点拉回播放键。必须在 Focus.onKeyEvent 里处理并返回 handled，
    // 否则 HardwareKeyboard 的全局处理器无法阻止焦点遍历把焦点移走。
    final primary = FocusManager.instance.primaryFocus;
    final atRoot =
        primary == null || primary == _focus.root || !primary.hasFocus;
    final isArrow =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (atRoot &&
        _error == null &&
        !_errorVisible &&
        (isArrow ||
            key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter)) {
      if (_focus.play.canRequestFocus) {
        _focus.play.requestFocus();
      } else {
        _focusPlay();
      }
      return KeyEventResult.handled;
    }
    // 左右键语义：焦点在进度条或下方播放操作区时由那些控件自己处理
    // （进度条 ±10s seek、按钮间左右移动），页面根不插手；焦点在顶栏时左右键
    // 正常在顶栏按钮间移动。任何情况下都不会「既 seek 又移焦点」。
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final episode = _episode;
    final line = _line;
    final skin = TvSkin.of(context);
    final library = context.watch<LibraryStore>();
    final favorite = library.isFavorite(widget.vod);
    return PopScope(
      canPop: !_episodesOpen && !_errorVisible && _castDevice == null,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_castDevice != null) {
          // 投屏中系统返回：先结束投屏回本机续播，再按才退页。
          _castExitLocal();
          return;
        }
        if (_episodesOpen) {
          _closeEpisodes();
        } else if (_errorVisible) {
          _dismissError();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus.root,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video != null && video.value.isInitialized)
                _buildVideo(video)
              else
                const ColoredBox(color: Colors.black),
              if (video != null && _danmakuEnabled && _danmaku.isNotEmpty)
                DanmakuOverlay(
                  video: video,
                  comments: _danmaku,
                  opacity: _danmakuOpacity,
                  large: _danmakuLarge,
                ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                ),
              ),
              if (_loading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 38,
                        height: 38,
                        child: CircularProgressIndicator(strokeWidth: 2.6),
                      ),
                      SizedBox(height: skin.spaceMd),
                      Text(
                        episode?.name ?? '正在准备播放…',
                        style: AppText.of(context).bodyStrong.copyWith(
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
              if (video != null)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: video,
                  builder: (context, value, _) {
                    return value.isBuffering && !_loading
                        ? const Center(
                            child: SizedBox(
                              width: 42,
                              height: 42,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            ),
                          )
                        : const SizedBox.shrink();
                  },
                ),
              // 控制层隐藏时整棵子树（顶部返回、下方播放/进度/功能行）
              // 一起退出绘制与命中测试，省 GPU；`ExcludeFocus` 把焦点排除（§3 规则 4）。
              _wrapControls(skin, video, line, episode, favorite),
              if (_castDevice != null)
                // 投屏面板盖住本机控制层（本机已暂停且 _controlsVisible
                // 为 false），焦点由面板首项 autofocus 接管。
                Positioned.fill(
                  child: CastControlPanel(
                    focusScope: _castScope,
                    device: _castDevice!,
                    control: _castControl ?? DlnaControl(),
                    onPositionChanged: (ms) => _castPositionMs = ms,
                    onPlayingChanged: (playing) => _castPlaying = playing,
                    onExitLocal: _castExitLocal,
                    onStopped: _castStopped,
                  ),
                ),
              if (_errorVisible && _castDevice == null)
                ExcludeFocus(
                  excluding: _episodesOpen,
                  child: FocusScope(
                    node: _errorScope,
                    child: _buildError(skin, episode),
                  ),
                ),
              if (_episodesOpen)
                // 面板只在打开时挂进树里：关闭后连同 `FocusScope` 一起销毁，
                // 面板内节点不会留在焦点树里抢方向键（AGENTS.md §3 规则 4）。
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: 640,
                  child: FocusScope(
                    node: _focus.panelScope,
                    child: _buildEpisodePanel(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 控制层显隐包装：统一走 [PlayerControlsLayer]（AnimatedOpacity 淡入
  /// 淡出 + Offstage 省 GPU + ExcludeFocus 焦点排除 + IgnorePointer 命中
  /// 排除，见 player_focus.dart 头注）。排除条件：控制层可见之外的附加
  /// 条件 = 选集面板打开 / 错误层可见（投屏由 `_controlsVisible=false`
  /// 覆盖，与重建前行为一致）。
  Widget _wrapControls(
    TvSkin skin,
    PlayerBackend? video,
    PlayLine? line,
    Episode? episode,
    bool favorite,
  ) {
    return PlayerControlsLayer(
      visible: _controlsVisible,
      focusExcluded: _episodesOpen || _errorVisible,
      child: _buildControls(video, line, episode, favorite),
    );
  }

  /// 皮肤动效时长（`Duration + Duration` 在 Dart 里不是合法组合，
  /// 所以把余量折算成毫秒再加，语义等价于「皮肤时长再稍慢一点」）。
  Duration _panelMotion(Duration base, {int extra = 0}) =>
      playerPanelMotion(context, base, extra: extra);

  /// 控制层主体。进度文本、进度条、播放/暂停图标这些高频变化部件各自包
  /// 独立的 [ValueListenableBuilder]，让播放中 10Hz 的位置更新只重建「进度行」
  /// 和「播放/暂停按钮」两个小块，而不是整棵 60–80 widget 的控制层
  /// （AGENTS.md §5.5 / P0-6 10Hz 整树重建）。
  Widget _buildControls(
    PlayerBackend? video,
    PlayLine? line,
    Episode? episode,
    bool favorite,
  ) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    if (video == null) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(decoration: BoxDecoration(gradient: skin.controlScrim)),
        Positioned(
          left: TvCanvas.detailPad,
          right: TvCanvas.detailPad,
          top: AppSpacing.xl + AppSpacing.md,
          // 顶行 UP → 回画面、DOWN → 播放胶囊（_handlePlayerTopRowKey）；
          // canRequestFocus: false 只挂键监听，不参与焦点。
          child: Focus(
            canRequestFocus: false,
            debugLabel: 'playerTopRow',
            onKeyEvent: _handlePlayerTopRowKey,
            child: Row(
              children: [
                _PlayerControlCapsule(
                  enableBlur: true,
                  child: _PlayerControlButton(
                    icon: Icons.arrow_back_rounded,
                    label: '返回',
                    onTap: () => Navigator.maybePop(context),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.vod.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // 控制层文字硬约束白色：视频亮度不可控，smartisan
                        // 的深色字在画面上读不出来（字号/字重仍跟皮肤）。
                        style: text.section.copyWith(color: Colors.white),
                      ),
                      SizedBox(height: skin.spaceXs - 3),
                      Text(
                        [
                          line?.name,
                          episode?.name,
                        ].where((e) => (e ?? '').isNotEmpty).join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyStrong.copyWith(
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: video,
                        builder: (_, value, _) => Text(
                          '${_clock.hour}:${_clock.minute.toString().padLeft(2, '0')}  ·  ${value.size.width.toInt()}×${value.size.height.toInt()}  ·  ${value.isBuffering ? '正在缓冲' : '播放就绪'}',
                          style: text.label.copyWith(
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      // 流代理启用时视频流有独立统计，显示单流速率/累计；
                      // 未启用时回落到应用整体接收流量，不误导。
                      if (_controlsVisible)
                        StreamProxyServer.enabled
                            ? const NetworkSpeed(mode: NetworkSpeedMode.video)
                            : const NetworkSpeed(),
                    ],
                  ),
                ),
                _PlayerControlCapsule(
                  child: _PlayerControlButton(
                    icon: Icons.speed_rounded,
                    label: '${_controller!.playbackSpeed}×',
                    onTap: () => _chooseOption<double>(
                      '播放倍速',
                      playbackSpeeds,
                      (speed) => '$speed×',
                      (speed) async {
                        try {
                          await _video?.setPlaybackSpeed(speed);
                          await _controller!.setPlaybackSpeed(speed);
                          if (mounted) setState(() {});
                        } catch (_) {
                          if (mounted) {
                            showAppSnack(
                              context,
                              '设备不支持此倍速，请选择其他档位',
                              error: true,
                            );
                          }
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _PlayerControlCapsule(
                  child: _PlayerControlButton(
                    icon: Icons.aspect_ratio_rounded,
                    label: _controller!.playbackScale.label,
                    onTap: () => _chooseOption<PlaybackScale>(
                      '画面比例',
                      PlaybackScale.values,
                      (scale) => scale.label,
                      (scale) async {
                        await _controller!.setPlaybackScale(scale);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: TvCanvas.detailPad,
          right: TvCanvas.detailPad,
          bottom: AppSpacing.xl + AppSpacing.md,
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: Column(
              children: [
                _PlayerControlCapsule(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _PlayerControlButton(
                        icon: Icons.replay_10_rounded,
                        label: '快退 ${_controller?.seekStepSeconds ?? 10} 秒',
                        onTap: () => _seekRelative(
                          -(_controller?.seekStepSeconds ?? 10),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: video,
                        builder: (context, value, _) => _PlayerControlButton(
                          icon: value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          label: value.isPlaying ? '暂停' : '播放',
                          focusNode: _focus.play,
                          onTap: _togglePlay,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _PlayerControlButton(
                        icon: Icons.forward_10_rounded,
                        label: '快进 ${_controller?.seekStepSeconds ?? 10} 秒',
                        onTap: () =>
                            _seekRelative(_controller?.seekStepSeconds ?? 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // 进度行：position/duration 随播放 10Hz 变化，单独包 VLB，
                // 让高频重建只发生在「时间文本 + 进度条」这一小块上。
                _PlayerControlCapsule(
                  enableBlur: true,
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: video,
                    builder: (context, value, _) {
                      final duration = value.duration;
                      final position = value.position;
                      final maxMs = duration.inMilliseconds
                          .toDouble()
                          .clamp(1.0, double.infinity)
                          .toDouble();
                      final currentMs = position.inMilliseconds
                          .toDouble()
                          .clamp(0.0, maxMs);
                      return Column(
                        children: [
                          TvFocusable(
                            radius: skin.radiusPill,
                            // 全宽轨道缩放会越过 48 安全边距；保留皮肤描边/填充，
                            // 只固定轨道几何，避免时间轴获焦时横向跳动。
                            scale: 1,
                            allowKeyRepeat: true,
                            semanticLabel:
                                '播放进度，左右键快退或快进 ${_controller?.seekStepSeconds ?? 10} 秒，长按连续调整，确定键播放或暂停',
                            onTap: _togglePlay,
                            onKeyEvent: (event) {
                              if (event is! KeyDownEvent &&
                                  event is! KeyRepeatEvent) {
                                return KeyEventResult.ignored;
                              }
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowLeft) {
                                _seekRelative(
                                  -(_controller?.seekStepSeconds ?? 10),
                                );
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowRight) {
                                _seekRelative(
                                  _controller?.seekStepSeconds ?? 10,
                                );
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            // 轨道只保留一个 TV 焦点，Slider 仍支持指针拖动。
                            child: ExcludeFocus(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 6,
                                  // 控制层滑块/进度前景硬约束白色（§8.3）：smartisan 的
                                  // textPrimary(#333) 压在黑色遮罩上不可见（P1-B）。
                                  thumbColor: Colors.white,
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white.withValues(
                                    alpha: 0.25,
                                  ),
                                  overlayColor: Colors.white.withValues(
                                    alpha: 0.12,
                                  ),
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 10,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 24,
                                  ),
                                ),
                                child: Slider(
                                  value: currentMs,
                                  max: maxMs,
                                  onChanged: (value) => _seekTo(value),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  formatMilliseconds(position.inMilliseconds),
                                  style: text.bodyLarge.copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  formatMilliseconds(duration.inMilliseconds),
                                  style: text.bodyLarge.copyWith(
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // 功能行（页面最下沿）：DOWN → 回画面（_handlePlayerBottomRowKey）。
                Focus(
                  canRequestFocus: false,
                  debugLabel: 'playerBottomRow',
                  onKeyEvent: _handlePlayerBottomRowKey,
                  child: Row(
                    children: [
                      _PlayerControlCapsule(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PlayerControlButton(
                              onTap: _hasPreviousEpisode
                                  ? () => _switchEpisode(
                                      _lineIndex,
                                      _episodeIndex - 1,
                                    )
                                  : null,
                              icon: Icons.skip_previous_rounded,
                              label: '上一集',
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            _PlayerControlButton(
                              onTap: _hasNextEpisode
                                  ? () => _switchEpisode(
                                      _lineIndex,
                                      _episodeIndex + 1,
                                    )
                                  : null,
                              icon: Icons.skip_next_rounded,
                              label: '下一集',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      _PlayerControlCapsule(
                        child: _PlayerControlButton(
                          icon: Icons.playlist_play_rounded,
                          label: '选集 / 线路',
                          focusNode: _focus.panelTrigger,
                          onTap: _openEpisodes,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      _PlayerControlCapsule(
                        child: _PlayerControlButton(
                          icon: favorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          label: favorite ? '取消收藏' : '收藏',
                          color: favorite ? skin.accent : null,
                          onTap: _toggleFavorite,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${widget.vod.lines.length} 条线路 · ${line?.episodes.length ?? 0} 集',
                        style: text.label.copyWith(
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 面板打开时把焦点收进面板作用域（FOCUS-06 / AGENTS.md §3 规则 3）。
  ///
  /// 页面主体的焦点隔离靠两件事叠加：控制层被 [ExcludeFocus] 挡住；面板本身
  /// 只在自己打开时才挂进树里（见 build），关闭即销毁。UP/DOWN 因此只会在
  /// 面板内部走（FOCUS-08 不困住焦点）。默认定位当前集所在区间及对应节点；
  /// `requestFocus` 必须在帧回调之后（节点要先进焦点树）。
  void _focusPanel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_episodesOpen) return;
      _playerEpisodeKey.currentState?.reveal(_episodeIndex, focus: true);
    });
  }

  // ———————— 选集面板内部投递链（工具行 ↔ 线路胶囊 ↔ 字幕行 ↔ 网格）————
  //
  // 面板焦点契约（focus-system-spec §5，打开后焦点默认直达当前集）：
  //
  // | 焦点位置 \ 键 | UP admission            | DOWN                          |
  // | ------------- | ----------------------- | ----------------------------- |
  // | 工具行（Wrap） | 吞（面板顶）            | 字幕行（MediaKit）→ 线路胶囊 → 网格 |
  // | 线路胶囊      | 工具行                   | 字幕行（MediaKit）→ 网格       |
  // | 字幕行        | 线路胶囊（无 → 工具行）  | 网格                           |
  // | 网格          | 首行 → 字幕行/胶囊/工具行 | 末行 → 吞（面板底）           |
  //
  // 行内 LEFT/RIGHT：网格由 EpisodeSelector 显式投递；工具行/字幕行是
  // Wrap 布局走几何（全部挂载，方向遍历在单行内可靠）；线路胶囊少且全挂载
  // 走几何。面板外（控制层/错误层）由 ExcludeFocus 挡住，方向遍历在
  // 面板作用域边缘 stop，不会穿出去。

  /// 面板主体入口：字幕行（MediaKit）→ 线路胶囊（多线路）→ 网格。
  void _focusPanelBody() {
    if (_video is MediaKitBackend) {
      _focusPanelNode(_extraNode(0));
    } else if (widget.vod.lines.length > 1) {
      _focusPanelNode(_panelLineNode(_lineIndex));
    } else {
      _focusPanelGrid();
    }
  }

  /// 网格入口：reveal 当前集所在区间并投焦（焦点直达选中集，面板打开
  /// 默认落点；reveal 内部自带组件滚动与帧后投焦）。
  void _focusPanelGrid() {
    _playerEpisodeKey.currentState?.reveal(_episodeIndex, focus: true);
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 网格首行 UP 的落点：字幕行（MediaKit）→ 线路胶囊（多线路）→ 工具行。
  void _panelGridExitUp() {
    if (_video is MediaKitBackend) {
      _focusPanelNode(_extraNode(0));
    } else if (widget.vod.lines.length > 1) {
      _focusPanelNode(_panelLineNode(_lineIndex));
    } else {
      _focusPanelNode(_toolNode(0));
    }
  }

  /// 帧后投焦到面板内节点（面板刚挂载/刚切换时节点要先进树）。
  void _focusPanelNode(FocusNode node) {
    if (!node.canRequestFocus) return;
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.hasFocus) return;
      final ctx = node.context;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: AppMotion.scrollDuration(context),
          curve: AppMotion.scrollCurve,
        );
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 工具行键处理：DOWN 进面板主体；UP 面板顶（吞）；LEFT/RIGHT 几何。
  KeyEventResult _handlePanelToolsKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _focusPanelBody();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      // 面板顶：显式吞（放行几何会在面板作用域边缘空转）。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 线路胶囊行键处理：UP 回工具行、DOWN 进面板主体；LEFT/RIGHT 几何。
  KeyEventResult _handlePanelLinesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _focusPanelNode(_toolNode(0));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _focusPanelBody();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 字幕行键处理：UP 回线路胶囊（无多线路 → 工具行）、DOWN 进网格；
  /// LEFT/RIGHT 几何。
  KeyEventResult _handlePanelExtrasKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (widget.vod.lines.length > 1) {
        _focusPanelNode(_panelLineNode(_lineIndex));
      } else {
        _focusPanelNode(_toolNode(0));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _focusPanelGrid();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildError(TvSkin skin, Episode? episode) {
    final text = AppText.of(context);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: EdgeInsets.all(skin.spaceLg + 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, color: skin.danger, size: 44),
                SizedBox(height: skin.spaceMd - 2),
                Text(
                  _error ?? '播放失败，请重试',
                  textAlign: TextAlign.center,
                  style: text.bodyStrong.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.6,
                  ),
                ),
                if (episode != null) ...[
                  SizedBox(height: skin.spaceSm - 2),
                  Text(
                    episode.name,
                    textAlign: TextAlign.center,
                    style: text.meta.copyWith(
                      color: Colors.white.withValues(alpha: 0.32),
                      height: 1.4,
                    ),
                  ),
                ],
                SizedBox(height: skin.spaceLg - 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PlayerControlButton(
                      focusNode: _retryFocus,
                      onTap: () => _prepare(
                        lineIndex: _lineIndex,
                        episodeIndex: _episodeIndex,
                      ),
                      icon: Icons.refresh_rounded,
                      label: '重试',
                    ),
                    if (widget.vod.lines.length > 1) ...[
                      SizedBox(width: skin.spaceSm),
                      _PlayerControlButton(
                        onTap: () {
                          final next =
                              (_lineIndex + 1) % widget.vod.lines.length;
                          _switchEpisode(next, _episodeIndex);
                        },
                        icon: Icons.swap_horiz_rounded,
                        label: '换线路',
                      ),
                    ],
                    if (_controller!.config.parses.isNotEmpty) ...[
                      SizedBox(width: skin.spaceSm),
                      _PlayerControlButton(
                        onTap: _chooseParse,
                        icon: Icons.settings_input_component_rounded,
                        label: '换解析',
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  final _playerEpisodeKey = GlobalKey<EpisodeSelectorState>();

  /// 选集面板。宽度是设计常量 640（固定 1280×720 画布，不做设备判断）；
  /// 滑入用 [TweenAnimationBuilder] 而不是 `AnimatedPositioned`——面板只在
  /// 打开时挂进树里（见 build），入场即从右侧滑到 0。
  Widget _buildEpisodePanel() {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    // 固定 1280×720 设计画布：侧栏宽度是设计常量，不做设备判断。
    const panelWidth = 640.0;
    final line = _line;
    final panel = Material(
      color: Colors.transparent,
      child: Container(
        // 侧栏压在视频上：底色与描边硬约束深色（跟皮肤会让 smartisan
        // 亮色面板糊在画面上），只有圆角/间距/字号跟皮肤。
        decoration: BoxDecoration(
          color: const Color(0xF20A0C12),
          border: Border(
            left: BorderSide(
              color: Colors.white.withValues(alpha: 0.13),
              width: skin.surfaceSkin.panelBorderWidth,
            ),
          ),
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(skin.radiusMd),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(skin.radiusMd),
          ),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    skin.spaceMd + 2,
                    skin.spaceMd - 2,
                    skin.spaceSm - 2,
                    skin.spaceXs,
                  ),
                  // 工具行（面板第一块）：DOWN 进面板主体（线路胶囊/字幕行/
                  // 网格），UP 是面板顶（显式吞）；行内 LEFT/RIGHT 走几何。
                  child: Focus(
                    canRequestFocus: false,
                    debugLabel: 'playerPanelTools',
                    onKeyEvent: _handlePanelToolsKey,
                    child: Wrap(
                      spacing: skin.spaceXs,
                      runSpacing: skin.spaceXs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '选集',
                          style: text.cardTitle.copyWith(color: Colors.white),
                        ),
                        SizedBox(width: skin.spaceSm - 2),
                        Text(
                          '${line?.episodes.length ?? 0} 集',
                          style: text.label.copyWith(
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                        ),
                        _PlayerControlButton(
                          icon: Icons.picture_in_picture_alt_rounded,
                          label: '画中画',
                          focusNode: _toolNode(0),
                          onTap: _enterPip,
                        ),
                        _PlayerControlButton(
                          icon: Icons.comment_rounded,
                          label: '弹幕',
                          focusNode: _toolNode(1),
                          onTap: _danmakuOptions,
                        ),
                        _PlayerControlButton(
                          icon: Icons.open_in_new_rounded,
                          label: '外部',
                          focusNode: _toolNode(2),
                          onTap: _openExternal,
                        ),
                        _PlayerControlButton(
                          icon: Icons.cast_rounded,
                          label: '投屏',
                          focusNode: _castTrigger,
                          onTap: _castOpenDevices,
                        ),
                        _PlayerControlButton(
                          icon: Icons.fast_forward_rounded,
                          label: '步长',
                          focusNode: _toolNode(4),
                          onTap: () => _chooseOption<int>(
                            '快进步长',
                            const [5, 10, 30],
                            (step) => '$step 秒',
                            (step) async {
                              await _controller!.setSeekStep(step);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                        _PlayerControlButton(
                          icon: Icons.skip_next_rounded,
                          label: '跳过',
                          focusNode: _toolNode(5),
                          onTap: _chooseSkip,
                        ),
                        _PlayerControlButton(
                          icon: Icons.settings_input_component_rounded,
                          label: '解析源',
                          focusNode: _toolNode(6),
                          onTap: _chooseParse,
                        ),
                        TvFocusable(
                          onTap: _closeEpisodes,
                          semanticLabel: '关闭选集',
                          radius: skin.radiusPill,
                          focusNode: _toolNode(7),
                          child: const SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.vod.lines.length > 1)
                  SizedBox(
                    height: 38,
                    // 线路胶囊行（面板第二块）：UP 回工具行、DOWN 进面板
                    // 主体（字幕行/网格）；行内 LEFT/RIGHT 走几何。
                    child: Focus(
                      canRequestFocus: false,
                      debugLabel: 'playerPanelLines',
                      onKeyEvent: _handlePanelLinesKey,
                      child: ListView.separated(
                        padding: EdgeInsets.symmetric(horizontal: skin.spaceMd),
                        scrollDirection: Axis.horizontal,
                        scrollCacheExtent: const ScrollCacheExtent.pixels(
                          kTvListCacheExtent,
                        ),
                        addAutomaticKeepAlives: false,
                        itemCount: widget.vod.lines.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(width: skin.spaceXs + 1),
                        itemBuilder: (context, index) {
                          final selected = index == _lineIndex;
                          return TvFocusable(
                            radius: skin.radiusPill,
                            focusNode: _panelLineNode(index),
                            onTap: () => _switchEpisode(index, 0),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: skin.spaceMd - 3,
                                vertical: skin.spaceSm - 3,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? skin.accent
                                    : Colors.white.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(
                                  skin.radiusPill,
                                ),
                              ),
                              child: Text(
                                widget.vod.lines[index].name,
                                style: text.body.copyWith(
                                  color: selected
                                      ? skin.textOnAccent
                                      : Colors.white.withValues(alpha: 0.72),
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                SizedBox(height: skin.spaceMd - 4),
                if (_video is MediaKitBackend)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: skin.spaceMd),
                    // 字幕/音轨工具行（面板第三块，仅 MediaKit 内核）：
                    // UP 回线路胶囊（无多线路时回工具行）、DOWN 进网格。
                    child: Focus(
                      canRequestFocus: false,
                      debugLabel: 'playerPanelExtras',
                      onKeyEvent: _handlePanelExtrasKey,
                      child: Wrap(
                        spacing: skin.spaceSm,
                        children: [
                          _PlayerControlButton(
                            icon: Icons.subtitles_rounded,
                            label: '字幕',
                            focusNode: _extraNode(0),
                            onTap: () => _chooseTracks(true),
                          ),
                          _PlayerControlButton(
                            icon: Icons.audiotrack_rounded,
                            label: '音轨',
                            focusNode: _extraNode(1),
                            onTap: () => _chooseTracks(false),
                          ),
                          _PlayerControlButton(
                            icon: Icons.add_rounded,
                            label: '外挂字幕',
                            focusNode: _extraNode(2),
                            onTap: _externalSubtitle,
                          ),
                          _PlayerControlButton(
                            icon: Icons.timer_rounded,
                            label: '字幕延迟',
                            focusNode: _extraNode(3),
                            onTap: () => _chooseOption<double>(
                              '字幕延迟',
                              const [-5, -2, -1, -0.5, 0, 0.5, 1, 2, 5],
                              (delay) => '$delay 秒',
                              (delay) => _video!.setSubtitleDelay(delay),
                            ),
                          ),
                          _PlayerControlButton(
                            icon: Icons.text_fields_rounded,
                            label: '字幕大小',
                            focusNode: _extraNode(4),
                            onTap: () => _chooseOption<double>(
                              '字幕大小',
                              const [18, 24, 30, 36],
                              (size) => '${size.toInt()}',
                              (size) async {
                                setState(() => _video!.subtitleSize = size);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: line == null
                      ? const EmptyState(message: '暂无可选集数')
                      : EpisodeSelector(
                          key: _playerEpisodeKey,
                          dataKey: _lineIndex,
                          episodes: line.episodes,
                          selectedIndex: _episodeIndex,
                          onSelected: (index) =>
                              _switchEpisode(_lineIndex, index),
                          onVideo: true,
                          autofocus: true,
                          columns: 3,
                          rowHeight: 48,
                          // 网格首行 UP → 面板上一块（字幕行/线路胶囊/
                          // 工具行）；末行 DOWN 由组件显式吞（面板底）。
                          onExitUp: _panelGridExitUp,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: _panelMotion(skin.motionPanel, extra: 40),
      curve: Curves.easeOutCubic,
      builder: (context, slide, child) => Transform.translate(
        offset: Offset((panelWidth + 20) * slide, 0),
        child: child,
      ),
      child: panel,
    );
  }
}

// 玻璃只做分组外壳，组内按钮不再叠加材质。同屏模糊预算最多两处：
// 仅返回与进度胶囊启用，其余只保留与首页 bar 相同的皮肤边缘和高光。
class _PlayerControlCapsule extends StatelessWidget {
  const _PlayerControlCapsule({required this.child, this.enableBlur = false});

  final Widget child;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return SkinSurface(
      floating: true,
      enableBlur: enableBlur,
      // TV 控件按操作分组，统一胶囊轮廓；不沿用内容卡片的方角。
      radius: skin.radiusPill,
      padding: const EdgeInsets.all(AppSpacing.sm),
      // 外壳完整读取皮肤底色/渐变，不能用控制遮罩覆盖，否则三套皮肤都变黑。
      // §8.3：白色视频前景仍需深底；仅在内容区衬控制遮罩，保留外缘皮肤材质。
      // 衬底不模糊，不叠加玻璃，也不把控制层前景接回亮色皮肤的深色文字。
      child: ClipRRect(
        borderRadius: BorderRadius.circular(skin.radiusPill),
        child: ColoredBox(color: skin.controlScrim.colors.last, child: child),
      ),
    );
  }
}

class _PlayerControlButton extends StatelessWidget {
  const _PlayerControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    // 视频上的前景保持白色，禁用项只降透明度且退出遥控器遍历。
    return ExcludeFocus(
      excluding: onTap == null,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: TvFocusable(
          radius: skin.radiusPill,
          focusNode: focusNode,
          semanticLabel: label,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: SizedBox(
              height: 56,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 28, color: color ?? Colors.white),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    label,
                    style: AppText.of(context).bodyLarge
                        .copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
