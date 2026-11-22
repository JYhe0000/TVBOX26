import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/ui.dart';
import 'common.dart';

/// 可展开左侧导航栏（izuko TvNavigationSideRail 布局模式）。
///
/// 收起态是一列窄图标（[railCollapsedWidth] 40dp 宽，贴屏幕左缘与
/// 顶部排列——izuko 同款，内容页按 [TvCanvas.pagePad] 自然让开）；
/// 焦点进入侧栏后展开——图标右侧浮出文字标签并压一层左缘渐变遮罩
/// （[railScrimWidth] 宽的页面底色渐变、右缘多色标羽化），焦点离开自动
/// 收起。展开时内容**不重排**：侧栏始终盖在内容区之上，这是与 izuko
/// 一致的「悬浮浮层」语义（展开面板压住内容左缘的让位问题见
/// `docs/izuko-layout-spec.md` O-1）。
///
/// 视觉规则（2026-11-19 用户反馈「太突兀」修正）：贴边 + 贴顶 + 选中
/// 指示条三件套——旧版 leftInset=20 垂直居中的悬浮图标列无容器感，
/// 已全部收掉；图标块无底色是 izuko 收起态同款（浮在页面底色上），
/// 容器感靠「贴边对齐 + 选中条 + 展开遮罩」表达，不加栏底。
///
/// 焦点门控（AGENTS.md §3 焦点即设计）：
/// - 进页默认焦点落内容区（由壳层投递），侧栏**只能从内容区按左键进入**
///   （壳层根 Focus 拦截 LEFT）；栏内 UP/DOWN 的空间遍历一律吞掉，
///   不接「误入」（内容页头部元素按上/右不会掉进侧栏）。
/// - 栏内 UP/DOWN 在条目间确定性移动（按 index 投递，不依赖几何遍历）；
///   到顶/到底停住吞键。
/// - 退出通道（O-1 收口 b，spec §3）：LEFT / RIGHT / BACK / ESC 一律
///   回内容区——展开面板压住内容左缘期间，LEFT 是符合空间直觉的退出键；
///   组件内直接消费（izuko railExitKeys 同款），壳层 PopScope 兜底触屏/
///   其他路径的 BACK。
/// - OK 切页后焦点交还内容区（壳层的 onSelected 回调负责投递）。
///
/// 焦点视觉统一走 [TvFocusable]（读 `TvSkin.focus` 的 token），这里只加
/// 一层「选中」的语义表达：未获焦的选中项图标与文字取 `skin.accent`、
/// 字重 w700；获焦时整块焦点填充 + 内容反白由 `TvFocusable` 承担。
class TvSideRail extends StatefulWidget {
  const TvSideRail({
    super.key,
    required this.index,
    required this.destinations,
    required this.itemNodes,
    required this.onSelected,
    required this.onFocusExit,
    this.leftInset = 0,
  });

  /// 当前选中页索引（选中语义，与焦点分离）。
  final int index;

  /// 导航条目（Tab 集合）。顺序即栏内自上而下的顺序。
  final List<TvRailDestination> destinations;

  /// 每个条目注入给 [TvFocusable] 的外部焦点节点（壳层持有，debugLabel
  /// `rail-$i`，测试与页面侧投递焦点用）。长度与 [destinations] 一致。
  final List<FocusNode> itemNodes;

  /// OK / 触屏点按选中某页。壳层切页后负责把焦点交还内容区。
  final ValueChanged<int> onSelected;

  /// BACK / ESC / 焦点被请求离开侧栏（壳层决定回内容区的落点）。
  final VoidCallback onFocusExit;

  /// 距屏幕左缘的内缩（与内容页的 [TvCanvas.pagePad] 呼应，悬浮层不贴边）。
  final double leftInset;

  /// 收起态占位宽度（内容页按这个宽度让开侧栏）。
  static double get railCollapsedWidth => _railItemSize;

  /// 展开面板（渐变遮罩）宽度：收起图标列 + 文字标签区。
  static double get railScrimWidth => 220;

  static const double _railItemSize = 40;
  static const double _railGlyphSize = 22;
  static const _railItemGap = 12.0;

  @override
  State<TvSideRail> createState() => _TvSideRailState();
}

class _TvSideRailState extends State<TvSideRail> {
  /// 栏内是否持有焦点（含子节点）：驱动展开/收起。全部条目节点都挂
  /// 监听——栏内上下移动后进出栏的节点会变，只挂第一个会漏判。
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _attachNodeListeners();
  }

  @override
  void didUpdateWidget(covariant TvSideRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.itemNodes, widget.itemNodes)) {
      _detachNodeListeners();
      _attachNodeListeners();
    }
  }

  @override
  void dispose() {
    _detachNodeListeners();
    super.dispose();
  }

  void _attachNodeListeners() {
    for (final node in widget.itemNodes) {
      node.addListener(_syncExpanded);
    }
  }

  void _detachNodeListeners() {
    for (final node in widget.itemNodes) {
      node.removeListener(_syncExpanded);
    }
  }

  void _syncExpanded() {
    final expanded = widget.itemNodes.any((node) => node.hasFocus);
    if (expanded == _expanded) return;
    setState(() => _expanded = expanded);
  }

  /// 展开/收起的整体时长与曲线取皮肤 [TvSkin.motionPanel]（两套皮肤
  /// ≈200ms），减弱动态时归零（AppMotion.duration）。
  Duration get _revealDuration => AppMotion.duration(
    context,
    TvSkin.maybeOf(context)?.motionPanel ?? AppMotion.panel,
  );

  /// 栏内 UP/DOWN 确定性投递：按 index 走，到顶/到底停住吞键。
  /// RIGHT / BACK / ESC 回内容区；LEFT 已到栏外沿，停住吞键。
  ///
  /// 焦点体系重建（spec §3 O-1 收口 b 方案）：LEFT 从「吞键」改为
  /// 「回内容区」——侧栏展开面板（[TvSideRail.railScrimWidth] 220dp）压住
  /// 内容左缘期间，LEFT 是符合空间直觉的退出键（栏已在最左，再往左
  /// =回内容，izuko「内容区最左列 LEFT → 进侧栏」的反向通道）；RIGHT /
  /// OK / BACK / ESC 的退出语义不变。退出通道收敛为
  /// 「LEFT = RIGHT = BACK = ESC → 回内容区」。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final current = widget.itemNodes.indexWhere((n) => n == node);
    if (current < 0) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        if (current < widget.itemNodes.length - 1) {
          widget.itemNodes[current + 1].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (current > 0) {
          widget.itemNodes[current - 1].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      // BACK / ESC：izuko railExitKeys 同款——组件内消费回内容区，
      // 不交给 PopScope（壳层 PopScope 仍兜底触屏/其他路径的 BACK）。
      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
      // LEFT（O-1 收口 b）：栏外沿再往左 = 回内容区（见方法头注）。
      case LogicalKeyboardKey.arrowLeft:
        widget.onFocusExit();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    // 遮罩面板底：展开时压在内容上的一层页面底色渐变（右缘羽化透明，
    // 与 izuko 的 tvRailScrimFeather 同款：前段纯色、末段淡出）。
    final scrimColor = skin.bg;
    final scrim = IgnorePointer(
      child: AnimatedOpacity(
        opacity: _expanded ? 1 : 0,
        duration: _revealDuration,
        curve: Curves.easeOutCubic,
        child: Container(
          width: TvSideRail.railScrimWidth,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: const [0, 0.82, 0.9, 0.96, 1],
              colors: [
                scrimColor,
                scrimColor,
                scrimColor.withValues(alpha: 0.82),
                scrimColor.withValues(alpha: 0.38),
                scrimColor.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );

    Widget railItem(int i) {
      final destination = widget.destinations[i];
      final selected = i == widget.index;
      // 选中语义：图标与文字取强调色；获焦反白态由 TvFocusable 的
      // _FocusTint 提供（IconTheme/DefaultTextStyle 翻成 textOnAccent，
      // 显式色的文字要自己读 TvFocusTint 让位——与玻璃胶囊同一约定）。
      //
      // 宽度语义：收起态只有图标块（40 宽）；展开态行整体变宽（图标 +
      // 文字），焦点框随之变宽——izuko 同款（ expanded 时条目是
      // 图标 + 文字的一整行）。所以 TvFocusable 不设 padding、不套固定
      // 宽 SizedBox，内边距全在 Row 自身的 Padding 里。
      return TvFocusable(
        radius: skin.radiusSm,
        scale: 1.04,
        focusNode: widget.itemNodes[i],
        semanticLabel: destination.label,
        onTap: () => widget.onSelected(i),
        onKeyEvent: (event) => _handleKeyEvent(widget.itemNodes[i], event),
        child: Builder(
          builder: (context) {
            final tinted = TvFocusTint.of(context);
            final contentColor = tinted
                ? skin.textOnAccent
                : selected
                ? skin.accent
                : skin.textSecondary;
            return Padding(
              // 收起态贴左缘（leftInset=0）：移除横向内缩，让 40dp 图标块
              // 从画布边缘起排，图标向左收 2dp。旧版 leftInset=20
              // + horizontal 8 = 68dp 的悬浮列无容器感、悬空突兀（用户
              // 反馈「太突兀」，2026-11-19 修正）。
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: TvSideRail._railItemSize,
                    height: TvSideRail._railItemSize,
                    // 选中指示条：叠在图标块左缘的 3dp 竖条（smartisan
                    // 列表行选中语言的电视化借用）。叠放不占额外宽度，
                    // 不会把收起列撑过内容页 pagePad(40) 的左缘。获焦
                    // 时整块换蓝，条与焦点块同色融为一体，无冲突。
                    child: Stack(
                      children: [
                        if (selected)
                          PositionedDirectional(
                            start: 0,
                            top: 12,
                            bottom: 12,
                            width: 3,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: contentColor,
                                borderRadius: BorderRadius.circular(
                                  TvSideRail._railItemSize,
                                ),
                              ),
                            ),
                          ),
                        Center(
                          child: Icon(
                            selected
                                ? destination.activeIcon
                                : destination.icon,
                            size: TvSideRail._railGlyphSize,
                            color: contentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 文字标签：展开时淡入浮出（izuko 同款 if (expanded)
                  // 条件挂载 + AnimatedSwitcher 淡入，不用 AnimatedSize——
                  // 后者会在布局期间重启动画，触发「mutated in its own
                  // performLayout」框架断言）。
                  AnimatedSwitcher(
                    duration: _revealDuration,
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: _expanded
                        ? Padding(
                            key: const ValueKey(true),
                            padding: EdgeInsets.only(
                              left: skin.spaceSm,
                              right: skin.spaceMd,
                            ),
                            child: Text(
                              destination.label,
                              softWrap: false,
                              style: text.bodyLarge.copyWith(
                                color: contentColor,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          )
                        : const SizedBox(
                            key: ValueKey(false),
                            width: 0,
                            height: 0,
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: widget.leftInset.toDouble()),
      child: Stack(
        children: [
          scrim,
          // 图标列：贴左上排列（izuko 收起态同款——贴顶而非垂直居中；
          // 垂直居中会让四个图标孤悬在屏幕中部，与页头/hero 的版式
          // 基线完全脱节，是「突兀」的另一半原因）。顶部 24 与首页
          // 页头行的内边距基线对齐。动画（展开/收起）期间仍能接收
          // 按键，焦点不丢。
          Align(
            alignment: Alignment(-1, -1),
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.destinations.length; i++) ...[
                    if (i > 0) const SizedBox(height: TvSideRail._railItemGap),
                    railItem(i),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 侧栏条目：[label] 文字（展开时可见）、[icon]/[activeIcon] 未选中/选中图标。
class TvRailDestination {
  const TvRailDestination(this.label, this.activeIcon, this.icon);

  final String label;
  final IconData activeIcon;
  final IconData icon;
}
