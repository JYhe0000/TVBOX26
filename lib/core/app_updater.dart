// 应用自更新：检查 GitHub Releases 最新版 + 下载 APK。
// 安装经原生拉起系统安装器（lib/core/android_updater.dart ↔
// MainActivity.kt 的 `tvbox/updater` 分支，FileProvider 共享缓存文件）。
//
// 发版约定（发布新版本时参照）：
// - 打 tag `v1.2.3`（可选 build 后缀 `v1.2.3+4`，对应 pubspec version）；
// - Release 正文写更新说明，App 内按纯文本展示；
// - 挂 APK 资产：文件名含 `arm64-v8a` 的优先被选中，否则取第一个 .apk
//   （建议 arm64-v8a 与 universal 各挂一份）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../data/network_policy.dart';

/// 源码仓库主页（设置页「关于」展示 + 扫码/复制用）。
const String kRepoUrl = 'https://github.com/JYhe0000/TVBOX26';

/// GitHub Releases「最新版」端点（仓库无任何 Release 时返回 404）。
const String kLatestReleaseUrl =
    'https://api.github.com/repos/JYhe0000/TVBOX26/releases/latest';

/// 检查更新失败的类型；UI 按型给可操作文案。
enum AppUpdateError {
  /// 仓库还没有发布任何版本（404）。
  noRelease,

  /// 最新 Release 存在，但没有可安装的 .apk 资产。
  noApk,

  /// 网络不可达 / 响应异常。
  network,
}

/// 检查更新失败异常；[type] 决定 UI 文案。
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.type);

  final AppUpdateError type;
}

/// 一条最新 Release 的可安装更新信息。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tagName,
    required this.versionName,
    required this.releaseNotes,
    required this.assetName,
    required this.assetUrl,
    required this.assetSize,
    required this.publishedAt,
  });

  /// 原始 tag（如 `v1.2.3`），展示直接用它。
  final String tagName;

  /// 剥掉 `v` 前缀的版本号（如 `1.2.3`），用于与本机 [isNewerVersion] 比较。
  final String versionName;

  /// Release 正文（更新说明，纯文本展示）。
  final String releaseNotes;

  /// 选中的 APK 资产（见 [pickApkAsset]）。
  final String assetName;
  final String assetUrl;
  final int assetSize;
  final DateTime? publishedAt;
}

/// 版本号比较：`current` 是否低于 `remote`（即远端有可升级的新版）。
///
/// 支持 `v` 前缀与 `+build` 后缀；数字段逐位比较，段数不同按 0 补齐
/// （`1.0` 与 `1.0.0` 等价）；解析失败的段按 0 处理，脏 tag 不会抛异常。
/// 本机版本只带 versionName（无 build）时，同版本号、更高 build 的远端
/// 仍视为有更新（`1.0.0` vs `1.0.0+2` → 新）。
bool isNewerVersion(String current, String remote) {
  final (curSeg, curBuild) = _parseVersion(current);
  final (remSeg, remBuild) = _parseVersion(remote);
  final len = curSeg.length > remSeg.length ? curSeg.length : remSeg.length;
  for (var i = 0; i < len; i++) {
    final c = i < curSeg.length ? curSeg[i] : 0;
    final r = i < remSeg.length ? remSeg[i] : 0;
    if (r != c) return r > c;
  }
  return remBuild > curBuild;
}

/// 解析 `v1.2.3+4` → `([1, 2, 3], 4)`。
(List<int>, int) _parseVersion(String input) {
  var text = input.trim().replaceFirst(RegExp(r'^[vV]'), '');
  var build = 0;
  final plus = text.indexOf('+');
  if (plus >= 0) {
    build = int.tryParse(text.substring(plus + 1)) ?? 0;
    text = text.substring(0, plus);
  }
  final segments = text
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList();
  return (segments, build);
}

/// 从 Release 的 assets 里挑 APK：文件名含 `arm64-v8a` 的优先（电视盒
/// 主流 ABI），否则取第一个 `.apk`；没有可安装资产返回 null。
Map<Object?, Object?>? pickApkAsset(List<Object?> assets) {
  Map<Object?, Object?>? firstApk;
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = (asset['name'] as String?) ?? '';
    if (!name.toLowerCase().endsWith('.apk')) continue;
    firstApk ??= asset;
    if (name.contains('arm64-v8a')) return asset;
  }
  return firstApk;
}

/// 解析 GitHub `releases/latest` 响应体；没有 APK 资产时抛
/// [UpdateCheckException]（[AppUpdateError.noApk]）。
AppUpdateInfo parseLatestRelease(Map<Object?, Object?> json) {
  final tagName = (json['tag_name'] as String?) ?? '';
  final body = (json['body'] as String?) ?? '';
  final publishedAt = DateTime.tryParse(
    (json['published_at'] as String?) ?? '',
  );
  final assets = (json['assets'] as List<Object?>?) ?? const <Object?>[];
  final asset = pickApkAsset(assets);
  if (asset == null) {
    throw const UpdateCheckException(AppUpdateError.noApk);
  }
  var versionName = tagName.trim();
  if (versionName.startsWith('v') || versionName.startsWith('V')) {
    versionName = versionName.substring(1);
  }
  return AppUpdateInfo(
    tagName: tagName,
    versionName: versionName.isEmpty ? tagName : versionName,
    releaseNotes: body.trim(),
    assetName: (asset['name'] as String?) ?? '',
    assetUrl: (asset['browser_download_url'] as String?) ?? '',
    assetSize: (asset['size'] as num?)?.toInt() ?? 0,
    publishedAt: publishedAt,
  );
}

/// 更新检查与下载（dio 走 NetworkPolicy：代理 / DoH 与站点请求同策略）。
class AppUpdater {
  AppUpdater({Dio? dio})
    : _dio =
        dio ??
        NetworkPolicy.attach(
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 10),
            ),
          ),
        );

  final Dio _dio;

  /// 拉取最新 Release；失败抛 [UpdateCheckException]（按型给 UI 文案）。
  Future<AppUpdateInfo> fetchLatest() async {
    Response<dynamic> response;
    try {
      response = await _dio.getUri<dynamic>(
        Uri.parse(kLatestReleaseUrl),
        options: Options(
          headers: const {
            'Accept': 'application/vnd.github+json',
            // GitHub API 强制要求 User-Agent，缺省会被 403。
            'User-Agent': 'TVBOX26-Flutter',
          },
          // 404（暂无 Release）也不抛 DioException，走下方状态码分型。
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } on DioException {
      throw const UpdateCheckException(AppUpdateError.network);
    }
    if (response.statusCode == 404) {
      throw const UpdateCheckException(AppUpdateError.noRelease);
    }
    if (response.statusCode != 200) {
      throw const UpdateCheckException(AppUpdateError.network);
    }
    final data = response.data;
    if (data is! Map) {
      throw const UpdateCheckException(AppUpdateError.network);
    }
    return parseLatestRelease(data);
  }

  /// 下载 APK 到应用缓存目录 `cache/updates/`（与原生
  /// `res/xml/file_paths.xml` 的 cache-path 对应，FileProvider 据此共享）。
  Future<File> downloadApk(
    AppUpdateInfo info, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/tvbox26-${info.versionName}.apk');
    await _dio.download(
      info.assetUrl,
      file.path,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return file;
  }

  void dispose() => _dio.close();
}
