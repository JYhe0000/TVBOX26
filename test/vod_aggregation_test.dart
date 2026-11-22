import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/config_service.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/data/vod_aggregation.dart';

const a = 'https://a.example/config.json';
const b = 'https://b.example/config.json';
const first = '''{
  "spider":"./a.jar;md5;abc",
  "sites":[
    {"key":"cms","api":"https://api.example/list"},
    {"key":"sp","api":"csp_Demo","type":3},
    {"key":"explicit","api":"csp_Demo","type":3,"jar":"../explicit.jar;md5;xyz"}
  ],
  "lives":[{"name":"原直播","url":"./base.m3u"}]
}''';
const second = '''{
  "spider":"./b.jar;md5;def",
  "sites":[
    {"key":"sameEndpoint","api":"https://api.example/list"},
    {"key":"cms","api":"https://api.example/list","ext":{"header":{"Referer":"https://b.example/"}}},
    {"key":"sp","api":"csp_Demo","type":3}
  ],
  "lives":[{"name":"不合并","url":"./other.m3u"}]
}''';

class _Config extends ConfigService {
  final payloads = {a: first, b: second};

  @override
  Future<LoadedConfig> loadFromUrl(String input) async {
    final raw = payloads[input];
    if (raw == null) throw ConfigException('离线');
    return LoadedConfig(
      config: parse(raw, baseUrl: input),
      raw: raw,
      sourceUrl: input,
    );
  }
}

class _Api extends SiteApi {
  @override
  Future<int?> probeLatency(SiteConfig site) async =>
      site.headers.isEmpty ? 50 : 10;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('按行为去重，保留站点 JAR，站点 key 不随来源顺序改变', () {
    final config = ConfigService();
    final base = config.parse(first, baseUrl: a);
    final extra = config.parse(second, baseUrl: b);
    AppConfig merge(Map<String, AppConfig> sources) =>
        VodAggregate(sources: sources, statuses: {}).applyTo(base)!;
    final merged = merge({a: base, b: extra});
    final reversed = merge({b: extra, a: base});
    expect(
      merged.sites.map((s) => s.key).toSet(),
      reversed.sites.map((s) => s.key).toSet(),
    );
    expect(merged.sites.where((s) => s.isHttpSite), hasLength(2));
    expect(merged.sites.first.key, 'cms');
    expect(merged.sites.where((s) => s.isSpider).map((s) => s.jar), [
      'https://a.example/a.jar;md5;abc',
      'https://a.example/explicit.jar;md5;xyz',
      'https://b.example/b.jar;md5;def',
    ]);
    expect(merged.lives.single.url, 'https://a.example/base.m3u');
  });

  test('部分源无效时沿用缓存，断网重启后仍可关闭聚合回单源', () async {
    SharedPreferences.setMockInitialValues({});
    final config = _Config();
    final controller = AppController(configService: config, siteApi: _Api());
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(await controller.loadConfig(a), isTrue);
    expect(await controller.setVodSources([a, '$a#duplicate']), isFalse);
    expect(await controller.setVodSources([a, b]), isTrue);
    final reordered = Completer<void>();
    void onSitesChanged() {
      if (!reordered.isCompleted &&
          controller.sites
              .where((s) => s.isHttpSite)
              .first
              .headers
              .isNotEmpty) {
        reordered.complete();
      }
    }

    controller.addListener(onSitesChanged);
    try {
      onSitesChanged();
      await reordered.future.timeout(const Duration(seconds: 2));
    } finally {
      controller.removeListener(onSitesChanged);
    }
    expect(controller.selectedSite?.key, 'cms');
    config.payloads[b] = '{"lives":[]}';
    await controller.refreshCurrentConfig();
    expect(controller.vodSourceStatuses[b], VodSourceStatus.cached);
    expect(
      await controller.setVodSources([
        'https://x.example',
        'https://y.example',
      ]),
      isFalse,
    );
    expect(controller.vodUrls, [a, b]);
    config.payloads.clear();
    final restarted = AppController(configService: config, siteApi: _Api());
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(
      restarted.vodSourceStatuses.values,
      everyElement(VodSourceStatus.cached),
    );
    expect(restarted.config.sites.where((s) => s.isHttpSite), hasLength(2));
    expect(restarted.liveSources.single.url, 'https://a.example/base.m3u');
    expect(await restarted.setVodSources([]), isTrue);
    expect(restarted.usingVodAggregate, isFalse);
    expect(restarted.config.sites.where((s) => s.isHttpSite).single.key, 'cms');
  });
}
