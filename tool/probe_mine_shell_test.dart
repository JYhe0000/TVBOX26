// 临时探针 4：切到「设置」分类后再由顶栏 DOWN 进入内容（跑完即删）。
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

String describe() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null) return '<null>';
  final ctx = focus.context;
  var text = '';
  if (ctx != null) {
    final widgets = <String>[];
    ctx.visitAncestorElements((element) {
      final name = element.widget.runtimeType.toString();
      if (name.contains('TvFocusable') ||
          name.contains('PanelAction') ||
          name.contains('CategoryItem') ||
          name.contains('StatCard')) {
        widgets.add(name);
      }
      return widgets.length < 2;
    });
    text = widgets.isEmpty ? '?' : widgets.first;
  }
  final r = focus.rect;
  return '${focus.debugLabel} $text '
      'x${r.left.toStringAsFixed(0)}-${r.right.toStringAsFixed(0)} '
      'y${r.top.toStringAsFixed(0)}-${r.bottom.toStringAsFixed(0)}';
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey k, String tag) async {
  await tester.sendKeyEvent(k);
  await tester.pumpAndSettle();
  // ignore: avoid_print
  print('[$tag] ${describe()}');
}

void main() {
  testWidgets('probe shell mine settings category', (tester) async {
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

    // 左栏「设置」项：requestFocus + OK 切分类。
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
    // ignore: avoid_print
    print('[rail 设置] ${describe()}');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('[after OK] ${describe()}');

    await key(tester, LogicalKeyboardKey.arrowRight, '设置 rail RIGHT');
    await key(tester, LogicalKeyboardKey.arrowDown, '设置 panel DOWN');

    tab3.requestFocus();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('[back to tab] ${describe()}');
    await key(tester, LogicalKeyboardKey.arrowDown, 'tab DOWN (设置分类)');
    await key(tester, LogicalKeyboardKey.arrowDown, '设置 panel DOWN 2');
    await key(tester, LogicalKeyboardKey.arrowUp, '设置 panel UP');
    await key(tester, LogicalKeyboardKey.arrowUp, '设置 panel UP 2');
    await tester.pumpWidget(const SizedBox());
  });
}
