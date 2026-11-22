import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:punycode_converter/punycode_converter.dart';

import 'models.dart';
import 'network_policy.dart';

class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LoadedConfig {
  const LoadedConfig({
    required this.config,
    required this.raw,
    this.sourceUrl = '',
    this.baseUrl,
    this.warning,
  });

  final AppConfig config;
  final String raw;
  final String sourceUrl;
  final String? baseUrl;
  final String? warning;
}

class ConfigService {
  ConfigService({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 25),
                sendTimeout: const Duration(seconds: 15),
              ),
            ),
          );

  final Dio _dio;

  static const builtInAsset = 'assets/default_config.json';

  Future<LoadedConfig> loadBuiltIn() async {
    final raw = await rootBundle.loadString(builtInAsset);
    return LoadedConfig(config: parse(raw), raw: raw, warning: null);
  }

  Future<LoadedConfig> loadFromUrl(String input) async {
    final url = normalizeUrl(input);
    if (url.isEmpty) throw ConfigException('配置地址不能为空');
    final requestUrl = _fixUrl(url, null);
    final uri = Uri.tryParse(requestUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw ConfigException('请使用 HTTP(S) 或指向局域网 Box 文件服务的 clan:// 配置地址');
    }
    var target = _encodeHost(uri);
    final visited = {target.removeFragment()};
    late Response<String> response;
    for (var redirects = 0; ; redirects++) {
      response = await _dio.getUri<String>(
        target,
        options: Options(
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
          // 每次跳转都重新设置请求头，避免回落到 Dart 的默认 UA。
          headers: const {
            'User-Agent': 'okhttp/3.15',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,'
                'image/avif,image/webp,image/apng,*/*;q=0.8,'
                'application/signed-exchange;v=b3;q=0.9',
          },
        ),
      );
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) break;
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) break;
      final redirect = Uri.tryParse(location.trim());
      final next = redirect == null ? null : target.resolveUri(redirect);
      if (next == null ||
          !['http', 'https'].contains(next.scheme) ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty) {
        throw ConfigException('配置地址跳转目标无效');
      }
      final previous = target;
      target = _encodeHost(next);
      debugPrint(
        'TvboxConfig 第 ${redirects + 1} 次跳转 HTTP ${response.statusCode} '
        '${previous.host} → ${target.host}',
      );
      if (!visited.add(target.removeFragment())) {
        throw ConfigException('配置地址循环跳转（HTTP ${response.statusCode}），请检查订阅入口');
      }
      // 与参考项目 OkHttp 的后续请求上限一致。
      if (redirects >= 20) throw ConfigException('配置地址连续跳转超过 20 次，请检查订阅入口');
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw ConfigException('配置请求失败：HTTP $status');
    }
    final raw = decodeJsonish(response.data ?? '');
    if (raw.isEmpty) throw ConfigException('配置内容为空');
    if (RegExp(
      r'^<(?:!doctype\s+html\b|html\b)',
      caseSensitive: false,
    ).hasMatch(raw)) {
      throw ConfigException('接口返回的是网页，请检查配置地址');
    }
    final baseUrl = response.realUri.toString();
    final config = parse(raw, baseUrl: baseUrl);
    return LoadedConfig(
      config: config,
      raw: raw,
      sourceUrl: url,
      baseUrl: baseUrl,
    );
  }

  Uri _encodeHost(Uri uri) {
    // Dart 会对中文主机名做百分号编码，DNS 和 TLS 需要 ASCII 域名。
    if (!uri.host.contains('%') || uri.host.contains(':')) return uri;
    try {
      return Punycode.uriEncode(uri);
    } on FormatException {
      throw ConfigException('配置地址的域名格式无效');
    } on PunycodeException {
      throw ConfigException('配置地址的域名格式无效');
    }
  }

  /// TVBox accepts a few formats. This normalizer keeps the useful URL part
  /// and adds http:// when the user pasted a bare host.
  String normalizeUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';
    final pkIndex = value.indexOf(';pk;');
    if (pkIndex >= 0) value = value.substring(0, pkIndex).trim();
    if (value.startsWith('clan://')) return value;
    if (value.startsWith('csp_')) return value;
    if (!value.contains('://')) value = 'http://$value';
    return value;
  }

  AppConfig parse(String rawInput, {String? baseUrl}) {
    final raw = decodeJsonish(rawInput);
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Some deployments base64-encode the complete config.
      try {
        decoded = jsonDecode(_tryBase64(raw));
      } catch (_) {
        final start = raw.indexOf('{');
        final end = raw.lastIndexOf('}');
        if (start >= 0 && end > start) {
          try {
            decoded = jsonDecode(raw.substring(start, end + 1));
          } catch (_) {
            // ignore
          }
        }
      }
    }
    if (decoded is! Map) {
      throw ConfigException('无法识别配置格式，请确认这是 TVBox JSON 配置');
    }
    final root = Map<String, dynamic>.from(decoded);

    final video = root['video'];
    dynamic rawSites = video is Map ? video['sites'] : null;
    rawSites ??= root['sites'];
    final sites = <SiteConfig>[];
    if (rawSites is List) {
      for (final entry in rawSites) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final api = _fixUrl(asString(map['api']), baseUrl);
        map['api'] = api;
        map['jar'] = _fixJar(asString(map['jar']), baseUrl);
        if (asInt(map['type'], 1) >= 3 && map['ext'] is String) {
          final ext = asString(map['ext']).trim();
          if (ext.startsWith('./') ||
              ext.startsWith('../') ||
              ext.startsWith('//') ||
              ext.startsWith('clan://')) {
            map['ext'] = _fixUrl(ext, baseUrl);
          }
        }
        final site = SiteConfig.fromJson(map);
        if (site.api.isEmpty && !site.isSpider) continue;
        sites.add(site);
      }
    }

    final spider = _fixJar(asString(root['spider']), baseUrl);
    final parses = <ParseConfig>[];
    final rawParses = root['parses'];
    if (rawParses is List) {
      for (final entry in rawParses) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final type = asInt(map['type']);
        if (type == 2 || type == 3) {
          map['jar'] = spider;
        } else {
          map['url'] = _fixUrl(asString(map['url']), baseUrl);
        }
        if (asString(map['url']).isEmpty) continue;
        parses.add(ParseConfig.fromJson(map));
      }
    }

    final lives = <LiveSource>[];
    final rawLives = root['lives'];
    if (rawLives is List) {
      for (final entry in rawLives) {
        if (entry is Map) {
          final map = Map<String, dynamic>.from(entry);
          var url = asString(map['url']).trim();
          if (url.startsWith('proxy://')) {
            url = _extractProxyUrl(url) ?? url;
          }
          if (url.isEmpty) continue;
          map['url'] = _fixUrl(url, baseUrl, resolveClan: false);
          map['name'] = asString(map['name'] ?? map['group'], '直播源');
          lives.add(LiveSource.fromJson(map));
        } else if (entry is String && entry.trim().isNotEmpty) {
          lives.add(
            LiveSource(
              name: '直播源',
              url: _fixUrl(entry.trim(), baseUrl, resolveClan: false),
            ),
          );
        }
      }
    }

    final flags = <String>[];
    final rawFlags = root['flags'];
    if (rawFlags is List) {
      flags.addAll(rawFlags.map((e) => e.toString()));
    }

    final wallpaper = _fixUrl(asString(root['wallpaper']), baseUrl);
    for (var i = 0; i < sites.length; i++) {
      final site = sites[i];
      if (site.isSpider && site.jar.isEmpty && spider.isNotEmpty) {
        sites[i] = site.withKeyAndJar(site.key, spider);
      }
    }

    return AppConfig(
      sites: sites,
      parses: parses,
      lives: lives,
      spider: spider,
      wallpaper: wallpaper,
      flags: flags,
      name: asString(root['name'], 'TVBOX26'),
    );
  }

  String _tryBase64(String raw) {
    var text = raw.replaceAll(RegExp(r'\s'), '');
    text = text.replaceAll('-', '+').replaceAll('_', '/');
    while (text.length % 4 != 0) {
      text += '=';
    }
    return utf8.decode(base64Decode(text), allowMalformed: true);
  }

  String _fixUrl(String value, String? baseUrl, {bool resolveClan = true}) {
    final url = value.trim();
    if (url.isEmpty) return '';
    if (url.startsWith('clan://')) {
      if (!resolveClan) return url;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.length <= 1) {
        return url;
      }
      return uri.replace(scheme: 'http', path: '/file${uri.path}').toString();
    }
    if (url.startsWith('http://') ||
        url.startsWith('https://') ||
        url.startsWith('csp_') ||
        url.startsWith('proxy://') ||
        url.startsWith('assets/') ||
        url.startsWith('file://')) {
      return url;
    }
    if (baseUrl == null || baseUrl.isEmpty) return url;
    try {
      final base = Uri.parse(baseUrl);
      if (url.startsWith('//')) return '${base.scheme}:$url';
      return base.resolve(url).toString();
    } catch (_) {
      return url;
    }
  }

  String _fixJar(String value, String? baseUrl) {
    final suffix = value.indexOf(';');
    if (suffix < 0) return _fixUrl(value, baseUrl);
    return '${_fixUrl(value.substring(0, suffix), baseUrl)}${value.substring(suffix)}';
  }

  String? _extractProxyUrl(String proxyUrl) {
    try {
      String ext;
      final question = proxyUrl.indexOf('?');
      final queryString = question >= 0
          ? proxyUrl.substring(question + 1)
          : proxyUrl.substring(proxyUrl.indexOf('://') + 3);
      final params = Uri.splitQueryString(queryString);
      ext = params['ext'] ?? '';
      if (ext.isEmpty) {
        final uri = Uri.parse(proxyUrl);
        ext = uri.queryParameters['ext'] ?? '';
      }
      if (ext.isEmpty) return null;
      // splitQueryString/queryParameters 已经完成一次 URI 解码。不要再次
      // decodeComponent，否则带签名的 `%2F` 会被改写，导致代理目标失效。
      final direct = ext.trim();
      final directUri = Uri.tryParse(direct);
      if (directUri != null &&
          ['http', 'https'].contains(directUri.scheme) &&
          directUri.host.isNotEmpty) {
        return direct;
      }
      var normalized = ext.replaceAll('-', '+').replaceAll('_', '/');
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      return utf8.decode(base64Decode(normalized), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
