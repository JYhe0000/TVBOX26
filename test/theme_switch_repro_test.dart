// 使用生产挂载入口验证冷切换确实卸载旧路由及横向 Scrollable，
// 防止同类型 runApp 保留旧 State 后触发内部 GlobalKey 冲突。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/main.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/ui/pages/settings_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';

class _FakeSiteApi extends SiteApi {
  @override
  Future<HomeData> home(SiteConfig site) async => HomeData(
    categories: const [
      CategoryItem(id: '1', name: '电影'),
      CategoryItem(id: '2', name: '电视剧'),
    ],
    videos: _videos,
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
  }) async => CatalogData(
    videos: _videos,
    page: page,
    pageCount: 1,
    total: _videos.length,
  );

  @override
  Future<CatalogData> latest(SiteConfig site, int page) async =>
      CatalogData(videos: _videos, page: page, pageCount: 2);

  @override
  Future<List<VodItem>> search(SiteConfig site, String keyword, {SearchCancellation? cancellation}) async =>
      _videos;

  @override
  Future<VodItem> detail(SiteConfig site, String id) async => _videos.first;

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

class _FakeLiveService extends LiveService {
  @override
  Future<LiveParseResult> load(LiveSource source) async => LiveParseResult(
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

AppController _buildController() {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(
      storage: StorageService(),
      siteApi: _FakeSiteApi(),
      liveService: _FakeLiveService(),
    )
    ..config = const AppConfig(
      sites: [site],
      parses: [],
      lives: [LiveSource(name: '测试直播', url: 'https://live.test/list.m3u')],
    )
    ..selectedSiteKey = 'test'
    ..initialized = true;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final tab in [0, 3]) {
    testWidgets('netflix→smartisan 冷切换卸载旧树并恢复 tab=$tab', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = _buildController()..skinId = TvSkinId.netflix;
      await controller.storage.init();
      await controller.storage.setString('ui_tab_index', '$tab');
      final library = LibraryStore();
      await library.initialize();
      await library.addHistory(
        HistoryEntry(
          vod: _FakeSiteApi._videos.first,
          sourceKey: 'test',
          sourceName: '测试站点',
          lineName: '默认线路',
          lineIndex: 0,
          episodeName: '第1集',
          episodeUrl: 'https://video.test/1.m3u8',
          episodeIndex: 0,
          positionMs: 1000,
          durationMs: 10000,
          updatedAt: DateTime(2026),
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      await tester.pumpWidget(createTvboxRoot(controller, library));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final oldApp = tester.state(find.byType(TvboxApp));
      final oldShell = tester.state(find.byType(ShellPage));
      final oldScrollables = tester
          .stateList<ScrollableState>(
            find.byType(Scrollable, skipOffstage: false),
          )
          .toList();
      expect(
        oldScrollables.where((s) => s.widget.axis == Axis.horizontal),
        isNotEmpty,
      );

      // push 的 Future 要等 pop 才完成，此处只启动路由并 pump。
      final nav = Navigator.of(tester.element(find.byType(ShellPage)));
      nav.push<void>(MaterialPageRoute(builder: (_) => const SettingsPage()));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      Widget? nextRoot;
      controller.onRestartRequested = () {
        nextRoot = createTvboxRoot(controller, library);
      };
      await controller.setSkin(TvSkinId.smartisan);
      expect(nextRoot, isNotNull);
      await tester.pumpWidget(nextRoot!);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(oldApp.mounted, isFalse, reason: '冷切换必须真正销毁旧 State');
      expect(oldShell.mounted, isFalse);
      expect(nav.mounted, isFalse, reason: '设置路由所属 Navigator 必须销毁');
      expect(oldScrollables.every((s) => !s.mounted), isTrue);
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(ErrorWidget, skipOffstage: false), findsNothing);
      expect(
        TvSkin.of(tester.element(find.byType(ShellPage))).id,
        TvSkinId.smartisan,
      );
      if (tab == 0) {
        expect(find.text('全部'), findsOneWidget);
        expect(find.text('电影'), findsWidgets);
      } else {
        expect(find.text('继续观看'), findsOneWidget);
        expect(find.text('测试影片 0'), findsWidgets);
      }
      expect(library.history, hasLength(1));

      await tester.pumpWidget(const SizedBox());
    });
  }
}
