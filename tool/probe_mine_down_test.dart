// 临时探针：只为定位「我的」页 DOWN 方向键卡住，跑完即删。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:tvbox_flutter/ui/pages/mine_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';

class FakeSiteApi extends SiteApi {
  @override
  Future<HomeData> home(SiteConfig site) async {
    return HomeData(
      categories: const [CategoryItem(id: '1', name: '电影')],
      videos: vods,
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
  }) async =>
      CatalogData(videos: vods, page: 1, pageCount: 1, total: vods.length);

  @override
  Future<CatalogData> latest(SiteConfig site, int page) async =>
      CatalogData(videos: vods, page: page, pageCount: 2);

  @override
  Future<List<VodItem>> search(
    SiteConfig site,
    String keyword, {
    SearchCancellation? cancellation,
  }) async => vods;

  static final vods = List.generate(
    12,
    (index) => VodItem(
      id: '$index',
      name: '测试影片 $index',
      pic: '',
      remarks: '',
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
            10,
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

LibraryStore buildLibrary({int count = 4}) {
  return LibraryStore()
    ..history.addAll(
      List.generate(
        count,
        (index) => HistoryEntry(
          vod: FakeSiteApi.vods[index],
          sourceKey: 'test',
          sourceName: '测试站点',
          lineName: '线路一',
          lineIndex: 0,
          episodeName: '第${index + 1}集',
          episodeUrl: 'https://video.test/$index.m3u8',
          episodeIndex: index,
          positionMs: 60000,
          durationMs: 600000,
          updatedAt: DateTime(2026, 11, 14 - index),
        ),
      ),
    );
}

Widget harness(AppController controller, Widget child, LibraryStore library) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>.value(value: library),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(body: child),
    ),
  );
}

void dumpFocus(String tag) {
  final focus = FocusManager.instance.primaryFocus;
  final chain = <String>[];
  var node = focus;
  var guard = 0;
  while (node != null && guard++ < 8) {
    final label = (node.debugLabel ?? '');
    chain.add(
      '${label.isEmpty ? node.runtimeType.toString() : label}'
      '(${node.rect.shortestSide.toStringAsFixed(0)})',
    );
    if (node is FocusScopeNode) break;
    node = node.parent;
  }
  // ignore: avoid_print
  print('[$tag] ${focus?.rect} <- ${chain.join(' / ')}');
}

void main() {
  testWidgets('probe mine page standalone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final library = buildLibrary();
    final entry = FocusNode(debugLabel: 'mine-entry');
    await tester.pumpWidget(
      harness(controller, MinePage(entryFocus: entry), library),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    dumpFocus('entry');
    for (var i = 1; i <= 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      dumpFocus('panel-down-$i');
    }
    // 从「继续观看」行内向右、再向下。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    dumpFocus('shelf-right');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    dumpFocus('shelf-down');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('probe mine page empty history', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final library = buildLibrary(count: 0);
    final entry = FocusNode(debugLabel: 'mine-entry');
    await tester.pumpWidget(
      harness(controller, MinePage(entryFocus: entry), library),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    dumpFocus('empty-entry');
    for (var i = 1; i <= 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      dumpFocus('empty-down-$i');
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('probe full shell on mine tab', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final library = buildLibrary();
    await tester.pumpWidget(
      harness(controller, const ShellPage(), library),
    );
    await tester.pumpAndSettle();
    // 切到「我的」tab：定位 shell 注入的 tab-3 节点（debugLabel）。
    final tab3 = FocusManager.instance.rootScope.descendants
        .firstWhere((n) => n.debugLabel == 'tab-3');
    tab3.requestFocus();
    await tester.pumpAndSettle();
    dumpFocus('tab-3');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    dumpFocus('mine-tab-selected');
    for (var i = 1; i <= 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      dumpFocus('shell-down-$i');
    }
    await tester.pumpWidget(const SizedBox());
  });
}
