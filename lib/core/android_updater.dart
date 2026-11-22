import 'package:flutter/services.dart';

/// 原生安装辅助：方法名与 MainActivity.kt 的 `tvbox/updater` 分支一一对应。
class AndroidUpdater {
  static const channel = MethodChannel('tvbox/updater');

  /// 拉起系统安装器安装已下载的 APK。
  ///
  /// 返回 false 表示尚未授权「安装未知应用」（原生侧已跳系统授权页），
  /// 用户允许后重新发起安装即可。
  static Future<bool> installApk(String path) async =>
      await channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;
}
