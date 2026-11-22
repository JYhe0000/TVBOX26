import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dart:async';

import 'network_policy.dart';

class SniffedMedia {
  const SniffedMedia(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

class WebSniffer {
  static const _channel = MethodChannel('tvbox/web_sniffer');
  static Future<void> _queue = Future.value();

  Future<SniffedMedia?> sniff(
    String url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    final deadline = DateTime.now().add(timeout);
    await previous;
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      done.complete();
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('sniff', {
        'url': url,
        'headers': headers,
        'timeoutMs': remaining.inMilliseconds,
        // WebView 走原生网络栈，代理由 Android 侧 ProxyController 应用；
        // DoH 对 WebView 不可配（原生栈无 JSON DoH 入口），留空。
        if (NetworkPolicy.proxy.isNotEmpty) 'proxy': NetworkPolicy.proxy,
      });
      if (result == null || result['url'] is! String) return null;
      return SniffedMedia(
        result['url'] as String,
        Map<String, String>.from(result['headers'] as Map? ?? const {}),
      );
    } finally {
      done.complete();
    }
  }

  Future<void> cancel() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('cancel');
  }
}
