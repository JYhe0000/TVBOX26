import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/live_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/tv_keyboard.dart';

/// 直播频道搜索：中间弹窗 + T9 键盘 + 扫码入口回归。
///
/// 关键约束：页面上不能出现 `TextField`——否则电视上会拉起系统软键盘
/// （挡画面、抢方向键）。输入只走遥控器九宫格弹窗，且边输边筛。
///
/// 2026-11-19 焦点体系重建追加：直播页方向键投递表回归（docs/focus-
/// system-spec.md §3/§4/§5）——网格显式投递、首行/末行/最左列/最右列
/// 边界、分组栏进出、页头行、LEFT 交壳层通道（用最小壳层桩模拟
/// shell_page 的 `_handleShellKey`，冻结边界内不能挂真壳层）。

class _FakeLiveService extends LiveService {
  _FakeLiveService({
    this._channels = 12,
    this._groups = const ['央视频道'],
  });

  final int _channels;
  final List<String> _groups;

  @override
  Future<LiveParseResult> load(LiveSource source) async {
    return LiveParseResult(
      title: source.name,
      groups: [
        for (final group in _groups)
          LiveGroup(
            name: group,
            channels: List.generate(
              _channels,
              (index) => LiveChannel(
                name: '$group-CCTV-${index + 1}',
                urls: ['https://live.test/$index.m3u8'],
                sourceNames: const ['默认线路'],
                group: group,
              ),
            ),
          ),
      ],
    );
  }
}

AppController _buildController({LiveService? liveService}) {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(
    storage: StorageService(),
    siteApi: SiteApi(),
    liveService: liveService ?? _FakeLiveService(),
  )
    ..config = const AppConfig(
      sites: [site],
      parses: [],
      lives: [LiveSource(name: '测试直播', url: 'https://live.test/list.m3u')],
    )
    ..selectedSiteKey = 'test'
    ..initialized = true;
}

Widget _harness(AppController controller, Widget child) {
  final skin = skinFor(TvSkinId.smartisan);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(backgroundColor: skin.bg, body: child),
    ),
  );
}

/// 模拟壳层根 Focus 的 LEFT 拦截（shell_page.dart `_handleShellKey` 的
/// 最小复刻）：内容区未消费的 LEFT 投到 rail 节点。rail 节点必须挂树
/// （Focus widget 持有）才能 requestFocus 成功。
class _ShellLeftStub {
  final FocusNode root = FocusNode(debugLabel: 'stub-shell-root');
  final FocusNode rail = FocusNode(debugLabel: 'stub-rail');
  bool leftFired = false;

  Widget wrap(Widget child) => Focus(
    focusNode: root,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        leftFired = true;
        rail.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        child,
        // rail 落点：挂树的 Focus 持有 stub 节点（模拟壳层侧栏）。
        Focus(focusNode: rail, skipTraversal: true, child: const SizedBox()),
      ],
    ),
  );

  void dispose() {
    root.dispose();
    rail.dispose();
  }
}

/// 带壳层桩的 harness：桩在 MaterialApp 内、页面之上（真实壳层的
/// 位置——挂在外层会被 WidgetsApp 的 Shortcuts 先消费 LEFT）。
Widget _stubHarness(AppController controller, _ShellLeftStub stub, Widget child) {
  final skin = skinFor(TvSkinId.smartisan);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(backgroundColor: skin.bg, body: stub.wrap(child)),
    ),
  );
}

Finder _action(String label) => find.byWidgetPredicate(
  (widget) => widget is TvFocusable && widget.semanticLabel == label,
);

FocusNode _searchFieldNode(WidgetTester tester) =>
    tester.widget<TvFocusable>(_action('搜索频道')).focusNode!;

/// 频道格（网格 tile）的焦点节点：页面持有（Map 显式投递），挂在
/// tile 的 TvFocusable 上，从 widget 直接读。
FocusNode _channelNode(WidgetTester tester, String name) => tester
    .widget<TvFocusable>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TvFocusable &&
            (widget.semanticLabel?.startsWith('$name，') ?? false),
      ),
    )
    .focusNode!;

/// 分组栏行的焦点节点（ShelfRow itemBuilder 透传到 TvFocusable）。
FocusNode _groupNode(WidgetTester tester, String name) => tester
    .widget<TvFocusable>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TvFocusable &&
            (widget.semanticLabel?.startsWith('$name，') ?? false),
      ),
    )
    .focusNode!;

Future<void> _openSearch(
  WidgetTester tester,
  AppController controller,
) async {
  await tester.pumpWidget(_harness(controller, const LivePage()));
  await tester.pumpAndSettle();
  await tester.tap(_action('搜索频道'));
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('频道搜索走中间 T9 弹窗，页面上没有 TextField', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    await tester.pumpWidget(_harness(controller, const LivePage()));
    await tester.pumpAndSettle();

    // 页面上没有任何输入框 → 不可能拉起系统软键盘。
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TvSearchKeyboard), findsNothing);

    await tester.tap(_action('搜索频道'));
    await tester.pumpAndSettle();

    // 弹窗内是九宫格键盘，依旧没有 TextField。
    expect(find.byType(TvSearchKeyboard), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('搜索频道'), findsWidgets);
    expect(_action('完 成'), findsNothing);
    expect(_action('完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('T9 输入实时过滤频道，退格恢复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    await _openSearch(tester, controller);

    expect(find.text('央视频道-CCTV-1'), findsOneWidget);

    // 「2」单击 → A：没有频道名含 A，网格给出空态文案（边输边筛）。
    await tester.tap(_action('键 2 ABC'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有找到包含「A」的频道'), findsOneWidget);

    // 退格清空 → 频道复原。
    await tester.tap(_action('退格'));
    await tester.pumpAndSettle();
    expect(find.text('央视频道-CCTV-1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('弹窗键盘带扫码入口（手机远程输入二维码）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    await _openSearch(tester, controller);
    expect(_action('扫码'), findsOneWidget);
    expect(find.text('扫码可用手机输入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('关闭弹窗后焦点回到搜索框', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    await _openSearch(tester, controller);
    final node = _searchFieldNode(tester);
    expect(node.hasFocus, isFalse);

    await tester.tap(_action('完成'));
    await tester.pumpAndSettle();

    expect(find.byType(TvSearchKeyboard), findsNothing);
    // FOCUS-07：焦点回到触发点，而不是页面根。
    expect(node.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  // ===== 2026-11-19 焦点体系重建：直播页方向键投递表回归 =====

  testWidgets('入口焦点落网格第一格，DOWN 按列数逐行下移，末行吞键', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(_harness(controller, LivePage(entryFocus: entry)));
    await tester.pumpAndSettle();
    expect(entry.hasFocus, isTrue, reason: '入口焦点应落网格第 0 格');
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-1')),
    );

    // smartisan 皮肤下网格 3 列（见 live_page `_gridColumns` 推导）。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-4')),
      reason: 'DOWN 应落到下一行同列（index + 列数）',
    );
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-7')),
    );
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-10')),
    );
    // 12 个频道 = 4 行：末行以下 DOWN 吞键（页面底，焦点原地不动）。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-10')),
      reason: '末行以下 DOWN 应吞键（spec §4.4）',
    );
    // UP 逐行回顶。
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-7')),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网格首行 UP：最左列去分组栏记忆行，其余列去搜索框', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    await tester.pumpWidget(_harness(controller, const LivePage()));
    await tester.pumpAndSettle();

    // 焦点在第 2 格（非最左列）：UP → 页头搜索框行。
    _channelNode(tester, '央视频道-CCTV-2').requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(_searchFieldNode(tester)),
      reason: '非最左列 UP 应落搜索框行',
    );

    // 焦点在第 1 格（最左列）：UP → 分组栏记忆行（受控记忆节点
    // live-rail-current 挂在第 0 行）。
    _channelNode(tester, '央视频道-CCTV-1').requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(_groupNode(tester, '央视频道')),
      reason: '最左列 UP 应落分组栏记忆行',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网格行内 LEFT/RIGHT 显式移动，最左列 LEFT 回分组栏、最右列吞键', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 壳层桩：验证页面消费了 LEFT（桩不触发 = 没被壳层吃掉）。
    final stub = _ShellLeftStub();
    addTearDown(stub.dispose);
    final controller = _buildController();
    await tester.pumpWidget(_stubHarness(controller, stub, const LivePage()));
    await tester.pumpAndSettle();

    // 行内左移：CCTV-2 LEFT → CCTV-1（页面显式投递，壳层桩不触发）。
    _channelNode(tester, '央视频道-CCTV-2').requestFocus();
    await tester.pumpAndSettle();
    stub.leftFired = false;
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-1')),
    );
    expect(stub.leftFired, isFalse, reason: '行内 LEFT 应被页面消费');

    // 行内右移：CCTV-1 RIGHT → CCTV-2。
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-2')),
    );

    // 最左列 LEFT → 分组栏记忆行（不是壳层）。
    _channelNode(tester, '央视频道-CCTV-1').requestFocus();
    await tester.pumpAndSettle();
    stub.leftFired = false;
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_groupNode(tester, '央视频道')),
      reason: '最左列 LEFT 应落分组栏记忆行',
    );
    expect(stub.leftFired, isFalse);

    // 分组栏 LEFT → 放行给壳层（进侧栏通道）。
    stub.leftFired = false;
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(stub.leftFired, isTrue, reason: '分组栏 LEFT 应交壳层进侧栏');
    expect(FocusManager.instance.primaryFocus, same(stub.rail));

    // 最右列 RIGHT：吞键（行尾）。
    _channelNode(tester, '央视频道-CCTV-3').requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-3')),
      reason: '最右列 RIGHT 应吞键',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分组栏 RIGHT/栏尾 DOWN 进网格记忆格，栏首 UP 回搜索框', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController(
      liveService: _FakeLiveService(groups: ['央视频道', '卫视频道']),
    );
    await tester.pumpWidget(_harness(controller, const LivePage()));
    await tester.pumpAndSettle();

    // 分组栏第 2 行获焦（换组）：RIGHT → 网格记忆格（新组第 0 格）。
    _groupNode(tester, '卫视频道').requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '卫视频道-CCTV-1')),
      reason: '分组栏 RIGHT 应进网格记忆格',
    );

    // 网格下移一行，LEFT 回分组栏，RIGHT 回同一记忆格。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    final memory = FocusManager.instance.primaryFocus;
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_groupNode(tester, '卫视频道')),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(memory),
      reason: '分组栏 RIGHT 应回网格上次聚焦格（记忆）',
    );

    // 栏尾（最后一组）DOWN → 网格记忆格。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(memory),
      reason: '栏尾 DOWN 应进网格记忆格',
    );

    // 栏首 UP → 页头搜索框行。
    _groupNode(tester, '央视频道').requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(_searchFieldNode(tester)),
      reason: '栏首 UP 应落搜索框行',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('页头行左右显式移动，行尾吞键，UP 回分组栏、DOWN 进网格', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController();
    await tester.pumpWidget(_harness(controller, const LivePage()));
    await tester.pumpAndSettle();

    // 搜索框 RIGHT → 刷新 → 继续上次频道 → 直播设置（无搜索词无清空钮）。
    _searchFieldNode(tester).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('刷新直播源')).focusNode),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('继续上次频道')).focusNode),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('直播设置')).focusNode),
    );
    // 行尾 RIGHT 吞键。
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('直播设置')).focusNode),
    );
    // 行内 LEFT 逐步左移：设置 → 继续上次频道 → 刷新 → 搜索框。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('继续上次频道')).focusNode),
    );
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('刷新直播源')).focusNode),
    );
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_searchFieldNode(tester)),
    );

    // 页头 DOWN → 网格记忆格；页头 UP → 分组栏记忆行。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-1')),
      reason: '页头 DOWN 应进网格记忆格',
    );
    _searchFieldNode(tester).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(_groupNode(tester, '央视频道')),
      reason: '页头 UP 应落分组栏记忆行',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('搜索框 LEFT 放行交壳层进侧栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final stub = _ShellLeftStub();
    addTearDown(stub.dispose);
    final controller = _buildController();
    await tester.pumpWidget(_stubHarness(controller, stub, const LivePage()));
    await tester.pumpAndSettle();

    _searchFieldNode(tester).requestFocus();
    await tester.pumpAndSettle();
    stub.leftFired = false;
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(stub.leftFired, isTrue, reason: '搜索框 LEFT 应交壳层（进侧栏）');
    expect(FocusManager.instance.primaryFocus, same(stub.rail));
    // 拆树前把焦点从桩节点挪回页面，避免拆树时桩节点带焦断开。
    _searchFieldNode(tester).requestFocus();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分组栏换组不抢焦：焦点留在栏内（焦点体系重建回归）', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController(
      liveService: _FakeLiveService(groups: ['央视频道', '卫视频道']),
    );
    final entry = FocusNode(debugLabel: 'live-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(_harness(controller, LivePage(entryFocus: entry)));
    await tester.pumpAndSettle();
    expect(entry.hasFocus, isTrue);

    // 焦点移到分组栏第 2 行（触发换组 + 网格重建）：焦点必须留在栏内。
    // 修复前 _claimEntry 会在帧末把入口焦点抢回网格第一格（跳丢）；
    // 换组时 ShelfRow 的记忆节点会换位（内部节点 → 受控记忆节点
    // live-rail-current），落点断言用 debugLabel。
    _groupNode(tester, '卫视频道').requestFocus();
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      isNot(same(entry)),
      reason: '换组重建网格不得把焦点从分组栏拽走',
    );
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'live-rail-current',
      reason: '换组后焦点应落在分组栏记忆行',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('跨缓存区 DOWN 确定性投递（40 频道滚动到底）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _buildController(
      liveService: _FakeLiveService(channels: 40),
    );
    await tester.pumpWidget(_harness(controller, const LivePage()));
    await tester.pumpAndSettle();

    // 逐行 DOWN 到最后一行（40 频道 / 3 列 = 14 行）：中途目标行在
    // 缓存区外，走「先滚动再补投」路径。
    for (var i = 0; i < 13; i++) {
      await _send(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-40')),
      reason: '连续 DOWN 应逐行到达最后一行（index 39）',
    );
    // 网格确实滚动过（焦点揭示生效）。
    final scrollable = find
        .descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0), reason: '网格应随焦点滚动');

    // 末行以下 DOWN 吞键；UP 逐行回。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-40')),
    );
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(_channelNode(tester, '央视频道-CCTV-37')),
    );
    await tester.pumpWidget(const SizedBox());
  });
}