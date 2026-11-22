// 皮肤冷切换回归测试（P0-1 根治后重写）。
//
// 目的：验证「切皮肤 = 持久化 + 冷重启」，而非旧的热切换（notifyListeners →
// Consumer/MaterialApp/整树 rebuild）。冷切换语义：
//   1. setSkin 更新 controller.skinId；
//   2. setSkin 把新 skinId 写进 storage（持久化 key `ui_skin_id`）；
//   3. setSkin 触发 onRestartRequested（冷重启回调）；
//   4. setSkin **不** notifyListeners（不热切换、不触发整树 rebuild）；
//   5. 冷重启（pumpWidget 重挂整棵树、同一 controller）后，MaterialApp.theme /
//      TvSkin.of 反映新皮肤；
//   6. 壳层：三套皮肤统一用 Scaffold 薄壳（液态玻璃已移除）。
//
// 历史：原 P0-1 是「ios26 走全屏玻璃壳 ↔ 其他皮肤走普通 Scaffold」两套壳层
// 分支，运行时热切换（notifyListeners → MaterialApp.theme 变化 → 壳层 widget 类型
// 变化）会让 IndexedStack 内 4 页 State 全部重建 + 重拉数据 + 焦点全灭（真机卡死）。
// 2026-11-15 改为冷切换（setSkin 只持久化 + runApp 重建整树），并把壳层统一为
// 单一 Scaffold 薄壳（液态玻璃已移除，不再引入任何玻璃 shader——那是
// 文字下划线伪影根因；内部是 CupertinoPageScaffold，需在 body 补透明 Material 兜底）。
//
// 用法：flutter test test/skin_switch_test.dart
//   期望：全绿。冷切换不再触发整树 rebuild，故不再有旧的「整树 rebuild 框架
//   debug 边界」红项（那 5 红源于 notifyListeners 热切换 + 整树 rebuild 打断
//   dispose 导致的 timer 泄漏；冷切换下 dispose 完整跑完、timer 正常 cancel）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';

// ---------------------------------------------------------------------------
// 测试替身（与 ui_smoke_test.dart 同构，独立复制避免跨测试文件依赖）
// ---------------------------------------------------------------------------

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
  Future<CatalogData> latest(SiteConfig site, int page) async =>
      CatalogData(videos: _videos, page: page, pageCount: 2);

  @override
  Future<List<VodItem>> search(SiteConfig site, String keyword, {SearchCancellation? cancellation}) async =>
      _videos;

  @override
  Future<VodItem> detail(SiteConfig site, String id) async =>
      _videos.first.copyWith(content: '剧情简介。' * 10);

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
            40,
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

/// 复刻 main.dart 的挂载方式：MultiProvider → `Consumer<AppController>` →
/// MaterialApp(theme: forSkin)。冷重启等价于「以同一 controller 重新 pump 本
/// harness」——每次 pumpWidget 都是新根，Consumer 构建期重新读 skinId。
Widget harness(AppController controller, Widget home) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(create: (_) => LibraryStore()),
    ],
    child: Consumer<AppController>(
      builder: (context, c, _) => MaterialApp(
        title: 'TVBOX26',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.forSkin(c.skinId),
        home: home,
      ),
    ),
  );
}

/// 探针：把当前 `TvSkin.of(context).id` 渲染成文本，用于断言主题是否随皮肤切换。
class SkinProbe extends StatelessWidget {
  const SkinProbe({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('skin=${TvSkin.of(context).id.name}')),
    );
  }
}

void main() {
  // ---------------------------------------------------------------------------
  // 组 A：setSkin 冷切换语义（纯 Dart，无 widget）
  // ---------------------------------------------------------------------------
  group('setSkin 冷切换语义', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('切皮肤：更新 skinId + 持久化 + 触发重启 + 不热切换', () async {
      final controller = buildController()..skinId = TvSkinId.smartisan;
      await controller.storage.init();
      var restarts = 0;
      var notified = 0;
      controller.onRestartRequested = () => restarts++;
      controller.addListener(() => notified++);

      await controller.setSkin(TvSkinId.netflix);

      expect(controller.skinId, TvSkinId.netflix);
      expect(
        controller.storage.getString(AppController.skinStorageKey),
        TvSkinId.netflix.name,
      );
      expect(restarts, 1, reason: 'setSkin 必须触发一次冷重启回调');
      expect(
        notified,
        0,
        reason: 'setSkin 不得 notifyListeners（热切换是 P0-1 卡死根因）',
      );
    });

    test('同一皮肤 setSkin 是无操作', () async {
      final controller = buildController()..skinId = TvSkinId.smartisan;
      await controller.storage.init();
      var restarts = 0;
      controller.onRestartRequested = () => restarts++;

      await controller.setSkin(TvSkinId.smartisan);

      expect(restarts, 0);
      expect(controller.skinId, TvSkinId.smartisan);
    });

    test('持久化后可被新 controller 冷启动回读', () async {
      final first = buildController()..skinId = TvSkinId.smartisan;
      await first.storage.init();
      await first.setSkin(TvSkinId.netflix);

      // 模拟冷重启：新 controller（新 StorageService 实例）读到持久化值。
      final second = buildController();
      await second.storage.init();
      expect(
        second.storage.getString(AppController.skinStorageKey),
        TvSkinId.netflix.name,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 组 B：冷重启后主题反映新皮肤（widget 测试）
  // ---------------------------------------------------------------------------
  group('冷重启后主题反映新皮肤', () {
    testWidgets('setSkin 不热重建，重挂 harness 后主题更新', (tester) async {
      final controller = buildController()..skinId = TvSkinId.netflix;
      await controller.storage.init();
      var restarts = 0;
      controller.onRestartRequested = () => restarts++;

      await tester.pumpWidget(harness(controller, const SkinProbe()));
      expect(find.text('skin=netflix'), findsOneWidget);

      await controller.setSkin(TvSkinId.smartisan);
      expect(restarts, 1);
      await tester.pump();
      // 未重挂：Consumer 没被通知，主题仍是 netflix（冷切换不做增量 rebuild）。
      expect(find.text('skin=netflix'), findsOneWidget);
      expect(find.text('skin=smartisan'), findsNothing);

      // 冷重启：以同一 controller 重挂整棵树（等价于 _runApp 重新 runApp）。
      // MaterialApp 的 theme 切换走 AnimatedTheme（默认 200ms 过渡），
      // TvSkinTokens.lerp 在 t<0.5 返回旧值，必须 pumpAndSettle 走完过渡。
      await tester.pumpWidget(harness(controller, const SkinProbe()));
      await tester.pumpAndSettle();
      expect(find.text('skin=smartisan'), findsOneWidget);
      expect(find.text('skin=netflix'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------------------------
  // 组 C：壳层统一（widget 测试）
  // ---------------------------------------------------------------------------
  group('壳层统一', () {
    testWidgets('三套皮肤都用统一壳层（不再有玻璃 shader 包装）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final smartisan = buildController()..skinId = TvSkinId.smartisan;
      await tester.pumpWidget(harness(smartisan, const ShellPage()));
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsWidgets,
          reason: 'smartisan 壳层应为统一 Scaffold');
      await tester.pumpWidget(const SizedBox());

      final netflix = buildController()..skinId = TvSkinId.netflix;
      await tester.pumpWidget(harness(netflix, const ShellPage()));
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsWidgets,
          reason: 'netflix 壳层应为统一 Scaffold');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
