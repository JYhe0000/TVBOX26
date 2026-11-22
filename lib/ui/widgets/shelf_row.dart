import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../theme/ui.dart';
import 'common.dart';

/// 可滚动单行 + **逐行焦点记忆**（横向 shelf / 纵向侧栏两用；等价于
/// Jetpack Compose TV 的 `Modifier.focusRestorer()`，AGENTS.md §3 FOCUS-02）。
///
/// 解决的问题：可滚动 `ListView` 没有焦点记忆——用户在第 1 行右移到第 4 张卡，
/// 按 DOWN 到第 2 行、再按 UP 回来时，Flutter 的几何遍历会按 X 坐标（或
/// widget 树顺序）把焦点落到第 1 张卡，而不是他刚才看的那张。
///
/// 机制：行根 `Focus` 的 `onFocusChange` 从 false→true 代表「焦点从行外
/// 进入」（首次进入、从别的行 UP/DOWN 回来，或受控记忆换位后的抖回），
/// 此时把焦点 `requestFocus` 回 `_lastFocused` 记录的项；`_lastFocused`
/// 只在行内项之间移动时更新，所以离开再回来一定落在上次那张卡上。
///
/// 节点挂载契约（重要）：`itemBuilder` 拿到的 `node` 由**调用方**挂载——
/// 透传给 [TvFocusable.focusNode] 或自包 `Focus`。本组件只负责持有与回收，
/// 不重复挂载：同一个节点挂到两处会触发 Flutter 的「Tried to make a child
/// into a parent of itself」断言（内层 `Focus.reparent` 会把节点挂到它自己
/// 下面）。每项另有一个轻量哨兵 `Focus`（skipTraversal、不持有节点）负责
/// 记账：项内容（含后代）获焦时更新行内记忆；哨兵本身不参与遍历，正常
/// 遥控器操作不会落在它上面。
///
/// 调用方挂载的节点是行内的遍历目标（可获焦、参与方向键），行根与哨兵
/// 都 skipTraversal：焦点离开整行后落到行根，由行根投回记忆项，而不是
/// 落到行的第一个可获焦项——后者是「没有焦点记忆」的 Flutter 原生行为。
///
/// 记忆项滚出挂载区（横向滚远、`ListView` 回收）时：用统一的非线性滚动
/// 动效平滑定位，目标挂载后再投递焦点；减弱动态时直接定位。`itemExtent`
/// 为空（每项自决尺寸）时无法算位置，按节点投递并由统一焦点 helper 揭示。
///
/// 焦点视觉不在本组件里画：全部归 skin 的 `TvSkin.focus` 与 [TvFocusable]，
/// 本组件只负责节点编排（AGENTS.md §7）。
class ShelfRow extends StatefulWidget {
  const ShelfRow({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.height,
    this.padding = EdgeInsets.zero,
    this.itemExtent,
    this.separator = 0,
    this.onFocusIndex,
    this.focusTraversalGroup = true,
    this.controller,
    this.entryFocus,
    this.scrollDirection = Axis.horizontal,
    this.memoryFocus,
    this.memoryIndex,
  });

  final int itemCount;

  /// `(context, index, node) -> Widget`。`node` 的挂载权归调用方（见类文档
  /// 的挂载契约）；本组件只持有与回收，外部节点（[entryFocus] /
  /// [memoryFocus]）不入回收表、不 dispose。
  final Widget Function(BuildContext context, int index, FocusNode node)
  itemBuilder;

  /// 行高（横向模式）。缺省时按 `spaceLg`（24）+ 间距 + 最小项高 120 推导。
  /// 垂直模式忽略——高度由外部约束决定（页面用 `Expanded` 包）。
  final double? height;

  /// 首尾 padding。与页面 `TvCanvas.pagePad` / `livePad` / `detailPad` 对齐
  /// 由调用方给（本组件不猜页面归属）。纵向时 left/right 是 cross axis
  /// 内边距：给获焦放大/光晕留余量，避免被 viewport 裁掉（RenderViewport
  /// 的裁切在 viewport 边界，padding 区域本身可绘制）。
  final EdgeInsetsGeometry padding;

  /// 每项主轴尺寸（`ListView` 的 `itemExtent`）：横向 = 宽度，纵向 = 高度。
  /// null 时每项自己决定尺寸（如分类胶囊行、直播分组行）。
  final double? itemExtent;

  /// 项间距（`ListView.separated` 的 separatorBuilder 宽/高，按轴取）。
  final double separator;

  /// 行内焦点变化时回调（父级可用于联动 hero / 氛围背景）。
  final ValueChanged<int>? onFocusIndex;

  /// 是否把整行包进 `FocusTraversalGroup`（多行 shelf 建议 true，
  /// 每行一个分组，行内左右移动不会串到相邻行）。
  final bool focusTraversalGroup;

  /// 外部 ScrollController（可选）。
  final ScrollController? controller;

  /// 外部注入的入口焦点节点（shell 的 DOWN 落点，挂在 index 0）。
  /// 与 [memoryFocus] 并存时 memoryFocus 优先（index 0 也归它）。
  final FocusNode? entryFocus;

  /// 滚动轴。默认横向（海报行 / shelf）；纵向用于侧栏（如直播分组栏）。
  /// 垂直模式下 [itemExtent] = 每项高度（`mainAxisExtent`），[height]
  /// 被忽略。
  final Axis scrollDirection;

  /// 受控记忆节点（外部生命周期，本组件不 dispose）：非 null 时挂到
  /// [memoryIndex] 当前值指向的项，取代该项内部创建的节点。页面侧的显式
  /// 投递（如直播页网格最左列 LEFT → 分组栏上次聚焦行）直接 requestFocus
  /// 这个节点即可落在记忆行。索引变化只换挂载项，不主动 requestFocus
  /// （不抢焦）；若变化恰发生在「某行刚获焦、页面同步索引」的时刻，重建
  /// 后会把记忆节点补投回该行（见 [_onMemoryIndexChanged] 的注释），
  /// 行内移动的焦点不中断。
  final FocusNode? memoryFocus;

  /// 与 [memoryFocus] 配套的外部记忆索引。
  final ValueListenable<int>? memoryIndex;

  @override
  State<ShelfRow> createState() => _ShelfRowState();
}

class _ShelfRowState extends State<ShelfRow> {
  /// 行内焦点记忆：最近一次获焦的项。行外→行内时投回这里。
  final ValueNotifier<int> _lastFocused = ValueNotifier<int>(0);

  /// 每项一个焦点节点，交给调用方挂载（`itemBuilder` 的 `node` 形参）。
  /// 懒创建、随项回收时 dispose；外部节点（entryFocus / memoryFocus）
  /// 不入表、不 dispose——它们的生命周期归页面。
  final Map<int, FocusNode> _nodes = <int, FocusNode>{};

  /// 行根焦点：onFocusChange false→true 代表「焦点从行外进入（或换位
  /// 抖回行根）」。
  final FocusNode _rowFocus = FocusNode(debugLabel: 'shelf-row');

  /// 新焦点意图或离开行时使旧滚动完成回调失效，避免过期回调抢焦。
  int _scrollRequest = 0;

  /// 「本次焦点应用内有具体项获焦」的标记（哨兵 onFocusChange 写入，
  /// 微任务末清除——同一次焦点应用内的所有 notify 同步跑完）。行根进入
  /// 恢复据此让位：外部显式投递/换位补投落在具体项上时，新落点就是新
  /// 记忆，恢复不再劫持；只有焦点落到行根、无具体项时才投回记忆项。
  /// 语义固定为「外部投递优先」，不依赖 Flutter 的 notify 顺序。
  int? _itemFocusedThisPass;

  /// 横向行焦点仍在行内时只更新记忆下标，不重建并迁移受控记忆节点；
  /// 离开行后再统一重建，避免左右移动期间 FocusNode reparent 造成停顿。
  bool _memoryIndexNeedsRebuild = false;

  /// 当前实际挂载受控记忆节点的项；行内导航时即使父级重建也保持不动。
  int? _mountedMemoryIndex;

  void _clearItemFocusedThisPass() {
    _itemFocusedThisPass = null;
  }

  @override
  void initState() {
    super.initState();
    _rowFocus.addListener(_onRowFocusChanged);
    _lastFocused.addListener(_onLastFocusedChanged);
    widget.memoryIndex?.addListener(_onMemoryIndexChanged);
    _mountedMemoryIndex = widget.memoryIndex?.value;
  }

  @override
  void didUpdateWidget(covariant ShelfRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // itemCount 变小：裁掉越界节点并 dispose，避免节点泄漏。
    if (oldWidget.itemCount != widget.itemCount) {
      final removed = _nodes.keys
          .where((index) => index >= widget.itemCount)
          .toList(growable: false);
      for (final index in removed) {
        _nodes.remove(index)?.dispose();
      }
      if (_lastFocused.value >= widget.itemCount) {
        _lastFocused.value = widget.itemCount - 1;
      }
    }
    // 受控记忆索引换了 Listenable 源：改挂监听。外部记忆节点本身换了
    // 不用处理——下次 build 自动挂到 memoryIndex 项；旧节点不归我们管。
    if (oldWidget.memoryIndex != widget.memoryIndex) {
      oldWidget.memoryIndex?.removeListener(_onMemoryIndexChanged);
      widget.memoryIndex?.addListener(_onMemoryIndexChanged);
      _mountedMemoryIndex = widget.memoryIndex?.value;
    }
  }

  @override
  void dispose() {
    _rowFocus.removeListener(_onRowFocusChanged);
    _lastFocused.removeListener(_onLastFocusedChanged);
    widget.memoryIndex?.removeListener(_onMemoryIndexChanged);
    for (final node in _nodes.values) {
      node.dispose();
    }
    _nodes.clear();
    _rowFocus.dispose();
    _lastFocused.dispose();
    super.dispose();
  }

  /// 受控记忆索引变化：行内导航期间延后迁移节点，离开行后统一同步。
  void _onMemoryIndexChanged() {
    if (!mounted) return;
    if (widget.scrollDirection == Axis.horizontal && _rowFocus.hasFocus) {
      _memoryIndexNeedsRebuild = true;
      return;
    }
    _mountedMemoryIndex = widget.memoryIndex?.value;
    final memory = widget.memoryFocus;
    final index = widget.memoryIndex?.value ?? -1;
    final reclaim =
        memory != null &&
        index >= 0 &&
        index < widget.itemCount &&
        (_nodes[index]?.hasFocus ?? false);
    setState(() {});
    if (!reclaim) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 等待帧内记忆被外部投递改写（哨兵已记账到别的项）时不劫持焦点。
      if (_lastFocused.value != index) return;
      if (memory.canRequestFocus && !memory.hasFocus) {
        memory.requestFocus();
      }
    });
  }

  /// 项的当前节点：受控记忆节点优先（外部节点不入 `_nodes`），其次内部
  /// 节点（懒创建）。index 0 的入口节点同为外部生命周期，也不入表。
  FocusNode _nodeFor(int index) {
    final memory = widget.memoryFocus;
    if (memory != null && index == (_mountedMemoryIndex ?? 0)) {
      return memory;
    }
    final existing = _nodes[index];
    if (existing != null) return existing;
    // index 0 挂外部入口节点（shell DOWN 落点）；与 memoryFocus 并存时
    // memoryFocus 优先（上面已返回）。
    if (index == 0 && widget.entryFocus != null) {
      return widget.entryFocus!;
    }
    final node = FocusNode(debugLabel: 'shelf-item-$index');
    _nodes[index] = node;
    return node;
  }

  /// 已构建项的当前节点：受控记忆节点优先，其次内部节点表。不懒创建——
  /// 未构建的项没有可获焦节点，交给回退链处理。
  FocusNode? _nodeIfBuilt(int index) {
    if (index < 0 || index >= widget.itemCount) return null;
    final memory = widget.memoryFocus;
    if (memory != null && index == (_mountedMemoryIndex ?? 0)) {
      return memory;
    }
    return _nodes[index];
  }

  void _onLastFocusedChanged() {
    widget.onFocusIndex?.call(_lastFocused.value);
  }

  /// 行根获焦状态变化：false→true 是「焦点从行外进入」。
  ///
  /// 进入若伴随具体项获焦（外部显式投递 / 换位补投，哨兵已把新落点记成
  /// 新记忆）：恢复让位、尊重新落点——「记忆在 2、外部直接投 0」的行为
  /// 是确定的（落 0、记忆变 0，不漂移）。只有焦点落到行根、没有具体项
  /// 获焦时（遍历到边缘的回落、换位抖回）才投回记忆项。
  void _onRowFocusChanged() {
    if (!mounted) return;
    if (!_rowFocus.hasFocus) {
      _scrollRequest++;
      _cancelScroll();
      if (_memoryIndexNeedsRebuild) {
        _memoryIndexNeedsRebuild = false;
        _mountedMemoryIndex = widget.memoryIndex?.value;
        setState(() {});
      }
    }
    if (_rowFocus.hasFocus && _itemFocusedThisPass == null) {
      _restoreLastFocused();
    }
  }

  void _cancelScroll() {
    final controller = widget.controller;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    if (!position.isScrollingNotifier.value) return;
    // 只终止旧动画并保留当前位置；目标定位仍走 AppMotion 的动画/减弱动态分支。
    position.jumpTo(position.pixels);
  }

  void _restoreLastFocused() {
    var index = _lastFocused.value;
    if (index < 0 || index >= widget.itemCount) index = 0;
    final node = _nodeIfBuilt(index);
    if (node != null &&
        node.canRequestFocus &&
        (node.context?.mounted ?? false)) {
      deliverFocusNode(node);
      return;
    }
    // 记忆项已离开懒列表挂载区：先定位并待目标挂载后再投焦。
    _scrollToIndex(index);
  }

  /// 记忆项离开懒列表挂载区时平滑滚回去，目标挂载后再投递焦点。
  void _scrollToIndex(int index) {
    final controller = widget.controller;
    if (controller == null || !controller.hasClients) {
      _focusFallback(index);
      return;
    }
    final extent = widget.itemExtent;
    if (extent == null || extent <= 0) {
      _focusFallback(index);
      return;
    }
    final position = controller.position;
    final padding = widget.padding.resolve(TextDirection.ltr);
    // 主轴起点按轴取：横向 left、纵向 top（滚动内容里第 index 项的起始
    // 偏移 = 首项内边距 + index ×（每项主轴尺寸 + 间距），减回首项内边距
    // 即让该项顶到视口主轴起点）。
    final leading = widget.scrollDirection == Axis.vertical
        ? padding.top
        : padding.left;
    final itemStart = leading + index * (extent + widget.separator);
    final target = (itemStart - leading)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final request = ++_scrollRequest;
    final duration = AppMotion.scrollDuration(context);
    if (duration == Duration.zero) {
      position.jumpTo(target);
      _deliverRestoredFocus(index, request);
    } else {
      unawaited(
        position
            .animateTo(target, duration: duration, curve: AppMotion.scrollCurve)
            .then((_) => _deliverRestoredFocus(index, request)),
      );
    }
  }

  void _deliverRestoredFocus(int index, int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _scrollRequest) return;
      // 等待帧内记忆被外部投递改写（哨兵记账到别的项）或焦点已离开
      // 整行时不劫持焦点——恢复是补投，不是抢占。
      if (_lastFocused.value != index || !_rowFocus.hasFocus) return;
      final node = _nodeIfBuilt(index);
      if (node != null &&
          node.canRequestFocus &&
          (node.context?.mounted ?? false)) {
        deliverFocusNode(node);
      } else {
        _focusFallback(index);
      }
    });
  }

  void _focusFallback(int index) {
    final target = _nodeIfBuilt(index);
    if (target != null &&
        (target.context?.mounted ?? false) &&
        target.canRequestFocus) {
      deliverFocusNode(target);
      return;
    }
    final entry = widget.entryFocus;
    if (entry != null &&
        (entry.context?.mounted ?? false) &&
        entry.canRequestFocus) {
      deliverFocusNode(entry);
      return;
    }
    // 缺少固定 itemExtent/controller 时无法把未挂载目标定位进列表；保留
    // 一个当前已挂载的行内节点，让焦点始终落在可见项而非空行根。
    for (final node in _nodes.values) {
      if ((node.context?.mounted ?? false) && node.canRequestFocus) {
        deliverFocusNode(node);
        return;
      }
    }
  }

  double get _resolvedHeight {
    if (widget.height != null) return widget.height!;
    final skin = TvSkin.of(context);
    // 缺省行高：间距 + 间距 + 最小项高（竖版海报 2:3 下 180 宽 ≈ 270 高，
    // 这里只保证不小于可获焦最小尺寸，具体高由调用方给）。
    return skin.spaceLg + skin.spaceMd + 120;
  }

  Widget _buildItem(BuildContext context, int index) {
    final node = _nodeFor(index);
    // 哨兵 Focus：不持有节点（挂载权归调用方，见类文档），只在项内容
    // （含后代）获焦时记账；skipTraversal 保证它不参与遍历、不抢焦点。
    // 获焦时写记忆 + 标记「本次焦点应用内有具体项获焦」（行根恢复据此
    // 让位，外部投递优先）；焦点离开整行时落到行根，由行根投回记忆项。
    return Focus(
      debugLabel: 'shelf-sentinel-$index',
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) {
          _scrollRequest++;
          _cancelScroll();
          _lastFocused.value = index;
          _itemFocusedThisPass = index;
          scheduleMicrotask(_clearItemFocusedThisPass);
        }
      },
      child: widget.itemBuilder(context, index, node),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.scrollDirection == Axis.vertical;
    // ListView.separated 没有 itemExtent 形参：每项主轴尺寸写死时改用
    // builder + 显式的 SizedBox，项间距继续走 separator。
    Widget row = ListView.separated(
      controller: widget.controller,
      scrollDirection: widget.scrollDirection,
      physics: const ClampingScrollPhysics(),
      scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      padding: widget.padding,
      itemCount: widget.itemCount,
      separatorBuilder: (_, _) => vertical
          ? SizedBox(height: widget.separator)
          : SizedBox(width: widget.separator),
      itemBuilder: (context, index) => SizedBox(
        // 横向锁宽、纵向锁高；extent 为空时两个方向都放行（每项自决）。
        width: vertical ? null : widget.itemExtent,
        height: vertical ? widget.itemExtent : null,
        child: _buildItem(context, index),
      ),
    );
    // 行根 Focus 包在 ListView 外层：行获焦 = 焦点从行外进入。
    Widget result = Focus(
      focusNode: _rowFocus,
      skipTraversal: true,
      child: row,
    );
    if (widget.focusTraversalGroup) {
      result = FocusTraversalGroup(child: result);
    }
    // 横向模式保持原行为：SizedBox(height:) 包住 ListView（viewport 裁切
    // 与改前一致）。垂直模式高度由外部约束决定（页面用 Expanded 包），
    // 不再包 SizedBox(height:)。
    if (vertical) return result;
    return SizedBox(height: _resolvedHeight, child: result);
  }
}
