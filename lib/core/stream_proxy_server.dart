import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/network_policy.dart';

/// 本地流代理的转发统计（供「网速/码率显示」接线消费）。
///
/// 独立于任何播放器状态模块：只做纯计数，`activeSessions` 是当前回源
/// 转发中的会话数，`totalServedBytes` 是累计发给播放器的字节数，
/// `currentBytesPerSecond` 取 3 秒滑动窗口（样本在转发泵里采样）。
class StreamProxyStats {
  StreamProxyStats._();

  int _activeSessions = 0;
  int _totalServedBytes = 0;
  final List<(int, int)> _samples = [];

  int get activeSessions => _activeSessions;
  int get totalServedBytes => _totalServedBytes;

  /// 3 秒滑动窗口内的平均速率（字节/秒）。
  int get currentBytesPerSecond {
    final now = DateTime.now().millisecondsSinceEpoch;
    _prune(now);
    var sum = 0;
    for (final sample in _samples) {
      sum += sample.$2;
    }
    return (sum * 1000) ~/ _windowMs;
  }

  static const int _windowMs = 3000;

  void _prune(int now) {
    while (_samples.isNotEmpty && now - _samples.first.$1 > _windowMs) {
      _samples.removeAt(0);
    }
  }

  void _sessionStarted() => _activeSessions += 1;

  void _sessionEnded() {
    if (_activeSessions > 0) _activeSessions -= 1;
  }

  void _onBytes(int count) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _prune(now);
    _samples.add((now, count));
    _totalServedBytes += count;
  }
}

/// 本地流代理服务器：把原生播放器（ExoPlayer / mpv / 系统播放器）的视频
/// 字节流拉回 Dart 侧，让 [NetworkPolicy] 的 HTTP 代理 / JSON DoH 对解码
/// 链路同样生效。
///
/// 原理：video_player 的 ExoPlayer 在插件内部创建，无法替换其 DataSource
/// （禁止 fork 插件），因此播放 URL 在交给后端前改写为
/// `http://127.0.0.1:<port>/m?u=<base64url(upstream)>&h=<base64url(headers)>`，
/// 由本服务用 [NetworkPolicy.attach] 的 Dio 回源并逐块转发。m3u8 播放列表
/// 会被改写，让分片与变体也走本代理。
///
/// 只 bind 回环地址；上游仅接受 http/https；已是本机地址的 URL 原样返回
/// （防递归改写）。
///
/// 回源连接走 [NetworkPolicy.attach] 的 Dio：代理 / DoH 对解码链路
/// 同样生效；回源目标是局域网 / 本机地址时由 [NetworkPolicy.isDirectHost]
/// 旁路，DLNA 渲染器、OpenList 网关等内网设备不被误伤。
class StreamProxyServer {
  StreamProxyServer._();

  static HttpServer? _server;
  static final StreamProxyStats stats = StreamProxyStats._();

  /// m3u8 改写判定：超过该大小的播放列表按普通字节流透传（放弃改写）。
  static const int _maxPlaylistBytes = 8 << 20;

  /// 是否启用改写：代理或 DoH 任一配置了才接原生链路。
  static bool get enabled =>
      NetworkPolicy.proxy.isNotEmpty || NetworkPolicy.dohEndpoint.isNotEmpty;

  /// 把上游播放地址改写为本地代理地址。
  ///
  /// 不改写的情形原样返回：策略关闭、非 http/https、已是本机地址。
  static Future<String> urlFor(
    String upstream,
    Map<String, String> headers,
  ) async {
    if (!_eligible(upstream)) return upstream;
    final server = await _ensureServer();
    return _wrap(server, upstream, headers);
  }

  static bool _eligible(String upstream) {
    if (!enabled) return false;
    final uri = Uri.tryParse(upstream);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return host != '127.0.0.1' && host != 'localhost' && host != '::1';
  }

  static String _wrap(
    HttpServer server,
    String upstream,
    Map<String, String> headers,
  ) {
    final u = base64Url.encode(utf8.encode(upstream));
    final base = 'http://${server.address.address}:${server.port}/m?u=$u';
    if (headers.isEmpty) return base;
    final h = base64Url.encode(utf8.encode(jsonEncode(headers)));
    return '$base&h=$h';
  }

  static Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (request) {
        // 每个连接独立兜错，不让单条会话拖垮监听。
        unawaited(_route(request));
      },
      onError: (Object error) {
        _log('listener error: $error');
      },
    );
    _server = server;
    return server;
  }

  static Future<void> _route(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path != '/m') {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType.text;
      response.write('未找到代理路由');
      await response.close();
      return;
    }
    final upstream = _decodeParam(request.uri.queryParameters['u']);
    final headersJson = _decodeParam(request.uri.queryParameters['h']);
    final upstreamUri = Uri.tryParse(upstream ?? '');
    if (upstream == null ||
        upstreamUri == null ||
        (upstreamUri.scheme != 'http' && upstreamUri.scheme != 'https')) {
      response.statusCode = HttpStatus.badRequest;
      _log('本机媒体代理拒绝无效目标 HTTP 400');
      response.headers.contentType = ContentType.text;
      response.write('代理目标无效');
      await response.close();
      return;
    }
    Map<String, String> baseHeaders = const {};
    if (headersJson != null) {
      try {
        final decoded = jsonDecode(headersJson);
        if (decoded is Map) {
          baseHeaders = decoded.map(
            (key, value) => MapEntry('$key'.toLowerCase(), '$value'),
          );
        }
      } catch (_) {
        baseHeaders = const {};
      }
    }
    await _proxy(request, upstream, baseHeaders);
  }

  static String? _decodeParam(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return utf8.decode(base64Url.decode(raw));
    } catch (_) {
      return null;
    }
  }

  /// hop-by-hop 与本代理不转发的客户端请求头（host/编码由代理自己决定）。
  static const Set<String> _droppedClientHeaders = {
    'host',
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'content-length',
    'accept-encoding',
  };

  static Future<void> _proxy(
    HttpRequest request,
    String upstream,
    Map<String, String> baseHeaders,
  ) async {
    final response = request.response;
    final token = CancelToken();
    stats._sessionStarted();
    final upstreamUri = Uri.parse(upstream);
    try {
      final dio = _ensureDio();
      // 合并顺序：客户端头作底（hop-by-hop 滤除）→ h 参数的站点头覆盖
      // （Referer/UA/Cookie 以站点指定为准）→ 客户端 Range 优先 →
      // Accept-Encoding 恒为 identity（保证 Content-Length 可透传）。
      final merged = <String, String>{};
      request.headers.forEach((name, values) {
        if (_droppedClientHeaders.contains(name.toLowerCase())) return;
        final value = values.join(', ');
        if (value.isNotEmpty) merged[name.toLowerCase()] = value;
      });
      merged.addAll(baseHeaders);
      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null && clientRange.isNotEmpty) {
        merged[HttpHeaders.rangeHeader] = clientRange;
      }
      merged[HttpHeaders.acceptEncodingHeader] = 'identity';

      final method = request.method.toUpperCase();
      final upstreamResponse = await dio.request<ResponseBody>(
        upstream,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          headers: merged,
          // 4xx/5xx 原样透传给播放器，让 ExoPlayer 走自己的重试/换源。
          validateStatus: (_) => true,
          followRedirects: true,
          maxRedirects: 10,
        ),
        cancelToken: token,
      );
      final status = upstreamResponse.statusCode ?? HttpStatus.badGateway;
      if (status >= 400) _log('上游 ${upstreamUri.host} 返回 HTTP $status');
      final contentType =
          upstreamResponse.headers.value(HttpHeaders.contentTypeHeader) ?? '';

      // 透传关键响应头。
      response.statusCode = status;
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        'accept-ranges',
      ]) {
        final value = upstreamResponse.headers.value(name);
        if (value != null && value.isNotEmpty) {
          response.headers.set(name, value);
        }
      }

      // 重定向后的最终地址才是分片相对解析的基准。RedirectInfo.location
      // 可能是相对路径（dart:io 存的是原始 Location 头），必须以原始
      // 上游 URI 为基准 resolve 成绝对地址，否则改写后的分片 URL 会
      // 退回相对路径被 _route 判为无效目标。
      final effectiveUri = upstreamResponse.redirects.isEmpty
          ? upstreamUri
          : upstreamUri.resolveUri(upstreamResponse.redirects.last.location);

      final body = upstreamResponse.data;
      final mayRewrite =
          status == HttpStatus.ok &&
          method == 'GET' &&
          body != null &&
          _bodyAllowed(status);

      if (mayRewrite) {
        final iterator = StreamIterator<Uint8List>(body.stream);
        try {
          var rewrite =
              _playlistHint(upstreamUri) ||
              _playlistHint(effectiveUri) ||
              contentType.toLowerCase().contains('mpegurl');
          Uint8List? peeked;
          if (!rewrite) {
            if (await iterator.moveNext()) {
              peeked = iterator.current;
              rewrite = _startsWithExtm3u(peeked);
            }
          }
          if (rewrite) {
            final served = await _serveRewrittenPlaylist(
              response,
              iterator,
              peeked,
              effectiveUri,
              baseHeaders,
            );
            if (served) return;
            // 超限放弃改写：按普通字节流透传（退化为直链语义，不至于断流）。
            peeked = null;
          }
          if (peeked != null) {
            response.add(peeked);
            stats._onBytes(peeked.length);
            await response.flush();
          }
          await _pump(iterator, response, token);
        } finally {
          await iterator.cancel();
        }
      } else if (body != null && _bodyAllowed(status)) {
        await _pump(StreamIterator(body.stream), response, token);
      }
      await response.close();
    } on DioException catch (error) {
      // 客户端断开（写失败）触发取消时无需回 502。
      if (CancelToken.isCancel(error)) return;
      _log('upstream ${upstreamUri.host} failed: ${error.type}');
      await _badGateway(response, '上游视频源访问失败');
    } catch (error) {
      _log('upstream ${upstreamUri.host} error: $error');
      await _badGateway(response, '上游视频源访问失败');
    } finally {
      stats._sessionEnded();
      // 兜底取消（请求已完成时调用 cancel 是无害的 no-op）。
      if (!token.isCancelled) token.cancel();
    }
  }

  static bool _bodyAllowed(int status) =>
      status != HttpStatus.noContent && status != HttpStatus.notModified;

  static Dio _ensureDio() {
    final existing = _dio;
    // 代理 / DoH 变更后重建 Dio：旧实例的连接池仍被在途会话使用，直接丢弃。
    if (existing != null && _dioGeneration == NetworkPolicy.generation) {
      return existing;
    }
    _dioGeneration = NetworkPolicy.generation;
    // 不设 receiveTimeout：直播是持续流，不能按总接收时长掐断。
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        followRedirects: true,
      ),
    );
    _dio = NetworkPolicy.attach(dio);
    return dio;
  }

  static Dio? _dio;
  static int _dioGeneration = -1;

  static bool _playlistHint(Uri uri) =>
      uri.path.toLowerCase().endsWith('.m3u8');

  static bool _startsWithExtm3u(Uint8List chunk) {
    if (chunk.length < 7) return false;
    var start = 0;
    while (start < chunk.length && chunk[start] == 0x20) {
      start += 1;
    }
    if (chunk.length - start < 7) return false;
    const marker = '#EXTM3U';
    for (var i = 0; i < marker.length; i++) {
      if (chunk[start + i] != marker.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 收集整个 playlist 并改写后返回；超限返回 false（调用方退回透传）。
  static Future<bool> _serveRewrittenPlaylist(
    HttpResponse response,
    StreamIterator<Uint8List> iterator,
    Uint8List? peeked,
    Uri upstream,
    Map<String, String> baseHeaders,
  ) async {
    // 这里只把调用方明确提供的 Cookie/Referer 等 baseHeaders 复制到
    // 分片、变体和 key 请求。上游 playlist 的 Set-Cookie 没有安全的
    // CookieJar 域/Path/SameSite 语义可供本地代理复现，故不擅自把它
    // 拼成 Cookie，避免跨域泄漏或破坏签名；需要会话 Cookie 的源应由
    // 播放链路显式传入 headers。
    final chunks = <List<int>>[?peeked];
    var total = peeked?.length ?? 0;
    while (total <= _maxPlaylistBytes && await iterator.moveNext()) {
      chunks.add(iterator.current);
      total += iterator.current.length;
    }
    if (total > _maxPlaylistBytes) {
      // 超限放弃改写：已收集字节按原样写出（Content-Length 保持上游
      // 全长——调用方会把 iterator 剩余部分续泵完，总字节数与之一致；
      // 此处若改写长度会破坏 HTTP 分帧）。
      for (final chunk in chunks) {
        response.add(chunk);
        stats._onBytes(chunk.length);
      }
      await response.flush();
      return false;
    }
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    final source = utf8.decode(builder.takeBytes(), allowMalformed: true);
    final rewritten = _rewritePlaylist(source, upstream, baseHeaders);
    final bytes = utf8.encode(rewritten);
    response.statusCode = HttpStatus.ok;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
      ..set(HttpHeaders.contentLengthHeader, '${bytes.length}')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    response.add(bytes);
    stats._onBytes(bytes.length);
    await response.close();
    return true;
  }

  /// m3u8 改写：非注释行（分片/变体地址）与 `URI="..."` 属性
  /// （EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA 等）解析为绝对地址后重新包一层
  /// 本代理（携带原 headers）；`data:` URI 原样保留。
  static String _rewritePlaylist(
    String body,
    Uri upstream,
    Map<String, String> headers,
  ) {
    final server = _server;
    if (server == null || !enabled) return body;
    final out = StringBuffer();
    for (final rawLine in const LineSplitter().convert(body)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        out.writeln(rawLine);
        continue;
      }
      if (line.startsWith('#')) {
        out.writeln(_rewriteAttributeUris(rawLine, server, upstream, headers));
        continue;
      }
      out.writeln(_wrapLine(line, server, upstream, headers));
    }
    return out.toString();
  }

  static final RegExp _uriAttribute = RegExp('URI="([^"]+)"');

  static String _rewriteAttributeUris(
    String line,
    HttpServer server,
    Uri upstream,
    Map<String, String> headers,
  ) {
    return line.replaceAllMapped(_uriAttribute, (match) {
      final target = match.group(1)!;
      if (target.startsWith('data:')) return match.group(0)!;
      final absolute = upstream.resolve(target).toString();
      return 'URI="${_wrap(server, absolute, headers)}"';
    });
  }

  static String _wrapLine(
    String line,
    HttpServer server,
    Uri upstream,
    Map<String, String> headers,
  ) {
    if (line.startsWith('data:')) return line;
    final absolute = upstream.resolve(line).toString();
    return _wrap(server, absolute, headers);
  }

  static Future<void> _pump(
    StreamIterator<Uint8List> source,
    HttpResponse response,
    CancelToken token,
  ) async {
    try {
      while (await source.moveNext()) {
        final chunk = source.current;
        response.add(chunk);
        stats._onBytes(chunk.length);
        await response.flush();
      }
    } catch (error) {
      // 客户端断开（写失败）：取消上游回源，尽快释放连接。
      _log('client went away: $error');
      if (!token.isCancelled) {
        token.cancel('client disconnected');
      }
    }
  }

  static Future<void> _badGateway(HttpResponse response, String message) async {
    try {
      response.statusCode = HttpStatus.badGateway;
      response.headers
        ..contentType = ContentType.text
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      response.write(message);
      await response.close();
    } catch (_) {
      // 客户端已断开时写错误响应会失败，忽略。
    }
  }

  static void _log(String message) {
    if (kDebugMode) {
      // 只打主机与事件，不打请求头（含 Referer/Cookie 等敏感值）。
      debugPrint('[StreamProxy] $message');
    }
  }
}
