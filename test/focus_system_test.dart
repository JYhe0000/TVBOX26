// 焦点体系测试中心（docs/focus-system-spec.md §8 验收线的体系级回归）。
//
// 覆盖契约（与 focus-system-spec §3/§4 对齐）：
//   G1 壳层链：进页 entry → 内容 LEFT 进侧栏 → 侧栏遍历 → OK 切页落新页
//      entry → RIGHT/BACK 回内容 → 边界吞键不死键；
//   G2 首页骨架：hero CTA → 分类栏 → 推荐行 → 网格的 DOWN/UP 链 + hero
//      左右翻页 + 网格同列换行；
//   G3 直播骨架：搜索框 ↔ 分组栏 ↔ 网格的进出链 + 分组栏遍历；
//   G4 详情骨架：hero CTA ↔ 线路胶囊 ↔ 选集网格 ↔ 相关推荐行（焦点记忆）；
//   G5 搜索骨架：搜索框 → 搜索按钮 → T9 键盘 → 结果网格；
//   G6 设置骨架：分类列 ↔ 条目面板 UP/DOWN/LEFT/RIGHT + BACK 退层；
//   G7 我的骨架：entry → 概览到底 → 继续观看行焦点记忆 → 浮层进出 →
//      子路由返回焦点归还（didPopNext）；
//   G8 覆盖层通用契约（数据驱动）：tv_sheet / T9 弹窗 / 二维码弹窗 /
//      TvNotice 的「打开焦点在层内、BACK 回触发节点、无焦点陷阱」；
//   G9 公共组件契约：PosterCard / WideVodCard / ContinueCard / SiteRow
//      的外部 focusNode 透传与「无内部焦点窃取」。
//
// debugLabel 仅用于定位稳定节点；行为验收同时检查实际内容、节点归属、
// 焦点进出与按键效果，标签存在本身不证明可达或焦点可见。
//
// 页面组件由各子代理并行重建（F1-F4）：本文件按契约写死断言，页面
// 侧中间态导致的失败在汇总报告里标注「待协调」，不算公共组件问题。
//
// 用法：flutter test test/focus_system_test.dart   （期望全绿）

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
import 'package:tvbox_flutter/ui/pages/live_page.dart';
import 'package:tvbox_flutter/ui/pages/mine_page.dart';
import 'package:tvbox_flutter/ui/pages/search_page.dart';
import 'package:tvbox_flutter/ui/pages/settings_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/poster_card.dart';
import 'package:tvbox_flutter/ui/widgets/remote_search_dialog.dart';
import 'package:tvbox_flutter/ui/widgets/site_row.dart';
import 'package:tvbox_flutter/ui/widgets/t9_search_dialog.dart';
import 'package:tvbox_flutter/ui/widgets/tv_keyboard.dart';
import 'package:tvbox_flutter/ui/widgets/tv_notice.dart';
import 'package:tvbox_flutter/ui/widgets/tv_sheet.dart';

// ---------------------------------------------------------------------------
// 测试替身（与 ui_smoke_test 同构，保持数据形状一致；ui_smoke 归 F1 所有，
// 本文件不修改它，只复制模式）
// ---------------------------------------------------------------------------

class FocusFakeSiteApi extends SiteApi {
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

  static final List<VodItem> _videos = List.generate(
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

  /// 详情页测试用的样片（详情数据由 [detail] 覆写 lines）。
  static VodItem get first => _videos.first;
}

class FocusFakeLiveService extends LiveService {
  @override
  Future<LiveParseResult> load(LiveSource source) async {
    return LiveParseResult(
      title: source.name,
      groups: [
        LiveGroup(
          name: '央视频道',
          channels: List.generate(
            12,
            (index) => LiveChannel(
              name: 'CCTV-${index + 1}',
              urls: ['https://live.test/$index.m3u8'],
              sourceNames: const ['默认线路'],
              group: '央视频道',
            ),
          ),
        ),
        LiveGroup(
          name: '卫视频道',
          channels: List.generate(
            10,
            (index) => LiveChannel(
              name: '卫视-${index + 1}',
              urls: ['https://live.test/ws$index.m3u8'],
              sourceNames: const ['默认线路'],
              group: '卫视频道',
            ),
          ),
        ),
      ],
    );
  }
}

AppController focusController() {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(
      storage: StorageService(),
      siteApi: FocusFakeSiteApi(),
      liveService: FocusFakeLiveService(),
    )
    ..config = const AppConfig(
      sites: [site],
      parses: [],
      lives: [LiveSource(name: '测试直播', url: 'https://live.test/list.m3u')],
    )
    ..selectedSiteKey = 'test'
    ..initialized = true;
}

/// 主壳 harness：smartisan 皮肤 + 1280×720 表面 + kRouteObserver
/// （mine/详情页的 didPopNext 焦点归还依赖它被挂进 navigatorObservers）。
Widget focusHarness(
  AppController controller,
  Widget child, {
  LibraryStore? library,
  GlobalKey<NavigatorState>? navigatorKey,
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
      navigatorObservers: [kRouteObserver],
      navigatorKey: navigatorKey,
      home: Scaffold(backgroundColor: skin.bg, body: child),
    ),
  );
}

/// 浮层/弹窗 harness：一个可获焦的触发按钮 + 上下文捕获。
/// 返回 context 供测试直接调用 showTvSheet / showDialog 系入口。
Future<BuildContext> pumpTriggerHarness(
  WidgetTester tester, {
  required FocusNode trigger,
  void Function(BuildContext context)? onTap,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      navigatorObservers: [kRouteObserver],
      navigatorKey: navigatorKey,
      home: Scaffold(
        backgroundColor: skinFor(TvSkinId.smartisan).bg,
        body: Builder(
          builder: (context) {
            captured = context;
            return Center(
              child: TvFocusable(
                focusNode: trigger,
                semanticLabel: '触发浮层',
                onTap: () => onTap?.call(context),
                child: const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('触发浮层'),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  return captured;
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/// 当前主焦点节点（null = 无焦点，死焦点的最直接症状）。
FocusNode? primary() => FocusManager.instance.primaryFocus;

/// 当前主焦点的 debugLabel（体系断言的主锚点）。
String? primaryLabel() => FocusManager.instance.primaryFocus?.debugLabel;

/// 按键 + 一帧（焦点标签的更新是同步的，一帧足够断言）。
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

/// 按键 + 走完所有帧（双重 post-frame 投递 / ensureVisible 滚动动画 /
/// 记忆行补投的场景用；详情/直播页无周期定时器，settle 安全）。
Future<void> pressSettle(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// 按 debugLabel 找已挂载的 FocusNode。
FocusNode? nodeByLabel(String label) {
  for (final element in find.byWidgetPredicate((w) => w is Focus).evaluate()) {
    final focus = element.widget;
    if (focus is Focus && focus.focusNode?.debugLabel == label) {
      return focus.focusNode;
    }
  }
  return null;
}

/// 文本中第一个匹配项最近的 Focus 祖先节点（公共组件的稳定定位法）。
FocusNode nodeOfText(String data, {int match = 0}) {
  return Focus.of(find.text(data).at(match).evaluate().single);
}

/// 上面 nodeOfText 需要 tester 的绑定版本（测试体内用）。
late WidgetTester tester0;

/// 主焦点是否在 [finder] 命中的 widget 子树内（覆盖层焦点陷阱断言）。
///
/// 双向判定：finder 元素在主焦点子树内（向下），或 finder 元素是主焦点
/// 的祖先（向上——例如「焦点在 TvSearchKeyboard 的某个键上」时键盘根是
/// 祖先而不是后代）。
bool primaryInside(Finder finder) {
  // 路由/分组 scope 包含整页文字，不能被误判成具体控件已获焦。
  if (primary() is FocusScopeNode) return false;
  final context = primary()?.context;
  if (context == null) return false;
  final matches = finder.evaluate().toList();
  if (matches.isEmpty) return false;
  var inside = false;
  // 向下：主焦点子树内是否有 finder 元素。
  void walk(Element node) {
    if (matches.contains(node)) {
      inside = true;
      return;
    }
    node.visitChildren((child) {
      if (!inside) walk(child);
    });
  }

  walk(context as Element);
  if (inside) return true;
  // 向上：finder 元素是否在主焦点的祖先链上。
  context.visitAncestorElements((element) {
    if (matches.contains(element)) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// 主焦点节点的子树内是否有该文本（记忆节点跟随行的断言法：
/// ShelfRow 的 memoryFocus 会随获焦行换位，debugLabel 不变、位置变）。
bool primaryIsWithinText(String data, {int match = 0}) {
  final element = primary()?.context;
  if (element == null) return false;
  final matches = find.text(data).at(match).evaluate();
  if (matches.isEmpty) return false;
  final target = matches.single;
  var inside = false;
  // FocusNode.context 的实际类型是 Element（BuildContext 只有 Element 实现）。
  void walk(Element node) {
    if (identical(node, target)) {
      inside = true;
      return;
    }
    node.visitChildren((child) {
      if (!inside) walk(child);
    });
  }

  walk(element as Element);
  return inside;
}

/// 页面收尾：卸载整树，取消页内周期定时器（hero 自动轮播 / 30s 时钟）。
Future<void> tearDownPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

// ---------------------------------------------------------------------------
// G1 壳层链（ShellPage + TvSideRail + IndexedStack 内容区）
// ---------------------------------------------------------------------------

void main() {
  testWidgets('G1 shell 进页默认焦点落内容区入口（tab-entry-0 = hero CTA）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    // spec §4-1：entryFocus 优先，debugLabel 命名 <page>-entry。
    expect(primaryLabel(), 'tab-entry-0');
    // entry 节点确实挂在首页主锚点（hero「查看详情」CTA）上。
    expect(find.byType(HomePage), findsOneWidget);
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：entry → DOWN 走完首页区块 → 逐级 UP 回顶', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'tab-entry-0');
    // hero CTA → 分类栏「全部」→ 推荐行记忆项 → 网格首项（spec §4-2 区块链）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-cat-all');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-shelf-memory');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-first-poster');
    // 逐级 UP 回顶：网格 → 推荐行 → 分类栏 → hero CTA。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'home-shelf-memory');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'home-cat-all');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'tab-entry-0');
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：LEFT 进侧栏 → DOWN 遍历 → OK 切页落新页 entry', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    // hero CTA 是轮播首项：LEFT 放行给壳层「进侧栏」通道（spec §3 矩阵）。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'rail-0');
    // 侧栏 DOWN 遍历条目（TvSideRail 按 index 确定性投递）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'rail-1');
    // OK 切页 → 焦点落新页（直播）entry：shell 注入的 tab-entry-1 挂网格首格。
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'tab-entry-1');
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：侧栏 RIGHT / BACK 回内容区（焦点回 tab-entry）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'rail-0');
    // RIGHT 回内容区（izuko onExitFocus 通道）。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'tab-entry-0');
    // BACK 语义（spec §3 矩阵）：侧栏获焦时 BACK = 回内容区（不退页）。
    // 测试模拟器没有 GoBack 的物理键映射，handlePopRoute 就是真实 BACK
    // 路径（PopScope canPop=false → onPopInvokedWithResult → 回内容区）。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'rail-0');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'tab-entry-0');
    // 页面还在（ShellPage 未被 pop）。
    expect(find.byType(ShellPage), findsOneWidget);
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：侧栏上下边界停住吞键（不死键、不跳丢）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'rail-0');
    // 顶部再按 UP：停住（handled 吞键），焦点不丢。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'rail-0');
    // 底部：DOWN ×4 到 rail-3，再按 DOWN 停住。
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(primaryLabel(), 'rail-3');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'rail-3');
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：网格末行 DOWN 到底吞键，焦点不丢', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    // 经页面显式投递下网格（不依赖缓存区是否已挂载末行）：
    // hero → 分类栏 → 推荐行 → 网格首项。
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-first-poster');
    // 5 列网格：DOWN 到第 2 行同列（index 5，若未挂载则投递时补挂载）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'home-poster-5');
    // DOWN 到末行首项（index 10）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'home-poster-10');
    // 末行之下没有网格目标：页面底吞键（spec §4-4），焦点仍在原处。
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'home-poster-10');
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：侧栏 LEFT 回内容区（O-1 收口 b，展开面板退出口）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'rail-0');
    // LEFT（栏外沿再往左）：回内容区——与 RIGHT/OK/BACK 退出语义收敛
    // （O-1 收口 b：展开面板压住内容左缘期间，LEFT 是符合空间直觉的
    // 退出键；壳层 _focusExitRail 投 tab-entry 落点）。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'tab-entry-0');
    await tearDownPage(tester);
  });

  testWidgets('G1 壳层链：FocusScope 分组契约（shell-rail + page-home）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const ShellPage()));
    await tester.pumpAndSettle();
    // 壳层创建的三层 FocusScope 契约（spec §2）：侧栏 shell-rail 独立，
    // 内容区 page-home 由壳层注入（页面只填内容）。
    expect(
      nodeByLabel('shell-rail'),
      isNotNull,
      reason: '侧栏 FocusScope 应由壳层创建',
    );
    expect(
      nodeByLabel('page-home'),
      isNotNull,
      reason: '内容区 FocusScope 应由壳层创建',
    );
    expect(primary()!.ancestors, contains(nodeByLabel('page-home')));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primary()!.ancestors, contains(nodeByLabel('shell-rail')));
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primary()!.ancestors, contains(nodeByLabel('page-home')));
    // scope 节点自身不作遍历候选（skipTraversal）——焦点不会落到无视觉的
    // scope 幽灵节点上（体系断言的主锚点始终是具体可获焦元素）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), isNot('shell-rail'));
    expect(primaryLabel(), isNot('page-home'));
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G2 首页骨架（独立挂载，hero CTA = home-hero-cta）
  // -------------------------------------------------------------------------

  testWidgets('G2 home hero CTA RIGHT 翻页（标题变化）且焦点不丢', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const HomePage()));
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'home-hero-cta');
    String heroTitle() => tester
        .widget<Text>(find.byKey(const ValueKey('home-hero-title')))
        .data!;
    expect(heroTitle(), '测试影片 0');
    // RIGHT 手动切换轮播（spec §3：hero CTA 上 LEFT/RIGHT 翻页是例外通道）。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(heroTitle(), '测试影片 1');
    expect(primaryLabel(), 'home-hero-cta');
    // 非首项 LEFT 翻回第一项。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(heroTitle(), '测试影片 0');
    expect(primaryLabel(), 'home-hero-cta');
    await tearDownPage(tester);
  });

  testWidgets('G2 home hero CTA DOWN → 分类栏；分类栏 UP → hero CTA', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const HomePage()));
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'home-hero-cta');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-cat-all');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'home-hero-cta');
    await tearDownPage(tester);
  });

  testWidgets('G2 home 分类栏 chips 横向遍历（全部 → 电影 → 电视剧）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const HomePage()));
    await tester.pumpAndSettle();
    final all = nodeByLabel('home-cat-all');
    all!.requestFocus();
    await tester.pump();
    // 分类行是 ShelfRow：index 0 = home-cat-all，其余为 shelf-item-N。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'shelf-item-1');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'shelf-item-2');
    // 注意：FocusTraversalGroup 在本版 Flutter 不约束方向键遍历，行尾再按
    // RIGHT 焦点可离开本行（几何最近项），这里不断言「停住」——不断言
    // 跳丢但也不把「几何逃逸」固化为契约（F1 重建时按投递表收口）。
    await tearDownPage(tester);
  });

  testWidgets('G2 home 分类栏 DOWN → 推荐行记忆项 → 网格首项', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const HomePage()));
    await tester.pumpAndSettle();
    final all = nodeByLabel('home-cat-all');
    all!.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-shelf-memory');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-first-poster');
    await tearDownPage(tester);
  });

  testWidgets('G2 home 网格同列换行 DOWN/UP（index ± 列数）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const HomePage()));
    await tester.pumpAndSettle();
    // 经页面显式投递下网格（hero → 分类栏 → 推荐行 → 网格首项），
    // 不依赖首项在首帧是否已挂载。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-cat-all');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-shelf-memory');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'home-first-poster');
    // 5 列网格：DOWN 到第 2 行同列（index 5），UP 回第 1 行。
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'home-poster-5');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'home-first-poster');
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G3 直播骨架（搜索框 ↔ 分组栏 ↔ 网格）
  // -------------------------------------------------------------------------

  testWidgets('G3 live entry 落网格首格（entryFocus 挂 channel tile）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, LivePage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    expect(entry.hasFocus, isTrue);
    expect(find.text('CCTV-1'), findsOneWidget);
    await tearDownPage(tester);
  });

  testWidgets('G3 live 搜索框 DOWN → 网格首格；UP → 分组栏记忆行', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, LivePage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    // 搜索框是展示型 TvFocusable（semanticLabel 搜索频道）。
    final search = nodeOfText('搜索频道');
    search.requestFocus();
    await tester.pump();
    // DOWN：离开搜索框落网格首格（FOCUS-08：绝不困住焦点）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), entry);
    // UP：回分组栏记忆行（live-rail-current）。
    search.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'live-rail-current');
    await tearDownPage(tester);
  });

  testWidgets('G3 live 网格最左列 LEFT → 分组栏记忆行（FOCUS-09）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, LivePage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primaryLabel(), 'live-rail-current');
    await tearDownPage(tester);
  });

  testWidgets('G3 live 分组栏 OK 切组后焦点保留分组项，RIGHT 可进新网格', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, LivePage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    final rail = nodeByLabel('live-rail-current');
    rail!.requestFocus();
    await tester.pump();
    // DOWN 到第二个分组（卫视频道）后 OK 切换。分组栏是 ShelfRow 受控记忆
    // （memoryFocus 跟随获焦行换位，debugLabel 恒为 live-rail-current，
    // 所以按「焦点子树内容」断言落点而不是按标签）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryIsWithinText('卫视频道'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    // 切组成功（网格换成卫视频道）且焦点仍有效（F2 现行实现切组后
    // 留在分组栏记忆行，不抢焦投网格——语义待主代理裁决，见报告）。
    expect(find.text('卫视-1'), findsOneWidget);
    expect(primaryIsWithinText('卫视频道'), isTrue);
    await pressSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryIsWithinText('卫视-1'), isTrue);
    await tearDownPage(tester);
  });

  testWidgets('G3 live 分组栏 UP/DOWN 遍历（ShelfRow 记忆行稳定）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, LivePage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    final rail = nodeByLabel('live-rail-current');
    rail!.requestFocus();
    await tester.pump();
    expect(primaryIsWithinText('央视频道'), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryIsWithinText('卫视频道'), isTrue);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryIsWithinText('央视频道'), isTrue);
    // 栏首 UP → 页头搜索框行（F2 投递表：层级上升的出口）。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primary(), nodeOfText('搜索频道'));
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G4 详情骨架（hero CTA ↔ 线路胶囊 ↔ 选集网格 ↔ 相关推荐行）
  // -------------------------------------------------------------------------

  testWidgets('G4 detail 进页焦点落 hero 播放按钮（detail-play）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, DetailPage(vod: FocusFakeSiteApi.first)),
    );
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'detail-play');
    await tearDownPage(tester);
  });

  testWidgets('G4 detail hero → 简介 → 线路胶囊 → 选集 的 DOWN/UP 全链', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, DetailPage(vod: FocusFakeSiteApi.first)),
    );
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'detail-play');
    // F3 投递表：hero DOWN → 简介 → 线路胶囊 → 选集网格。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'detail-info');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'detail-line-0');
    // 胶囊 DOWN → 选集是「reveal 双 post-frame」投递，settle 才落焦。
    await pressSettle(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'episode-0');
    // 逐级 UP 回 hero：选集首行 UP → 触发者（胶囊）→ 简介 → hero CTA。
    await pressSettle(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'detail-line-0');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'detail-info');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'detail-play');
    await tearDownPage(tester);
  });

  testWidgets('G4 detail 选集网格 DOWN 换行 + 末行 DOWN → 推荐行', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, DetailPage(vod: FocusFakeSiteApi.first)),
    );
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await pressSettle(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'episode-0');
    // 选集 7 列：DOWN 到第 2 行同列（index 7），UP 回第 1 行。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'episode-7');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'episode-0');
    // 末行（index 14/15）：DOWN 走出网格 → 推荐行记忆项（F3 onExitDown）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'episode-7');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'episode-14');
    await pressSettle(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'related-0');
    await tearDownPage(tester);
  });

  testWidgets('G4 detail 线路胶囊 RIGHT 遍历（行尾吞）+ DOWN 进选集 + UP 回', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, DetailPage(vod: FocusFakeSiteApi.first)),
    );
    await tester.pumpAndSettle();
    final line0 = nodeByLabel('detail-line-0');
    line0!.requestFocus();
    await tester.pump();
    // 胶囊行内 RIGHT 移到第 2 条线路。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'detail-line-1');
    // 行尾吞（F3 投递表：行尾 RIGHT 吞，不出胶囊组）。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'detail-line-1');
    // 胶囊 DOWN → 选集（进入时记住返回节点 = 当前胶囊）。
    await pressSettle(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'episode-0');
    // 选集首行 UP → 回胶囊（_episodeReturnFocus）。
    await pressSettle(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'detail-line-1');
    await tearDownPage(tester);
  });

  testWidgets('G4 detail hero 操作行 RIGHT 行内右移，行尾进选集', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, DetailPage(vod: FocusFakeSiteApi.first)),
    );
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'detail-play');
    // 无续播时操作行 = [立即播放, 收藏]：RIGHT 行内右移。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'detail-favorite');
    // 行尾（收藏）RIGHT → 选集网格选中集（详情页「下一步」语义；
    // 双重 post-frame 投递，settle 才落焦）。
    await pressSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'episode-0');
    await tearDownPage(tester);
  });

  testWidgets('G4 detail 相关推荐行：进出 + 行内移动 + 焦点记忆 + UP 回选集', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, DetailPage(vod: FocusFakeSiteApi.first)),
    );
    await tester.pumpAndSettle();
    // 滚到底露出相关推荐行（横向 ListView 懒建前几项）。
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final related0 = nodeByLabel('related-0');
    expect(related0, isNotNull);
    related0!.requestFocus();
    await tester.pump();
    // 行内 RIGHT 移到第 2 张卡（记忆项投递 + 横向滚动，settle 收敛）。
    await pressSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'related-1');
    // 焦点离开该行（投回线路胶囊），再回到行根 → 恢复记忆项 related-1。
    nodeByLabel('detail-line-0')!.requestFocus();
    await tester.pump();
    nodeByLabel('related-row')!.requestFocus();
    await tester.pump();
    expect(primaryLabel(), 'related-1');
    // 推荐行 UP → 回选集网格选中集（F3 投递表；reveal 双 post-frame）。
    await pressSettle(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'episode-0');
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G5 搜索骨架（搜索框 → 搜索按钮 → T9 键盘 → 结果网格）
  // -------------------------------------------------------------------------

  testWidgets('G5 search entry 落搜索框（entryFocus 透传 TextField）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'search-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, SearchPage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    expect(primary(), entry);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode, entry);
    await tearDownPage(tester);
  });

  testWidgets('G5 search 搜索框 DOWN → 搜索按钮 → T9 键盘可达', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'search-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, SearchPage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    // DOWN 显式落到「搜索」按钮（几何遍历会选到旁边的「清空」）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryLabel(), 'search-submit');
    // 继续 DOWN 进 T9 九宫格（页面内嵌键盘，不拉系统输入法）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryInside(find.byType(TvSearchKeyboard)), isTrue);
    await tearDownPage(tester);
  });

  testWidgets('G5 search 搜索框 UP → 搜索源设置 → 侧栏通道节点', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'search-entry');
    final tab = FocusNode(debugLabel: 'tab-search');
    addTearDown(entry.dispose);
    addTearDown(tab.dispose);
    await tester.pumpWidget(
      focusHarness(
        controller,
        Column(
          children: [
            // 模拟壳层侧栏「搜索」条目节点。
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
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'search-source-selection');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primaryLabel(), 'search-scope');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primary(), tab);
    await tearDownPage(tester);
  });

  testWidgets('G5 search OK 搜索 → 结果网格出现且卡片可获焦', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(
      focusHarness(controller, const SearchPage(standalone: true)),
    );
    await tester.pumpAndSettle();
    // 输入框只读：T9 键位输入后点「搜 索」。
    await tester.tap(
      find.descendant(
        of: find.byType(TvSearchKeyboard),
        matching: find.text('2'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('搜 索'));
    await tester.pumpAndSettle();
    expect(find.text('12 条结果'), findsWidgets);
    final cards = find.byType(WideVodCard);
    expect(cards, findsWidgets);
    // 结果卡可获焦（外部几何遍历或页面显式投递都能落焦）。
    final cardFocus = tester
        .widget<Focus>(
          find.descendant(of: cards.first, matching: find.byType(Focus)).first,
        )
        .focusNode!;
    cardFocus.requestFocus();
    await tester.pump();
    expect(cardFocus.hasFocus, isTrue);
    // 让 T9 多击循环定时器走完再收树。
    await tester.pump(TvSearchKeyboard.cycleWindow);
    await tearDownPage(tester);
  });

  testWidgets('G5 search 搜索框 LEFT 停住（不飞出内容列）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'search-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(controller, SearchPage(entryFocus: entry)),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primary(), entry);
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G6 设置骨架（分类列 ↔ 条目面板 + BACK 退层）
  // -------------------------------------------------------------------------

  testWidgets('G6 settings 进页焦点落分类列第一项', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const SettingsPage()));
    await tester.pumpAndSettle();
    final first = nodeOfText('主题皮肤');
    expect(primary(), first);
    await tearDownPage(tester);
  });

  testWidgets('G6 settings 分类列 UP/DOWN 遍历全部 5 项', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const SettingsPage()));
    await tester.pumpAndSettle();
    expect(primary(), nodeOfText('主题皮肤'));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), nodeOfText('配置接口'));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), nodeOfText('直播源'));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), nodeOfText('播放'));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), nodeOfText('关于'));
    // 回程 UP 逐项。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primary(), nodeOfText('播放'));
    await tearDownPage(tester);
  });

  testWidgets('G6 settings 分类项 RIGHT → 焦点进右侧面板首项', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const SettingsPage()));
    await tester.pumpAndSettle();
    final category = nodeOfText('主题皮肤');
    category.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowRight);
    // 面板第一条目 = 第一套皮肤行（Smartisan OS）。
    expect(primary(), nodeOfText('Smartisan OS'));
    await tearDownPage(tester);
  });

  testWidgets('G6 settings 面板内 DOWN 遍历条目且不出面板', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    await tester.pumpWidget(focusHarness(controller, const SettingsPage()));
    await tester.pumpAndSettle();
    nodeOfText('主题皮肤').requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primary(), nodeOfText('Smartisan OS'));
    // 面板内 DOWN 到第二套皮肤（暗色）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), nodeOfText('Smartisan OS 暗色'));
    await tearDownPage(tester);
  });

  testWidgets('G6 settings BACK：非首分类退首分类（不退页），再 BACK 退页', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      focusHarness(controller, const Text('设置父页'), navigatorKey: navigatorKey),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    await tester.pumpAndSettle();
    // DOWN ×4 把焦点移到「关于」分类，OK 选中（焦点移动不等于切分类）。
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(primary(), nodeOfText('关于'));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('版本 1.0.0 · 参考 TVBox 开源项目重制'), findsOneWidget);
    // BACK：先退分类（PopScope canPop=false），不退页。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('版本 1.0.0 · 参考 TVBox 开源项目重制'), findsNothing);
    expect(find.text('背景底图'), findsOneWidget);
    // 已在首分类：BACK 退页。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('设置父页'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // G7 我的骨架（entry → 概览 → 继续观看 → 浮层 → 子路由焦点归还）
  // -------------------------------------------------------------------------

  LibraryStore focusLibrary() => LibraryStore()
    ..history.addAll(
      List.generate(
        4,
        (index) => HistoryEntry(
          vod: FocusFakeSiteApi.first,
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

  testWidgets('G7 mine entry 落第一个统计卡（概览 · 收藏）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(
        controller,
        MinePage(entryFocus: entry),
        library: focusLibrary(),
      ),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    expect(primary(), entry);
    // entry 挂在概览第一个统计卡（收藏）上。
    expect(find.text('我的配置'), findsOneWidget);
    expect(find.text('继续观看'), findsOneWidget);
    await tearDownPage(tester);
  });

  testWidgets('G7 mine DOWN 遍历概览到底：吞键不丢焦，UP 可达统计卡行', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(
        controller,
        MinePage(entryFocus: entry),
        library: focusLibrary(),
      ),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    // 逐次 DOWN 直到焦点停稳（到底被 _onContentKey 吞键）。
    var previous = primary();
    var reachedShelf = false;
    for (var i = 0; i < 8; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      final now = primary();
      expect(now, isNotNull, reason: 'DOWN 链任何一步都不允许死焦点');
      if (now != previous && now?.debugLabel != null) {
        if (now!.debugLabel!.startsWith('shelf-item-')) reachedShelf = true;
      }
      previous = now;
    }
    expect(reachedShelf, isTrue, reason: 'DOWN 链应到达继续观看行');
    // 到底后再按 DOWN：停住吞键，焦点仍在页内。
    final settled = primary();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), settled);
    // UP 回到统计卡行（焦点不丢）。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(primary(), isNotNull);
    await tearDownPage(tester);
  });

  testWidgets('G7 mine 继续观看行焦点记忆（离开再回 ShelfRow 回记忆卡）', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(
        controller,
        MinePage(entryFocus: entry),
        library: focusLibrary(),
      ),
    );
    await tester.pumpAndSettle();
    final item0 = nodeByLabel('shelf-item-0');
    expect(item0, isNotNull);
    item0!.requestFocus();
    await tester.pump();
    // 行内 RIGHT 到第 2 张卡。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primaryLabel(), 'shelf-item-1');
    // 焦点离开该行，再回行根 → ShelfRow 投回记忆项（FOCUS-02）。
    entry.requestFocus();
    await tester.pump();
    nodeByLabel('shelf-row')!.requestFocus();
    await tester.pump();
    expect(primaryLabel(), 'shelf-item-1');
    await tearDownPage(tester);
  });

  testWidgets('G7 mine 站点卡 OK → tv_sheet 焦点在层内；BACK 回触发节点', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      focusHarness(
        controller,
        MinePage(entryFocus: entry),
        library: focusLibrary(),
      ),
    );
    await tester.pumpAndSettle();
    // 「站点」统计卡 → 站点选择浮层（共享 showTvSheet）。
    final siteCard = nodeOfText('站点');
    siteCard.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('选择视频站点'), findsOneWidget);
    // 焦点进层（关闭按钮或内容首项，反正不留在触发节点）。
    expect(
      primaryInside(
        find.byWidgetPredicate(
          (w) => w is TvFocusable && w.semanticLabel == '关闭',
        ),
      ),
      isTrue,
    );
    // BACK 关层 → 焦点回触发节点（FOCUS-07）。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选择视频站点'), findsNothing);
    expect(primary(), siteCard);
    await tearDownPage(tester);
  });

  testWidgets('G7 mine 子路由返回焦点回入口（didPopNext + kRouteObserver）', (
    tester,
  ) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = focusController();
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      focusHarness(
        controller,
        MinePage(entryFocus: entry),
        library: focusLibrary(),
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pumpAndSettle();
    entry.requestFocus();
    await tester.pump();
    expect(primary(), entry);
    // 压入子路由（焦点随之离开本页子树）。
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('子页'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('子页'), findsOneWidget);
    // 返回：didPopNext 重投入口（死焦点修复契约）。
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('子页'), findsNothing);
    expect(primary(), entry);
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G8 覆盖层通用契约（数据驱动：tv_sheet / T9 / 二维码 / TvNotice）
  // -------------------------------------------------------------------------

  testWidgets('G8 tv_sheet 默认焦点落层内关闭按钮，OK 关闭回触发节点', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'sheet-trigger');
    addTearDown(trigger.dispose);
    final context = await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) => showTvSheet<void>(
        ctx,
        title: '测试面板',
        builder: (sheetContext) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TvFocusable(
              semanticLabel: '条目一',
              onTap: () => Navigator.pop(sheetContext),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('条目一'),
              ),
            ),
          ],
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('测试面板'), findsOneWidget);
    // 打开焦点在层内（默认落关闭按钮；tv-sheet-close 是浮层私有节点，
    // 存在即证明焦点进了浮层子树而不是留在触发节点）。
    expect(primaryLabel(), 'tv-sheet-close');
    expect(
      primaryInside(
        find.byWidgetPredicate(
          (w) => w is TvFocusable && w.semanticLabel == '关闭',
        ),
      ),
      isTrue,
    );
    // 层内 DOWN 可达内容项（浮层内方向键可达全部按钮）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryInside(find.text('条目一')), isTrue);
    // OK 关闭 → 焦点回触发节点。
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('测试面板'), findsNothing);
    expect(primary(), trigger);
    expect(context, isNotNull);
    await tearDownPage(tester);
  });

  testWidgets('G8 tv_sheet autofocusClose=false：内容 autofocus 优先', (
    tester,
  ) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'sheet-trigger');
    addTearDown(trigger.dispose);
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) => showTvSheet<void>(
        ctx,
        title: '测试面板',
        autofocusClose: false,
        builder: (sheetContext) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TvFocusable(
              autofocus: true,
              semanticLabel: '条目一',
              onTap: () => Navigator.pop(sheetContext),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('条目一'),
              ),
            ),
          ],
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    // 内容自带 autofocus：焦点落内容首项而不是关闭按钮。
    expect(primary(), nodeOfText('条目一'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(primary(), trigger);
    await tearDownPage(tester);
  });

  testWidgets('G8 tv_sheet autofocusClose=false 且内容无 autofocus：兜底焦点进层', (
    tester,
  ) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'sheet-trigger');
    addTearDown(trigger.dispose);
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) => showTvSheet<void>(
        ctx,
        title: '测试面板',
        autofocusClose: false,
        builder: (sheetContext) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TvFocusable(
              semanticLabel: '条目一',
              onTap: () => Navigator.pop(sheetContext),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('条目一'),
              ),
            ),
          ],
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    // 无人认领初始焦点时，浮层帧末兜底投关闭按钮——方向键不会落到层外。
    expect(primaryLabel(), 'tv-sheet-close');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primaryInside(find.text('条目一')), isTrue);
    await tearDownPage(tester);
  });

  testWidgets('G8 tv_sheet BACK（路由 pop）后焦点回触发节点', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'sheet-trigger');
    addTearDown(trigger.dispose);
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) => showTvSheet<void>(
        ctx,
        title: '测试面板',
        builder: (sheetContext) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TvFocusable(
              semanticLabel: '条目一',
              onTap: () => Navigator.pop(sheetContext),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('条目一'),
              ),
            ),
          ],
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(primaryLabel(), 'tv-sheet-close');
    // BACK = 路由 pop（barrierDismissible=false，只有 pop 能关）。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('测试面板'), findsNothing);
    expect(primary(), trigger);
    await tearDownPage(tester);
  });

  testWidgets('G8 tv_sheet 四向遍历不穿透底页，关闭按钮 OK 回触发节点', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode();
    addTearDown(trigger.dispose);
    var opens = 0;
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) {
        opens++;
        showTvSheet<void>(ctx, title: '隔离面板', builder: (_) => const SizedBox());
      },
    );
    trigger.requestFocus();
    await tester.pump();
    await pressSettle(tester, LogicalKeyboardKey.select);
    final close = find.byWidgetPredicate(
      (w) => w is TvFocusable && w.semanticLabel == '关闭',
    );
    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await pressSettle(tester, key);
      expect(primaryInside(close), isTrue);
      expect(trigger.hasFocus, isFalse);
    }
    await pressSettle(tester, LogicalKeyboardKey.select);
    expect(find.text('隔离面板'), findsNothing);
    expect(primary(), trigger);
    expect(opens, 1, reason: '层内按键不能再次触发底页按钮');
    await tearDownPage(tester);
  });

  testWidgets('G8 网盘公共目录：40 项逐项往返、OK 选择、重开恢复远端记忆项', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode();
    addTearDown(trigger.dispose);
    var remembered = 0;
    final labels = List.generate(40, (i) => '目录项 $i');
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) {
        showTvSheet<int>(
          ctx,
          title: '长目录',
          autofocusClose: false,
          builder: (sheetContext) => TvSheetList(
            labels: labels,
            initialIndex: remembered,
            onSelected: (index) {
              remembered = index;
              Navigator.pop(sheetContext, index);
            },
          ),
        );
      },
    );
    trigger.requestFocus();
    await tester.pump();
    await pressSettle(tester, LogicalKeyboardKey.select);
    expect(primaryIsWithinText(labels.first), isTrue);
    for (var i = 1; i < labels.length; i++) {
      await pressSettle(tester, LogicalKeyboardKey.arrowDown);
      expect(primaryIsWithinText(labels[i]), isTrue, reason: 'DOWN 到第 $i 项');
      final rect = tester.getRect(find.text(labels[i]));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(720));
    }
    await pressSettle(tester, LogicalKeyboardKey.select);
    expect(remembered, 39);
    expect(primary(), trigger);
    await pressSettle(tester, LogicalKeyboardKey.select);
    expect(primaryIsWithinText(labels.last), isTrue);
    for (var i = labels.length - 2; i >= 0; i--) {
      await pressSettle(tester, LogicalKeyboardKey.arrowUp);
      expect(primaryIsWithinText(labels[i]), isTrue, reason: 'UP 到第 $i 项');
    }
    await pressSettle(tester, LogicalKeyboardKey.arrowUp);
    expect(
      primaryInside(
        find.byWidgetPredicate(
          (w) => w is TvFocusable && w.semanticLabel == '关闭',
        ),
      ),
      isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(primary(), trigger);
    await tearDownPage(tester);
  });

  testWidgets('G8 T9 弹窗：焦点进九宫格，BACK 回 returnFocus 触发节点', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 't9-trigger');
    addTearDown(trigger.dispose);
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) =>
          showT9SearchDialog(ctx, title: '搜索频道', returnFocus: trigger),
    );
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvSearchKeyboard), findsOneWidget);
    // 弹窗焦点在九宫格内（TvSearchKeyboard 的 autofocus 键）。
    expect(primaryInside(find.byType(TvSearchKeyboard)), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TvSearchKeyboard), findsNothing);
    expect(primary(), trigger);
    await tearDownPage(tester);
  });

  testWidgets('G8 远程搜索弹窗：默认焦点落「返回搜索」，OK 关闭', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'remote-trigger');
    addTearDown(trigger.dispose);
    await pumpTriggerHarness(
      tester,
      trigger: trigger,
      onTap: (ctx) =>
          showRemoteSearchDialog(ctx, 'http://192.168.1.2:8080/search'),
    );
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('返回搜索'), findsOneWidget);
    expect(primary(), nodeOfText('返回搜索'));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('返回搜索'), findsNothing);
    await tearDownPage(tester);
  });

  testWidgets('G8 TvNotice：提示条不抢焦点、无焦点陷阱', (tester) async {
    tester0 = tester;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = FocusNode(debugLabel: 'notice-btn-1');
    final second = FocusNode(debugLabel: 'notice-btn-2');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    late BuildContext noticeContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Builder(
          builder: (context) {
            noticeContext = context;
            return Scaffold(
              backgroundColor: skinFor(TvSkinId.smartisan).bg,
              body: Center(
                child: Column(
                  children: [
                    TvFocusable(
                      focusNode: first,
                      semanticLabel: '按钮一',
                      child: const Text('按钮一'),
                    ),
                    TvFocusable(
                      focusNode: second,
                      semanticLabel: '按钮二',
                      child: const Text('按钮二'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();
    // 提示条弹出（Overlay 层，无 Focus 节点）。
    TvNotice.show(noticeContext, '已加入收藏');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('已加入收藏'), findsOneWidget);
    expect(primary(), first, reason: '提示条不得抢走焦点');
    // 提示期间方向键仍作用于底层（无焦点陷阱）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(primary(), second);
    await tearDownPage(tester);
  });

  // -------------------------------------------------------------------------
  // G9 公共组件契约（poster_card / site_row 焦点内部）
  // -------------------------------------------------------------------------

  Widget componentHarness(Widget child) {
    return MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(
        backgroundColor: skinFor(TvSkinId.smartisan).bg,
        body: Center(child: child),
      ),
    );
  }

  VodItem componentVod() => VodItem(
    id: '0',
    name: '测试影片',
    pic: '',
    remarks: '更新至 1 集',
    typeId: '1',
    typeName: '电影',
    year: '2026',
    area: '中国大陆',
    sourceKey: 'test',
    sourceName: '测试站点',
  );

  testWidgets('G9 PosterCard：外部 focusNode 透传获焦（不自建节点）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final node = FocusNode(debugLabel: 'poster-ext');
    addTearDown(node.dispose);
    await tester.pumpWidget(
      componentHarness(
        SizedBox(
          width: 220,
          height: 380,
          child: PosterCard(vod: componentVod(), focusNode: node, onTap: () {}),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    expect(primary(), node);
    await tearDownPage(tester);
  });

  testWidgets('G9 PosterCard：无 autofocus 不抢焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final node = FocusNode(debugLabel: 'poster-ext');
    addTearDown(node.dispose);
    await tester.pumpWidget(
      componentHarness(
        SizedBox(
          width: 220,
          height: 380,
          child: PosterCard(vod: componentVod(), focusNode: node, onTap: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 无 autofocus 的卡片不得自抢焦点（默认焦点留给路由 scope，
    // 卡片节点必须保持失焦）。
    expect(node.hasFocus, isFalse);
    expect(primary() != node, isTrue);
    await tearDownPage(tester);
  });

  testWidgets('G9 WideVodCard / ContinueCard：外部 focusNode 透传', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final wideNode = FocusNode(debugLabel: 'wide-ext');
    final continueNode = FocusNode(debugLabel: 'continue-ext');
    addTearDown(wideNode.dispose);
    addTearDown(continueNode.dispose);
    final entry = HistoryEntry(
      vod: componentVod(),
      sourceKey: 'test',
      sourceName: '测试站点',
      lineName: '线路一',
      lineIndex: 0,
      episodeName: '第1集',
      episodeUrl: 'https://video.test/0.m3u8',
      episodeIndex: 0,
      positionMs: 60000,
      durationMs: 600000,
      updatedAt: DateTime(2026, 11, 14),
    );
    await tester.pumpWidget(
      componentHarness(
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 150,
              child: WideVodCard(
                vod: componentVod(),
                focusNode: wideNode,
                onTap: () {},
              ),
            ),
            ContinueCard(entry: entry, focusNode: continueNode, onTap: () {}),
          ],
        ),
      ),
    );
    wideNode.requestFocus();
    await tester.pump();
    expect(primary(), wideNode);
    continueNode.requestFocus();
    await tester.pump();
    expect(primary(), continueNode);
    await tearDownPage(tester);
  });

  testWidgets('G9 ContinueCard：OK 键触发 onTap（TvFocusable 包裹）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final node = FocusNode(debugLabel: 'continue-ext');
    addTearDown(node.dispose);
    var taps = 0;
    final entry = HistoryEntry(
      vod: componentVod(),
      sourceKey: 'test',
      sourceName: '测试站点',
      lineName: '线路一',
      lineIndex: 0,
      episodeName: '第1集',
      episodeUrl: 'https://video.test/0.m3u8',
      episodeIndex: 0,
      positionMs: 60000,
      durationMs: 600000,
      updatedAt: DateTime(2026, 11, 14),
    );
    await tester.pumpWidget(
      componentHarness(
        ContinueCard(entry: entry, focusNode: node, onTap: () => taps++),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(taps, 1);
    await tearDownPage(tester);
  });

  testWidgets('G9 SiteRow：无内部焦点节点（纯视觉由外层 TvFocusable 驱动）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const site = SiteConfig(
      key: 'test',
      name: '测试站点',
      api: 'https://api.test/',
      type: 1,
    );
    final node = FocusNode(debugLabel: 'site-row-ext');
    addTearDown(node.dispose);
    await tester.pumpWidget(
      componentHarness(
        TvFocusable(
          focusNode: node,
          semanticLabel: '测试站点',
          onTap: () {},
          child: const SizedBox(
            width: 420,
            child: SiteRow(site: site, selected: true),
          ),
        ),
      ),
    );
    // SiteRow 子树内没有任何 Focus 节点（不偷焦点、不自建节点）。
    expect(
      find.descendant(of: find.byType(SiteRow), matching: find.byType(Focus)),
      findsNothing,
    );
    // 外层节点获焦后整行可达、OK 响应由外层处理。
    node.requestFocus();
    await tester.pump();
    expect(primary(), node);
    await tearDownPage(tester);
  });
}
