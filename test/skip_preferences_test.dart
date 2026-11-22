import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/skip_preferences.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/data/models.dart';

void main() {
  test('禁用站点同时影响浏览与搜索候选，置顶顺序可保存', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final controller = AppController(storage: storage);
    addTearDown(controller.dispose);
    controller.config = const AppConfig(
      parses: [],
      lives: [],
      sites: [
        SiteConfig(key: 'a', name: '甲', api: 'https://a.test'),
        SiteConfig(key: 'b', name: '乙', api: 'https://b.test'),
      ],
    );
    await controller.promoteSite('b');
    expect(controller.sites.map((site) => site.key), ['b', 'a']);
    await controller.toggleSite('b');
    expect(controller.sites.map((site) => site.key), ['a']);
    await controller.toggleSite('b');
    expect(controller.sites.first.key, 'b');
    await controller.setEpgUrl('https://epg.test/1');
    await controller.setEpgUrl('https://epg.test/2');
    await controller.setEpgUrl('https://epg.test/1');
    expect(storage.getJsonList('epg_url_history').length, 2);
    expect(
      storage.getJsonList('epg_url_history').first['url'],
      'https://epg.test/1',
    );
  });
  test('快进步长限制与搜索源排除持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final controller = AppController(storage: storage);
    addTearDown(controller.dispose);
    await controller.setSeekStep(30);
    await controller.setSeekStep(99);
    expect(controller.seekStepSeconds, 30);
    expect(storage.getDouble('seek_step_seconds'), 30);
    await controller.toggleSearchSite('a');
    expect(controller.excludedSearchSites, contains('a'));
    expect(storage.getJsonList('search_excluded_sites').single['key'], 'a');
    await controller.toggleSearchSite('a');
    expect(controller.excludedSearchSites, isEmpty);
    expect(storage.getJsonList('search_excluded_sites'), isEmpty);
  });
  test('续播优先、短视频忽略超长片头、片尾不能吞掉正片', () {
    const value = SkipPreference(introMs: 60000, outroMs: 30000);
    expect(value.startPosition(120000, 300000), 120000);
    expect(value.startPosition(0, 300000), 60000);
    expect(value.startPosition(0, 50000), 0);
    expect(value.reachesOutro(269999, 300000), isFalse);
    expect(value.reachesOutro(270000, 300000), isTrue);
    expect(value.reachesOutro(50000, 80000), isFalse);
  });
  test('跳过点按站点影片隔离、重载恢复、清除不影响其他剧', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final store = SkipPreferences(storage);
    await store.save(
      'a',
      '1',
      const SkipPreference(introMs: 60000, outroMs: 30000),
    );
    await store.save('b', '1', const SkipPreference(introMs: 15000));
    expect(SkipPreferences(storage).read('a', '1').outroMs, 30000);
    expect(store.read('b', '1').introMs, 15000);
    expect(store.read('a', '2').introMs, 0);
    await store.save('a', '1', const SkipPreference());
    expect(store.read('a', '1').introMs, 0);
    expect(store.read('b', '1').introMs, 15000);
  });
}
