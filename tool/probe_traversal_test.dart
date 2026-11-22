// 临时探针 5：直查 tab-3 DOWN 时 traversalDescendants（跑完即删）。
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
import 'package:tvbox_flutter/ui/shell_page.dart';

class FakeSiteApi extends SiteApi {
  @override
  Future<HomeData> home(SiteConfig site) async => HomeData(
    categories: const [CategoryItem(id: '1', name: '电影')],
    videos: vods,
    page: 1,
    pageCount: 2,
    total: 20,
  );

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
    3,
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
  Future<LiveParseResult> load(LiveSource source) async => LiveParseResult(
    title: source.name,
    groups: [
      LiveGroup(
        name: '央视频道',
        channels: [
          LiveChannel(
            name: 'CCTV-1',
            urls: const ['https://live.test/0.m3u8'],
            sourceNames: const ['默认线路'],
            group: '央视频道',
          ),
        ],
      ),
    ],
  );
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

LibraryStore buildLibrary() => LibraryStore()
  ..history.addAll(
    List.generate(
      2,
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

Widget harness(AppController controller, Widget child, LibraryStore library) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<LibraryStore>.value(value: library),
      ],
      child: MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('probe traversal descendants', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const ShellPage(), buildLibrary()),
    );
    await tester.pumpAndSettle();
    final tab3 = FocusManager.instance.rootScope.descendants.firstWhere(
      (n) => n.debugLabel == 'tab-3',
    );
    tab3.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final settingsFocus = tester
        .widget<Focus>(
          find
              .ancestor(
                of: find.text('设置').last,
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    settingsFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    tab3.requestFocus();
    await tester.pumpAndSettle();
    final scope = FocusScope.of(tab3.context!);
    // ignore: avoid_print
    print('scope=${scope.debugLabel} focusedChild=${scope.focusedChild?.debugLabel}');
    for (final node in scope.traversalDescendants) {
      // ignore: avoid_print
      print('  cand ${node.debugLabel} canFocus=${node.canRequestFocus} '
          'skip=${node.skipTraversal} rect=${node.rect}');
    }
    final moved = scope.focusInDirection(TraversalDirection.down);
    // ignore: avoid_print
    print('focusInDirection(down) => $moved, primary='
        '${FocusManager.instance.primaryFocus?.debugLabel} '
        '${FocusManager.instance.primaryFocus?.rect}');
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('after pump primary=${FocusManager.instance.primaryFocus?.debugLabel} '
        '${FocusManager.instance.primaryFocus?.rect}');
    await tester.pumpWidget(const SizedBox());
  });
}
