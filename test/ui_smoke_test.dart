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
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/detail_page.dart';
import 'package:tvbox_flutter/ui/pages/home_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';
import 'package:tvbox_flutter/ui/pages/live_page.dart';
import 'package:tvbox_flutter/ui/pages/mine_page.dart';
import 'package:tvbox_flutter/ui/pages/search_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/poster_card.dart';
import 'package:tvbox_flutter/ui/widgets/tv_keyboard.dart';
import 'package:tvbox_flutter/ui/widgets/tv_notice.dart';

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

  @override
  Future<List<VodItem>> search(
    SiteConfig site,
    String keyword, {
    SearchCancellation? cancellation,
  }) async => _videos;

  @override
  Future<VodItem> detail(SiteConfig site, String id) async {
    return _videos.first.copyWith(
      content: '这是一段用于测试布局的剧情简介。' * 10,
      actor: '演员甲, 演员乙, 演员丙',
      director: '导演甲',
      lines: [
        PlayLine(
          name: '线路一',
          episodes: List.generate(
            16,
            (index) => Episode(
              name: '第${index + 1}集',
              url: 'https://video.test/$index.m3u8',
              index: index,
            ),
          ),
        ),
        PlayLine(
          name: '线路二',
          episodes: List.generate(
            8,
            (index) => Episode(
              name: '第${index + 1}集',
              url: 'https://video2.test/$index.m3u8',
              index: index,
            ),
          ),
        ),
      ],
    );
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

Widget harness(
  AppController controller,
  Widget child, {
  LibraryStore? library,
}) {
  final skin = skinFor(TvSkinId.smartisan);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(
        create: (_) => library ?? LibraryStore(),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(backgroundColor: skin.bg, body: child),
    ),
  );
}

void main() {
  final skin = skinFor(TvSkinId.smartisan);
  testWidgets('home page renders a TV layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const HomePage()));
    await tester.pumpAndSettle();
    expect(find.text('TVBOX 26'), findsOneWidget);
    expect(find.text('测试影片 0'), findsWidgets);
    expect(find.text('全部'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'home focuses the first poster and keeps type at 12sp or larger',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = buildController();
      await tester.pumpWidget(harness(controller, const HomePage()));
      await tester.pumpAndSettle();
      // FOCUS-06: the screen opens with a focused element (the first poster).
      expect(FocusManager.instance.primaryFocus, isNotNull);
      // DISTANCE / AGENTS: nothing on the home screen drops below 12sp.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final size = text.style?.fontSize;
        if (size != null) expect(size, greaterThanOrEqualTo(12));
      }
      // OK on the focused first poster opens the detail page.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('线路一'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('site picker is a focus-managed side sheet, not a bottom sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const HomePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试站点').first);
    await tester.pumpAndSettle();
    expect(find.text('选择视频站点'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    // Back closes the panel and returns focus to the page.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选择视频站点'), findsNothing);
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('notices render as a TV banner instead of a SnackBar', (
    tester,
  ) async {
    late BuildContext noticeContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Builder(
          builder: (context) {
            noticeContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    TvNotice.show(noticeContext, '已加入收藏');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('已加入收藏'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('已加入收藏'), findsNothing);
  });

  testWidgets('ensureFocusBelowTopBar is a no-op under the side-rail shell', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nodes = List.generate(12, (i) => FocusNode(debugLabel: 'row-$i'));
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          backgroundColor: skin.bg,
          body: ListView.builder(
            itemCount: 12,
            itemBuilder: (context, index) => Focus(
              focusNode: nodes[index],
              child: SizedBox(height: 200, child: Text('条目 $index')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(254);
    await tester.pump();
    // 侧栏壳层没有顶部悬浮栏，空操作不应滚动任何东西。
    ensureFocusBelowTopBar();
    await tester.pumpAndSettle();
    expect(position.pixels, 254);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ensureFocusBelowTopBar stays inert with a nested horizontal list',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final chipNodes = List.generate(
        12,
        (i) => FocusNode(debugLabel: 'chip-$i'),
      );
      addTearDown(() {
        for (final node in chipNodes) {
          node.dispose();
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.forSkin(TvSkinId.smartisan),
          home: Scaffold(
            backgroundColor: skin.bg,
            body: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: 12,
                    itemBuilder: (context, index) => index == 0
                        // 首行模拟分类 chips：水平列表嵌在垂直列表里。
                        ? SizedBox(
                            height: 60,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: 12,
                              itemBuilder: (context, i) => Focus(
                                focusNode: chipNodes[i],
                                child: SizedBox(
                                  width: 100,
                                  child: Text('分类 $i'),
                                ),
                              ),
                            ),
                          )
                        : SizedBox(height: 200, child: Text('条目 $index')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 外层垂直列表的 Scrollable（内层水平 chips 行也有自己的 Scrollable）。
      final positions = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .where((state) => state.widget.axis == Axis.vertical)
          .map((state) => state.position)
          .toList();
      expect(positions, isNotEmpty);
      final position = positions.first;
      position.jumpTo(100);
      await tester.pump();
      // 空操作：嵌套水平列表的焦点也不触发任何滚动。
      chipNodes[0].requestFocus();
      await tester.pump();
      ensureFocusBelowTopBar();
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(100, 4));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shell hands the default focus to the home entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    // 侧栏壳层（izuko 模式）：进页默认焦点落内容区入口（首页 hero CTA，
    // entry 节点 `tab-entry-0`），不再有「顶栏 DOWN 进内容」的按键路径。
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tab-entry-0');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('top bar focus springs the home page back to the top', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final topRequest = ValueNotifier<int>(0);
    addTearDown(topRequest.dispose);
    await tester.pumpWidget(
      harness(controller, HomePage(topRequest: topRequest)),
    );
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    topRequest.value++;
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    // TV lists clamp instead of bouncing past the edge.
    final view = tester.widget<CustomScrollView>(find.byType(CustomScrollView));
    expect(view.physics, isA<ClampingScrollPhysics>());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('top bar focus springs the live grid back to the top', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final topRequest = ValueNotifier<int>(0);
    addTearDown(topRequest.dispose);
    await tester.pumpWidget(
      harness(controller, LivePage(topRequest: topRequest)),
    );
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    topRequest.value++;
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('detail page renders episodes on a TV layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, DetailPage(vod: FakeSiteApi._videos.first)),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试影片 0'), findsOneWidget);
    expect(find.text('线路一'), findsOneWidget);
    expect(find.text('第1集'), findsWidgets);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('相关推荐'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shell page exposes TV navigation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    expect(find.text('TVBOX 26'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.live_tv_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('电视直播'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live page renders channel groups', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const LivePage()));
    await tester.pumpAndSettle();
    expect(find.text('电视直播'), findsOneWidget);
    expect(find.text('CCTV-1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search tab entry focus lands on the search field', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final entry = FocusNode(debugLabel: 'search-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(harness(controller, SearchPage(entryFocus: entry)));
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, entry);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode, entry);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'up from the search field reaches source settings before the active tab',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = buildController();
      final entry = FocusNode(debugLabel: 'search-entry');
      final tab = FocusNode(debugLabel: 'tab-search');
      addTearDown(entry.dispose);
      addTearDown(tab.dispose);
      await tester.pumpWidget(
        harness(
          controller,
          Column(
            children: [
              // 模拟 top bar 上的「搜索」tab 按钮实际挂在树上的节点。
              Focus(
                focusNode: tab,
                child: const SizedBox(width: 200, height: 48),
              ),
              Expanded(
                child: SearchPage(entryFocus: entry, tabFocus: tab),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      entry.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        tester
            .widget<TvFocusable>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is TvFocusable && widget.semanticLabel == '勾选聚合搜索源',
              ),
            )
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        tester
            .widget<TvFocusable>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is TvFocusable && widget.semanticLabel == '搜索范围',
              ),
            )
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, tab);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('down and right from the search field stay inside the columns', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final entry = FocusNode(debugLabel: 'search-entry');
    addTearDown(entry.dispose);
    final library = LibraryStore()..searchHistory.add('测试');
    await tester.pumpWidget(
      harness(controller, SearchPage(entryFocus: entry), library: library),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    // Down 落到「搜索」按钮，而不是几何上更近的「清空」。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search-submit');
    // 回到输入框后 Right 落到中栏第一项（历史记录胶囊）。
    entry.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search-middle');
    // 左方向键在左栏最左侧停住，不飞到顶部导航。
    entry.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, entry);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('t9 keyboard cycles letters and backspace works', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const SearchPage()));
    await tester.pumpAndSettle();
    // 右栏热词也有数字序号，键盘键位要限定在键盘内查找。
    Finder key(String label) => find.descendant(
      of: find.byType(TvSearchKeyboard),
      matching: find.text(label),
    );
    // T9 九宫格键位齐全（数字 + 字母组 + 功能键）。
    expect(key('2'), findsOneWidget);
    expect(key('9'), findsOneWidget);
    expect(key('ABC'), findsOneWidget);
    expect(key('WXYZ'), findsOneWidget);
    expect(key('退格'), findsOneWidget);
    expect(key('扫码'), findsOneWidget);
    TextField fieldOf() =>
        tester.widget<TextField>(find.byType(TextField).first);
    // 电视端不拉起系统输入法：输入框只读展示。
    expect(fieldOf().readOnly, isTrue);
    // 多击循环：2 -> A，再按 2 -> 替换为 B。
    await tester.tap(key('2'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fieldOf().controller!.text, 'A');
    await tester.tap(key('2'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fieldOf().controller!.text, 'B');
    // 跨键提交：按 3 追加 D（B 保留）。
    await tester.tap(key('3'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fieldOf().controller!.text, 'BD');
    // 循环窗口过期后同键重新开始：等 900ms 再按 2 -> 追加 A。
    await tester.pump(TvSearchKeyboard.cycleWindow);
    await tester.tap(key('2'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fieldOf().controller!.text, 'BDA');
    await tester.tap(key('退格'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fieldOf().controller!.text, 'BD');
    // 清空按钮一键回到初始状态。
    await tester.tap(find.text('清 空'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fieldOf().controller!.text, '');
    // 让循环定时器走完，避免测试结束时仍挂起。
    await tester.pump(TvSearchKeyboard.cycleWindow);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search results render in the middle column', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const SearchPage(standalone: true)),
    );
    await tester.pumpAndSettle();
    // 输入框是只读的（不拉系统输入法），改用 T9 键盘输入再点搜索。
    await tester.tap(
      find.descendant(
        of: find.byType(TvSearchKeyboard),
        matching: find.text('2'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('搜 索'));
    await tester.pumpAndSettle();
    // 让 T9 循环定时器走完。
    await tester.pump(TvSearchKeyboard.cycleWindow);
    expect(find.text('12 条结果'), findsWidgets);
    final cards = find.byType(WideVodCard);
    expect(cards, findsWidgets);
    final rect = tester.getRect(cards.first);
    // 结果卡必须有真实的可见几何，而不是零高度的幽灵。
    expect(rect.height, greaterThan(50));
    expect(rect.width, greaterThan(300));
    // 顶部来源筛选胶囊不能被固定高度的横向列表裁掉下半截。
    final chip = tester.getRect(find.byType(GlassChip).first);
    final chipList = tester.getRect(find.byType(ListView).first);
    expect(chip.bottom, lessThanOrEqualTo(chipList.bottom));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mine tab entry focus lands on the first stat card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(harness(controller, MinePage(entryFocus: entry)));
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, entry);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mine page renders the continue watching shelf from history', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    // 继续观看行走 ShelfRow + ContinueCard：history 为空时整段不渲染，
    // 此用例覆盖非空路径（渲染几何 + 卡片可获焦）。
    final library = LibraryStore()
      ..history.addAll(
        List.generate(
          4,
          (index) => HistoryEntry(
            vod: FakeSiteApi._videos[index],
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
    await tester.pumpWidget(
      harness(controller, const MinePage(), library: library),
    );
    await tester.pumpAndSettle();
    expect(find.text('继续观看'), findsOneWidget);
    // 4 张 ContinueCard（16:9 横版卡，300 宽）。
    expect(find.byType(ContinueCard), findsNWidgets(4));
    final card = tester.getSize(find.byType(ContinueCard).first);
    expect(card.width, ContinueCard.cardWidth);
    expect(card.height, greaterThan(200));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home grid hands focus to the top bar and keeps it there', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(harness(controller, HomePage(entryFocus: entry)));
    await tester.pumpAndSettle();
    // 加载完成后入口焦点落网格首项（entry 节点挂 PosterCard）。
    expect(entry.hasFocus, isTrue);
    // 焦点从页面升到顶栏搜索按钮：顶栏获焦触发 setState（TAB-02 让位），
    // 修复前 _claimEntry 每帧重投会把焦点劫持回内容区（真机 UP 卡死）。
    final searchNode = tester
        .widget<Focus>(
          find
              .ancestor(
                of: find.byIcon(Icons.search_rounded),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    searchNode.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, searchNode);
    // 顶栏停留期间的任何重建（如 30s 时钟 setState）同样不得劫持。
    await tester.pump(const Duration(seconds: 31));
    expect(FocusManager.instance.primaryFocus, searchNode);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mine site picker uses the shared side sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const MinePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('站点'));
    await tester.pumpAndSettle();
    expect(find.text('选择视频站点'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    // The shared row spells out the site capability instead of bare text.
    expect(find.textContaining('可搜索'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选择视频站点'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tv canvas scales 1280x720 design to any screen', (tester) async {
    // Simulate a 1080p panel: the canvas must still lay out at 1280×720
    // logical pixels and rewrite the inner MediaQuery accordingly.
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Inner MediaQuery is pinned to the design canvas.
    Size innerSize = Size.zero;
    EdgeInsets innerPadding = const EdgeInsets.all(-1);
    await tester.pumpWidget(
      MaterialApp(
        home: TvCanvas(
          child: Builder(
            builder: (context) {
              final media = MediaQuery.of(context);
              innerSize = media.size;
              innerPadding = media.padding;
              return const Scaffold(
                body: Center(
                  child: SizedBox(width: 1280, height: 720, child: Text('画布内')),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(innerSize, const Size(1280, 720));
    expect(innerPadding, EdgeInsets.zero);
    // Content placed at the canvas' right/bottom edge stays inside the
    // viewport (i.e. the FittedBox scaled it into the 1920×1080 surface).
    expect(tester.getTopLeft(find.text('画布内')).dy, lessThan(540));
    expect(tester.getTopLeft(find.text('画布内')).dx, lessThan(960));
    await tester.pumpWidget(const SizedBox());
  });
}
