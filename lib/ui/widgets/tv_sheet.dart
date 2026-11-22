import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../theme/ui.dart';
import 'common.dart';

/// Shows a focus-managed side panel, the TV counterpart of a bottom sheet.
///
/// tvOS has no pull-up drawer: overlays enter from the side, take focus while
/// open, and hand focus back to the element that opened them on dismiss
/// (FOCUS-03/06/07). Back always closes the panel.
Future<T?> showTvSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
  double width = 560,
  bool autofocusClose = true,
}) async {
  final previous = FocusManager.instance.primaryFocus;
  final reduced = AppMotion.reduced(context);
  // 这里的 context 在 MaterialApp 之内，Theme 一定有；用 of 以便断言生效。
  final skin = TvSkin.of(context);
  final duration = reduced ? Duration.zero : skin.motionPanel;
  final result = await Navigator.of(context, rootNavigator: true).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: false,
      // 复用皮肤控制层的黑系遮罩色，保持底层内容压暗。
      barrierColor: skin.controlScrim.colors.first.withValues(alpha: 0.6),
      transitionDuration: duration,
      reverseTransitionDuration: reduced ? Duration.zero : skin.motionPanel,
      pageBuilder: (context, animation, secondaryAnimation) {
        return _TvSheetPanel(
          title: title,
          subtitle: subtitle,
          width: width,
          autofocusClose: autofocusClose,
          child: Builder(builder: builder),
        );
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    ),
  );
  // FOCUS-07: focus returns to the trigger instead of the page root.
  if (previous != null &&
      previous.context != null &&
      previous.canRequestFocus) {
    previous.requestFocus();
  }
  return result;
}

class _TvSheetPanel extends StatefulWidget {
  const _TvSheetPanel({
    required this.title,
    required this.subtitle,
    required this.width,
    required this.autofocusClose,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final double width;
  final bool autofocusClose;
  final Widget child;

  @override
  State<_TvSheetPanel> createState() => _TvSheetPanelState();
}

class _TvSheetPanelState extends State<_TvSheetPanel> {
  /// 浮层独立焦点域（spec §2：覆盖层总在独立 FocusScope 里）。
  /// 壳层/页面层把焦点交出来时，域边界让几何遍历不会穿回背后的页面。
  final FocusScopeNode _scopeNode = FocusScopeNode(debugLabel: 'tv-sheet');

  /// 关闭按钮的稳定节点：默认焦点落点 + 兜底投备用。
  final FocusNode _closeFocus = FocusNode(debugLabel: 'tv-sheet-close');

  @override
  void initState() {
    super.initState();
    // 焦点陷阱兜底（spec §3 死键判据 / §4-5）：autofocusClose=false 且
    // 内容也没有 autofocus 项时，浮层打开后无人获焦——方向键会落到背后
    // 的页面上（「消费了但焦点在层外」）。帧末检查浮层域内是否有焦点；
    // 没有则给关闭按钮登记 autofocus。
    //
    // 必须走 [FocusScopeNode.autofocus]（进入框架的 pending 队列）而不是
    // 直接 `requestFocus`：直接请求会立刻把关闭按钮设成域内 focusedChild，
    // 内容自带 autofocus 的项还没轮到自己的 microtask 就会被判「域内已有
    // 焦点」而丢弃（autofocusClose=false + 内容 autofocus 的场景退行）。
    // 进队列后按登记顺序消费：先登记者（内容项，挂载早于本帧末回调）
    // 先获焦，关闭按钮的登记自然失效，两全。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final active = FocusManager.instance.primaryFocus;
      final inside = active != null && active.ancestors.contains(_scopeNode);
      if (!inside) _scopeNode.autofocus(_closeFocus);
    });
  }

  @override
  void dispose() {
    _scopeNode.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return FocusScope(
      node: _scopeNode,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              width: widget.width,
              height: double.infinity,
              decoration: BoxDecoration(
                // 侧栏是浮在内容之上的控件层：恒深色底 + 钉死白字（§8.3）。
                // 不再按 `skin.id == netflix` 分支——若让底色跟皮肤，smartisan
                // 的亮底会撞上白字、深底会撞上深字，二者不可兼得；统一取
                // 「深底 + 白字」保证三套皮肤都可读（AGENTS.md §8.4 收敛该例外）。
                color: const Color(0xF70C0E15),
                border: Border(
                  left: BorderSide(
                    color: skin.surfaceSkin.panelBorder,
                    width: skin.surfaceSkin.panelBorderWidth == 0
                        ? 0.8
                        : skin.surfaceSkin.panelBorderWidth,
                  ),
                ),
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(skin.radiusLg + 4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 40,
                    offset: const Offset(-16, 0),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      skin.spaceXl - 4,
                      skin.spaceLg,
                      skin.spaceLg - 4,
                      skin.spaceMd,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 标题/副标题钉死浅色（§8.3 深底 + 白字），
                              // 不读 skin.textPrimary：smartisan 亮色皮肤的深字
                              // 压深底对比度仅 ≈1.5:1，10 英尺外不可读。
                              Text(
                                widget.title,
                                style: text.section.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                              if (widget.subtitle != null) ...[
                                SizedBox(height: skin.spaceXs),
                                Text(
                                  widget.subtitle!,
                                  style: text.label.copyWith(
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        SizedBox(width: skin.spaceSm + 2),
                        TvFocusable(
                          radius: skin.radiusPill,
                          semanticLabel: '关闭',
                          focusNode: _closeFocus,
                          // 默认关闭按钮优先；内容需要认领初始焦点时，调用方
                          // 必须传 autofocusClose=false，不能依赖挂载顺序抢焦。
                          autofocus: widget.autofocusClose,
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: skin.surfaceSubtle,
                              shape: BoxShape.circle,
                              border: Border.all(color: skin.border),
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, thickness: 0.8, color: skin.borderSoft),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 网盘共用的定高懒加载目录：UP/DOWN 显式按下标投递，首项 UP 交给
// 浮层关闭按钮；左右没有相邻列，留在本列；BACK 仍由路由关闭整层。
// 初始下标由调用方按目录保存，返回父目录或播放器后恢复原项。
class TvSheetList extends StatefulWidget {
  const TvSheetList({
    super.key,
    required this.labels,
    required this.onSelected,
    this.initialIndex = 0,
  });

  final List<String> labels;
  final ValueChanged<int> onSelected;
  final int initialIndex;

  @override
  State<TvSheetList> createState() => _TvSheetListState();
}

class _TvSheetListState extends State<TvSheetList> {
  static const _extent = 60.0;
  final _nodes = <int, FocusNode>{};
  int _focusRequest = 0;
  int? _requestedIndex;
  FocusScopeNode? _routeFocusScope;
  late final int _initial = widget.labels.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, widget.labels.length - 1);
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _initial * _extent,
  );

  FocusNode _node(int index) => _nodes.putIfAbsent(index, () => FocusNode());

  bool _isListFocus(FocusNode? active) =>
      active != null &&
      (identical(active, _routeFocusScope) ||
          _nodes.values.any((node) => identical(node, active)) ||
          active.context?.findAncestorStateOfType<_TvSheetListState>() == this);

  void _cancelScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.isScrollingNotifier.value) return;
    // 只终止旧动画并保留当前位置；目标定位仍走 AppMotion 的动画/减弱动态分支。
    position.jumpTo(position.pixels);
  }

  void _focus(int index) {
    if (index < 0 || index >= widget.labels.length) return;
    final request = ++_focusRequest;
    _requestedIndex = index;
    _cancelScroll();
    final node = _node(index);
    if (node.context != null) {
      _requestFocus(node, index, request);
      return;
    }
    if (!_scroll.hasClients) return;

    // 目标超出 ListView 的缓存挂载区时，先保留当前可见焦点，平滑滚动到
    // 目标附近；动画完成且焦点仍在目录内后再投递，防止未挂载节点的延迟
    // requestFocus 在用户离开目录后反过来抢焦。
    final position = _scroll.position;
    final target = (index * _extent)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final duration = AppMotion.scrollDuration(context);
    if (duration == Duration.zero) {
      position.jumpTo(target);
      _deliverPendingFocus(index, request);
    } else {
      unawaited(
        position
            .animateTo(target, duration: duration, curve: AppMotion.scrollCurve)
            .then((_) => _deliverPendingFocus(index, request)),
      );
    }
  }

  void _deliverPendingFocus(int index, int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _focusRequest || _requestedIndex != index) {
        return;
      }
      final active = FocusManager.instance.primaryFocus;
      if (active != null && !_isListFocus(active)) {
        _focusRequest++;
        _requestedIndex = null;
        return;
      }
      final node = _node(index);
      if (node.context != null && node.canRequestFocus) {
        _requestFocus(node, index, request);
      }
    });
  }

  void _requestFocus(FocusNode node, int index, int request) {
    node.requestFocus();
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _focusRequest ||
          _requestedIndex != index ||
          !node.hasFocus) {
        return;
      }
      final target = node.context;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: AppMotion.scrollDuration(context),
        curve: AppMotion.scrollCurve,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.labels.isNotEmpty) _focus(_initial);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeFocusScope = FocusScope.of(context);
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return ListView.builder(
      controller: _scroll,
      itemExtent: _extent,
      scrollCacheExtent: const ScrollCacheExtent.pixels(_extent * 2),
      addAutomaticKeepAlives: false,
      padding: EdgeInsets.all(skin.spaceLg),
      itemCount: widget.labels.length,
      itemBuilder: (context, index) => TvFocusable(
        focusNode: _node(index),
        semanticLabel: widget.labels[index],
        onFocusChange: (focused) {
          if (focused) {
            // 较早排队的节点挂载获焦时不能覆盖更新后的目标下标。
            if (_requestedIndex != null && _requestedIndex != index) return;
            if (_requestedIndex != index) {
              _focusRequest++;
              _cancelScroll();
            }
            _requestedIndex = index;
            return;
          }
          final active = FocusManager.instance.primaryFocus;
          if (active == null || !_isListFocus(active)) {
            // 目录关闭按钮等区块接管焦点后，不允许旧滚动完成回调再投焦。
            _focusRequest++;
            _requestedIndex = null;
            _cancelScroll();
          }
        },
        onKeyEvent: (event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          final current = _requestedIndex ?? index;
          if (key == LogicalKeyboardKey.arrowUp && current > 0) {
            _focus(current - 1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowDown) {
            if (current + 1 < widget.labels.length) _focus(current + 1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        onTap: () => widget.onSelected(index),
        child: Padding(
          padding: EdgeInsets.all(skin.spaceMd),
          // 公共侧栏内容区恒为深色，前景固定白色。
          child: Text(
            widget.labels[index],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.of(context).body.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
