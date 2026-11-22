// 可展开左侧导航栏（TvSideRail）的导航回归测试。
//
// 覆盖 tvOS FOCUS-01/06/08、AGENTS.md §3 焦点规则与 izuko 侧栏模式：
//   - 侧栏 4 个条目全部可获焦，焦点视觉走 TvFocusable（FOCUS-01）；
//   - 进页默认焦点落内容区（壳层帧末投递，不停在侧栏上）；
//   - 侧栏只能从内容区按左键进入（壳层根 Focus 的 LEFT 通道）；
//   - 栏内上下键确定性移动（按 index 投递），到顶/到底停住；
//   - OK 切页后焦点交还内容区（新页入口节点）；
//   - RIGHT / BACK 从侧栏回内容区；
//   - 选中页跨 setState 重建保持（TAB-06 语义延续）；
//   - 内容层 UP 到首页页头后，走 onExitToNav 通道回侧栏。
//
// 环境约定（与旧顶栏测试同源）：
//   - smartisan 皮肤挂壳；侧栏条目节点 debugLabel 为 rail-0..3，
//     壳层注入的入口节点 debugLabel 为 tab-entry-0..3；
//   - 定位侧栏节点只用 debugLabel，不靠标签文字（IndexedStack 的
//     4 个页面会渲染同样的词，按文字取 .first 会命中内容层）；
//   - disableAnimations 关掉焦点缩放缓动，方向遍历几何保持确定；
//   - StorageService 在 widget 测试中未初始化，持久化读写退化为
//     fallback/无-op，每个用例初始 tab 索引固定为 0。

import 'dart:async';

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
import 'package:tvbox_flutter/theme/theme_controller.dart';
import 'package:tvbox_flutter/ui/pages/home_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

/// 侧栏挂载的单层皮肤分支（见文件头注）。
const TvSkinId _kSkin = TvSkinId.smartisan;

/// 可手动触发一次父级 setState 重建的宿主，用于 TAB-06 用例模拟「父级重建、
/// ShellPage 的 State 保留」。用 setState 只重建本宿主：它的 child 是
/// `const ShellPage`（同一 const 实例），element 走 update、State 保留，
/// 不经过任何 InheritedElement 的 deactivate 路径（框架 debug 边界）。
class _RebuildableHost extends StatefulWidget {
  const _RebuildableHost({super.key, required this.child});
  final Widget child;
  @override
  State<_RebuildableHost> createState() => _RebuildableHostState();
}

class _RebuildableHostState extends State<_RebuildableHost> {
  /// 触发一次父级 setState 重建（ShellPage 的 element 走 update、State 保留）。
  void rebuild() => setState(() {});
  @override
  Widget build(BuildContext context) => widget.child;
}

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

class _PendingHomeApi extends FakeSiteApi {
  final request = Completer<HomeData>();

  @override
  Future<HomeData> home(SiteConfig site) => request.future;

  Future<void> completeWithVideos(SiteConfig site) async {
    request.complete(await super.home(site));
  }
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

AppController buildController({SiteApi? siteApi}) {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(
      storage: StorageService(),
      siteApi: siteApi ?? FakeSiteApi(),
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

/// 与 ui_smoke_test.dart 的 harness 相同，外加 disableAnimations：关掉焦点缩放缓动，
/// 方向遍历的落点几何保持确定。
Widget harness(
  AppController controller,
  Widget child, {
  LibraryStore? library,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(
        create: (_) => library ?? LibraryStore(),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(_kSkin),
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child,
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 定位辅助
// ---------------------------------------------------------------------------

/// 侧栏第 [index] 个条目的 [TvFocusable]。
///
/// 用 shell 注入的 `focusNode`（debugLabel `rail-$index`）定位，不用标签
/// 文字：页面内容也会渲染同样的词（SearchPage『搜索』、LivePage 频道行
/// 『直播』等），`find.text(...).first` 在 IndexedStack 里会先命中内容层。
TvFocusable _railFocusable(WidgetTester tester, int index) {
  final matches = tester
      .widgetList<TvFocusable>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TvFocusable &&
              widget.focusNode?.debugLabel == 'rail-$index',
        ),
      )
      .toList();
  expect(matches, hasLength(1), reason: '侧栏应有唯一的 rail-$index 节点');
  return matches.single;
}

/// 侧栏第 [index] 个条目的焦点节点。
FocusNode _railNode(WidgetTester tester, int index) =>
    _railFocusable(tester, index).focusNode!;

/// 「我的」页中间分类栏的第 [index] 个焦点项。
FocusNode _mineCategoryNode(WidgetTester tester, int index) {
  final matches = tester
      .widgetList<TvFocusable>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TvFocusable &&
              widget.focusNode?.debugLabel == 'mine-category-$index',
        ),
      )
      .toList();
  expect(matches, hasLength(1), reason: '「我的」页应有唯一的分类焦点项');
  return matches.single.focusNode!;
}

/// 条目焦点描边层（TvFocusable 的前景装饰，不参与内容布局）。
BoxDecoration _focusChrome(WidgetTester tester, int index) {
  final item = _railFocusable(tester, index);
  final chrome = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byWidget(item),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return chrome.foregroundDecoration! as BoxDecoration;
}

/// 条目是否处于「选中」态（当前页）。内层图标/文字取强调色；获焦反白态
/// （smartisan 的 TvFocusTint 约定）下强调色让位给焦点反白，此时选中
/// 语义读不到颜色——只断言未获焦路径，获焦路径由焦点描边断言覆盖。
bool _railItemSelected(WidgetTester tester, int index) {
  final icon = tester.widget<Icon>(
    find
        .descendant(
          of: find.byWidget(_railFocusable(tester, index)),
          matching: find.byType(Icon),
        )
        .first,
  );
  final skin = skinFor(_kSkin);
  return icon.color == skin.accent;
}

/// 壳层当前选中的页面索引（IndexedStack 是 shell 的唯一索引真相）。
int _shellIndex(WidgetTester tester) =>
    tester.widget<IndexedStack>(find.byType(IndexedStack)).index!;

/// 页头站点 chip 的 FocusNode（FOCUS-UP 的页头落点）。
FocusNode _siteChipNode(WidgetTester tester) {
  final icon = find.descendant(
    of: find.byType(HomePage),
    matching: find.byIcon(Icons.expand_more_rounded),
  );
  expect(icon, findsOneWidget, reason: '页头应有唯一的站点 chip');
  return Focus.of(tester.element(icon));
}

/// 当前主焦点必须有真实布局几何，返回它的全局矩形。
Rect _focusRect(FocusNode node) {
  final rect = node.rect;
  expect(rect.width, greaterThan(0), reason: '获焦节点必须有宽度（不能是幽灵焦点）');
  expect(rect.height, greaterThan(0), reason: '获焦节点必须有高度（不能是幽灵焦点）');
  return rect;
}

Future<void> pumpShell(
  WidgetTester tester,
  AppController controller, {
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // 每个用例结束前兜底拆掉 ShellPage 树（即使用例体在离开前抛异常也清理），
  // 避免残留焦点/脏元素污染下一用例。
  addTearDown(() async => await tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(harness(controller, const ShellPage()));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> leaveShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

/// 从内容区发起「LEFT 进侧栏」：焦点先落到页头站点 chip（非 hero CTA
/// ——首页 hero CTA 的 LEFT 被轮播翻页消费，见「LEFT from content」用例
/// 注释），再按左键，断言落入侧栏当前条目。
Future<void> enterRailViaLeft(
  WidgetTester tester, {
  int expectIndex = 0,
}) async {
  final site = _siteChipNode(tester);
  site.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  await tester.pump();
  expect(
    FocusManager.instance.primaryFocus,
    same(_railNode(tester, expectIndex)),
    reason: '内容区按左键应进入侧栏第 ${expectIndex + 1} 个条目',
  );
}

void main() {
  testWidgets('shelf memory cancels pending focus retries after disposal', (
    tester,
  ) async {
    final memory = ShelfFocusMemory();
    memory.focusHere();
    await tester.pump();
    memory.dispose();
    await tester.pump();
    memory.syncIndex(1);
    memory.focusHere();
    expect(tester.takeException(), isNull);
  });

  group('可展开左侧导航栏回归（smartisan 侧栏）', () {
    testWidgets('rail and home belong to independent focus scopes', (
      tester,
    ) async {
      await pumpShell(tester, buildController());
      final home = FocusManager.instance.primaryFocus!;
      final homeScope = home.enclosingScope!;
      expect(homeScope.debugLabel, 'page-home');
      expect(homeScope.skipTraversal, isTrue);
      await enterRailViaLeft(tester);
      final railScope = FocusManager.instance.primaryFocus!.enclosingScope!;
      expect(railScope.debugLabel, 'shell-rail');
      expect(railScope.skipTraversal, isTrue);
      expect(railScope, isNot(same(homeScope)));
      expect(railScope.descendants, isNot(contains(home)));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(home));
      await leaveShell(tester);
    });

    // FOCUS-01：4 个条目都可获焦，且焦点视觉是真实、唯一的结构变化。
    testWidgets('side rail has 4 items all focusable', (tester) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      const labels = ['首页', '直播', '搜索', '我的'];
      final nodes = [for (var i = 0; i < 4; i++) _railNode(tester, i)];
      // 4 个条目是 4 个不同的焦点节点。
      expect(nodes.toSet(), hasLength(4));

      for (var i = 0; i < 4; i++) {
        nodes[i].requestFocus();
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus,
          same(nodes[i]),
          reason: '${labels[i]} 条目应可获焦',
        );
        // 4 个条目都在屏幕左侧栏内（不是内容层或屏幕外的节点）。
        final rect = _focusRect(nodes[i]);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThan(240), reason: '${labels[i]} 条目应位于左侧导航栏内');
        // 焦点视觉：获焦条目有描边，其余条目描边宽度为 0（不是常亮装饰，
        // 也不是只靠颜色区分——描边存在/消失是结构差异）。
        for (var j = 0; j < 4; j++) {
          final border = (_focusChrome(tester, j).border! as Border).top;
          if (j == i) {
            expect(
              border.width,
              greaterThan(0),
              reason: '获焦的 ${labels[j]} 条目必须有可见描边（FOCUS-01）',
            );
            expect(border.color.a, greaterThan(0));
          } else {
            expect(border.width, 0, reason: '未获焦的 ${labels[j]} 条目不应显示焦点描边');
          }
        }
      }

      // 4 个条目纵向单列排布，UP/DOWN 的几何顺序确定。
      for (var i = 1; i < 4; i++) {
        expect(
          _focusRect(nodes[i - 1]).top,
          lessThan(_focusRect(nodes[i]).top),
          reason: '条目顺序应为 ${labels[i - 1]} → ${labels[i]}',
        );
      }
      await leaveShell(tester);
    });

    // FOCUS-06 + izuko 进页落点：默认焦点落内容区，不停在侧栏上。
    testWidgets('entry focus lands in content, not the rail', (tester) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      final entry = FocusManager.instance.primaryFocus;
      expect(entry, isNotNull, reason: '进页必须有默认焦点（FOCUS-06）');
      expect(
        entry!.debugLabel,
        'tab-entry-0',
        reason: '默认焦点应落首页入口（网格首项），而不是侧栏条目',
      );
      // 侧栏此刻是收起态：没有任何条目获焦。
      for (var i = 0; i < 4; i++) {
        expect(_railNode(tester, i).hasFocus, isFalse);
      }
      await leaveShell(tester);
    });

    testWidgets('我的页 LEFT 先到中间分类，再到全局侧栏并可原路返回', (tester) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      await enterRailViaLeft(tester);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tab-entry-3');

      // 内容（收藏统计卡）LEFT → 页内「概览」分类，而不是直接飞到最左栏。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      final category = _mineCategoryNode(tester, 0);
      expect(FocusManager.instance.primaryFocus, same(category));

      // 分类栏 LEFT → 全局「我的」图标；RIGHT → 回分类；再 RIGHT 回原内容。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(_railNode(tester, 3)));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(category));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tab-entry-3');
      await leaveShell(tester);
    });

    // 侧栏入口通道：内容区按左键 → 侧栏当前页条目。
    //
    // 发起 LEFT 的焦点位置用页头站点 chip（非 hero CTA）：hero CTA 的
    // LEFT 被首页轮播消费去翻页（首页 `_onHeroCtaKey`，izuko「焦点在
    // 按钮上时左右键手动切换轮播」同款语义），侧栏入口只对非 hero 内容
    // 生效——与 izuko 的「第一个条目按左不翻，交给侧边栏」分层一致。
    testWidgets('LEFT from content enters the rail at the active item', (
      tester,
    ) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      final site = _siteChipNode(tester);
      site.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        same(_railNode(tester, 0)),
        reason: '内容区按左键应进入侧栏当前页（首页）条目',
      );
      // 展开态：条目获焦时文字浮出（展开态下条目内存在文字 Text）。
      expect(
        find.descendant(
          of: find.byWidget(_railFocusable(tester, 0)),
          matching: find.text('首页'),
        ),
        findsOneWidget,
        reason: '侧栏获焦时应展开显示文字标签',
      );
      await leaveShell(tester);
    });

    // 首页加载中 LEFT 也能进侧栏（数据未到，焦点在站点 chip 上）。
    for (final timedOut in [true, false]) {
      testWidgets('首页加载中可进侧栏，${timedOut ? '超时后仍稳定' : '数据到达不抢焦'}', (
        tester,
      ) async {
        final api = _PendingHomeApi();
        final controller = buildController(siteApi: api);
        await pumpShell(tester, controller, settle: false);
        await tester.pump();
        final site = _siteChipNode(tester);
        site.requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        // 用 pump 而非 pumpAndSettle：首页在 pending/错误态下有常驻
        // （错误横幅的淡入 / 轮播计时器），动画链不会收敛——本用例的
        // 判据是焦点落点，不依赖动画走完。
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          same(_railNode(tester, 0)),
          reason: '站点 chip 按左键应进入侧栏',
        );

        if (timedOut) {
          api.request.completeError(TimeoutException('站点连接超时'));
        } else {
          await api.completeWithVideos(controller.selectedSite!);
        }
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          same(_railNode(tester, 0)),
          reason: '数据到达不能把侧栏焦点抢回内容区',
        );

        // RIGHT 回内容区。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus,
          isNot(same(_railNode(tester, 0))),
          reason: '侧栏按右键应回内容区',
        );
        await leaveShell(tester);
      });
    }

    // 栏内导航：UP/DOWN 确定性移动，到顶/到底停住不逃进内容。
    testWidgets('rail UP/DOWN move within the rail and stop at the ends', (
      tester,
    ) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      await enterRailViaLeft(tester);

      // DOWN 逐个走。
      for (var i = 1; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          same(_railNode(tester, i)),
          reason: 'DOWN 应依次移到第 ${i + 1} 个条目',
        );
      }
      // 最底部再按 DOWN：停在原地，焦点不丢、不逃进内容区。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(_railNode(tester, 3)));

      // UP 逐个走回。
      for (var i = 2; i >= 0; i--) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          same(_railNode(tester, i)),
          reason: 'UP 应依次移回第 ${i + 1} 个条目',
        );
      }
      // 最顶部再按 UP：停住。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(_railNode(tester, 0)));

      // 栏内 LEFT：已到栏外沿，停住吞键（回内容区走 RIGHT/OK/BACK）。
      // 焦点体系重建（O-1 收口 b）：LEFT 改为退出键——栏已在最左，再往左
      // = 回内容区（展开面板压住内容左缘期间符合空间直觉），与
      // RIGHT/OK/BACK 退出语义收敛一致。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tab-entry-0',
        reason: '栏内左键应回内容区（O-1 收口 b：LEFT = 退出侧栏）',
      );
      await leaveShell(tester);
    });

    // §3 硬性规则 1/3 + izuko OK 语义：切页 + 焦点交还新页内容区。
    testWidgets('OK switches the page and hands focus to the new content', (
      tester,
    ) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      await enterRailViaLeft(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(_railNode(tester, 1)));

      // OK 激活直播页，焦点交还直播页入口。
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(_shellIndex(tester), 1, reason: 'OK 应激活「直播」页');

      final entry = FocusManager.instance.primaryFocus;
      expect(entry, isNotNull, reason: '切页后焦点不能丢');
      expect(entry!.debugLabel, 'tab-entry-1');
      final rect = _focusRect(entry);
      expect(rect.top, greaterThanOrEqualTo(0), reason: '焦点不能飞到屏幕上方之外');
      expect(rect.left, greaterThanOrEqualTo(0), reason: '焦点不能飞到屏幕左侧之外');
      expect(rect.bottom, lessThanOrEqualTo(720), reason: '焦点不能飞到屏幕下方之外');
      expect(rect.right, lessThanOrEqualTo(1280), reason: '焦点不能飞到屏幕右侧之外');
      expect(find.text('电视直播'), findsWidgets);
      await leaveShell(tester);
    });

    // 侧栏 RIGHT / BACK 回内容区。
    testWidgets('RIGHT and BACK return focus from the rail to content', (
      tester,
    ) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      await enterRailViaLeft(tester);

      // RIGHT：焦点回内容区入口。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tab-entry-0',
        reason: '侧栏按右键应回内容区入口',
      );

      // 再进侧栏，BACK：焦点回内容区。
      await enterRailViaLeft(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tab-entry-0',
        reason: '侧栏获焦时 BACK 应回内容区而不是退页',
      );
      // Android 系统 BACK 走 PopScope，与键盘 ESC 是独立入口。
      await enterRailViaLeft(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tab-entry-0');
      expect(find.byType(ShellPage), findsOneWidget);
      await leaveShell(tester);
    });

    // izuko BACK 语义：焦点在内容区时 BACK 不归壳层管（非首页切回首页）。
    testWidgets('BACK with content focus keeps the page-level semantics', (
      tester,
    ) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      // 切到直播页（内容区焦点）。
      await enterRailViaLeft(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(_shellIndex(tester), 1);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tab-entry-1');

      // 内容区 BACK：系统返回（handlePopRoute 模拟 Android BACK）→
      // PopScope 把它翻译成「切回首页」。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_shellIndex(tester), 0, reason: '内容区 BACK 应切回首页');
      await leaveShell(tester);
    });

    // TAB-06（语义延续）：选中页跨重建保持（索引 + 选中视觉 + 焦点）。
    testWidgets('rail remembers selection across rebuild', (tester) async {
      final controller = buildController();
      final hostKey = GlobalKey<_RebuildableHostState>();
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() async => await tester.pumpWidget(const SizedBox()));
      await tester.pumpWidget(
        harness(
          controller,
          _RebuildableHost(key: hostKey, child: const ShellPage()),
        ),
      );
      await tester.pumpAndSettle();

      final rail1 = _railNode(tester, 1);
      expect(_shellIndex(tester), 0);

      // 进入侧栏、移到「直播」、OK 选中。
      await enterRailViaLeft(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(rail1));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(_shellIndex(tester), 1, reason: 'OK 应选中「直播」页');
      expect(_railItemSelected(tester, 1), isTrue);
      expect(_railItemSelected(tester, 0), isFalse);

      // 父级 setState 重建（ShellPage 是 const，element 走 update、State 保留）。
      hostKey.currentState!.rebuild();
      await tester.pumpAndSettle();
      expect(_shellIndex(tester), 1, reason: '重建后选中页应保持（TAB-06）');
      expect(_railItemSelected(tester, 1), isTrue, reason: '重建后「直播」仍应是选中态');
      expect(_railItemSelected(tester, 0), isFalse);
      await leaveShell(tester);
    });

    // 内容层 UP 通道（新首页层级：hero CTA → 页头 → 侧栏；原顶栏语义
    // 平移：旧版是「页头 UP → 顶部 Tab」，新版是「页头 UP → 侧栏当前
    // 条目」）。首页 hero 化后 entry 落在 hero CTA 上，UP 直达页头
    // （hero UP → 站点 chip，首页 _handleNavKey 的确定性投递）。
    testWidgets('content UP exits to the rail', (tester) async {
      final controller = buildController();
      await pumpShell(tester, controller);
      final rail0 = _railNode(tester, 0);
      rail0.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(rail0));

      // RIGHT 进内容（entry = hero CTA）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tab-entry-0');

      // Up ×1：hero CTA → 页头站点 chip（首页 _handleNavKey 的 hero 分支）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        same(_siteChipNode(tester)),
        reason: '内容层 Up 第一层应落页头站点 chip',
      );

      // Up ×2：页头 → 侧栏（shell 的 onExitToNav 通道，落点确定）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        same(rail0),
        reason: '页头 Up 第二层应退回侧栏当前条目',
      );
      await leaveShell(tester);
    });

    // FOCUS-01 回归（延续顶栏时代同款断言）：选中条目获焦时，选中强调色
    // 让位给 TvFocusable 的焦点填充——smartisan 下焦点填充画在子内容
    // 之下，图标/文字显式强调色会把焦点翻白盖掉，故选中态获焦时图标色
    // 必须由 TvFocusTint 翻成 textOnAccent（_FocusTint 的 IconTheme 生效
    // 前提是子内容不自持显式颜色）。
    testWidgets(
      'selected rail item yields accent color to focus when focused',
      (tester) async {
        final controller = buildController();
        await pumpShell(tester, controller);
        final rail0 = _railNode(tester, 0);
        rail0.requestFocus();
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus, same(rail0));

        final chrome = _focusChrome(tester, 0);
        expect(chrome.border, isNotNull);
        expect(chrome.border!.top.width, greaterThan(0), reason: '焦点描边必须存在');
        // 获焦反白态：条目图标色应为 textOnAccent（白），而非强调色。
        final icon = tester.widget<Icon>(
          find
              .descendant(
                of: find.byWidget(_railFocusable(tester, 0)),
                matching: find.byType(Icon),
              )
              .first,
        );
        final skin = skinFor(_kSkin);
        expect(
          icon.color,
          skin.textOnAccent,
          reason: '获焦反白态下选中条目图标必须翻白（内容让位给焦点填充）',
        );

        // 对照：未选中且未获焦的条目无强调色、无描边。
        expect(_railItemSelected(tester, 1), isFalse);
        expect(_focusChrome(tester, 1).border?.top.width ?? 0, 0);
        await leaveShell(tester);
      },
    );
  });
}
