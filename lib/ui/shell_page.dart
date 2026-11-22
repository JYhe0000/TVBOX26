import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_controller.dart';
import '../theme/ui.dart';
import 'pages/home_page.dart';
import 'pages/live_page.dart';
import 'pages/mine_page.dart';
import 'pages/search_page.dart';
import 'widgets/common.dart';
import 'widgets/tv_side_rail.dart';

/// 焦点变化后调用：若焦点元素顶部被悬浮顶栏（高 [kTopBarHeight]）遮住，
/// 把包围它的**垂直**滚动列表向下滚，让它完整露出（tvOS 焦点可见性，
/// FOCUS-01）。
///
/// 壳层已切换为 izuko 式可展开左侧导航栏（`TvSideRail`），不再注入
/// 顶部让位，本函数成为无害空操作：保留导出与签名，既有调用点
/// （`ui_smoke_test.dart` 等）继续编译，页面侧无需改动。
void ensureFocusBelowTopBar() {}

/// 壳层：izuko 式可展开左侧导航栏（`TvSideRail`）+ IndexedStack 内容区。
///
/// Tab 集合与顺序保持原顶部 Tab 栏的四个：首页 / 直播 / 搜索 / 我的。
/// 交互模型（与 izuko TvMainScreenLayout 同构）：
/// - 进页默认焦点落内容区（壳层在帧末投 `entryNodes[i]`）；
/// - 侧栏只能从内容区按左键进入（壳层根 Focus 拦截 LEFT 投递到
///   `railNodes[_index]`）；
/// - 侧栏内上下选择、OK 切页、RIGHT / BACK 回内容区；
/// - `ui_tab_index` 持久化恢复保留。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0;
  bool _restored = false;

  /// 每个 tab 的内容区入口节点：帧末投给页面（页面把它挂到自己的
  /// 主入口上，见各页 entryFocus 参数）。
  late final List<FocusNode> _entryNodes = List.generate(
    4,
    (i) => FocusNode(debugLabel: 'tab-entry-$i'),
  );
  final _homeFallbackFocus = FocusNode(debugLabel: 'home-site-chip');

  /// 侧栏条目节点：LEFT 从内容区进入时的落点（当前 tab 的条目）。
  late final List<FocusNode> _railNodes = List.generate(
    4,
    (i) => FocusNode(debugLabel: 'rail-$i'),
  );
  FocusNode? _mineCategoryReturnFocus;

  /// 切页回顶请求：切到某页时自增，页面监听后滚回顶部
  /// （沿用顶栏时代的 topRequest 通道）。
  late final List<ValueNotifier<int>> _topRequests = List.generate(
    4,
    (_) => ValueNotifier<int>(0),
  );

  /// 壳层根 Focus（skipTraversal）：拦截 LEFT 键——焦点在内容区任意处
  /// 按左键都投递到侧栏当前条目，形成「内容 → 侧栏」的唯一入口
  /// （spec §3 矩阵：页面最左列/行首 LEFT 由页面层 ignored 放行到这里；
  /// 页面行内 LEFT 由页面投递表显式消费，不会误入）。
  final FocusNode _shellKeyFocus = FocusNode(debugLabel: 'shell-nav-key');

  /// 侧栏 FocusScope（spec §2「侧栏 FocusScope: shell-rail」）：栏内
  /// UP/DOWN 的遍历范围隔离在侧栏子树，栏内移动不会串进内容区。
  /// skipTraversal：scope 节点自身不作遍历候选（防幽灵焦点）；
  /// canRequestFocus 保持默认 true——false 会连带 descendantsAreFocusable
  /// 把整棵子树变不可获焦（FocusScopeNode 的 descendantsAreFocusable
  /// 依赖自身 canRequestFocus）。
  final FocusScopeNode _railScope = FocusScopeNode(debugLabel: 'shell-rail');

  /// 内容区 FocusScope（spec §4-2「内容区 FocusScope: page-`name`，每页
  /// 一个」）：壳层创建并注入每页（页面只填内容，不再自建根 scope）。
  /// 页面内再包自己的 FocusScope（如直播页 page-live）时自然嵌套，无冲突。
  /// skipTraversal 同上（scope 节点不入遍历候选）；debugLabel 即 spec
  /// 契约的 `page-<name>` 锚点。
  late final List<FocusScopeNode> _pageScopes = List.generate(
    4,
    (i) => FocusScopeNode(debugLabel: 'page-${_tabNames[i]}'),
  );

  static const _tabNames = ['home', 'live', 'search', 'mine'];

  /// 侧栏当前是否持有焦点（任一 rail 节点获焦）。BACK 的 PopScope
  /// 拦截依赖它。
  bool get _railFocused => _railNodes.any((node) => node.hasFocus);

  @override
  void initState() {
    super.initState();
    _railScope.addListener(_onRailFocusChanged);
    // 壳层帧末把默认焦点投进内容区（FOCUS-06：进页焦点落内容区，
    // 不停在壳层或侧栏上）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusContent(_index, top: false);
    });
  }

  @override
  void dispose() {
    _railScope.removeListener(_onRailFocusChanged);
    for (final node in _entryNodes) {
      node.dispose();
    }
    _homeFallbackFocus.dispose();
    for (final node in _railNodes) {
      node.dispose();
    }
    _shellKeyFocus.dispose();
    _railScope.dispose();
    for (final scope in _pageScopes) {
      scope.dispose();
    }
    for (final notifier in _topRequests) {
      notifier.dispose();
    }
    super.dispose();
  }

  // PopScope 的 canPop 必须随焦点进入/离开侧栏更新，不能仅由切页触发。
  void _onRailFocusChanged() {
    if (mounted) setState(() {});
  }

  void _requestTop(int i) => _topRequests[i].value++;

  /// 把焦点投给第 [i] 页的内容区入口。`top` 是否同时触发回顶
  /// （切页 / 从侧栏进入时 true；启动恢复默认焦点时 false）。
  bool _focusContent(int i, {bool top = true}) {
    final primary = _entryNodes[i];
    bool available(FocusNode node) =>
        (node.context?.mounted ?? false) && node.canRequestFocus;
    final node = i == 0 && !available(primary) ? _homeFallbackFocus : primary;
    if (available(node)) {
      node.requestFocus();
      if (top) _requestTop(i);
      return true;
    }
    // 没有已挂载的页内入口时留在原处（侧栏或旧内容），避免几何遍历
    // 跳到相邻 Tab。
    return true;
  }

  /// 侧栏 OK / 触屏点按：切页 + 焦点交还内容区。
  void _handleRailSelected(int i) {
    _mineCategoryReturnFocus = null;
    if (i != _index) {
      _select(i);
    }
    // 切页后新页面刚 build，入口节点在帧末才挂载可用——post-frame
    // 投递（ izuko 同款：点击后清焦点由全局兜底送人，这里壳层显式送）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusContent(i);
    });
  }

  /// 侧栏 RIGHT / BACK：焦点回内容区（ izuko 的 onExitFocus 通道）。
  void _focusExitRail() {
    final category = _mineCategoryReturnFocus;
    _mineCategoryReturnFocus = null;
    if (category != null &&
        (category.context?.mounted ?? false) &&
        category.canRequestFocus) {
      category.requestFocus();
      return;
    }
    _focusContent(_index);
  }

  /// 内容层 UP 到页头的出口（旧 onExitToNav 通道）：把焦点交给侧栏
  /// 当前条目——izuko 的「内容区按左键进侧栏」在内容页头部的对应物，
  /// 首页页头行 UP 走这里。搜索页的 tabFocus 同理（页首 UP → 搜索条目）。
  void _exitToRail() {
    _railNodes[_index].requestFocus();
  }

  /// 壳层根按键：LEFT 从内容区进入侧栏。焦点已在侧栏内时由
  /// `TvSideRail` 自己的 onKeyEvent 处理（事件先到子节点）。
  KeyEventResult _handleShellKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    if (_railFocused) return KeyEventResult.handled;
    // 焦点在内容区（或壳层自身）时按左键：投递到侧栏当前条目。
    // 从「我的」页中间分类栏进入时，退出全局侧栏应返回原分类项。
    final primary = FocusManager.instance.primaryFocus;
    _mineCategoryReturnFocus =
        primary?.debugLabel?.startsWith('mine-category-') == true
        ? primary
        : null;
    _railNodes[_index].requestFocus();
    return KeyEventResult.handled;
  }

  static const _destinations = <TvRailDestination>[
    TvRailDestination('首页', Icons.home_rounded, Icons.home_outlined),
    TvRailDestination('直播', Icons.live_tv_rounded, Icons.live_tv_outlined),
    TvRailDestination('搜索', Icons.search_rounded, Icons.search_outlined),
    TvRailDestination('我的', Icons.person_rounded, Icons.person_outline_rounded),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // TAB-06: remember the selected tab across launches.
    final raw = context.read<AppController>().storage.getString(
      'ui_tab_index',
      '0',
    );
    final saved = int.tryParse(raw) ?? 0;
    if (saved >= 0 && saved < _destinations.length && saved != _index) {
      _index = saved;
      // 恢复 tab 后默认焦点落对应页（首页已在 initState 投过，这里
      // 补投其余页）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusContent(_index, top: false);
      });
    }
  }

  void _select(int value) {
    _mineCategoryReturnFocus = null;
    setState(() => _index = value);
    context.read<AppController>().storage.setString('ui_tab_index', '$value');
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final skin = TvSkin.of(context);
    final media = MediaQuery.of(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 20;

    return PopScope(
      // BACK 语义（izuko onExitFocus 的壳层版）：
      // - 侧栏获焦：回内容区（消费按键，不退页）；
      // - 非首页：切回首页（消费按键，同旧顶栏语义）；
      // - 首页 + 内容区焦点：放行 pop（退出应用）。
      canPop: !_railFocused && _index == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_railFocused) {
          _focusExitRail();
        } else {
          _select(0);
        }
      },
      child: _buildShell(
        skin: skin,
        controller: controller,
        media: media,
        keyboardOpen: keyboardOpen,
        content: _buildContent(),
      ),
    );
  }

  /// 壳层：皮肤底色 + 内容。液态玻璃已移除，材质统一走 [SkinSurface] 自绘的
  /// 毛玻璃（`BackdropFilter` + 半透明填充），壳层本身不再引入任何 shader。
  Widget _buildShell({
    required TvSkin skin,
    required AppController controller,
    required MediaQueryData media,
    required bool keyboardOpen,
    required Widget content,
  }) {
    final body = AppBackground(
      wallpaper: controller.wallpaper,
      child: _buildBodyStack(skin, media, keyboardOpen, content),
    );
    return Scaffold(backgroundColor: skin.bg, body: body);
  }

  Widget _buildBodyStack(
    TvSkin skin,
    MediaQueryData media,
    bool keyboardOpen,
    Widget content,
  ) {
    // 键盘弹出（理论零，电视端软键盘由 TvCanvas 的 viewInsets 换算处理）
    // 保持与顶栏时代一致的收起策略：侧栏左置悬浮，与垂直键盘无冲突。
    return Focus(
      focusNode: _shellKeyFocus,
      skipTraversal: true,
      onKeyEvent: _handleShellKey,
      child: Stack(
        children: [
          // 内容层：占满画布。顶栏让位已归零——壳不再注入 padding.top，
          // 页面里 contentTopInset(context) 读到 0（与子代理 C/D 的
          // 「页面占满垂直空间」设计对齐）。
          Positioned.fill(child: content),
          // 侧栏浮层：左置悬浮，展开时压一层右缘羽化渐变遮罩
          // （TvSideRail 内部绘制）。内容不重排。侧栏 FocusScope
          // （shell-rail）把栏内遍历隔离在侧栏子树（spec §2）。
          Positioned.fill(
            child: FocusScope(
              node: _railScope,
              skipTraversal: true,
              child: TvSideRail(
                index: _index,
                destinations: _destinations,
                itemNodes: _railNodes,
                onSelected: _handleRailSelected,
                onFocusExit: _focusExitRail,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // 注意：不要在这里再包一层 MediaQuery(data: media)——会把外层
    // Positioned.fill 注入的 padding 覆盖回原始值，页面里的
    // contentTopInset(context) 会永远读到内层值（子代理 C 审计实证）。
    // 页面直接继承外层注入的 MediaQuery。
    //
    // 每页一个内容区 FocusScope（page-<name>，spec §4-2）：壳层创建注入，
    // 页面只填内容。ExcludeFocus 负责非当前页的焦点排除，FocusScope
    // 负责当前页内部的遍历范围——两者职责不重叠。
    return IndexedStack(
      index: _index,
      children: [
        ExcludeFocus(
          excluding: _index != 0,
          child: FocusScope(
            node: _pageScopes[0],
            skipTraversal: true,
            child: HomePage(
              entryFocus: _entryNodes[0],
              siteFocus: _homeFallbackFocus,
              topRequest: _topRequests[0],
              onExitToNav: _exitToRail,
            ),
          ),
        ),
        ExcludeFocus(
          excluding: _index != 1,
          child: FocusScope(
            node: _pageScopes[1],
            skipTraversal: true,
            child: LivePage(
              entryFocus: _entryNodes[1],
              topRequest: _topRequests[1],
            ),
          ),
        ),
        ExcludeFocus(
          excluding: _index != 2,
          // 搜索页 LEFT/UP 的导航通道：搜索框在页首按 UP 交回 shell 的
          // 搜索侧栏条目（原 tab 节点）。DOWN/RIGHT 留在页内三栏。
          child: FocusScope(
            node: _pageScopes[2],
            skipTraversal: true,
            child: SearchPage(
              entryFocus: _entryNodes[2],
              topRequest: _topRequests[2],
              tabFocus: _railNodes[2],
            ),
          ),
        ),
        ExcludeFocus(
          excluding: _index != 3,
          child: FocusScope(
            node: _pageScopes[3],
            skipTraversal: true,
            child: MinePage(
              entryFocus: _entryNodes[3],
              topRequest: _topRequests[3],
            ),
          ),
        ),
      ],
    );
  }
}
