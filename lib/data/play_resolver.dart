import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'network_policy.dart';
import 'web_sniffer.dart';

class PlayResolveException implements Exception {
  PlayResolveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ResolvedPlayUrl {
  const ResolvedPlayUrl({
    required this.url,
    this.viaParse = false,
    this.parseName = '',
    this.headers = const {},
  });

  final String url;
  final bool viaParse;
  final String parseName;
  final Map<String, String> headers;
}

class PlayResolver {
  PlayResolver({
    Dio? dio,
    WebSniffer? sniffer,
    this.timeout = const Duration(seconds: 20),
  }) : _sniffer = sniffer ?? WebSniffer(),
       _dio =
           dio ??
           NetworkPolicy.attach(
             Dio(
               BaseOptions(
                 connectTimeout: const Duration(seconds: 12),
                 receiveTimeout: const Duration(seconds: 18),
                 followRedirects: true,
                 headers: const {'User-Agent': 'okhttp/3.15'},
               ),
             ),
           );

  final Dio _dio;
  final WebSniffer _sniffer;
  final Duration timeout;

  Future<ResolvedPlayUrl> sniffPage(
    String url,
    Map<String, String> headers,
  ) async {
    final result = await _sniffer.sniff(url, headers, timeout);
    if (result == null) throw PlayResolveException('未嗅探到可播放视频，请切换线路。');
    return ResolvedPlayUrl(
      url: result.url,
      headers: {...headers, ...result.headers},
    );
  }

  Future<ResolvedPlayUrl> resolve(
    String rawUrl, {
    List<ParseConfig> parses = const [],
    Map<String, String> headers = const {},
    ParseConfig? selectedParse,
    bool forceParse = false,
    String flag = '',
    Future<String> Function(String)? bindProxy,
  }) async {
    final episodeUrl = rawUrl.trim();
    if (episodeUrl.isEmpty) {
      throw PlayResolveException('播放地址为空');
    }
    final episodeUri = Uri.tryParse(episodeUrl);
    if (episodeUri == null ||
        !['http', 'https'].contains(episodeUri.scheme) ||
        episodeUri.host.isEmpty) {
      throw PlayResolveException('暂不支持该播放协议：${_short(episodeUrl)}');
    }

    final direct = _extractDirectUrl(episodeUrl);
    if (direct != null && selectedParse == null && !forceParse) {
      return ResolvedPlayUrl(url: direct, headers: headers);
    }

    final candidates = (selectedParse == null ? parses : [selectedParse])
        .where((parse) => parse.url.isNotEmpty)
        .toList();
    if (candidates.isEmpty) {
      throw PlayResolveException('请先在配置接口中添加可用的解析源，或切换直连线路。');
    }
    final deadline = DateTime.now().add(timeout);
    final cancel = CancelToken();
    final winner = Completer<ResolvedPlayUrl>();
    final failures = <Object>[];
    var cursor = 0;
    var active = 0;
    Future<void> worker() async {
      active++;
      try {
        while (!winner.isCompleted &&
            !cancel.isCancelled &&
            cursor < candidates.length) {
          final parse = candidates[cursor++];
          final parseHeaders = {...headers, ..._parseHeaders(parse.ext)};
          try {
            final result = await _tryParse(
              parse,
              episodeUrl,
              deadline: deadline,
              headers: parseHeaders,
              cancelToken: cancel,
              parses: parses,
              flag: flag,
              bindProxy: bindProxy,
              onFailure: failures.add,
            );
            if (result != null && !winner.isCompleted) {
              winner.complete(
                ResolvedPlayUrl(
                  url: result.url,
                  viaParse: true,
                  parseName: parse.name,
                  headers: {...parseHeaders, ...result.headers},
                ),
              );
            }
          } catch (error) {
            failures.add(error);
          }
        }
      } finally {
        active--;
        if (active == 0 && !winner.isCompleted) {
          final timedOut =
              !DateTime.now().isBefore(deadline) ||
              failures.any(_isTimeoutFailure);
          final connectionFailed = failures.any(_isConnectionFailure);
          winner.completeError(
            PlayResolveException(
              timedOut
                  ? '解析超时，请换解析源或线路后重试。'
                  : connectionFailed
                  ? '连接解析源失败，请检查网络或切换线路后重试。'
                  : '解析源未找到可播放视频，请换解析或线路。',
            ),
          );
        }
      }
    }

    // 最多三路并发，取首个有效响应；失败结果不参与竞速。
    for (var i = 0; i < candidates.length && i < 3; i++) {
      unawaited(worker());
    }
    try {
      return await winner.future.timeout(
        timeout,
        onTimeout: () => throw PlayResolveException('解析超时，请换解析源或线路后重试。'),
      );
    } finally {
      cancel.cancel('解析完成或超时');
    }
  }

  String? _extractDirectUrl(String url) {
    if (_isDirectPlaybackUrl(url)) return url;
    try {
      final uri = Uri.parse(url);
      for (final key in const ['url', 'u', 'v', 'src', 'play']) {
        final value = uri.queryParameters[key];
        if (value == null || value.isEmpty) continue;
        // queryParameters 已经按 URI 规则解码过一次。这里不能再调用
        // Uri.decodeComponent：签名中常见的 `%2F` 会被错误地还原成 `/`。
        if (_isDirectPlaybackUrl(value)) return value;
        if (value.length <= 8192) {
          try {
            final base64Decoded = utf8.decode(
              base64Decode(_normalizeBase64(value)),
              allowMalformed: true,
            );
            if (_isDirectPlaybackUrl(base64Decoded)) return base64Decoded;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  Future<SniffedMedia?> _tryParse(
    ParseConfig parse,
    String episodeUrl, {
    required DateTime deadline,
    required Map<String, String> headers,
    required CancelToken cancelToken,
    required List<ParseConfig> parses,
    required String flag,
    required Future<String> Function(String)? bindProxy,
    required void Function(Object error) onFailure,
  }) async {
    if (parse.type == 2 || parse.type == 3) {
      if (kIsWeb ||
          defaultTargetPlatform != TargetPlatform.android ||
          parse.jar.isEmpty) {
        return null;
      }
      final definitions = parses.where(
        (item) => item.jar == parse.jar || item.jar.isEmpty,
      );
      final entries = <String, Object>{};
      for (final item in definitions) {
        if (parse.type == 2) {
          if (item.type != 1) continue;
          final index = item.url.indexOf('?');
          entries[item.name] = item.ext.isNotEmpty && index > 0
              ? '${item.url.substring(0, index + 1)}cat_ext=${base64Url.encode(utf8.encode(item.ext))}&${item.url.substring(index + 1)}'
              : item.url;
        } else {
          entries[item.name] = {
            'url': item.url,
            'type': '${item.type}',
            'ext': item.ext,
          };
        }
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final raw = await const MethodChannel('tvbox/spider')
          .invokeMethod<String>('parse', {
            'jar': parse.jar,
            'key': parse.url,
            'name': parse.name,
            'type': parse.type,
            'flag': flag,
            'url': episodeUrl,
            'entries': entries,
          })
          .timeout(remaining);
      final result = jsonDecode(raw ?? '{}');
      if (result is! Map || cancelToken.isCancelled) return null;
      var url = asString(result['url']).trim();
      final proxied = url.startsWith('proxy://');
      if (proxied && bindProxy != null) url = await bindProxy(url);
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        return null;
      }
      final resolvedHeaders = <String, String>{
        ...headers,
        ..._headersFromMap(result),
      };
      final ua = asString(result['ua']).trim();
      if (ua.isNotEmpty) resolvedHeaders['User-Agent'] = ua;
      if (!proxied && asBool(result['parse'])) {
        final budget = deadline.difference(DateTime.now());
        if (budget <= Duration.zero) return null;
        return _sniffer.sniff(url, resolvedHeaders, budget);
      }
      return SniffedMedia(url, resolvedHeaders);
    }
    final candidates = <String>[
      _buildParseUrl(parse.url, episodeUrl),
      _buildParseUrl(parse.url, Uri.encodeComponent(episodeUrl)),
    ];
    // JSON parse APIs often use base64 for the target URL.
    try {
      final encoded = base64Url
          .encode(utf8.encode(episodeUrl))
          .replaceAll('=', '');
      candidates.add(_buildParseUrl(parse.url, encoded));
    } catch (_) {}

    for (final endpoint in candidates.toSet()) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero || cancelToken.isCancelled) return null;
      try {
        final response = await _dio.get<String>(
          endpoint,
          cancelToken: cancelToken,
          options: Options(
            headers: headers,
            responseType: ResponseType.plain,
            validateStatus: (status) => status != null && status < 500,
            // 用剩余预算截断单候选，避免单个慢接口吃掉整个 20s 预算。
            connectTimeout: remaining,
            sendTimeout: remaining,
            receiveTimeout: remaining,
          ),
        );
        if ((response.statusCode ?? 0) >= 400) continue;
        final body = response.data ?? '';
        final found = _extractFromParseResponse(body);
        if (found != null) {
          return SniffedMedia(found, _responseHeaders(body));
        }
        if (parse.type == 0 && body.contains('<') && !cancelToken.isCancelled) {
          // 原生 WebView 在主线程串行使用；嗅探只处理确实返回网页的接口。
          final budget = deadline.difference(DateTime.now());
          if (budget > Duration.zero) {
            final media = await _sniffer.sniff(endpoint, headers, budget);
            if (media != null) return media;
          }
        }
      } catch (error) {
        onFailure(error);
        // Keep trying variants.
      }
    }
    return null;
  }

  Map<String, String> _parseHeaders(String raw) {
    final json = _decodeJsonOrBase64(raw);
    return _headersFromMap(json);
  }

  Map<String, String> _headersFromMap(dynamic node) {
    if (node is! Map) return const {};
    final raw = node['header'] ?? node['headers'];
    if (raw is String) {
      // 兼容接口把 header/headers 再包成 JSON 字符串的写法。
      final nested = _decodeJsonOrBase64(raw);
      if (nested is Map) return _headersFromMap({'header': nested});
    }
    final result = <String, String>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value != null) result[key.toString()] = value.toString();
      });
    }
    for (final key in ['User-Agent', 'Referer', 'Cookie']) {
      final value = node[key] ?? node[key.toLowerCase()];
      if (value is String && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  dynamic _decodeJsonOrBase64(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      try {
        return jsonDecode(
          utf8.decode(
            base64Decode(_normalizeBase64(text)),
            allowMalformed: true,
          ),
        );
      } catch (_) {
        return null;
      }
    }
  }

  Map<String, String> _responseHeaders(String body) {
    try {
      final node = jsonDecode(body);
      return {
        ..._headersFromMap(node),
        if (node is Map) ..._headersFromMap(node['data']),
      };
    } catch (_) {
      return const {};
    }
  }

  String _buildParseUrl(String template, String target) {
    if (template.contains('{url}')) {
      return template.replaceAll('{url}', target);
    }
    if (template.contains('{target}')) {
      return template.replaceAll('{target}', target);
    }
    if (template.endsWith('=')) return '$template$target';
    final separator = template.contains('?') ? '&' : '?';
    return '$template${separator}url=$target';
  }

  String? _extractFromParseResponse(String body) {
    final text = body.trim();
    if (text.isEmpty) return null;
    if (_isDirectPlaybackUrl(text) && !text.contains(' ')) return text;

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);
      final candidates = <dynamic>[
        map['url'],
        map['playUrl'],
        map['play_url'],
        map['video'],
        map['parse'],
        map['result'],
        map['data'],
      ];
      for (final value in candidates) {
        if (value is String) {
          final direct = _extractDirectUrl(value);
          if (direct != null) return direct;
        }
        if (value is Map) {
          final nested = _extractFromMap(value);
          if (nested != null) return nested;
        }
      }
    }
    if (decoded is String) {
      final direct = _extractDirectUrl(decoded);
      if (direct != null) return direct;
    }

    final match = RegExp(
      r'''https?://[^\s"'<>?#]*\.(?:m3u8|mp4|flv|mkv|m4v|mov|ts|mpd)(?:\?[^\s"'<>]*)?''',
      caseSensitive: false,
    ).firstMatch(text);
    final candidate = match?.group(0);
    if (candidate != null && _isDirectPlaybackUrl(candidate)) return candidate;
    return null;
  }

  String? _extractFromMap(Map map) {
    for (final key in const [
      'url',
      'playUrl',
      'play_url',
      'src',
      'video',
      'parse',
    ]) {
      final value = map[key];
      if (value is String) {
        final direct = _extractDirectUrl(value);
        if (direct != null) return direct;
      }
      if (value is Map) {
        final nested = _extractFromMap(value);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  String _normalizeBase64(String value) {
    var text = value.replaceAll('-', '+').replaceAll('_', '/');
    while (text.length % 4 != 0) {
      text += '=';
    }
    return text;
  }

  String _short(String value) =>
      value.length > 42 ? '${value.substring(0, 42)}…' : value;

  bool _isTimeoutFailure(Object error) =>
      error is TimeoutException ||
      error is DioException &&
          const {
            DioExceptionType.connectionTimeout,
            DioExceptionType.sendTimeout,
            DioExceptionType.receiveTimeout,
          }.contains(error.type);

  bool _isConnectionFailure(Object error) =>
      error is DioException && error.type == DioExceptionType.connectionError;

  /// 只根据 URL path 判断直链，不能用整个 URL 做子串匹配：解析接口的
  /// `?format=mp4`、`?ext=.m3u8` 等查询参数不是媒体文件本身。
  bool _isDirectPlaybackUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return false;
    }
    final path = uri.path.toLowerCase();
    if (RegExp(r'\.(?:m3u8|mp4|flv|mkv|m4v|mov|ts|mpd)$').hasMatch(path)) {
      return true;
    }
    // 保留 TVBox 常见的无扩展名 CDN 路径，但仍只看 path。
    return path.contains('/video/tos') || path.contains('/hls/');
  }
}
