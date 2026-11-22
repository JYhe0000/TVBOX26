// 首页方向键回归：网格 UP/DOWN 同列逐行移动，首行 UP 逐层退出；
// hero 轮播的手动切换、自动推进和滚动跟随。
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
import 'package:tvbox_flutter/ui/pages/home_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/home_hero_carousel.dart';
import 'package:tvbox_flutter/ui/widgets/poster_card.dart';

/// 与 ui_smoke_test.dart 同构的假站点 API：2 个分类 + 12 条影片。
class FakeSiteApi extends SiteApi {
  FakeSiteApi({String? secondTitle})
    : _videos = List.generate(
        12,
        (index) => VodItem(
          id: '$index',
          name: index == 1 && secondTitle != null ? secondTitle : '测试影片 $index',
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

  final List<VodItem> _videos;

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
    return _videos.first;
  }
}

class FakeLiveService extends LiveService {
  @override
  Future<LiveParseResult> load(LiveSource source) async {
    return LiveParseResult(title: source.name, groups: const []);
  }
}

AppController buildController({String? secondTitle}) {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(
      storage: StorageService(),
      siteApi: FakeSiteApi(secondTitle: secondTitle),
      liveService: FakeLiveService(),
    )
    ..config = const AppConfig(sites: [site], parses: [], lives: [])
    ..selectedSiteKey = 'test'
    ..initialized = true;
}

/// 与 ui_smoke_test.dart 的 harness 相同，外加 disableAnimations：
/// 关掉焦点缩放缓动与 hero 自动轮播（减弱动态语义），方向遍历的几何
/// 基准保持确定。自动轮播用例传 false 关掉。
Widget harness(
  AppController controller,
  Widget child, {
  LibraryStore? library,
  bool disableAnimations = true,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(
        create: (_) => library ?? LibraryStore(),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      builder: (context, child) => TvCanvas(child: child!),
      home: Scaffold(
        backgroundColor: skinFor(TvSkinId.smartisan).bg,
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: disableAnimations),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// 首页内的地标节点（都在 HomePage 子树里找，避免 shell 其它页的干扰）。
class Landmarks {
  Landmarks(this.tester);

  final WidgetTester tester;

  /// 外部注入的 entry 节点（传了 HomePage.entryFocus 时记录）。
  /// hero 可见时它挂在 hero「查看详情」CTA 上。
  FocusNode? entry;

  Finder get _home => find.byType(HomePage);

  /// 取 PosterCard / GlassChip 内部 TvFocusable 的 Focus 节点
  /// （这两个卡片是 Focus 的父级，不能直接 Focus.of；TvFocusable 的
  /// Focus 一定显式挂了 focusNode，直接读 widget 上的节点）。
  /// skipOffstage 双侧 false：offstage（首屏之下）的卡片也要能取到
  /// 内部节点。
  FocusNode _innerNode(Element item) {
    final inner = find
        .descendant(
          of: find.byWidget(item.widget, skipOffstage: false),
          matching: find.byType(Focus, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    return tester.widget<Focus>(inner).focusNode!;
  }

  /// 分类 chips：skipOffstage 双侧传 false——izuko 版式首屏被 hero +
  /// 推荐行占满，分类栏在首屏之下（offstage），descendant 外层与内层
  /// byType 任一为 true 都会把它滤掉（Flutter 3.47：descendant 的
  /// skipOffstage 默认 true）。
  List<(String, FocusNode)> get _chips => [
    for (final e in tester.elementList(
      find.descendant(
        of: _home,
        matching: find.byType(GlassChip, skipOffstage: false),
        skipOffstage: false,
      ),
    ))
      ((e.widget as GlassChip).label, _innerNode(e)),
  ];

  /// 墙网格（grid）的海报：只认 `home-wall-*` 键，与「为你推荐」行
  /// （`home-shelf-*`）区分——两份内容有重复条目，按 vod.id 找不到。
  /// skipOffstage: false：izuko 版式首屏被 hero + 推荐行占满，网格在
  /// 首屏之下（offstage），默认 finder 看不见。
  List<(int, FocusNode)> get _wallPosters => [
    for (final e in tester.elementList(
      find.byWidgetPredicate(
        (widget) =>
            widget is PosterCard &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('home-wall-'),
        skipOffstage: false,
      ),
    ))
      (
        int.parse((e.widget.key! as ValueKey<String>).value.substring(10)),
        _innerNode(e),
      ),
  ];

  /// 「为你推荐」行的海报（`home-shelf-*` 键）。
  List<(int, FocusNode)> get _shelfPosters => [
    for (final e in tester.elementList(
      find.byWidgetPredicate(
        (widget) =>
            widget is PosterCard &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('home-shelf-'),
        skipOffstage: false,
      ),
    ))
      (
        int.parse((e.widget.key! as ValueKey<String>).value.substring(11)),
        _innerNode(e),
      ),
  ];

  /// hero「查看详情」CTA 的焦点节点。
  FocusNode get heroCta => tester
      .widget<TvFocusable>(
        find.byKey(const ValueKey('home-hero-cta'), skipOffstage: false),
      )
      .focusNode!;

  FocusNode get siteChip => Focus.of(
    tester.element(
      find
          .descendant(
            of: _home,
            matching: find.byIcon(Icons.expand_more_rounded),
          )
          .first,
    ),
  );

  ScrollPosition get pageScroll => tester
      .widget<CustomScrollView>(
        find.descendant(of: _home, matching: find.byType(CustomScrollView)),
      )
      .controller!
      .position;

  /// hero 当前标题（手动/自动切换的观测点）。
  String? get heroTitle =>
      tester.widget<Text>(find.byKey(const ValueKey('home-hero-title'))).data;

  // 按数据身份取节点（按 key 定位，滚动后也不受 onstage 影响）。
  FocusNode wallPoster(int index) => tester
      .widget<PosterCard>(
        find.byKey(ValueKey('home-wall-$index'), skipOffstage: false),
      )
      .focusNode!;

  FocusNode shelfPoster(int index) => tester
      .widget<PosterCard>(
        find.byKey(ValueKey('home-shelf-$index'), skipOffstage: false),
      )
      .focusNode!;

  static const _namedIcons = <String, IconData>{
    '站点chip': Icons.expand_more_rounded,
    '搜索': Icons.search_rounded,
    '刷新': Icons.refresh_rounded,
    '设置': Icons.settings_rounded,
  };

  /// 焦点节点的身份描述：把 primaryFocus 跟各地标节点做同一性比较。
  String describe() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return 'null（焦点丢失）';
    if (entry != null && identical(node, entry)) {
      return 'entry（= hero CTA）';
    }
    for (final e in _namedIcons.entries) {
      final found = find.descendant(of: _home, matching: find.byIcon(e.value));
      if (found.evaluate().isEmpty) continue;
      if (identical(Focus.of(tester.element(found.first)), node)) {
        return '页头·${e.key}';
      }
    }
    for (final c in _chips) {
      if (identical(c.$2, node)) return '分类chip[${c.$1}]';
    }
    for (final s in _shelfPosters) {
      if (identical(s.$2, node)) return '推荐行[${s.$1}]';
    }
    for (final p in _wallPosters) {
      if (identical(p.$2, node)) return '网格[${p.$1}]';
    }
    return '${node.debugLabel ?? 'TvFocusable'} rect=${node.rect}';
  }

  /// 打印方向遍历会用到的关键几何（节点 rect，全局逻辑坐标）。
  void dump() {
    final sb = StringBuffer('    [几何]');
    for (final e in _namedIcons.entries) {
      final found = find.descendant(of: _home, matching: find.byIcon(e.value));
      if (found.evaluate().isEmpty) continue;
      sb.write(' ${e.key}=${Focus.of(tester.element(found.first)).rect};');
    }
    for (final c in _chips) {
      sb.write(' chip[${c.$1}]=${c.$2.rect};');
    }
    for (final p in _wallPosters) {
      sb.write(' wall[${p.$1}]=${p.$2.rect};');
    }
    debugPrint('$sb\n');
  }
}

Future<Landmarks> pumpHome(
  WidgetTester tester, {
  FocusNode? entry,
  bool disableAnimations = true,
  String? secondTitle,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = buildController(secondTitle: secondTitle);
  await tester.pumpWidget(
    harness(
      controller,
      HomePage(entryFocus: entry),
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pumpAndSettle();
  final marks = Landmarks(tester);
  marks.entry = entry;
  return marks;
}

Future<void> teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

/// izuko 版式首屏被 hero + 为你推荐占满，分类栏/网格在首屏之下：
/// 上滑把它们露出来再点按（分类 chips 的 tap 场景需要）。
Future<void> revealWall(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -420));
  await tester.pumpAndSettle();
}

void main() {
  // 场景 1：加载完成 → entry 获焦（hero CTA，shell 入口焦点挂它）→ UP
  // 落到页头站点 chip。
  testWidgets('场景1: 加载完成 entry 落 hero CTA，UP 到页头站点 chip', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    expect(entry.hasFocus, isTrue);
    expect(marks.heroCta, entry);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final siteChip = Focus.of(
      tester.element(
        find
            .descendant(
              of: marks._home,
              matching: find.byIcon(Icons.expand_more_rounded),
            )
            .first,
      ),
    );
    expect(FocusManager.instance.primaryFocus, siteChip);
    await teardown(tester);
  });

  // 场景 1a：hero → 分类栏 → 推荐行 → 网格 的 DOWN 链与 UP 回链
  //（每层确定性投递，不赌几何遍历）。
  testWidgets('场景1a: hero→分类栏→推荐行→网格 逐层 DOWN/UP', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    // hero DOWN → 分类栏「全部」（贴 hero 下缘的导航条）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      allChip.$2,
      reason: 'hero DOWN 应落分类栏「全部」',
    );
    // 分类栏 DOWN → 「为你推荐」记忆项（首卡）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.shelfPoster(0));
    // 推荐行 DOWN → 网格首项。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.wallPoster(0));
    // 回链：网格首项 UP → 推荐行记忆项；推荐行 UP → 「全部」；
    // 「全部」UP → hero CTA；hero UP → 站点 chip。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.shelfPoster(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, allChip.$2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, entry);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final siteChip = Focus.of(
      tester.element(
        find
            .descendant(
              of: marks._home,
              matching: find.byIcon(Icons.expand_more_rounded),
            )
            .first,
      ),
    );
    expect(FocusManager.instance.primaryFocus, siteChip);
    expect(siteChip.rect.top, greaterThanOrEqualTo(0));
    expect(siteChip.rect.bottom, lessThanOrEqualTo(720));
    await teardown(tester);
  });

  // 场景 1b：真实 shell（izuko 式左侧导航栏）：启动后壳层帧末把默认
  // 焦点投进内容区（首页入口 = hero CTA）；内容区 LEFT 进侧栏，侧栏
  // RIGHT 回内容区。
  testWidgets('场景1b: shell 内容区默认落 hero CTA，LEFT 进侧栏 RIGHT 回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    await tester.pumpWidget(harness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    final marks = Landmarks(tester);
    // 壳层启动默认焦点落内容区入口（hero CTA）。
    expect(marks.heroCta.hasFocus, isTrue);
    // 内容区 LEFT → 侧栏当前条目（izuko：侧栏只能从内容区按左键进入）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'rail-0');
    // 侧栏 RIGHT → 焦点回内容区入口。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.heroCta);
    // hero DOWN → 分类栏「全部」；UP → 回 hero。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    expect(FocusManager.instance.primaryFocus, allChip.$2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.heroCta);
    await teardown(tester);
  });

  // 场景 1c：hero 焦点上 LEFT/RIGHT 手动切换轮播（标题跟着换）。
  testWidgets('场景1c: hero 焦点上左右键手动切换轮播', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    expect(marks.heroTitle, '测试影片 0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(marks.heroTitle, '测试影片 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(marks.heroTitle, '测试影片 2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(marks.heroTitle, '测试影片 1');
    // 回拨到第一项；再按 LEFT 不翻页（izuko：第一项按左交给侧栏通道，
    // 独立挂载下无 shell 接管——焦点停在 hero，不崩溃）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(marks.heroTitle, '测试影片 0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(marks.heroTitle, '测试影片 0');
    await teardown(tester);
  });

  testWidgets('轮播快速切换和反向时保留 CTA 焦点，首项左键交侧栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const ShellPage(), disableAnimations: false),
    );
    await tester.pumpAndSettle();
    final marks = Landmarks(tester);
    final cta = marks.heroCta;
    const right = LogicalKeyboardKey.arrowRight;
    const left = LogicalKeyboardKey.arrowLeft;
    await tester.sendKeyDownEvent(right);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.sendKeyRepeatEvent(right);
    await tester.sendKeyUpEvent(right);
    await tester.pump();
    expect(marks.heroTitle, '测试影片 2');
    expect(FocusManager.instance.primaryFocus, cta);

    await tester.sendKeyDownEvent(left);
    await tester.sendKeyRepeatEvent(left);
    await tester.sendKeyRepeatEvent(left);
    await tester.sendKeyUpEvent(left);
    await tester.pumpAndSettle();
    expect(marks.heroTitle, '测试影片 0');
    expect(FocusManager.instance.primaryFocus, cta);

    await tester.sendKeyEvent(left);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'rail-0');
    await tester.sendKeyEvent(right);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, cta);
    await teardown(tester);
  });

  testWidgets('推荐行滚动中连按 UP 返回轮播，完整轮播可见', (tester) async {
    final marks = await pumpHome(tester, disableAnimations: false);
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部').$2;
    final initialHero = tester.getRect(find.byType(HomeHeroCarousel));
    final initialScroll = marks.pageScroll.pixels;
    const down = LogicalKeyboardKey.arrowDown;
    const up = LogicalKeyboardKey.arrowUp;

    await tester.sendKeyEvent(down);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, allChip);
    final beforeShelfScroll = marks.pageScroll.pixels;
    await tester.sendKeyEvent(down);
    await tester.pump();
    await tester.pump(); // 启动滚动动画的第一个 tick。
    await tester.pump(const Duration(milliseconds: 40));
    expect(FocusManager.instance.primaryFocus, marks.shelfPoster(0));
    expect(marks.pageScroll.pixels, greaterThan(beforeShelfScroll));
    expect(marks.pageScroll.isScrollingNotifier.value, isTrue);
    await tester.sendKeyEvent(up);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, allChip);
    await tester.sendKeyEvent(up);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.heroCta);
    expect(marks.pageScroll.pixels, initialScroll);
    expect(tester.getRect(find.byType(HomeHeroCarousel)), initialHero);

    await tester.sendKeyEvent(up);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, marks.siteChip);
    await tester.sendKeyEvent(down);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.heroCta);
    expect(tester.getRect(find.byType(HomeHeroCarousel)), initialHero);
    await teardown(tester);
  });

  // 场景 1d：自动轮播——展开态每 6s 推进；手动切换重置计时；
  // 移开焦点（减弱态）停止。
  testWidgets('场景1d: hero 展开态自动轮播，手动切换重置计时', (tester) async {
    // 关掉 disableAnimations：AppMotion.reduced 为 false，计时器才会启动。
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(
      tester,
      entry: entry,
      disableAnimations: false,
    );
    expect(entry.hasFocus, isTrue); // hero 展开态（焦点在 CTA 上）。
    expect(marks.heroTitle, '测试影片 0');
    // 6s 间隔：推进到第 2 项。
    await tester.pump(const Duration(seconds: 7));
    expect(marks.heroTitle, '测试影片 1');
    // 手动 RIGHT → 第 3 项，且计时重置。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(marks.heroTitle, '测试影片 2');
    // 5s < 6s：不重推。
    await tester.pump(const Duration(seconds: 5));
    expect(marks.heroTitle, '测试影片 2');
    // 再 2s（累计 7s > 6s）：推进到第 4 项。
    await tester.pump(const Duration(seconds: 2));
    expect(marks.heroTitle, '测试影片 3');
    await teardown(tester);
  });

  testWidgets('轮播等长标题露出尾部再自动换片', (tester) async {
    final longTitle = '测试轮播长标题' * 5;
    final marks = await pumpHome(
      tester,
      disableAnimations: false,
      secondTitle: longTitle,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(marks.heroTitle, longTitle);
    final title = find.byKey(const ValueKey('home-hero-title'));
    final viewport = find.byKey(const ValueKey('home-hero-title-viewport'));

    await tester.pump(const Duration(seconds: 6));
    expect(marks.heroTitle, longTitle);
    await tester.pump(const Duration(milliseconds: 4100));
    expect(marks.heroTitle, longTitle);
    expect(
      tester.getRect(title).right,
      closeTo(tester.getRect(viewport).right, 1),
    );

    await tester.pump(const Duration(seconds: 1));
    expect(marks.heroTitle, '测试影片 2');
    expect(marks.heroCta.hasPrimaryFocus, isTrue);
    await teardown(tester);
  });

  // 场景 1e：减弱动态（disableAnimations）下自动轮播关闭。
  testWidgets('场景1e: 减弱动态下 hero 不自动轮播', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    expect(entry.hasFocus, isTrue);
    await tester.pump(const Duration(seconds: 30));
    expect(marks.heroTitle, '测试影片 0');
    await teardown(tester);
  });

  testWidgets('轮播移焦或被不抢焦的路由覆盖时停表，返回后重新计时', (tester) async {
    final marks = await pumpHome(tester, disableAnimations: false);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(marks.heroTitle, '测试影片 0');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.siteChip);
    await tester.pump(const Duration(seconds: 7));
    expect(marks.heroTitle, '测试影片 0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.heroCta);

    navigator.push<void>(
      DialogRoute<void>(
        context: marks.heroCta.context!,
        requestFocus: false,
        builder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.heroCta);
    await tester.pump(const Duration(seconds: 7));
    expect(marks.heroTitle, '测试影片 0');
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(marks.heroTitle, '测试影片 0');
    await tester.pump(const Duration(seconds: 2));
    expect(marks.heroTitle, '测试影片 1');
    await teardown(tester);
  });

  testWidgets('场景1f: 轮播随首页内容一起滚动', (tester) async {
    final marks = await pumpHome(tester);
    final hero = find.byType(HomeHeroCarousel, skipOffstage: false);
    final top = tester.getRect(hero);
    marks.pageScroll.jumpTo(top.bottom + 20);
    await tester.pump();
    expect(tester.getRect(hero).bottom, lessThanOrEqualTo(0));
    marks.pageScroll.jumpTo(0);
    await tester.pump();
    expect(tester.getRect(hero), top);
    await teardown(tester);
  });

  // 场景 2：切到分类「电影」（网格接管）→ DOWN 进网格 →
  // 右移两格 → UP。统一落分类栏「全部」chip（不随列漂移）。
  testWidgets('场景2: 网格中部 UP 统一落分类栏「全部」chip', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    // 分类栏在首屏之下（izuko 版式）：先上滑露出来再点按。
    await revealWall(tester);
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    expect(FocusManager.instance.primaryFocus, allChip.$2);
    await teardown(tester);
  });

  // 场景 3：网格内部 UP 按空间顺序上行——第 2 行（1280 画布 5 列下
  // 即「第 2 行第 1 列」）应回到第 1 行同列（网格[0]）；只有首行 UP
  // 才出网格，落「为你推荐」记忆项（稳定落点，不随列漂移）。
  testWidgets('场景3: 跨行 UP 落上一行同列，首行 UP 逐层退出到页头', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    await revealWall(tester);
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    final firstPoster = marks.wallPoster(0);
    marks.wallPoster(5).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      firstPoster,
      reason: '第 2 行 UP 应回到第 1 行同列（AGENTS.md §3 规则 2：空间顺序）',
    );
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    // 首行 UP → 「为你推荐」记忆项（墙网格正上方的行）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      marks.shelfPoster(0),
      reason: '网格首行 UP 应落推荐行记忆项（稳定落点，不随列漂移）',
    );
    // 推荐行再 UP：落分类栏「全部」。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, allChip.$2);
    // 分类栏再 UP：落 hero CTA。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, entry);
    await teardown(tester);
  });

  // 场景 4（几何对照）：第 2 行 → UP → 第 1 行同列 → UP → 「为你推荐」
  // 记忆项 → UP → 分类栏「全部」→ UP → hero。断言「逐层上行」的层级
  // 语义（旧实现分类栏之上直接跳页头，推荐行/hero 层不存在）。
  testWidgets('场景4: 网格内 UP 逐层上行（网格→推荐行→分类栏→hero）', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    final firstPoster = marks.wallPoster(0);
    marks.wallPoster(5).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      firstPoster,
      reason: '第 2 行 UP 应回到第 1 行同列，不跳出网格',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.shelfPoster(0));
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, allChip.$2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, entry);
    await teardown(tester);
  });

  // 场景 4b（探针）：直接 requestFocus 到分类栏「全部」chip → UP。
  // 层级语义：从分类栏 UP → hero CTA。
  testWidgets('场景4b: 分类栏 UP 落到 hero CTA', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    allChip.$2.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, entry);
    await teardown(tester);
  });

  // 场景 4c（探针）：hero DOWN 直投分类栏，再直投网格首项 → UP。
  // 层级投递接管：落「为你推荐」记忆项。
  testWidgets('场景4c: DOWN 直投分类栏，网格直投后 UP 落推荐行记忆项', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    expect(FocusManager.instance.primaryFocus, allChip.$2);
    marks.wallPoster(0).requestFocus();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.wallPoster(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.shelfPoster(0));
    await teardown(tester);
  });

  // 场景 4d（焦点体系重建）：页头行 / 分类栏 / 推荐行的行内 LEFT/RIGHT
  // 显式投递——重建前这些格子放行给框架几何遍历，而壳层根 Focus 拦截
  // 一切未消费的 LEFT，行内左移全部跳丢进侧栏（真机「焦点移动困难」
  // 的核心症状）。重建后行内移动显式投递，行首/最左列才 pass 进侧栏。
  testWidgets('场景4d: 页头行/分类栏/推荐行行内 LEFT/RIGHT 显式移动', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);

    // 页头行：站点 chip → RIGHT → 搜索 → RIGHT → 刷新 → RIGHT → 设置。
    final siteChip = Focus.of(
      tester.element(
        find
            .descendant(
              of: marks._home,
              matching: find.byIcon(Icons.expand_more_rounded),
            )
            .first,
      ),
    );
    siteChip.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home-header-search',
      reason: '页头站点 chip RIGHT 应落搜索',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home-header-refresh',
      reason: '搜索 RIGHT 应落刷新',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home-header-settings',
      reason: '刷新 RIGHT 应落设置（行尾）',
    );
    // 行尾（设置）RIGHT：吞键停住（焦点不丢、不飞出内容列）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home-header-settings',
    );
    // 设置 LEFT → 刷新 → 站点 chip（行内回程）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home-header-refresh',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home-header-search',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, siteChip);

    // 分类栏：全部 → RIGHT → 电影 → RIGHT → 电视剧（记账节点）。
    final allChip = marks._chips.firstWhere((c) => c.$1 == '全部');
    allChip.$2.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      marks._chips.firstWhere((c) => c.$1 == '电影').$2,
      reason: '分类栏「全部」RIGHT 应落「电影」',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      marks._chips.firstWhere((c) => c.$1 == '电视剧').$2,
      reason: '「电影」RIGHT 应落「电视剧」（行尾）',
    );
    // 行尾 RIGHT：吞键停住。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      marks._chips.firstWhere((c) => c.$1 == '电视剧').$2,
    );
    // 回程：「电视剧」LEFT → 「电影」→ 「全部」。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      marks._chips.firstWhere((c) => c.$1 == '电影').$2,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, allChip.$2);

    // 推荐行：首卡 → RIGHT → 第 2 卡（记账节点 home-shelf-1）。
    final shelf0 = marks.shelfPoster(0);
    shelf0.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      marks.shelfPoster(1),
      reason: '推荐行首卡 RIGHT 应落第 2 卡',
    );
    // 第 2 卡 LEFT → 回第 1 卡（重建前此键跳丢进侧栏）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, shelf0);
    await teardown(tester);
  });

  // 场景 4e（焦点体系重建）：网格行内 LEFT/RIGHT 显式移动——最左列
  // LEFT 才 pass 进侧栏（spec §3 唯一入口），其余列行内左移一格。
  testWidgets('场景4e: 网格行内 LEFT/RIGHT 显式移动，最左列 LEFT 进侧栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness(buildController(), const ShellPage()));
    await tester.pumpAndSettle();
    final marks = Landmarks(tester);
    final first = marks.wallPoster(0);
    first.requestFocus();
    await tester.pump();

    // 网格[1] → LEFT → 网格[0]（行内左移一格）。
    marks.wallPoster(1).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, first);

    // 网格[1] → RIGHT → 网格[2]（行内右移一格）。
    marks.wallPoster(1).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, marks.wallPoster(2));

    // 网格[0]（最左列）LEFT：pass → 壳层根 Focus 投侧栏当前条目。
    first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'rail-0',
      reason: '网格最左列 LEFT 应进侧栏（spec §3 唯一进侧栏入口）',
    );
    await teardown(tester);
  });

  // 场景 5（回归）：页头行 UP 在无 shell 的独立挂载下放行默认遍历
  // （onExitToNav 为 null）——焦点停在页头，不崩溃、不丢失。
  testWidgets('场景5: 独立挂载页头 UP 放行默认遍历（焦点不丢失）', (tester) async {
    final entry = FocusNode(debugLabel: 'home-entry');
    addTearDown(entry.dispose);
    final marks = await pumpHome(tester, entry: entry);
    final siteChip = Focus.of(
      tester.element(
        find
            .descendant(
              of: marks._home,
              matching: find.byIcon(Icons.expand_more_rounded),
            )
            .first,
      ),
    );
    siteChip.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(FocusManager.instance.primaryFocus, siteChip);
    await teardown(tester);
  });
}
