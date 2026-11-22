import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';

/// ios26 壳滚动回归。
///
/// 守护的 bug：`shell_page.dart` 的 ios26 壳用
/// `Material(type: MaterialType.transparency)` 包住 body，滚动结束（
/// `ScrollEndNotification`）会触发 `Cannot get renderObject of inactive element`。
///
/// 根因链路：Flutter 的 `Material` 会包一层
/// `NotificationListener<LayoutChangedNotification>`，而 `ScrollNotification`
/// 是 `LayoutChangedNotification` 的子类，所以每次滚动通知都会进入该监听器，
/// 回调里 `_inkFeatureRenderer.currentContext!.findRenderObject()` 会在
/// `_InkFeatures` 元素已失活（defunct）时抛异常。这个测试在 ios26 壳下做一次
/// 真实滚动，断言滚动结束没有未捕获异常。

/// 与 `ui_smoke_test.dart` 的 FakeSiteApi 一致：不依赖网络，直接返回内存数据。
class FakeSiteApi extends SiteApi {
  @override
  Future<HomeData> home(SiteConfig site) async {
    return HomeData(
      categories: const [
        CategoryItem(id: '1', name: '电影'),
        CategoryItem(id: '2', name: '电视剧'),
      ],
      videos: _videos,
      page: 1,
      pageCount: 2,
      total: 20,
    );
  }

  @override
  Future<CatalogData> category(
    SiteConfig site,
    String categoryId,
    int page, {
    Map<String, String> filters = const {},
  }) async {
    return CatalogData(
      videos: _videos,
      page: 1,
      pageCount: 1,
      total: _videos.length,
    );
  }

  @override
  Future<CatalogData> latest(SiteConfig site, int page) async {
    return CatalogData(videos: _videos, page: page, pageCount: 2);
  }

  static final _videos = List.generate(
    12,
    (index) => VodItem(
      id: '$index',
      name: '测试影片 $index',
      pic: '',
      remarks: '更新至 ${index + 1} 集',
      typeId: '1',
      typeName: '电影',
      year: '2026',
      area: '中国大陆',
      sourceKey: 'test',
      sourceName: '测试站点',
    ),
  );
}

class FakeLiveService extends LiveService {
  @override
  Future<LiveParseResult> load(LiveSource source) async {
    return LiveParseResult(
      title: source.name,
      groups: [
        LiveGroup(
          name: '央视频道',
          channels: List.generate(
            20,
            (index) => LiveChannel(
              name: 'CCTV-${index + 1}',
              urls: ['https://live.test/$index.m3u8'],
              sourceNames: const ['默认线路'],
              group: '央视频道',
            ),
          ),
        ),
      ],
    );
  }
}

AppController buildController() {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(
      storage: StorageService(),
      siteApi: FakeSiteApi(),
      liveService: FakeLiveService(),
    )
    ..config = const AppConfig(
      sites: [site],
      parses: [],
      lives: [LiveSource(name: '测试直播', url: 'https://live.test/list.m3u')],
    )
    ..selectedSiteKey = 'test'
    ..initialized = true;
}

/// ios26 壳 harness：**不**额外包一层 `Scaffold`，让 `ShellPage` 内部返回的
/// `Scaffold` 成为顶层壳、`Material(type: MaterialType.transparency)`
/// 成为页面唯一 Material 祖先——与 `main.dart` 的真实结构一致（真机上没有
/// 外层 Scaffold，正是这层透明 Material 在给 home/mine 等页兜底 Material 祖先）。
Widget shellHarness(AppController controller) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(create: (_) => LibraryStore()),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: const ShellPage(),
    ),
  );
}

void main() {
  testWidgets('ios26 壳下滚动结束不抛 renderObject 异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(shellHarness(controller));
    await tester.pumpAndSettle();

    // 首页内容在垂直 CustomScrollView 里；确认它是可滚动的。
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));

    // 触发一次真实滚动（animateTo 完整走 ScrollStart → Update → End 通知，
    // 其中 ScrollEndNotification 会冒泡到 ios26 壳那层透明 Material 的
    // NotificationListener，正是真机抛异常的位置）。
    position.animateTo(
      position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
    await tester.pumpAndSettle();

    // 回归目标：滚动结束没有 `Cannot get renderObject of inactive element`。
    expect(tester.takeException(), isNull);

    // 卸载整棵树，走完 HomePage 的 30s 时钟定时器。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('透明 Material 包裹 ListView 滚动结束无异常（最小复现）', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 与 shell_page.dart:254 完全相同的 widget 组合：透明 Material 直接包
    // 一个可滚动列表。若 ios26 壳在测试环境有障碍，此用例独立守护该组合。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Material(
          type: MaterialType.transparency,
          child: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) => SizedBox(
              height: 80,
              child: Text('条目 $index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.animateTo(
      position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
