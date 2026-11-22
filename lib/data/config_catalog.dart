import 'dart:convert';

import 'package:dio/dio.dart';

import 'network_policy.dart';

/// `urls.json` 里的一条配置源。
class ConfigCatalogEntry {
  const ConfigCatalogEntry({required this.name, required this.url});

  final String name;
  final String url;

  @override
  String toString() => '$name <$url>';
}

class ConfigCatalogException implements Exception {
  ConfigCatalogException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ConfigCatalogResult {
  const ConfigCatalogResult({required this.indexUrl, required this.entries});

  /// 列表来源地址（手机扫码/手输的那个 urls.json）。
  final String indexUrl;
  final List<ConfigCatalogEntry> entries;
}

/// 读取配置源列表：`{ "urls": [{ "url": "...", "name": "..." }] }`。
///
/// 列表可以来自任意地址，例如 `hkuc/tvbox-config` 的
/// `tv/{0..6}/urls.json`（各镜像副本）。列表项本身就是标准 TVBox 配置
/// 地址，选中后可直接加载，也可加入点播聚合。
class ConfigCatalog {
  ConfigCatalog({Dio? dio})
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

  /// 设置页文案用的参考仓库；导入不依赖它，任何 urls.json 都可以。
  static const repo = 'hkuc/tvbox-config';

  /// 该仓库的原始列表（GitHub 直连），供提示与测试引用。
  static const repoIndexUrl =
      'https://raw.githubusercontent.com/hkuc/tvbox-config/main/tv/6/urls.json';

  /// 解析 `{ "urls": [...] }`，同时兼容裸数组与 `alias` 字段。
  static List<ConfigCatalogEntry> parseIndex(String body) {
    final text = body.trim();
    if (text.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const [];
    }
    final raw = decoded is Map ? decoded['urls'] : decoded;
    if (raw is! List) return const [];
    final entries = <ConfigCatalogEntry>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final url = (item['url'] ?? '').toString().trim();
      if (url.isEmpty || !seen.add(url)) continue;
      final rawName = (item['name'] ?? '').toString().trim();
      final alias = (item['alias'] ?? '').toString().trim();
      entries.add(
        ConfigCatalogEntry(
          name: rawName.isNotEmpty
              ? rawName
              : (alias.isNotEmpty ? alias : _nameFromUrl(url)),
          url: url,
        ),
      );
    }
    return entries;
  }

  /// 从指定地址拉取并解析列表。
  Future<ConfigCatalogResult> loadFromUrl(String input) async {
    final url = input.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw ConfigCatalogException('请填写 http(s) 开头的 urls.json 地址');
    }
    try {
      final body = await _fetch(uri);
      final entries = parseIndex(body);
      if (entries.isEmpty) {
        throw ConfigCatalogException('地址返回的不是 urls.json 列表');
      }
      return ConfigCatalogResult(indexUrl: url, entries: entries);
    } catch (error) {
      throw error is ConfigCatalogException
          ? error
          : ConfigCatalogException('拉取失败：$error');
    }
  }

  Future<String> _fetch(Uri uri) async {
    final response = await _dio.getUri<String>(
      uri,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null,
        headers: const {'User-Agent': 'okhttp/3.15'},
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw ConfigCatalogException('HTTP $status');
    }
    final body = response.data ?? '';
    // urls.json 正常只有几十 KB；异常巨大的响应直接判失败，避免读爆内存。
    if (body.length > 5 * 1024 * 1024) {
      throw ConfigCatalogException('列表文件过大（超过 5MB）');
    }
    return body;
  }

  static String _nameFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final parts = path.split('/').where((part) => part.isNotEmpty).toList();
    final file = parts.isEmpty ? url : parts.last;
    return file.replaceAll(RegExp(r'\.json$'), '');
  }
}
