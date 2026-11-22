import 'dart:convert';

import '../data/storage.dart';
import 'android_playback.dart';

/// 长驻后台播放的 Dart 侧状态层（前台服务 + 媒体通知 + 系统媒体控制）。
///
/// 职责边界：
/// - 本类只负责「发通道命令 + 持久化会话 + 回放原生动作」；
/// - 是否自动续播、续播到哪一集等 UI 决策由集成方（player_page）消费
///   [restore] 的返回值自行决定，见 [restore] 文档。
///
/// 通道协议（'tvbox/playback'，与 MainActivity.kt 一一对应）：
/// - backgroundStart：url/title/positionMs/playing → 拉起前台服务
/// - backgroundUpdateState：playing/positionMs → 刷新通知
/// - backgroundStop：停服务 + 撤通知
/// - backgroundRestore：Map? 原生侧兜底快照
/// - backgroundAction（原生 → Dart）：play/pause/stop/audioFocusLost
class BackgroundPlayback {
  BackgroundPlayback({StorageService? storage})
    : storage = storage ?? StorageService();

  /// 持久化 key（storage.dart 范式：单 key 存整段 JSON）。
  static const String _storageKey = 'bg_playback_state';

  /// 原生 → Dart 的动作回调（通知栏播放/暂停/停止、音频焦点丢失）。
  /// 约定按单例使用：回调全局唯一，后设覆盖先设。
  static void Function(String action)? onAction;

  final StorageService storage;
  bool _active = false;
  BackgroundPlaybackState? _state;
  bool _handlerBound = false;

  bool get isActive => _active;
  BackgroundPlaybackState? get state => _state;

  /// 进播放页即调用：拉起前台服务 + 媒体通知，并持久化会话。
  ///
  /// 幂等：同一 [url] 重复 [start] 只下发 [update]，不重建服务/通知。
  Future<void> start({
    required String url,
    required String title,
    int positionMs = 0,
    bool playing = true,
  }) async {
    if (_active && _state?.url == url) {
      await update(playing: playing, positionMs: positionMs);
      return;
    }
    _active = true;
    _state = BackgroundPlaybackState(
      url: url,
      title: title,
      positionMs: positionMs,
      playing: playing,
    );
    await _save();
    await _ensureActionHandler();
    await AndroidPlayback.backgroundStart(
      url: url,
      title: title,
      positionMs: positionMs,
      playing: playing,
    );
  }

  /// 播放/暂停/拖动进度时调用：刷新通知与持久化位置。
  Future<void> update({bool? playing, int? positionMs}) async {
    final current = _state;
    if (current == null) return;
    final next = current.copyWith(playing: playing, positionMs: positionMs);
    _state = next;
    await _save();
    await AndroidPlayback.backgroundUpdateState(
      playing: next.playing,
      positionMs: next.positionMs,
    );
  }

  /// 退出播放/播完时调用：停服务、撤通知、清持久化。
  Future<void> stop() async {
    _active = false;
    _state = null;
    await storage.remove(_storageKey);
    await AndroidPlayback.backgroundStop();
  }

  /// 进程被杀后再次进 App 时读取上次会话。
  ///
  /// 主源是 Dart 侧 [storage]（与 AppController 同范式），原生侧
  /// SharedPreferences 仅作兜底；两者由 [start]/[update]/[stop] 双写。
  ///
  /// 建议默认值（供集成方参考，非强制）：
  /// - 返回 null → 无会话，正常起播；
  /// - [BackgroundPlaybackState.positionMs] > 5000 且未播完 → 从该位置续播；
  /// - [BackgroundPlaybackState.playing] 为 true 时自动续播，为 false 时
  ///   停在原位，等用户确认（避免后台被杀时留下"突然出声"的惊吓）。
  Future<BackgroundPlaybackState?> restore() async {
    final raw = storage.getString(_storageKey);
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return BackgroundPlaybackState.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {
        // 坏 JSON 降级到原生侧快照。
      }
    }
    final native = await AndroidPlayback.backgroundRestore();
    if (native == null) return null;
    return BackgroundPlaybackState.fromJson(native);
  }

  Future<void> _save() async {
    final state = _state;
    if (state == null) return;
    await storage.setString(_storageKey, jsonEncode(state.toJson()));
  }

  /// 绑定一次通道回调：原生通知动作/音频焦点事件经 backgroundAction 回到 Dart。
  /// 只绑一次；[onAction] 是静态回调，换实例无需重绑。
  Future<void> _ensureActionHandler() async {
    if (_handlerBound) return;
    _handlerBound = true;
    AndroidPlayback.channel.setMethodCallHandler((call) async {
      if (call.method != 'backgroundAction') return;
      final args = call.arguments as Map?;
      final action = args?['action'] as String?;
      final callback = onAction;
      if (action == null || callback == null) return;
      callback(action);
    });
  }
}

/// 一次后台播放会话的快照（url/标题/位置/播放态）。
class BackgroundPlaybackState {
  const BackgroundPlaybackState({
    required this.url,
    required this.title,
    this.positionMs = 0,
    this.playing = true,
  });

  final String url;
  final String title;
  final int positionMs;
  final bool playing;

  factory BackgroundPlaybackState.fromJson(Map<String, dynamic> json) =>
      BackgroundPlaybackState(
        url: json['url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        playing: json['playing'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'title': title,
    'positionMs': positionMs,
    'playing': playing,
  };

  BackgroundPlaybackState copyWith({bool? playing, int? positionMs}) =>
      BackgroundPlaybackState(
        url: url,
        title: title,
        positionMs: positionMs ?? this.positionMs,
        playing: playing ?? this.playing,
      );
}
