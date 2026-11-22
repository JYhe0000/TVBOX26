import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_probe.dart';

SiteConfig site(String key, {String api = '', String jar = ''}) => SiteConfig(
  key: key,
  name: key,
  api: api,
  jar: jar,
  type: api.startsWith('csp_') ? 3 : 1,
);

void main() {
  group('siteProbeUrl', () {
    test('JAR 站探测 JAR 地址，其余探测 api', () {
      expect(
        siteProbeUrl(site('a', jar: 'https://cdn.example/x.jar', api: 'csp_A')),
        'https://cdn.example/x.jar',
      );
      expect(
        siteProbeUrl(site('b', api: 'https://api.example/config.json')),
        'https://api.example/config.json',
      );
      expect(siteProbeUrl(site('c', api: 'assets://js/site.js')), isNull);
    });
  });

  group('SiteProbe.score', () {
    test('在线按延迟排序，4xx/5xx 有惩罚，离线最后', () {
      final now = DateTime.now();
      final fast = SiteProbe(online: true, latencyMs: 80, status: 200, checkedAt: now);
      final slow = SiteProbe(online: true, latencyMs: 300, status: 200, checkedAt: now);
      final notFound = SiteProbe(online: true, latencyMs: 80, status: 404, checkedAt: now);
      final offline = SiteProbe(online: false, latencyMs: 500, status: null, checkedAt: now);
      final sorted = [offline, slow, notFound, fast]..sort((a, b) => a.score.compareTo(b.score));
      // 200/80ms < 200/300ms < 404/80ms（+300 惩罚）< 离线。
      expect(sorted.map((p) => p.status), [200, 200, 404, null]);
      expect(sorted.map((p) => p.latencyMs), [80, 300, 80, 500]);
      expect(sorted.last.online, isFalse);
    });
  });

  group('SiteProbeService.probeAll', () {
    test('HEAD 连通性：2xx/4xx 算在线，超时/断连算不可达', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        switch (request.uri.path) {
          case '/ok':
            request.response.statusCode = HttpStatus.noContent;
          case '/missing':
            request.response.statusCode = HttpStatus.notFound;
          case '/slow':
            await Future<void>.delayed(const Duration(seconds: 2));
            request.response.statusCode = HttpStatus.ok;
          case '/reset':
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            return;
          default:
            request.response.statusCode = HttpStatus.ok;
        }
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final service = SiteProbeService(
        dio: Dio(
          BaseOptions(
            connectTimeout: const Duration(milliseconds: 300),
            sendTimeout: const Duration(milliseconds: 300),
            receiveTimeout: const Duration(milliseconds: 500),
            followRedirects: true,
            headers: const {'User-Agent': 'okhttp/3.15'},
          ),
        ),
      );
      final result = await service.probeAll([
        site('ok', api: '$base/ok'),
        site('missing', api: '$base/missing'),
        site('slow', api: '$base/slow'),
      ]);
      expect(result['ok']!.online, isTrue);
      expect(result['ok']!.status, HttpStatus.noContent);
      expect(result['missing']!.online, isTrue);
      expect(result['missing']!.status, HttpStatus.notFound);
      expect(result['slow']!.online, isFalse);
      expect(result['slow']!.status, isNull);
    });
  });
}