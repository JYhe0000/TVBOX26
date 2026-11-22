import 'package:flutter/services.dart';

class AndroidPlayback {
  static const channel = MethodChannel('tvbox/playback');
  static Future<int> receivedBytes() async =>
      await channel.invokeMethod<int>('receivedBytes') ?? -1;
  static Future<List<Map<String, String>>> apps() async {
    final result = await channel.invokeListMethod<dynamic>('apps') ?? [];
    return result
        .map((entry) => Map<String, String>.from(entry as Map))
        .toList();
  }

  static Future<bool> appAction(String action, String package) async =>
      await channel.invokeMethod<bool>(action, {'package': package}) ?? false;

  static Future<bool> enterPip(double ratio) async =>
      await channel.invokeMethod<bool>('pip', {'ratio': ratio}) ?? false;

  static Future<bool> openExternal(
    String url,
    Map<String, String> headers,
    String title,
    int positionMs,
  ) async =>
      await channel.invokeMethod<bool>('external', {
        'url': url,
        'headers': headers,
        'title': title,
        'positionMs': positionMs,
      }) ??
      false;

  // ── 长驻后台播放（ForegroundMediaService）─────────────────────────────
  // 方法名与 MainActivity.kt 的 'tvbox/playback' 分支一一对应。

  /// 拉起前台服务 + 媒体通知；同一会话重复调用由原生侧幂等处理。
  static Future<void> backgroundStart({
    required String url,
    required String title,
    int positionMs = 0,
    bool playing = true,
  }) async =>
      await channel.invokeMethod<void>('backgroundStart', <String, dynamic>{
        'url': url,
        'title': title,
        'positionMs': positionMs,
        'playing': playing,
      });

  /// 刷新通知的播放态与位置（播放/暂停/拖动进度时调用）。
  static Future<void> backgroundUpdateState({
    required bool playing,
    int positionMs = 0,
  }) async =>
      await channel.invokeMethod<void>('backgroundUpdateState', <String, dynamic>{
        'playing': playing,
        'positionMs': positionMs,
      });

  /// 停服务 + 撤通知 + 清原生侧持久化。
  static Future<void> backgroundStop() async =>
      await channel.invokeMethod<void>('backgroundStop');

  /// 读原生侧兜底快照（与 Dart 侧 storage.dart 双写互为兜底）；无会话返回 null。
  static Future<Map<String, dynamic>?> backgroundRestore() async {
    final result =
        await channel.invokeMethod<Map<dynamic, dynamic>>('backgroundRestore');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }
}
