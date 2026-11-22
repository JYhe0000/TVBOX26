import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/detail_page.dart';
import 'package:tvbox_flutter/ui/widgets/episode_selector.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

class _RelatedApi extends SiteApi {
  static final vod = VodItem(
    id: 'detail',
    name: '焦点回归',
    typeId: '1',
    lines: [
      PlayLine(
        name: '线路甲',
        episodes: List.generate(
          16,
          (i) => Episode(name: '第${i + 1}集', url: 'https://test/$i.mp4'),
        ),
      ),
      const PlayLine(name: '线路乙', episodes: []),
    ],
  );

  @override
  Future<VodItem> detail(SiteConfig site, String id) async => vod;

  @override
  Future<CatalogData> category(
    SiteConfig site,
    String categoryId,
    int page, {
    Map<String, String> filters = const {},
  }) async => CatalogData(
    videos: List.generate(14, (i) => VodItem(id: 'related-$i', name: '推荐$i')),
    page: 1,
    pageCount: 1,
  );
}

void main() {
  for (final skin in TvSkinId.values) {
    testWidgets('$skin 七列逐行到底进入未揭示推荐行，横向远移及记忆回链', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const site = SiteConfig(
        key: 'test',
        name: '测试',
        api: 'https://test',
        type: 1,
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => AppController(siteApi: _RelatedApi()),
            ),
            ChangeNotifierProvider(create: (_) => LibraryStore()),
          ],
          child: MaterialApp(
            theme: AppTheme.forSkin(skin),
            home: DetailPage(vod: _RelatedApi.vod, site: site),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      void expectFocus(String label) =>
          expect(FocusManager.instance.primaryFocus?.debugLabel, label);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown);
      expectFocus('episode-0');
      await press(LogicalKeyboardKey.arrowDown);
      expectFocus('episode-7');
      await press(LogicalKeyboardKey.arrowUp);
      expectFocus('episode-0');
      await press(LogicalKeyboardKey.arrowDown);
      expectFocus('episode-7');
      await press(LogicalKeyboardKey.arrowDown);
      expectFocus('episode-14');
      // 不预先 drag 页面，末行出口必须揭示并挂载横向列表的目标。
      await press(LogicalKeyboardKey.arrowDown);
      expectFocus('related-0');
      for (var i = 1; i <= 12; i++) {
        await press(LogicalKeyboardKey.arrowRight);
        expectFocus('related-$i');
      }
      final card = tester.getRect(find.text('推荐12'));
      expect(card.left, greaterThanOrEqualTo(0));
      expect(card.right, lessThanOrEqualTo(1280));
      expect(card.bottom, lessThanOrEqualTo(720));
      await press(LogicalKeyboardKey.arrowUp);
      expectFocus('episode-0');
      // 推荐行回网格不可改写原来的上行出口，否则首行 UP 会循环回推荐。
      await press(LogicalKeyboardKey.arrowUp);
      expectFocus('detail-line-0');
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown);
      expectFocus('related-12');
      await press(LogicalKeyboardKey.arrowLeft);
      expectFocus('related-11');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final skin in TvSkinId.values) {
    for (final count in [12, 70]) {
      testWidgets('$skin $count 集：线路向下进入集数并可返回', (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final episodes = List.generate(
          count,
          (i) => Episode(name: '第${i + 1}集', url: 'https://test/$i.mp4'),
        );
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AppController()),
              ChangeNotifierProvider(create: (_) => LibraryStore()),
            ],
            child: MaterialApp(
              theme: AppTheme.forSkin(skin),
              home: DetailPage(
                vod: VodItem(
                  id: 'test',
                  name: '测试剧集',
                  lines: [
                    PlayLine(name: '线路甲', episodes: episodes),
                    PlayLine(name: '线路乙', episodes: episodes),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-play');
        // hero 行内 RIGHT：立即播放 → 收藏（重建后行内左右移动显式化；
        // 重建前是「整行 RIGHT 拦截直接进选集」，收藏/第一集无法抵达）。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'detail-favorite',
        );
        // 行尾 RIGHT → 选集网格选中集（详情页「下一步」语义保留）。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-0');
        // 网格首行 UP → 回触发者（收藏按钮，onExitUp）。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'detail-favorite',
        );
        final button = find.ancestor(
          of: find.text('线路甲'),
          matching: find.byType(TvFocusable),
        );
        final focus = tester
            .widget<Focus>(
              find.descendant(of: button, matching: find.byType(Focus)).first,
            )
            .focusNode!;
        focus.requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-0');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-1');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-line-0');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  // 页面级投递表（detail_page.dart 头注释）：页头 → hero → 简介 → 线路胶囊
  // → 选集网格 的 DOWN 链与逐层 UP 回链，行首/行尾与全页 LEFT 的显式吞。
  // 本 harness 没有站点（详情加载失败横幅「重试」在场），正好覆盖错误横幅
  // 在页头与 hero 之间的档位。
  for (final skin in [TvSkinId.smartisan, TvSkinId.netflix]) {
    testWidgets('$skin 详情投递表：DOWN 到底逐层回 + 边界吞键', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final episodes = List.generate(
        12,
        (i) => Episode(name: '第${i + 1}集', url: 'https://test/$i.mp4'),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppController()),
            ChangeNotifierProvider(create: (_) => LibraryStore()),
          ],
          child: MaterialApp(
            theme: AppTheme.forSkin(skin),
            home: DetailPage(
              vod: VodItem(
                id: 'test',
                name: '测试剧集',
                lines: [
                  PlayLine(name: '线路甲', episodes: episodes),
                  PlayLine(name: '线路乙', episodes: episodes),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-play');

      // hero UP → 页头返回浮钮。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-back');
      // 页头 DOWN → 错误横幅「重试」（无站点 → 加载失败横幅在 hero 之上）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-retry');
      // 重试 DOWN → hero 播放键；hero DOWN → 简介。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-play');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-info');
      // 简介 DOWN → 线路胶囊；胶囊 LEFT（行首）→ 吞（详情页 LEFT 无处可去）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-line-0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-line-0');
      // 胶囊 RIGHT → 行内第二胶囊；胶囊 UP → 简介；简介 UP → hero。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-line-1');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-info');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-play');
      // hero 行首（立即播放）LEFT → 吞；再 DOWN → 简介 → DOWN → 胶囊 → DOWN
      // → 网格，网格首行 UP 回胶囊（逐层回链闭合）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-play');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-line-0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-line-0');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('详情从子路由返回后刷新最新续播集数与文案', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const site = SiteConfig(
      key: 'test',
      name: '测试',
      api: 'https://test',
      type: 1,
    );
    final library = LibraryStore();
    library.history.add(
      HistoryEntry(
        vod: _RelatedApi.vod,
        sourceKey: 'test',
        sourceName: '测试',
        lineName: '线路甲',
        lineIndex: 0,
        episodeName: '第1集',
        episodeUrl: 'https://test/0.mp4',
        episodeIndex: 0,
        positionMs: 1000,
        durationMs: 100000,
        updatedAt: DateTime(2026, 11, 19),
      ),
    );
    final controller = AppController(siteApi: _RelatedApi());
    addTearDown(controller.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<LibraryStore>.value(value: library),
        ],
        child: MaterialApp(
          theme: AppTheme.forSkin(TvSkinId.smartisan),
          navigatorObservers: [kRouteObserver],
          home: DetailPage(vod: _RelatedApi.vod, site: site),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('继续播放  第1集'), findsOneWidget);
    expect(
      tester
          .widget<EpisodeSelector>(find.byType(EpisodeSelector))
          .selectedIndex,
      0,
    );

    final navigator = Navigator.of(tester.element(find.byType(DetailPage)));
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('播放页替身')),
      ),
    );
    await tester.pumpAndSettle();

    await library.addHistory(
      HistoryEntry(
        vod: _RelatedApi.vod,
        sourceKey: 'test',
        sourceName: '测试',
        lineName: '线路甲',
        lineIndex: 0,
        episodeName: '第3集',
        episodeUrl: 'https://test/2.mp4',
        episodeIndex: 2,
        positionMs: 50000,
        durationMs: 100000,
        updatedAt: DateTime(2026, 11, 20),
      ),
    );
    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.text('继续播放  第3集'), findsOneWidget);
    expect(find.text('继续播放  第1集'), findsNothing);
    expect(
      tester
          .widget<EpisodeSelector>(find.byType(EpisodeSelector))
          .selectedIndex,
      2,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
