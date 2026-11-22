import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/live_preferences.dart';
import '../../core/remote_search_server.dart';
import '../../core/utils.dart';
import '../../data/live_parser.dart';
import '../../data/models.dart';
import '../../theme/ui.dart';
import '../pages/live_player_page.dart';
import '../pages/settings_page.dart';
import '../widgets/common.dart';
import '../widgets/channel_password_dialog.dart';
import '../widgets/remote_search_dialog.dart';
import '../widgets/shelf_row.dart';
import '../widgets/t9_search_dialog.dart';
import '../tv_canvas.dart';

/// 焦点所在区块（直播页投递表的行索引，见 `_LivePageState._handlePageKey`）。
enum _LiveZone { header, rail, grid }

/// 对直播分组过滤结果做小型记忆化：相同分组数据与规范化 query 重用同一
/// 个列表，避免一次 build 内重复遍历所有频道并重复创建过滤分组。
class LiveGroupFilterCache {
  static const int _maxEntries = 16;

  LiveParseResult? _source;
  final Map<String, List<LiveGroup>> _groupsByQuery = {};

  List<LiveGroup> groupsFor(LiveParseResult? result, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (!identical(result, _source)) {
      _source = result;
      _groupsByQuery.clear();
    }
    final cached = _groupsByQuery[normalizedQuery];
    if (cached != null) {
      // 读后重插维持小型 LRU，避免长时间输入不同 query 后缓存无限增长。
      _groupsByQuery
        ..remove(normalizedQuery)
        ..[normalizedQuery] = cached;
      return cached;
    }
    if (result == null || normalizedQuery.isEmpty) {
      final groups = result?.groups ?? const <LiveGroup>[];
      _cache(normalizedQuery, groups);
      return groups;
    }

    final groups = result.groups
        .map(
          (group) => LiveGroup(
            name: group.name,
            channels: group.channels
                .where(
                  (channel) =>
                      channel.name.toLowerCase().contains(normalizedQuery),
                )
                .toList(),
          ),
        )
        .where((group) => group.channels.isNotEmpty)
        .toList();
    _cache(normalizedQuery, groups);
    return groups;
  }

  void _cache(String query, List<LiveGroup> groups) {
    _groupsByQuery[query] = groups;
    if (_groupsByQuery.length > _maxEntries) {
      _groupsByQuery.remove(_groupsByQuery.keys.first);
    }
  }
}

class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    this.entryFocus,
    this.topRequest,
    this.onExitToNav,
  });

  /// Focus target when Down is pressed on the top tab bar.
  final FocusNode? entryFocus;

  /// Fires when the top tab bar takes focus; both columns scroll to the top.
  final ValueListenable<int>? topRequest;

  /// 内容层向上退出（页头行再按 UP）：把焦点交回导航栏。
  /// 独立挂载（测试/无 shell）时为 null——UP 放行默认遍历兜底。
  final VoidCallback? onExitToNav;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  AppController? _controller;
  LiveParseResult? _result;
  bool _loading = true;
  String? _error;
  String _selectedGroup = '';
  String _query = '';
  final LiveGroupFilterCache _groupFilterCache = LiveGroupFilterCache();
  int _requestToken = 0;
  String? _sourceKey;
  bool _booted = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _railScroll = ScrollController();
  final ScrollController _gridScroll = ScrollController();
  int _gridFocusRequest = 0;
  int? _pendingGridIndex;
  FocusNode? _pendingGridNode;
  FocusNode? _pendingGridOrigin;
  VoidCallback? _pendingGridScrollListener;
  bool _pendingGridScrollRunning = false;

  /// 分组栏「上次聚焦项」的焦点节点（FOCUS-08/09）。网格最左列按 LEFT
  /// 时几何遍历的落点不可预期（会挑到相邻分组而不是上次那行），所以把它
  /// 作为 `ShelfRow` 的受控记忆节点（memoryFocus）挂到 `_railIndex` 指向
  /// 的那一行，由 `_ChannelTile` 在收到 LEFT 时显式投递
  /// （AGENTS.md §3 FOCUS-08/09）。
  final FocusNode _railFocus = FocusNode(debugLabel: 'live-rail-current');

  /// 分组栏上次聚焦的行（FOCUS-09），即 `ShelfRow` 的受控记忆索引
  /// （memoryIndex）。节点跟着「上次聚焦项」走：焦点离开分组栏
  /// （网格/顶栏）再 DOWN/LEFT 回来时，落点才是用户最后看的那一行，
  /// 而不是第一行。
  final ValueNotifier<int> _railIndex = ValueNotifier<int>(0);

  // ===== 焦点体系重建（docs/focus-system-spec.md §4/§5）=====

  /// 页面根按键捕获（skipTraversal，不参与遍历）：区块内未消费的方向键
  /// 冒泡到这里，按「区块 × 方向」投递表显式派送（见 [_handlePageKey]
  /// 头注的投递表）。
  final FocusNode _navKeyFocus = FocusNode(debugLabel: 'live-nav-key');

  /// 内容区 FocusScope（spec §4.2）：搜索框行 / 分组栏 / 频道网格都是它
  /// 的后代；壳层根 Focus（LEFT → 侧栏）在它之上兜底。
  final FocusScopeNode _pageScope = FocusScopeNode(debugLabel: 'page-live');

  /// 分组栏 FocusScope（spec §2）：栏内上下移动的几何遍历范围，与网格
  /// 分区隔开。
  final FocusScopeNode _railScope = FocusScopeNode(
    debugLabel: 'page-live-rail',
  );

  /// 网格第 0 格的兜底入口节点（壳层未注入 entryFocus 的独立挂载 /
  /// 测试挂载时，入口焦点与 UP/DOWN 投递的落点节点）。
  final FocusNode _gridEntryFocus = FocusNode(debugLabel: 'live-grid-entry');

  /// 频道网格每格的焦点节点（spec §3 规则 7：多行网格显式投递，不赌
  /// 几何遍历是否看得到缓存区行）。index 0 归入口节点，不入表、不重复
  /// dispose。
  final Map<int, FocusNode> _gridNodes = {};

  /// 网格当前记忆格：分组栏 RIGHT / 页头 DOWN 的确定性落点。
  int _gridMemory = 0;

  /// 页头行动作的页面持有节点。页头行的 LEFT/RIGHT 要按下标找相邻元素
  /// 做显式投递（壳层根 Focus 会拦截一切未消费的 LEFT，放行会被壳层
  /// 吃掉），TvFocusable 自持节点拿不到，必须由页面持有。
  final FocusNode _clearFocus = FocusNode(debugLabel: 'live-header-clear');
  final FocusNode _refreshFocus = FocusNode(debugLabel: 'live-header-refresh');
  final FocusNode _resumeFocus = FocusNode(debugLabel: 'live-header-resume');
  final FocusNode _settingsFocus = FocusNode(
    debugLabel: 'live-header-settings',
  );

  /// 网格内容签名（分组名/频道数/过滤词）。内容变了才重投入口焦点，
  /// 避免普通滚动重建时抢焦点。
  String _lastGridSignature = '';

  /// 手机远程输入服务（扫码用）与两个浮层开关：二维码弹窗、T9 搜索弹窗。
  /// 服务生命周期绑定二维码浮层（关闭即停服，杜绝孤儿服务）。
  RemoteSearchServer? _remote;
  bool _remoteOpen = false;
  bool _searchDialogOpen = false;

  /// T9 弹窗里按了「扫码」：等弹窗关闭、焦点归位后再开二维码浮层，
  /// 避免两层模态叠在一起、焦点落在被盖住的页面上。
  bool _scanAfterSearchDialog = false;

  /// 网格是否还在顶部（TAB-02）：内容停在顶部时给悬浮顶栏让位，滚起来后
  /// 收回（否则会把已经滚走的内容钉回视口顶部）。
  ///
  /// 让位量**只跟滚动位置走、不跟焦点走**：若在「顶栏 ↔ 内容」之间移动焦点
  /// 时切换让位，内容会上下各跳 64px——尤其焦点上移到顶栏时收回让位，内容
  /// 顶行被悬浮顶栏遮住，正是「焦点上移到顶栏时顶栏跳动、遮住内容」的根因。
  bool _gridAtTop = true;

  /// FOCUS-06：搜索过滤或切分组后网格重建，第一项靠 `autofocus` 落焦点
  /// 并不可达（旧节点还活着时 autofocus 不会再次生效），所以这里在「整页
  /// 还没有任何焦点」时把入口焦点补投到网格第一格。
  ///
  /// 焦点已在本页任意区块（网格/分组栏/页头）时**不抢**：分组栏换组、
  /// 搜索过滤都会重建网格，抢焦会把焦点从用户正在操作的区块拽走
  /// （跳丢，2026-11-19 焦点体系重建立项审计实证）；焦点在本页之外
  /// （壳层侧栏 / 别的 tab）时同样不抢，用户意图优先。
  void _claimEntry() {
    final node = widget.entryFocus;
    if (node == null) return;
    if (node.hasFocus) return;
    final activeContext = FocusManager.instance.primaryFocus?.context;
    if (activeContext != null) return; // 页内页外都已有焦点：不抢。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.canRequestFocus || node.hasFocus) return;
      node.requestFocus();
    });
  }

  // ===== 焦点体系重建：显式投递工具（spec §5）=====

  /// 网格第 [index] 项的焦点节点（index 0 = 入口节点，不入表、不重复
  /// dispose）。
  FocusNode _gridNodeAt(int index) {
    if (index == 0) return widget.entryFocus ?? _gridEntryFocus;
    return _gridNodes.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'live-channel-$index'),
    );
  }

  /// 焦点节点反查网格下标（只有网格内的节点参与 UP/DOWN 投递判定）。
  int? _gridIndexOf(FocusNode node) {
    if (identical(node, widget.entryFocus) ||
        identical(node, _gridEntryFocus)) {
      return 0;
    }
    for (final MapEntry<int, FocusNode> entry in _gridNodes.entries) {
      if (entry.value == node) return entry.key;
    }
    return null;
  }

  /// 频道网格列数：与 `SliverGridDelegateWithMaxCrossAxisExtent` 同公式
  /// （max(1, ceil(网格宽 / (maxCrossAxisExtent + 交叉间距)))），供
  /// UP/DOWN 按「index ± 列数」算同列上/下行。网格宽 = 画布宽 − 直播页
  /// 左右边距 − 分组栏宽 − 栏间距，全部取设计常量与皮肤 token，三套
  /// 皮肤下与实际布局一致。
  int get _gridColumns {
    final skin = TvSkin.of(context);
    final railWidth = skin.spaceXl * 7 + skin.spaceMd;
    final boardWidth =
        TvCanvas.designWidth - 2 * TvCanvas.livePad - railWidth - skin.spaceMd;
    final stride = (skin.spaceXl * 9 + skin.spaceMd) + (skin.spaceSm + 2);
    final columns = (boardWidth / stride).ceil();
    return columns < 1 ? 1 : columns;
  }

  void _clearPendingGridFocus() {
    final listener = _pendingGridScrollListener;
    if (listener != null) _gridScroll.removeListener(listener);
    _pendingGridScrollListener = null;
    _pendingGridNode = null;
    _pendingGridOrigin = null;
    _pendingGridIndex = null;
    _pendingGridScrollRunning = false;
  }

  void _stopPendingGridScroll() {
    if (!_pendingGridScrollRunning) return;
    _pendingGridScrollRunning = false;
    if (!_gridScroll.hasClients) return;
    final position = _gridScroll.position;
    position.jumpTo(position.pixels);
  }

  void _cancelGridFocusRequest() {
    _gridFocusRequest++;
    _stopPendingGridScroll();
    _clearPendingGridFocus();
  }

  void _schedulePendingGridFocusCheck(int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryPendingGridFocus(request);
    });
  }

  void _tryPendingGridFocus(int request) {
    if (!mounted || request != _gridFocusRequest) return;
    final node = _pendingGridNode;
    if (node == null) return;
    if (ModalRoute.of(context)?.isCurrent == false) {
      _cancelGridFocusRequest();
      return;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (identical(primary, node)) {
      if (!_pendingGridScrollRunning) _clearPendingGridFocus();
      return;
    }
    if (!_isPendingGridOrigin(primary)) {
      _cancelGridFocusRequest();
      return;
    }
    final target = node.context;
    if (target == null || !target.mounted || !node.canRequestFocus) return;
    // 目标节点一挂载就取得焦点；滚动剩余部分期间按键仍按目标下标续投。
    node.requestFocus();
    _schedulePendingGridFocusCheck(request);
  }

  void _onFocusChanged() {
    final node = _pendingGridNode;
    if (node == null) return;
    final primary = FocusManager.instance.primaryFocus;
    if (identical(primary, node)) {
      if (!_pendingGridScrollRunning) _clearPendingGridFocus();
    } else if (!_isPendingGridOrigin(primary)) {
      _cancelGridFocusRequest();
    }
  }

  bool _isPendingGridOrigin(FocusNode? focus) =>
      focus == null ||
      identical(focus, _pendingGridOrigin) ||
      identical(focus, _pageScope) ||
      identical(focus, _navKeyFocus);

  /// 按 index 确定性投递焦点到网格格（spec §3 规则 7 + §5 范式）。
  /// 未挂载目标预滚动使用非线性曲线；节点一挂载便接管焦点，动画期间
  /// 连续按键沿目标索引继续派送。离开网格时会取消旧滚动与焦点请求。
  void _focusGridIndex(int index) {
    final group = _currentGroup;
    if (group == null || index < 0 || index >= group.channels.length) return;
    final request = ++_gridFocusRequest;
    _stopPendingGridScroll();
    _clearPendingGridFocus();
    _gridMemory = index;
    final node = _gridNodeAt(index);
    final skin = TvSkin.of(context);
    final rowHeight = skin.spaceLg * 3 + skin.spaceMd; // mainAxisExtent
    final stride = rowHeight + skin.spaceSm + 2; // + mainAxisSpacing
    if (_gridScroll.hasClients) {
      final position = _gridScroll.position;
      final rowTop = (index ~/ _gridColumns) * stride;
      final viewportBottom = position.pixels + position.viewportDimension;
      // 目标行有任一边越过视口时滚动到最小可见位置，避免离屏焦点。
      double target = position.pixels;
      if (rowTop + rowHeight > viewportBottom) {
        target = rowTop + rowHeight - position.viewportDimension;
      } else if (rowTop < position.pixels) {
        target = rowTop;
      }
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((position.pixels - target).abs() > 0.5) {
        _pendingGridIndex = index;
        _pendingGridNode = node;
        _pendingGridOrigin = FocusManager.instance.primaryFocus;
        void onScroll() => _schedulePendingGridFocusCheck(request);
        _pendingGridScrollListener = onScroll;
        _gridScroll.addListener(onScroll);
        final duration = AppMotion.scrollDuration(context);
        _pendingGridScrollRunning = duration != Duration.zero;
        if (node.context != null && node.canRequestFocus) node.requestFocus();
        if (duration == Duration.zero) {
          position.jumpTo(target);
        } else {
          position
              .animateTo(
                target,
                duration: duration,
                curve: AppMotion.scrollCurve,
              )
              .then((_) {
                if (request != _gridFocusRequest) return;
                _pendingGridScrollRunning = false;
                _schedulePendingGridFocusCheck(request);
              });
        }
        _schedulePendingGridFocusCheck(request);
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
    }
    _clearPendingGridFocus();
    if (node.context != null && node.canRequestFocus) {
      // 已挂载目标同步 requestFocus，方向键不等待滚动动画结束。
      node.requestFocus();
    } else {
      _pendingGridIndex = index;
      _pendingGridNode = node;
      _pendingGridOrigin = FocusManager.instance.primaryFocus;
      void onScroll() => _schedulePendingGridFocusCheck(request);
      _pendingGridScrollListener = onScroll;
      if (_gridScroll.hasClients) _gridScroll.addListener(onScroll);
      _schedulePendingGridFocusCheck(request);
    }
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 投递到分组栏记忆行（网格最左列 LEFT / 网格首行 UP / 页头 UP 共用）。
  /// 记忆行滚出视口（回顶请求把栏滚回首项）时补一次最小揭示，避免焦点
  /// 落在看不见的行上；记忆行未挂载（栏滚远）时放行几何遍历兜底，不让
  /// 按键变成死键。
  void _focusRailMemory() {
    _cancelGridFocusRequest();
    final node = _railFocus;
    if (node.canRequestFocus) {
      node.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !node.hasFocus) return;
        final target = node.context;
        if (target == null || !target.mounted) return;
        _revealRailNode(target);
      });
      return;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null) {
      FocusScope.of(focusContext).focusInDirection(TraversalDirection.left);
    }
  }

  void _revealRailNode(BuildContext target) {
    if (!_railScroll.hasClients) return;
    final duration = AppMotion.scrollDuration(context);
    if (duration != Duration.zero) {
      Scrollable.ensureVisible(
        target,
        alignment: 0.0,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: duration,
        curve: AppMotion.scrollCurve,
      );
      return;
    }
    final renderObject = target.findRenderObject();
    if (renderObject == null || !renderObject.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return;
    final position = _railScroll.position;
    final leading = viewport.getOffsetToReveal(renderObject, 0).offset;
    final trailing = viewport.getOffsetToReveal(renderObject, 1).offset;
    var offset = position.pixels;
    if (leading < position.pixels) {
      offset = leading;
    } else if (trailing > position.pixels) {
      offset = trailing;
    }
    offset = offset.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((offset - position.pixels).abs() > 0.5) position.jumpTo(offset);
  }

  /// 静态区块（页头行动作 / 搜索框 / 返回类按钮）的焦点投递：区块不
  /// 滚动，requestFocus 即达。
  void _focusNear(FocusNode node) {
    // 页头/分组栏入口替换频道网格目标时，取消仍在播放的网格滚动请求。
    _cancelGridFocusRequest();
    if (node.canRequestFocus) node.requestFocus();
  }

  /// 网格换组 / 过滤后回收超界节点：只 dispose 已不在树上的（仍挂树的
  /// 可能是当前焦点节点，dispose 会触发框架断言）。
  void _pruneGridNodes(int channelCount) {
    _gridNodes.removeWhere((index, node) {
      if (index < channelCount) return false;
      final context = node.context;
      if (context != null && context.mounted) return false;
      node.dispose();
      return true;
    });
  }

  // ===== 焦点体系重建：区块判定与方向键投递表（spec §4/§5）=====

  /// 焦点所在区块（沿 element 祖先找最近的区块标记）。顺序即判定顺序：
  /// 网格格（_ChannelTile）在 _ChannelBoard 内部，必须先判；分组栏
  /// （_GroupRail）是独立子树；页头行（搜索框 / 清空 / 圆钮）兜底。
  _LiveZone _zoneOf(BuildContext context) {
    var zone = _LiveZone.header;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is _GroupRail) {
        zone = _LiveZone.rail;
        return false;
      }
      if (widget is _ChannelTile) {
        zone = _LiveZone.grid;
        return false;
      }
      return true;
    });
    return zone;
  }

  /// 页面根方向键分发（spec §5 显式投递范式）：区块内未消费的方向键
  /// 冒泡到这里，按下表派送。
  ///
  /// 直播页投递表（行 = 当前焦点所在区块，列 = 方向）：
  ///
  /// | 区块＼方向 | UP | DOWN | LEFT | RIGHT |
  /// | --- | --- | --- | --- | --- |
  /// | 页头行 | 分组栏记忆行 | 网格记忆格 | 搜索框(行首) ignored→壳层进侧栏；其余显式左移 | 显式右移；行尾吞键 |
  /// | 分组栏 | 栏首→搜索框；栏内 ignored→框架几何遍历 | 栏尾→网格记忆格；栏内 ignored→框架 | ignored→壳层进侧栏（页面最左列，spec §3 唯一入口） | 网格记忆格 |
  /// | 频道网格 | index−列数；首行→最左列去分组栏、其余去搜索框 | index+列数；末行以下吞键（页面底） | 最左列→分组栏记忆行；其余 index−1（显式，LEFT 放行会被壳层吃掉） | 最右列吞键；其余 index+1 |
  ///
  /// 「ignored→壳层」的格子：壳层根 Focus 把内容区 LEFT 投到侧栏当前
  /// 条目（shell_page `_handleShellKey`），是 spec §3 唯一的进侧栏入口。
  /// 「ignored→框架」的格子：分组栏栏内 UP/DOWN 的相邻项已挂载
  /// （ShelfRow 缓存 ≥ 一行且移动自带 ensureVisible），几何遍历可靠。
  KeyEventResult _handlePageKey(FocusNode node, KeyEvent event) {
    // keydown 与长按 repeat 都走显式投递：repeat 放给框架会落回几何
    // 遍历，网格行落点不可控（死键 / 跳丢的根因之一）。
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isUp = key == LogicalKeyboardKey.arrowUp;
    final isDown = key == LogicalKeyboardKey.arrowDown;
    final isLeft = key == LogicalKeyboardKey.arrowLeft;
    final isRight = key == LogicalKeyboardKey.arrowRight;
    if (!isUp && !isDown && !isLeft && !isRight) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focus == null || focusContext == null) return KeyEventResult.ignored;
    if (_pendingGridIndex != null) {
      return _handleGridNavKey(
        _pendingGridNode ?? focus,
        isUp: isUp,
        isDown: isDown,
        isLeft: isLeft,
        isRight: isRight,
      );
    }
    switch (_zoneOf(focusContext)) {
      case _LiveZone.header:
        return _handleHeaderKey(
          focus,
          isUp: isUp,
          isDown: isDown,
          isLeft: isLeft,
          isRight: isRight,
        );
      case _LiveZone.rail:
        return _handleRailKey(
          isUp: isUp,
          isDown: isDown,
          isLeft: isLeft,
          isRight: isRight,
        );
      case _LiveZone.grid:
        return _handleGridNavKey(
          focus,
          isUp: isUp,
          isDown: isDown,
          isLeft: isLeft,
          isRight: isRight,
        );
    }
  }

  /// 页头行（搜索框 + 清空 + 刷新/继续/设置）方向键。LEFT/RIGHT 必须
  /// 显式投递：壳层根 Focus 拦截一切未消费的 LEFT，行内放行会被壳层
  /// 吃掉（焦点跳丢进侧栏）。
  KeyEventResult _handleHeaderKey(
    FocusNode focus, {
    required bool isUp,
    required bool isDown,
    required bool isLeft,
    required bool isRight,
  }) {
    final group = _currentGroup;
    if (isUp) {
      // 页头 UP → 分组栏记忆行（层级上升，落点稳定不随几何漂移）。
      _focusRailMemory();
      return KeyEventResult.handled;
    }
    if (isDown) {
      // 页头 DOWN → 频道网格当前记忆格；无频道时放行（空态按钮可达）。
      if (group != null && group.channels.isNotEmpty) {
        _focusGridIndex(_gridMemory.clamp(0, group.channels.length - 1));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final nodes = _headerNodes();
    final index = nodes.indexOf(focus);
    if (isLeft) {
      // 搜索框（行首）LEFT：ignored → 壳层根 Focus 投递侧栏当前条目
      // （与首页 LEFT 链一致）；其余元素显式左移。
      if (index <= 0) return KeyEventResult.ignored;
      _focusNear(nodes[index - 1]);
      return KeyEventResult.handled;
    }
    if (index < 0) return KeyEventResult.ignored;
    if (index >= nodes.length - 1) {
      // 行尾（直播设置）RIGHT：吞键（页头行到边缘，焦点原地不动）。
      return KeyEventResult.handled;
    }
    _focusNear(nodes[index + 1]);
    return KeyEventResult.handled;
  }

  /// 分组栏方向键。能冒泡到根 Focus = 框架几何遍历在栏内没有落点
  /// （栏首 / 栏尾）；栏内的上下移动由框架负责（见 [_handlePageKey]
  /// 投递表头注）。
  KeyEventResult _handleRailKey({
    required bool isUp,
    required bool isDown,
    required bool isLeft,
    required bool isRight,
  }) {
    if (isLeft) {
      // 分组栏 LEFT（页面最左列）：ignored → 壳层进侧栏（spec §3）。
      return KeyEventResult.ignored;
    }
    if (isRight) {
      // RIGHT → 频道网格当前记忆格（分组即选中，网格内容就是该组频道）。
      final group = _currentGroup;
      if (group != null && group.channels.isNotEmpty) {
        _focusGridIndex(_gridMemory.clamp(0, group.channels.length - 1));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (isUp && _railIndex.value <= 0) {
      // 栏首 UP → 页头搜索框行。
      _focusNear(_searchFocus);
      return KeyEventResult.handled;
    }
    if (isDown && _railIndex.value >= _visibleGroups.length - 1) {
      // 栏尾 DOWN → 频道网格当前记忆格；无频道时吞键（底吞键）。
      final group = _currentGroup;
      if (group != null && group.channels.isNotEmpty) {
        _focusGridIndex(_gridMemory.clamp(0, group.channels.length - 1));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 频道网格方向键（全显式投递，见 [_handlePageKey] 投递表）。
  KeyEventResult _handleGridNavKey(
    FocusNode focus, {
    required bool isUp,
    required bool isDown,
    required bool isLeft,
    required bool isRight,
  }) {
    final group = _currentGroup;
    if (group == null) return KeyEventResult.ignored;
    final count = group.channels.length;
    final index = _gridIndexOf(focus);
    if (index == null) return KeyEventResult.ignored;
    final columns = _gridColumns;
    if (isUp) {
      final target = index - columns;
      if (target >= 0) {
        _focusGridIndex(target);
        return KeyEventResult.handled;
      }
      // 首行 UP：最左列 → 分组栏记忆行（与 LEFT 同落点，分组栏就在
      // 网格左上）；其余列 → 页头搜索框行。
      if (index % columns == 0) {
        _focusRailMemory();
      } else {
        _focusNear(_searchFocus);
      }
      return KeyEventResult.handled;
    }
    if (isDown) {
      final target = index + columns;
      if (target < count) {
        _focusGridIndex(target);
        return KeyEventResult.handled;
      }
      // 末行以下 DOWN：吞键（页面底；焦点原地不动，spec §4.4 边界吞键）。
      return KeyEventResult.handled;
    }
    if (isLeft) {
      if (index % columns == 0) {
        // 最左列 LEFT → 分组栏记忆行（受控记忆节点，落上次聚焦组）。
        _focusRailMemory();
        return KeyEventResult.handled;
      }
      // 其余列：同排左移一格（显式投递；LEFT 放行会被壳层根 Focus
      // 拦截吃掉，跳丢进侧栏）。
      _focusGridIndex(index - 1);
      return KeyEventResult.handled;
    }
    // isRight：最右列（含末行不满列）→ 吞键（行尾）；其余 → 同排右移。
    final atRowEnd = index % columns == columns - 1 || index == count - 1;
    if (atRowEnd) return KeyEventResult.handled;
    _focusGridIndex(index + 1);
    return KeyEventResult.handled;
  }

  /// 页头行的可获焦元素（按视觉顺序）：搜索框 → 清空（有词时出现）→
  /// 刷新 → 继续上次频道 → 直播设置。页头行 LEFT/RIGHT 在这张表里
  /// 按下标显式移动。
  List<FocusNode> _headerNodes() => [
    _searchFocus,
    if (_searchController.text.isNotEmpty) _clearFocus,
    _refreshFocus,
    _resumeFocus,
    _settingsFocus,
  ];

  @override
  void initState() {
    super.initState();
    widget.topRequest?.addListener(_onTopRequest);
    _gridScroll.addListener(_onGridScroll);
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant LivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topRequest != widget.topRequest) {
      oldWidget.topRequest?.removeListener(_onTopRequest);
      widget.topRequest?.addListener(_onTopRequest);
    }
  }

  void _onTopRequest() {
    if (!mounted) return;
    _cancelGridFocusRequest();
    // 让位与回顶并行：回顶请求先把让位张开（_gridAtTop = true），再
    // animateTo(0)。旧实现让位只跟滚动位置走，要等 _onGridScroll 在动画
    // 末尾看到 pixels <= 0.5 才翻 true，内容贴顶后补滑 64px（回顶末尾又抖
    // 一下）；先张开让位，padding 动画与回顶动画同步收敛，不再有补滑。
    if (!_gridAtTop) {
      setState(() => _gridAtTop = true);
    }
    // 回顶用 animateTo(0)：视觉上是 TV 的「弹回顶部」，测试里
    // `pumpAndSettle` 会把动画走完再断言 pixels == 0，两者不冲突。
    final duration = AppMotion.scrollDuration(context);
    for (final controller in [_railScroll, _gridScroll]) {
      if (controller.hasClients && controller.offset > 0.5) {
        if (duration == Duration.zero) {
          controller.jumpTo(0);
        } else {
          controller.animateTo(
            0,
            duration: duration,
            curve: AppMotion.scrollCurve,
          );
        }
      }
    }
  }

  /// 网格滚动位置 → 让位开关（TAB-02）。网格停在顶部时两栏顶部让出顶栏
  /// 高度；滚起来之后收回，避免把已经滚走的内容钉回视口顶部。
  void _onGridScroll() {
    if (!_gridScroll.hasClients) return;
    final atTop = _gridScroll.position.pixels <= 0.5;
    if (atTop == _gridAtTop) return;
    if (mounted) setState(() => _gridAtTop = atTop);
  }

  /// 内容是否给悬浮顶栏让位（TAB-02）：只在网格停在顶部时加顶部 padding，
  /// 滚起来后收回。
  ///
  /// 让位量只跟滚动位置走、不跟焦点走。旧实现把让位挂在内容获焦状态上
  /// （`_topBarFocused && _gridAtTop`），焦点一上移到顶栏就收回让位、内容顶行
  /// 被顶栏遮住并整体上跳 64px（「跳」）；改成只看 `_gridAtTop` 后，顶栏与
  /// 内容之间来回移动焦点不再触发让位切换，回顶动画也不再与让位竞态叠加。
  bool get _yieldTopBar => _gridAtTop;

  /// 分组栏上次聚焦项 → 同步给选中项（选中即换分组，高亮跟着走），
  /// 并记住索引供下次 LEFT/UP 投递（FOCUS-09）。
  void _onRailFocusIndex(int index) {
    final groups = _visibleGroups;
    if (index < 0 || index >= groups.length) return;
    _railIndex.value = index;
    final name = groups[index].name;
    if (name != _selectedGroup) _selectGroup(name);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<AppController>();
    if (!identical(controller, _controller)) {
      _controller?.removeListener(_onControllerChanged);
      _controller = controller;
      controller.addListener(_onControllerChanged);
      _sourceKey = controller.activeLiveSource?.url;
      if (!_booted) {
        _booted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    }
  }

  void _onControllerChanged() {
    final key = _controller?.activeLiveSource?.url;
    if (key != _sourceKey) {
      _sourceKey = key;
      _load();
    }
  }

  @override
  void dispose() {
    widget.topRequest?.removeListener(_onTopRequest);
    _controller?.removeListener(_onControllerChanged);
    FocusManager.instance.removeListener(_onFocusChanged);
    _gridScroll.removeListener(_onGridScroll);
    _stopPendingGridScroll();
    _clearPendingGridFocus();
    _searchController.dispose();
    _searchFocus.dispose();
    _railScroll.dispose();
    _gridScroll.dispose();
    _railFocus.dispose();
    _railIndex.dispose();
    _navKeyFocus.dispose();
    _pageScope.dispose();
    _railScope.dispose();
    _gridEntryFocus.dispose();
    _clearFocus.dispose();
    _refreshFocus.dispose();
    _resumeFocus.dispose();
    _settingsFocus.dispose();
    for (final node in _gridNodes.values) {
      node.dispose();
    }
    _gridNodes.clear();
    final remote = _remote;
    if (remote != null) unawaited(remote.stop());
    super.dispose();
  }

  Future<void> _load() async {
    _cancelGridFocusRequest();
    final controller = _controller;
    final source = controller?.activeLiveSource;
    if (controller == null || source == null) {
      setState(() {
        _loading = false;
        _error = '还没有直播源，请先在设置中配置直播地址';
      });
      return;
    }
    final token = ++_requestToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await controller.liveService.load(source);
      if (!mounted || token != _requestToken) return;
      setState(() {
        _result = result;
        _loading = false;
        _selectedGroup = result.groups.isEmpty ? '' : result.groups.first.name;
      });
      _syncRailIndex();
      if (result.warning != null) {
        showAppSnack(context, result.warning!, error: true);
      }
    } catch (error) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = _friendly(error);
      });
    }
  }

  List<LiveGroup> get _visibleGroups {
    return _groupFilterCache.groupsFor(_result, _query);
  }

  LiveGroup? get _currentGroup {
    final groups = _visibleGroups;
    if (groups.isEmpty) return null;
    if (_query.trim().isNotEmpty) return groups.first;
    for (final group in groups) {
      if (group.name == _selectedGroup) return group;
    }
    return groups.first;
  }

  void _selectGroup(String name) {
    final changed = name != _selectedGroup;
    _cancelGridFocusRequest();
    setState(() {
      _selectedGroup = name;
      if (_query.isNotEmpty) {
        _query = '';
        _searchController.clear();
      }
    });
    if (changed) {
      // 换组后网格重建：记忆格归零（新组从头看起），超界节点帧末回收。
      // 焦点此刻在分组栏上（换组一定由栏内获焦触发），_claimEntry 不再
      // 抢焦（见它的头注），分组栏上下移动的焦点不会被网格拽走。
      _gridMemory = 0;
    }
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
    // 切分组后网格内容签名变化，_claimEntry 在无焦点时补投入口焦点。
    _lastGridSignature = '';
  }

  void _onQuery(String value) {
    _cancelGridFocusRequest();
    setState(() => _query = value);
    _syncRailIndex();
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
  }

  /// 分组过滤（`_visibleGroups` 变短）后把 `_railIndex` 校正到过滤后列表里
  /// 的有效索引：优先定位 `_selectedGroup` 的新位置，找不到（被过滤掉）则
  /// 落 0。否则 LEFT 回栏时 `_railFocus` 仍挂在过滤前索引对应的另一行上，
  /// 会切错分组并清空刚输入的搜索词（FOCUS-09：回到上次聚焦项）。
  void _syncRailIndex() {
    final groups = _visibleGroups;
    if (groups.isEmpty) {
      _railIndex.value = 0;
      return;
    }
    var index = groups.indexWhere((g) => g.name == _selectedGroup);
    if (index < 0) index = 0;
    _railIndex.value = index;
  }

  /// 原始异常转中文可操作文案（对照 site_api 的 `_friendlyError`）。
  String _friendly(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    return '直播源加载失败：$message\n请检查网络后点右上角刷新，或在设置中更换直播地址。';
  }

  /// 清空频道搜索：焦点留在搜索框，方向键不会被吞掉。
  void _clearQuery() {
    _searchController.clear();
    _onQuery('');
  }

  /// 打开中间弹窗式 T9 频道搜索（不弹系统键盘）。
  ///
  /// 输入实时回写到 [_query] 让右侧网格边输边筛；弹窗里的「扫码」不在
  /// 弹窗内直接开二维码，而是先记标记，等弹窗关闭、焦点归位后再开
  /// （避免两层模态叠加导致焦点落在被盖住的页面上）。
  Future<void> _openChannelSearch() async {
    if (_searchDialogOpen) return;
    _searchDialogOpen = true;
    _scanAfterSearchDialog = false;
    await showT9SearchDialog(
      context,
      title: '搜索频道',
      initial: _searchController.text,
      hint: '输入频道名或拼音首字母',
      onChanged: _applyQuery,
      onScan: () => _scanAfterSearchDialog = true,
      returnFocus: _searchFocus,
    );
    if (!mounted) return;
    _searchDialogOpen = false;
    if (_scanAfterSearchDialog) {
      _scanAfterSearchDialog = false;
      await _openRemoteSearch();
    }
  }

  /// 弹窗/手机远程输入回写：同步输入框文本（网格标题栏显示最新词）。
  void _applyQuery(String value) {
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
    _onQuery(value);
  }

  /// 扫码远程输入：起局域网服务弹二维码（复用搜索页的远程搜索服务）。
  Future<void> _openRemoteSearch() async {
    try {
      final remote = _remote ??= RemoteSearchServer(onQuery: _onRemoteQuery);
      final url = await remote.start();
      if (!mounted) {
        await remote.stop();
        return;
      }
      if (url.isEmpty) return;
      _remoteOpen = true;
      await showRemoteSearchDialog(context, url);
      _remoteOpen = false;
      await remote.stop();
    } catch (error) {
      if (!mounted) return;
      showAppSnack(
        context,
        '远程搜索启动失败：$error\n请确认电视与手机连接同一 Wi-Fi。',
        error: true,
      );
    }
  }

  /// 手机提交关键词：关二维码浮层 → 应用过滤词 → 焦点回网格。
  void _onRemoteQuery(String query) {
    if (!mounted) return;
    if (_remoteOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      _remoteOpen = false;
    }
    _applyQuery(query);
  }

  Future<void> _openChannel(LiveGroup group, int index) async {
    final channel = group.channels[index];
    final allowed = await unlockChannel(context, channel.password);
    if (!mounted || !allowed) return;
    final fullGroup =
        _result?.groups
            .where((g) => g.channels.contains(channel))
            .firstOrNull ??
        group;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LivePlayerPage(
          epgUrl: (_controller?.epgOverride.isNotEmpty ?? false)
              ? _controller!.epgOverride
              : (_controller?.activeLiveSource?.epg ?? ''),
          group: fullGroup,
          groups: _result?.groups ?? [fullGroup],
          preferences: _controller?.livePreferences ?? const LivePreferences(),
          initialUnlocked: true,
          initialIndex: fullGroup.channels.indexOf(channel),
          httpHeaders: {
            if ((_controller?.activeLiveSource?.ua ?? '').isNotEmpty)
              'User-Agent': _controller!.activeLiveSource!.ua,
          },
        ),
      ),
    );
  }

  void _resumeChannel() {
    final memory = _controller?.storage
        .getJsonList('live_last_channel')
        .firstOrNull;
    if (memory == null ||
        memory['source'] != _controller?.activeLiveSource?.url) {
      showAppSnack(context, '当前直播源没有上次频道记录');
      return;
    }
    for (final group in _result?.groups ?? <LiveGroup>[]) {
      if (group.name != memory['group']) continue;
      final index = group.channels.indexWhere(
        (channel) => channel.name == memory['channel'],
      );
      if (index >= 0) {
        _openChannel(group, index);
        return;
      }
    }
    showAppSnack(context, '上次频道已不在当前直播源中，请重新选择');
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final skin = TvSkin.of(context);
    const hPad = TvCanvas.livePad;
    final topInset = contentTopInset(context);
    final groups = _visibleGroups;
    final group = _currentGroup;

    Widget body;
    if (_loading) {
      body = const LoadingState(label: '正在解析直播源…');
    } else if (_error != null) {
      body = ErrorState(message: _error!, onRetry: _load);
    } else if (groups.isEmpty) {
      body = EmptyState(
        message: _query.isNotEmpty ? '没有找到包含「$_query」的频道' : '直播源中没有可用频道',
        icon: Icons.tv_off_rounded,
        actionLabel: '重新加载',
        action: _load,
      );
    } else {
      // FOCUS-06：搜索过滤或切分组后网格重建，第一项靠 autofocus 落焦点
      // 不可达（旧节点还活着时 autofocus 不会再生效），整页无焦点时由
      // _claimEntry 补投入口焦点；网格超界节点帧末回收（仍挂树的不杀）。
      final groupName = group?.name ?? '';
      final channelCount = group?.channels.length ?? 0;
      final signature = '$groupName|$channelCount|$_query';
      if (signature != _lastGridSignature) {
        _lastGridSignature = signature;
        _claimEntry();
        final count = channelCount;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pruneGridNodes(count);
        });
      }
      body = Focus(
        focusNode: _navKeyFocus,
        skipTraversal: true,
        onKeyEvent: _handlePageKey,
        child: FocusScope(
          node: _pageScope,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 分组栏 FocusScope（spec §2）：栏内 UP/DOWN 的几何遍历
              // 范围，与右侧网格分区隔开。
              FocusScope(
                node: _railScope,
                child: _GroupRail(
                  groups: groups,
                  selected: group?.name ?? '',
                  controller: _railScroll,
                  currentFocus: _railFocus,
                  focusIndex: _railIndex,
                  onFocusIndex: _onRailFocusIndex,
                  onSelect: _selectGroup,
                ),
              ),
              SizedBox(width: skin.spaceMd),
              Expanded(
                child: _ChannelBoard(
                  group: group,
                  title: '电视直播',
                  subtitle:
                      '${controller.activeLiveSource?.name ?? '未配置直播源'}'
                      '${_result == null ? '' : ' · ${_result!.channelCount} 个频道'}',
                  searchController: _searchController,
                  searchFocus: _searchFocus,
                  clearFocus: _clearFocus,
                  refreshFocus: _refreshFocus,
                  resumeFocus: _resumeFocus,
                  settingsFocus: _settingsFocus,
                  gridController: _gridScroll,
                  gridNodeAt: _gridNodeAt,
                  onOpenSearch: _openChannelSearch,
                  onClearQuery: _clearQuery,
                  onOpenChannel: (index) {
                    final g = group;
                    if (g != null) _openChannel(g, index);
                  },
                  onRefresh: _load,
                  onResume: _resumeChannel,
                  onSettings: _openSettings,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: skin.bg,
      body: AppBackground(
        wallpaper: controller.wallpaper,
        child: AnimatedPadding(
          duration: AppMotion.duration(context, _kTopBarYield),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(top: _yieldTopBar ? topInset : 0),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              hPad,
              skin.spaceXs,
              hPad,
              skin.spaceLg,
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// 顶栏获焦时两栏让位的时长（TAB-02）。比焦点本身慢一点，让位不是弹跳。
const Duration _kTopBarYield = Duration(milliseconds: 220);

/// Left rail: channel groups, TV sidebar style.
class _GroupRail extends StatelessWidget {
  const _GroupRail({
    required this.groups,
    required this.selected,
    required this.controller,
    required this.currentFocus,
    required this.focusIndex,
    required this.onFocusIndex,
    required this.onSelect,
  });

  final List<LiveGroup> groups;
  final String selected;
  final ScrollController controller;

  /// 上次聚焦行的稳定落点：作为 `ShelfRow` 的受控记忆节点
  /// （memoryFocus）挂到 focusIndex 指向的行；网格最左列按 LEFT 时由
  /// 页面一侧显式投递（FOCUS-09）。
  final FocusNode currentFocus;

  /// 上次聚焦的行（FOCUS-09）：作为 `ShelfRow` 的受控记忆索引
  /// （memoryIndex），节点挂载与逐行记忆都内化在 ShelfRow 里。
  final ValueListenable<int> focusIndex;

  /// 行获焦 → 页面记下索引（并同步选中）。
  final ValueChanged<int> onFocusIndex;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return SizedBox(
      width: skin.spaceXl * 7 + skin.spaceMd,
      child: SkinSurface(
        radius: skin.radiusLg,
        padding: EdgeInsets.fromLTRB(
          skin.spaceSm,
          skin.spaceMd - 2,
          skin.spaceSm,
          skin.spaceSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: skin.spaceSm - 2),
              child: Text(
                '频道分组',
                style: text.bodyStrong.copyWith(
                  fontWeight: FontWeight.w800,
                  color: skin.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            SizedBox(height: skin.spaceMd - 4),
            Expanded(
              // 纵向 ShelfRow：逐行焦点记忆内化（FOCUS-09），页面只留
              // memoryFocus / memoryIndex 两个受控入口。cross axis 留
              // spaceSm 内边距：获焦放大/光晕的横向溢出落在 padding 区
              // 域内，不被 viewport 裁掉（首末项滚动方向轻裁量接受）。
              child: ShelfRow(
                scrollDirection: Axis.vertical,
                controller: controller,
                memoryFocus: currentFocus,
                memoryIndex: focusIndex,
                onFocusIndex: onFocusIndex,
                itemCount: groups.length,
                padding: EdgeInsets.symmetric(horizontal: skin.spaceSm),
                separator: skin.spaceXs - 2,
                itemBuilder: (context, i, node) {
                  final item = groups[i];
                  final isSelected = item.name == selected;
                  return TvFocusable(
                    radius: skin.radiusMd - 4,
                    scale: 1.0,
                    focusNode: node,
                    semanticLabel: '${item.name}，${item.channels.length} 个频道',
                    onTap: () => onSelect(item.name),
                    onFocusChange: (focused) {
                      // 记住上次聚焦的行（FOCUS-09）。
                      if (focused) onFocusIndex(i);
                    },
                    child: Builder(
                      builder: (context) {
                        // TvFocusTint 约定：获焦反白态让出不透明底，否则
                        // surfaceSubtle/accentSoft 会把焦点填充整块盖住
                        // （P1-3 同病，顶栏/站点行同款修法）。
                        final tinted = TvFocusTint.of(context);
                        return AnimatedContainer(
                          duration: AppMotion.duration(
                            context,
                            skin.motionFast,
                          ),
                          curve: Curves.easeOutCubic,
                          padding: EdgeInsets.symmetric(
                            horizontal: skin.spaceMd - 4,
                            vertical: skin.spaceSm + 1,
                          ),
                          decoration: BoxDecoration(
                            color: tinted
                                ? null
                                : (isSelected
                                      ? skin.accentSoft
                                      : skin.surfaceSubtle),
                            borderRadius: BorderRadius.circular(
                              skin.radiusMd - 4,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyStrong.copyWith(
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: tinted
                                        ? skin.textOnAccent
                                        : (isSelected
                                              ? skin.accent
                                              : skin.textPrimary),
                                  ),
                                ),
                              ),
                              SizedBox(width: skin.spaceSm - 2),
                              Text(
                                '${item.channels.length}',
                                style: text.meta.copyWith(
                                  color: tinted
                                      ? skin.textOnAccent
                                      : (isSelected
                                            ? skin.accent
                                            : skin.textMuted),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Right board: title bar + channel search + channel grid.
class _ChannelBoard extends StatelessWidget {
  const _ChannelBoard({
    required this.group,
    required this.title,
    required this.subtitle,
    required this.searchController,
    required this.searchFocus,
    required this.clearFocus,
    required this.refreshFocus,
    required this.resumeFocus,
    required this.settingsFocus,
    required this.gridController,
    required this.gridNodeAt,
    this.onOpenSearch,
    this.onClearQuery,
    required this.onOpenChannel,
    required this.onRefresh,
    required this.onResume,
    required this.onSettings,
  });

  final LiveGroup? group;
  final String title;
  final String subtitle;
  final TextEditingController searchController;

  /// 搜索框焦点节点（页面持有；页头行 UP/DOWN 投递与 T9 弹窗的
  /// returnFocus 落点都挂它）。
  final FocusNode searchFocus;

  /// 清空搜索钮（有搜索词时出现）的焦点节点：页头行的显式左右投递
  /// 要按下标找邻居，必须由页面持有。
  final FocusNode clearFocus;
  final FocusNode refreshFocus;
  final FocusNode resumeFocus;
  final FocusNode settingsFocus;
  final ScrollController gridController;

  /// 网格第 index 格的焦点节点（页面侧 Map 显式投递，spec §3 规则 7）。
  final FocusNode Function(int index) gridNodeAt;

  /// 打开中间弹窗式 T9 搜索（不弹系统键盘）。
  final VoidCallback? onOpenSearch;

  /// 清空搜索（焦点不离开搜索框）。
  final VoidCallback? onClearQuery;
  final ValueChanged<int> onOpenChannel;
  final VoidCallback onRefresh;
  final VoidCallback onResume;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final channel = group;
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final actionSize = skin.spaceLg + skin.spaceMd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.pageTitle),
                  SizedBox(height: skin.spaceXs - 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.muted,
                  ),
                ],
              ),
            ),
            SizedBox(width: skin.spaceMd - 2),
            SizedBox(
              width: skin.spaceXl * 10,
              // 展示型搜索框：按下 OK 打开中间 T9 弹窗，页面上不存在
              // TextField，因此不会拉起系统软键盘（遥控器输入的唯一入口）。
              child: TvFocusable(
                focusNode: searchFocus,
                radius: skin.radiusSm + 1,
                // 搜索框不放大：宽度紧凑，放大后会顶到旁边的圆形按钮。
                scale: 1.0,
                semanticLabel: '搜索频道',
                onTap: onOpenSearch,
                child: Builder(
                  builder: (context) {
                    // TvFocusTint 约定：获焦反白态让出不透明底 + 内容反白。
                    final tinted = TvFocusTint.of(context);
                    return Container(
                      height: 44,
                      padding: EdgeInsets.symmetric(
                        horizontal: skin.spaceMd - 2,
                      ),
                      decoration: BoxDecoration(
                        color: tinted ? null : skin.surfaceSubtle,
                        borderRadius: BorderRadius.circular(skin.radiusSm + 1),
                        border: Border.all(
                          color: tinted ? Colors.transparent : skin.borderSoft,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: tinted
                                ? skin.textOnAccent
                                : skin.textSecondary,
                          ),
                          SizedBox(width: skin.spaceXs + 2),
                          Expanded(
                            child: Text(
                              searchController.text.isEmpty
                                  ? '搜索频道'
                                  : searchController.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  (searchController.text.isEmpty
                                          ? text.meta.copyWith(
                                              color: skin.textMuted,
                                            )
                                          : text.bodyStrong)
                                      .copyWith(
                                        color: tinted
                                            ? skin.textOnAccent
                                            : null,
                                      ),
                            ),
                          ),
                          Icon(
                            Icons.keyboard_alt_outlined,
                            size: 16,
                            color: tinted ? skin.textOnAccent : skin.textMuted,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (searchController.text.isNotEmpty) ...[
              SizedBox(width: skin.spaceXs + 2),
              TvFocusable(
                radius: skin.radiusPill,
                scale: 1.0,
                focusNode: clearFocus,
                semanticLabel: '清空搜索',
                onTap: onClearQuery,
                child: Builder(
                  builder: (context) {
                    // TvFocusTint 约定：获焦反白态让出不透明底 + 图标反白。
                    final tinted = TvFocusTint.of(context);
                    return Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: tinted ? null : skin.surfaceSubtle,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: tinted ? Colors.transparent : skin.borderSoft,
                        ),
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: tinted ? skin.textOnAccent : skin.textSecondary,
                      ),
                    );
                  },
                ),
              ),
            ],
            SizedBox(width: skin.spaceSm),
            _RoundAction(
              icon: Icons.refresh_rounded,
              size: actionSize,
              focusNode: refreshFocus,
              semanticLabel: '刷新直播源',
              onTap: onRefresh,
            ),
            SizedBox(width: skin.spaceSm - 2),
            _RoundAction(
              icon: Icons.history_rounded,
              size: actionSize,
              focusNode: resumeFocus,
              semanticLabel: '继续上次频道',
              onTap: onResume,
            ),
            SizedBox(width: skin.spaceSm - 2),
            _RoundAction(
              icon: Icons.settings_rounded,
              size: actionSize,
              focusNode: settingsFocus,
              semanticLabel: '直播设置',
              onTap: onSettings,
            ),
          ],
        ),
        SizedBox(height: skin.spaceMd - 2),
        Expanded(
          child: channel == null
              ? EmptyState(message: '该分组下暂无频道', icon: Icons.tv_off_rounded)
              : GridView.builder(
                  controller: gridController,
                  physics: const ClampingScrollPhysics(),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(
                    kTvGridCacheExtent,
                  ),
                  addAutomaticKeepAlives: false,
                  padding: EdgeInsets.only(bottom: skin.spaceSm - 2),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: skin.spaceXl * 9 + skin.spaceMd,
                    mainAxisExtent: skin.spaceLg * 3 + skin.spaceMd,
                    mainAxisSpacing: skin.spaceSm + 2,
                    crossAxisSpacing: skin.spaceSm + 2,
                  ),
                  itemCount: channel.channels.length,
                  itemBuilder: (context, index) {
                    return _ChannelTile(
                      channel: channel.channels[index],
                      // 节点由页面侧 Map 持有（显式投递，spec §3 规则 7）；
                      // index 0 = 壳层入口焦点节点（未注入时页面兜底）。
                      focusNode: gridNodeAt(index),
                      autofocus: index == 0,
                      onTap: () => onOpenChannel(index),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.onTap,
    required this.focusNode,
    this.autofocus = false,
  });

  final LiveChannel channel;
  final VoidCallback onTap;

  /// 页面持有的焦点节点（Map 显式投递）；方向键全部冒泡到页面根
  /// Focus 统一派送，卡片本身不挂 onKeyEvent。
  final FocusNode focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusMd,
      scale: 1.03,
      autofocus: autofocus,
      focusNode: focusNode,
      semanticLabel:
          '${channel.name}，'
          '${channel.urls.length > 1 ? '${channel.urls.length} 个源' : '直播'}',
      onTap: onTap,
      child: Builder(
        builder: (context) {
          // TvFocusTint 约定：获焦反白态让出不透明底 + 内容反白，否则
          // surfaceSubtle 会把焦点填充整块盖住（真机 K30 实证：网格卡片
          // 焦点只剩细描边，「整块换蓝」语言丢失）。
          final tinted = TvFocusTint.of(context);
          return Container(
            padding: EdgeInsets.symmetric(
              horizontal: skin.spaceSm,
              vertical: skin.spaceSm,
            ),
            decoration: BoxDecoration(
              color: tinted ? null : skin.surfaceSubtle,
              borderRadius: BorderRadius.circular(skin.radiusMd),
              border: Border.all(
                color: tinted ? Colors.transparent : skin.borderSoft,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: skin.spaceLg + skin.spaceMd,
                  height: skin.spaceLg + skin.spaceMd,
                  decoration: BoxDecoration(
                    color: skin.surfaceAlt,
                    borderRadius: BorderRadius.circular(skin.radiusSm + 5),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: channel.hasLogo
                      ? NetworkPoster(
                          url: channel.logo,
                          radius: skin.radiusSm + 5,
                          fit: BoxFit.contain,
                        )
                      : Center(
                          child: Text(
                            initials(channel.name),
                            style: text.bodyStrong.copyWith(
                              fontWeight: FontWeight.w800,
                              color: tinted
                                  ? skin.textOnAccent
                                  : skin.textMuted,
                            ),
                          ),
                        ),
                ),
                SizedBox(width: skin.spaceSm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyStrong.copyWith(
                          height: 1.25,
                          color: tinted ? skin.textOnAccent : null,
                        ),
                      ),
                      SizedBox(height: skin.spaceXs - 3),
                      Row(
                        children: [
                          Container(
                            width: skin.spaceXs - 1,
                            height: skin.spaceXs - 1,
                            decoration: BoxDecoration(
                              color: skin.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          SizedBox(width: skin.spaceXs - 3),
                          Text(
                            channel.urls.length > 1
                                ? '${channel.urls.length} 个源'
                                : '直播',
                            style: text.meta.copyWith(
                              color: tinted
                                  ? skin.textOnAccent
                                  : skin.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 右栏标题行右侧的圆形动作（刷新/继续/设置）。尺寸与图标色跟皮肤；
/// 焦点节点由页面持有（页头行的显式左右投递要按下标找邻居）。
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.focusNode,
    this.semanticLabel,
  });

  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final FocusNode focusNode;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return TvFocusable(
      radius: skin.radiusPill,
      focusNode: focusNode,
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Builder(
        builder: (context) {
          // TvFocusTint 约定：获焦反白态让出不透明底，图标反白。
          final tinted = TvFocusTint.of(context);
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: tinted ? null : skin.surfaceSubtle,
              shape: BoxShape.circle,
              border: Border.all(
                color: tinted ? Colors.transparent : skin.borderSoft,
              ),
            ),
            child: Icon(
              icon,
              size: skin.spaceMd + 5,
              color: tinted ? skin.textOnAccent : skin.textSecondary,
            ),
          );
        },
      ),
    );
  }
}
