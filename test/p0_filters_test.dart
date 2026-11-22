import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/ui/pages/home_page.dart';

import 'home_direction_test.dart' show FakeSiteApi, harness;

class _FilterApi extends FakeSiteApi {
  Map<String, String> selected = {};

  @override
  Future<HomeData> home(SiteConfig site) async {
    final data = await super.home(site);
    return HomeData(
      categories: data.categories,
      videos: data.videos,
      filters: const {
        '1': [
          CategoryFilter(key: 'year', name: '年份', values: {'2026': '2026'}),
        ],
      },
    );
  }

  @override
  Future<CatalogData> category(
    SiteConfig site,
    String categoryId,
    int page, {
    Map<String, String> filters = const {},
  }) async {
    selected = Map.of(filters);
    return super.category(site, categoryId, page, filters: filters);
  }
}

void main() {
  testWidgets('分类筛选应用到站点请求，切分类清空旧条件', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _FilterApi();
    final controller = AppController(siteApi: api)
      ..config = const AppConfig(
        sites: [SiteConfig(key: 'test', name: '测试站点', api: '', filterable: 1)],
        parses: [],
        lives: [],
      )
      ..selectedSiteKey = 'test'
      ..initialized = true;
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller, const HomePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('电影').first);
    await tester.pumpAndSettle();
    // hero 版式下墙头分区（含「筛选」按钮）位于首屏之下，先滚出来再点（同 home_direction_test 的 revealWall）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(api.selected, {'year': '2026'});
    await tester.tap(find.text('电视剧').first);
    await tester.pumpAndSettle();
    expect(api.selected, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
