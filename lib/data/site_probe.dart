import 'dart:async';

import 'package:dio/dio.dart';

import 'models.dart';
import 'network_policy.dart';

/// 单个站点的测速结果。
class SiteProbe {
  const SiteProbe({
    required this.online,
    required this.latencyMs,
    required this.status,
    required this.checkedAt,
  });

  /// 是否连通（拿到任意 HTTP 响应即算连通，4xx 也说明主机可达）。
  final bool online;

  /// HEAD 请求往返耗时（毫秒）。
  final int latencyMs;

  /// HTTP 状态码；网络失败时为 null。
  final int? status;

  final DateTime checkedAt;

  /// 质量分：越小越好。离线固定排最后；4xx/5xx 有惩罚。
  int get score {
    if (!online) return 1 << 30;
    final penalty = status == null
        ? 0
        : status! == 405
            // HEAD 不被支持但主机可达，不惩罚。
            ? 0
            : status! >= 500
                ? 800
                : status! >= 400
                    ? 300
                    : 0;
    return latencyMs + penalty;
  }
}

/// 站点连通性探测：HEAD 一次，不下载正文。
///
/// - 走 [NetworkPolicy]，代理 / DoH 对测速同样生效
/// - 任意 HTTP 状态码都算「连通」（403/404 说明主机可达，只是路径不对）
/// - 连接错误、超时、TLS 失败算「不可达」
class SiteProbeService {
  SiteProbeService({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 4),
                sendTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 5),
                followRedirects: true,
                headers: const {'User-Agent': 'okhttp/3.15'},
              ),
            ),
          );

  final Dio _dio;

  /// 在线结果有效期：10 分钟（网络稳定，不必频繁重测）。
  static const onlineTtl = Duration(minutes: 10);

  /// 可达但 4xx/5xx：5 分钟（可能临时故障，尽早重试）。
  static const degradedTtl = Duration(minutes: 5);

  /// 不可达：3 分钟（短暂断网/域名抖动，较快恢复）。
  static const offlineTtl = Duration(minutes: 3);

  /// 探测单个站点；没有可探测地址时返回 null。
  Future<SiteProbe?> probe(SiteConfig site) async {
    final url = siteProbeUrl(site);
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final watch = Stopwatch()..start();
    try {
      final response = await _dio.headUri<String>(
        uri,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
        ),
      );
      watch.stop();
      return SiteProbe(
        online: true,
        latencyMs: watch.elapsedMilliseconds,
        status: response.statusCode,
        checkedAt: DateTime.now(),
      );
    } catch (error) {
      watch.stop();
      final status = error is DioException ? error.response?.statusCode : null;
      if (status != null) {
        return SiteProbe(
          online: true,
          latencyMs: watch.elapsedMilliseconds,
          status: status,
          checkedAt: DateTime.now(),
        );
      }
      return SiteProbe(
        online: false,
        latencyMs: watch.elapsedMilliseconds,
        status: null,
        checkedAt: DateTime.now(),
      );
    }
  }

  /// 并发探测一批站点；[onResult] 每完成一个就回调（用于渐进刷新 UI）。
  Future<Map<String, SiteProbe>> probeAll(
    Iterable<SiteConfig> sites, {
    int concurrency = 8,
    void Function(String key, SiteProbe probe)? onResult,
  }) async {
    final list = sites.toList();
    final results = <String, SiteProbe>{};
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= list.length) return;
        final site = list[index];
        final probe = await this.probe(site);
        if (probe == null) continue;
        results[site.key] = probe;
        onResult?.call(site.key, probe);
      }
    }
    await Future.wait(
      List.generate(concurrency.clamp(1, 16), (_) => worker()),
    );
    return Map.unmodifiable(results);
  }
}

/// 测速目标：JAR 站探测 JAR 地址，其余探测 api；都不支持时返回 null。
String? siteProbeUrl(SiteConfig site) {
  final jar = site.jar;
  if (jar.startsWith('http://') || jar.startsWith('https://')) return jar;
  final api = site.api;
  if (api.startsWith('http://') || api.startsWith('https://')) return api;
  return null;
}