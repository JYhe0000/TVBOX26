// 网络策略库：HTTP 代理 + JSON DoH（Google 风格 `?name=&type=A`）。
//
// 作用域与边界（诚实声明）：
// - Dio 侧（站点配置 / EPG / WebDAV / 弹幕 / 本地流代理回源）经
//   [attach] / [createClient] 生效；
// - 原生视频解码器侧：mpv 走原生 `http-proxy` 属性、ExoPlayer 经
//   StreamProxyServer 本地流代理改写，详见 lib/core/player_backend.dart；
// - WebView（网页嗅探）：HTTP 代理已由原生侧 ProxyController 全局应用
//   （见 android/.../MainActivity.kt）；DoH 对 WebView 没有原生配置
//   入口（系统 WebView 不暴露 JSON DoH 接口），本库无法接线，WebView
//   维持系统 DNS——这是平台限制，不是遗漏；
// - 局域网 / 本机地址（[isDirectHost]）一律直连，跳过代理与 DoH，
//   避免误伤 DLNA 渲染器、OpenList 网关与局域网片源。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dns_presets.dart';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class NetworkPolicy {
  static Dio attach(Dio dio) {
    dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: createClient);
    return dio;
  }

  /// DoH 端点列表（按序尝试）；[configure] 时按空白切分，
  /// 单端点旧配置天然等价于只有一个元素的列表。
  static final List<String> dohEndpoints = [];

  /// 向后兼容字段：首个 DoH 端点（未配置时为空串）。
  /// 仅供 StreamProxyServer.enabled 等旧读取点使用。
  static String dohEndpoint = '';

  static String proxy = '';
  static final Map<String, (DateTime, InternetAddress)> _cache = {};

  /// 配置版本号：网络策略变更后，缓存的 Dio/HttpClient 需要按它重建。
  static int generation = 0;

  /// doh 参数允许传多端点（空白分隔，按序尝试）；也兼容旧的单端点写法。
  static void configure({required String doh, required String httpProxy}) {
    dohEndpoints
      ..clear()
      ..addAll(
        doh.split(RegExp(r'\s+')).where((entry) => entry.trim().isNotEmpty),
      );
    dohEndpoint = dohEndpoints.isEmpty ? '' : dohEndpoints.first;
    proxy = httpProxy;
    _cache.clear();
    generation++;
  }

  /// 写入解析缓存：过期项读时删除，总量超过 256 条时淘汰最旧的一条。
  static void _remember(String host, DateTime expires, InternetAddress address) {
    if (!_cache.containsKey(host) && _cache.length >= 256) {
      _cache.remove(_cache.keys.first);
    }
    _cache[host] = (expires, address);
  }

  static InternetAddress? _cached(String host) {
    final hit = _cache[host];
    if (hit == null) return null;
    if (DateTime.now().isBefore(hit.$1)) return hit.$2;
    _cache.remove(host);
    return null;
  }

  /// host 是否为直连（本机 / 局域网）地址：命中时代理与 DoH 都跳过。
  ///
  /// 动机：DLNA 渲染器、OpenList 网关、局域网片源都是私有地址，
  /// 代理服务器通常到不了内网设备，DoH 也解析不出内网名；不旁路会
  /// 把局域网功能全部误伤。覆盖范围：环回（127/8、::1）、链路本地
  /// （169.254/16、fe80::/10）、RFC1918 私有段（10/8、172.16/12、
  /// 192.168/16）、唯一本地地址（fc00::/7），以及名字 `localhost`。
  static bool isDirectHost(String host) {
    var normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized == 'localhost') return true;
    // 容忍 [::1]、[::1]:8080、192.168.1.1:8080 这类带括号 / 端口写法。
    if (normalized.startsWith('[')) {
      final end = normalized.indexOf(']');
      if (end < 0) return false;
      normalized = normalized.substring(1, end);
    } else {
      final colon = normalized.indexOf(':');
      // 只剩一个冒号时视为 IPv4:port；IPv6 字面量有多个冒号，
      // 交给 tryParse 判定。
      if (colon != -1 && !normalized.substring(colon + 1).contains(':')) {
        normalized = normalized.substring(0, colon);
      }
    }
    final address = InternetAddress.tryParse(normalized);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return _isDirectIPv4(bytes);
    }
    // ::1 / :: 环回与未指定地址。
    if (bytes.sublist(0, 15).every((byte) => byte == 0) && bytes[15] <= 1) {
      return true;
    }
    // fe80::/10 链路本地。
    if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return true;
    // fc00::/7 唯一本地地址。
    if ((bytes[0] & 0xFE) == 0xFC) return true;
    // ::ffff:a.b.c.d（IPv4-mapped）按其 IPv4 段判定。
    if (bytes[10] == 0xFF &&
        bytes[11] == 0xFF &&
        bytes.sublist(0, 10).every((byte) => byte == 0)) {
      return _isDirectIPv4(bytes.sublist(12));
    }
    return false;
  }

  static bool _isDirectIPv4(List<int> b) {
    if (b[0] == 127) return true; // 127/8 环回
    if (b[0] == 169 && b[1] == 254) return true; // 169.254/16 链路本地
    if (b[0] == 10) return true; // 10/8
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true; // 172.16/12
    if (b[0] == 192 && b[1] == 168) return true; // 192.168/16
    return false;
  }

  static HttpClient createClient() {
    final client = HttpClient();
    final endpoints = dohEndpoints;
    final proxyUri = Uri.tryParse(_normalizedProxy());
    if (proxyUri != null && proxyUri.host.isNotEmpty && proxyUri.hasPort) {
      client.findProxy = (uri) {
        // 局域网 / 本机直连旁路：代理通常到不了内网设备。
        if (isDirectHost(uri.host)) return 'DIRECT';
        return 'PROXY ${proxyUri.host}:${proxyUri.port}';
      };
    } else if (endpoints.isNotEmpty) {
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final address = isDirectHost(uri.host) ? null : await _lookup(uri.host);
        final tcp = await Socket.startConnect(address ?? uri.host, uri.port);
        if (uri.scheme != 'https') return tcp;
        // 自定义 connectionFactory 须自行握手。TCP 连接解析出的 IP，
        // TLS 仍按原域名发送 SNI 并验证证书。
        Socket? connected;
        final tls = tcp.socket.then((socket) async {
          connected = socket;
          try {
            // Socket 已连接到指定端口，只需指定 SNI 的主机名。
            return await SecureSocket.secure(socket, host: uri.host);
          } catch (_) {
            socket.destroy();
            rethrow;
          }
        });
        return ConnectionTask.fromSocket(tls, () {
          tcp.cancel();
          connected?.destroy();
        });
      };
    }
    return client;
  }

  /// 代理配置兼容 `host:port` 与 `http://host:port` 两种写法
  /// （与 player_backend 对 mpv 的补全策略一致）。
  static String _normalizedProxy() {
    final trimmed = proxy.trim();
    if (trimmed.isEmpty || trimmed.contains('://')) return trimmed;
    return 'http://$trimmed';
  }

  /// 按 [dohEndpoints] 顺序尝试 JSON DoH；全部失败返回 null，
  /// 由调用方回退系统 DNS，绝不抛错阻断。
  static Future<InternetAddress?> _lookup(String host) async {
    if (InternetAddress.tryParse(host) != null) return InternetAddress(host);
    final cached = _cached(host);
    if (cached != null) return cached;
    for (final endpoint in dohEndpoints) {
      final address = await _resolveOnce(host, endpoint);
      if (address != null) return address;
    }
    return null;
  }

  /// 单次 JSON DoH 查询（Google 风格 `?name=&type=A`）；
  /// 任何异常（超时 / 坏响应 / 坏 JSON）都视为该端点失败，
  /// 交还调用方试下一个端点。
  static Future<InternetAddress?> _resolveOnce(
    String host,
    String endpoint,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse(endpoint);
      if (dnsPresets.containsValue(endpoint) && endpoint.isNotEmpty) {
        final request = await client.postUrl(uri);
        request.headers.set('Accept', 'application/dns-message');
        request.headers.set('Content-Type', 'application/dns-message');
        request.add(dnsQuestion(host));
        final response = await request.close().timeout(const Duration(seconds: 4));
        if (response.statusCode != 200) return null;
        final bytes = BytesBuilder();
        await for (final chunk in response.timeout(const Duration(seconds: 4))) {
          if (bytes.length + chunk.length > 65535) return null;
          bytes.add(chunk);
        }
        final answer = dnsAnswer(bytes.takeBytes());
        if (answer == null) return null;
        final address = InternetAddress(answer.$1);
        if (dohEndpoints.contains(endpoint)) {
          final ttl = answer.$2.clamp(1, 300);
          _remember(
            host,
            DateTime.now().add(Duration(seconds: ttl)),
            address,
          );
        }
        return address;
      }
      final request = await client.getUrl(
        uri.replace(
          queryParameters: {...uri.queryParameters, 'name': host, 'type': 'A'},
        ),
      );
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 4));
      final json = jsonDecode(body);
      if (json is Map && json['Answer'] is List) {
        for (final answer in json['Answer'] as List) {
          // 只取 A 记录（type=1）的 IPv4 答案。
          if (answer is! Map || answer['type'] != 1) continue;
          final address = InternetAddress.tryParse('${answer['data']}');
          if (address == null || address.type != InternetAddressType.IPv4) {
            continue;
          }
          final ttl = answer['TTL'] is num
              ? (answer['TTL'] as num).toInt().clamp(1, 300)
              : 60;
          _remember(
            host,
            DateTime.now().add(Duration(seconds: ttl)),
            address,
          );
          return address;
        }
      }
    } catch (_) {
      // 该端点失败：交还调用方试下一个端点。
    } finally {
      client.close(force: true);
    }
    return null;
  }
}
