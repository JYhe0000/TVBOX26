import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

class SpiderProxy {
  SpiderProxy(this.channel);

  final MethodChannel channel;
  Future<HttpServer>? _server;
  final _routes = <String, Map<String, String>>{};
  bool _closed = false;
  int _active = 0;

  Future<String> bind(Map<String, String> site, String url) async {
    if (_closed) throw StateError('Spider 代理已关闭');
    final starting = _server ??= _start();
    final HttpServer server;
    try {
      server = await starting;
    } catch (_) {
      if (identical(_server, starting)) _server = null;
      rethrow;
    }
    if (_closed) throw StateError('Spider 代理已关闭');
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    if (_routes.length >= 64) _routes.remove(_routes.keys.first);
    _routes[token] = Map.unmodifiable(site);
    final suffix = url.substring('proxy://'.length);
    final query = suffix.startsWith('?') ? suffix.substring(1) : suffix;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/spider/$token',
      query: query,
    ).toString();
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
    return server;
  }

  Future<void> _serve(HttpRequest request) async {
    final reply = request.response;
    final parts = request.uri.pathSegments;
    final site = parts.length == 2 && parts.first == 'spider'
        ? _routes[parts.last]
        : null;
    // 拒绝浏览器跨站请求和非本机 Host，不接受调用方指定插件身份。
    if (_closed ||
        site == null ||
        request.headers.value(HttpHeaders.hostHeader) !=
            '127.0.0.1:${request.connectionInfo?.localPort}' ||
        request.headers.value('origin') != null ||
        request.method != 'GET' ||
        request.uri.query.length > 32768) {
      reply.statusCode = HttpStatus.notFound;
      await reply.close();
      return;
    }
    if (_active >= 4) {
      reply.statusCode = HttpStatus.serviceUnavailable;
      await reply.close();
      return;
    }
    _active++;
    try {
      const requestHeaders = {'range', 'user-agent', 'accept', 'referer'};
      final headers = <String, String>{};
      for (final name in requestHeaders) {
        final values = request.headers[name];
        if (values != null) headers[name] = values.join(', ');
      }
      final data = await channel
          .invokeMapMethod<String, Object>('proxy', {
            ...site,
            'params': {
              ...request.uri.queryParameters,
              ...headers,
              'request-headers': jsonEncode(headers),
            },
          })
          .timeout(const Duration(seconds: 20));
      final status = data?['status'];
      final body = data?['body'];
      if (status is! int ||
          status < 200 ||
          status > 599 ||
          body is! List<int> ||
          (status >= 300 && status < 400)) {
        throw const FormatException('插件代理响应无效');
      }
      final mime = data?['mime'];
      if (mime is String && mime.isNotEmpty) {
        reply.headers.contentType = ContentType.parse(mime);
      }
      reply.statusCode = status;
      final responseHeaders = data?['headers'];
      if (responseHeaders is Map) {
        for (final entry in responseHeaders.entries) {
          final name = entry.key.toString().toLowerCase();
          if (const {'content-range', 'accept-ranges'}.contains(name) &&
              entry.value is String) {
            reply.headers.set(name, entry.value);
          }
        }
      }
      reply.headers.set('X-Content-Type-Options', 'nosniff');
      reply.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      reply.add(body);
    } catch (_) {
      reply.statusCode = HttpStatus.badGateway;
    } finally {
      _active--;
      await reply.close();
    }
  }

  Future<void> close() async {
    _closed = true;
    _routes.clear();
    final server = await _server?.then<HttpServer?>(
      (server) => server,
      onError: (_) => null,
    );
    await server?.close(force: true);
  }
}
