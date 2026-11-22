import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../theme/ui.dart';
import 'common.dart';

class EpisodeRange {
  const EpisodeRange(this.start, this.end);

  final int start;
  final int end;
  String get label => '${start + 1}–$end';
}

List<EpisodeRange> episodeRanges(int count) => [
  for (var start = 0; start < count; start += 30)
    EpisodeRange(start, (start + 30).clamp(0, count)),
];

class EpisodeSelector extends StatefulWidget {
  const EpisodeSelector({
    super.key,
    required this.episodes,
    required this.selectedIndex,
    required this.onSelected,
    this.dataKey,
    this.onVideo = false,
    this.autofocus = false,
    this.columns = 7,
    this.rowHeight = 34,
    this.resumeIndex,
    this.onExitUp,
    this.onExitDown,
  });

  final List<Episode> episodes;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Object? dataKey;
  final bool onVideo;
  final bool autofocus;
  final int columns;
  final double rowHeight;
  final int? resumeIndex;

  /// 网格首行 UP 的出口（详情页回触发按钮 / 播放器面板回工具行）。
  /// null 时 UP 在首行被显式吞掉（防止框架几何遍历把焦点甩出组件）。
  final VoidCallback? onExitUp;

  /// 网格末行 DOWN 的出口（详情页 → 相关推荐行）。null 时末行 DOWN
  /// 显式吞掉——播放器面板下方没有区块，放行几何遍历只会让焦点在面板
  /// 作用域边缘空转（focus-system-spec §5：每个格子要么显式投递、要么
  /// 明确吞掉，不许落到没测过的几何兜底）。
  final VoidCallback? onExitDown;

  @override
  State<EpisodeSelector> createState() => EpisodeSelectorState();
}

class EpisodeSelectorState extends State<EpisodeSelector> {
  final _gridScroll = ScrollController();
  final _groupScroll = ScrollController();
  final Map<int, FocusNode> _episodes = {};
  final Map<int, FocusNode> _groups = {};
  final Map<int, int> _memory = {};
  int _revealRequest = 0;
  late int _group = _validIndex(widget.selectedIndex) ~/ 30;

  int _validIndex(int index) =>
      index.clamp(0, (widget.episodes.length - 1).clamp(0, 1 << 30));

  FocusNode _episodeNode(int index) => _episodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'episode-$index'),
  );
  FocusNode _groupNode(int index) => _groups.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'episode-range-$index'),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reveal(widget.selectedIndex, focus: widget.autofocus);
    });
  }

  @override
  void didUpdateWidget(covariant EpisodeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataKey != widget.dataKey ||
        oldWidget.episodes != widget.episodes ||
        oldWidget.selectedIndex != widget.selectedIndex) {
      _memory.clear();
      final hadEpisodeFocus = _episodes.values.any((node) => node.hasFocus);
      if (widget.episodes.isEmpty) {
        _group = 0;
      } else {
        reveal(widget.selectedIndex, focus: hadEpisodeFocus);
      }
    }
  }

  void _focus(FocusNode node) {
    final request = ++_revealRequest;
    // 按键当下确定目标；新分组尚未挂载时由 reparent 完成挂起请求。
    // 帧末只负责揭示，不能再次投焦覆盖下一次方向键的新目标。
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _revealRequest ||
          !node.hasFocus ||
          node.context == null) {
        return;
      }
      // 只滚动本组件内部，不把详情页主滚动一并拉走。
      Scrollable.of(node.context!).position.ensureVisible(
        node.context!.findRenderObject()!,
        alignment: 0.5,
        duration: AppMotion.scrollDuration(context),
        curve: AppMotion.scrollCurve,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void reveal(int index, {bool focus = false}) {
    if (widget.episodes.isEmpty) return;
    final request = ++_revealRequest;
    final valid = _validIndex(index);
    final group = valid ~/ 30;
    if (_group != group) setState(() => _group = group);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _revealRequest) return;
      if (_gridScroll.hasClients) {
        final target = ((valid % 30 ~/ widget.columns) * (widget.rowHeight + 8))
            .clamp(0, _gridScroll.position.maxScrollExtent)
            .toDouble();
        final duration = AppMotion.scrollDuration(context);
        if (focus && duration > Duration.zero) {
          _gridScroll.animateTo(
            target,
            duration: duration,
            curve: AppMotion.scrollCurve,
          );
        } else {
          _gridScroll.jumpTo(target);
        }
      }
      if (_groupScroll.hasClients) {
        final target = (group * 42.0)
            .clamp(0, _groupScroll.position.maxScrollExtent)
            .toDouble();
        final duration = AppMotion.scrollDuration(context);
        if (focus && duration > Duration.zero) {
          _groupScroll.animateTo(
            target,
            duration: duration,
            curve: AppMotion.scrollCurve,
          );
        } else {
          _groupScroll.jumpTo(target);
        }
      }
      if (focus) _focus(_episodeNode(valid));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _selectGroup(int group) {
    setState(() => _group = group);
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
  }

  void _enterGroup() => _focus(_episodeNode(_memory[_group] ?? _group * 30));

  KeyEventResult _episodeKey(int index, KeyEvent event) {
    final key = event.logicalKey;
    final start = _group * 30;
    final end = (start + 30).clamp(0, widget.episodes.length);
    final local = index - start;
    // 首行 UP：出口一（调用方决定回哪；null 时显式吞，防几何兜底）。
    if (key == LogicalKeyboardKey.arrowUp && local < widget.columns) {
      widget.onExitUp?.call();
      return KeyEventResult.handled;
    }
    // 末行 DOWN：出口二（详情页 → 推荐行；播放器面板吞掉）。
    if (key == LogicalKeyboardKey.arrowDown &&
        local ~/ widget.columns >= (end - start - 1) ~/ widget.columns) {
      widget.onExitDown?.call();
      return KeyEventResult.handled;
    }
    int? target;
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (local % widget.columns == 0) {
        if (widget.episodes.length <= 30) {
          // 单区间没有左栏可去：显式吞掉（详情页全屏路由 LEFT 无处可去，
          // 放行几何会把焦点甩到左上角返回浮钮——跳丢）。
          return KeyEventResult.handled;
        }
        _focus(_groupNode(_group));
        return KeyEventResult.handled;
      }
      target = index - 1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (local % widget.columns == widget.columns - 1 || index == end - 1) {
        // 行尾/末格 RIGHT：显式吞，防几何遍历甩出网格。
        return KeyEventResult.handled;
      }
      target = index + 1;
    } else if (key == LogicalKeyboardKey.arrowUp && local >= widget.columns) {
      target = index - widget.columns;
    } else if (key == LogicalKeyboardKey.arrowDown &&
        local ~/ widget.columns < (end - start - 1) ~/ widget.columns) {
      target = (index + widget.columns).clamp(start, end - 1);
    }
    if (target == null) return KeyEventResult.ignored;
    _focus(_episodeNode(target));
    return KeyEventResult.handled;
  }

  Widget _button({
    required String label,
    required FocusNode node,
    required bool selected,
    required VoidCallback onTap,
    required KeyEventResult Function(KeyEvent) onKey,
    ValueChanged<bool>? onFocus,
    bool resume = false,
  }) {
    final skin = TvSkin.of(context);
    // 视频上的前景保持黑白，普通详情区使用皮肤前景。
    final foreground = widget.onVideo ? Colors.white : skin.textPrimary;
    return TvFocusable(
      focusNode: node,
      radius: skin.radiusSm,
      semanticLabel: resume ? '$label，上次看到这里' : label,
      onTap: onTap,
      onKeyEvent: onKey,
      onFocusChange: onFocus,
      child: Builder(
        builder: (context) {
          final tinted = TvFocusTint.of(context);
          return SkinSurface(
            enableBlur: false,
            radius: skin.radiusSm,
            tint: tinted
                ? Colors.transparent
                : widget.onVideo
                ? Colors.white.withValues(alpha: selected ? 0.22 : 0.06)
                : selected
                ? skin.surface
                : skin.surfaceSubtle,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Center(
              child: Text(
                resume ? '• $label' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.of(context).body.copyWith(
                  color: tinted ? skin.textOnAccent : foreground,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ranges = episodeRanges(widget.episodes.length);
    if (ranges.isEmpty) {
      return Center(child: Text('暂无可选集数', style: AppText.of(context).body));
    }
    final range = ranges[_group.clamp(0, ranges.length - 1)];
    return FocusTraversalGroup(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ranges.length > 1) ...[
            SizedBox(
              width: 100,
              child: SingleChildScrollView(
                controller: _groupScroll,
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  children: [
                    for (var group = 0; group < ranges.length; group++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: SizedBox(
                          height: 36,
                          child: _button(
                            label: ranges[group].label,
                            node: _groupNode(group),
                            selected: group == _group,
                            onTap: () => _selectGroup(group),
                            onFocus: (focused) {
                              if (focused && _group != group) {
                                _selectGroup(group);
                              }
                            },
                            onKey: (event) {
                              final key = event.logicalKey;
                              if (key == LogicalKeyboardKey.arrowRight) {
                                // 区间栏 RIGHT → 进网格（记忆项）。
                                _enterGroup();
                                return KeyEventResult.handled;
                              }
                              if (key == LogicalKeyboardKey.arrowUp &&
                                  group == 0) {
                                // 首组 UP：出口（详情页回触发按钮 / 播放器
                                // 面板回工具行）；null 时显式吞。
                                widget.onExitUp?.call();
                                return KeyEventResult.handled;
                              }
                              if (key == LogicalKeyboardKey.arrowDown) {
                                final next = group + 1;
                                if (next >= ranges.length) {
                                  // 末组 DOWN：区间栏下方无区块，显式吞。
                                  return KeyEventResult.handled;
                                }
                                _focus(_groupNode(next));
                                return KeyEventResult.handled;
                              }
                              if (key == LogicalKeyboardKey.arrowUp) {
                                _focus(_groupNode(group - 1));
                                return KeyEventResult.handled;
                              }
                              // LEFT 与其他键放行：LEFT 在区间栏是边界键，
                              // 由页面层统一吞（详情页）或面板作用域收敛
                              // （播放器面板，方向遍历无候选即停）。
                              return KeyEventResult.ignored;
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: SingleChildScrollView(
              controller: _gridScroll,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width =
                      (constraints.maxWidth - (widget.columns - 1) * 8) /
                      widget.columns;
                  // 每组最多 30 格，全部挂载以保证跨屏方向键能确定性命中节点。
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var index = range.start; index < range.end; index++)
                        SizedBox(
                          key: ValueKey('episode-cell-$index'),
                          width: width,
                          height: widget.rowHeight,
                          child: _button(
                            label: widget.episodes[index].name,
                            node: _episodeNode(index),
                            selected:
                                index == _validIndex(widget.selectedIndex),
                            resume: index == widget.resumeIndex,
                            onTap: () => widget.onSelected(index),
                            onFocus: (focused) {
                              if (focused) {
                                _memory[_group] = index;
                                // 详情页还有外层纵向滚动，获焦时需同时露出集数区域。
                                if (!widget.onVideo &&
                                    _episodeNode(index).context != null) {
                                  Scrollable.ensureVisible(
                                    _episodeNode(index).context!,
                                    duration: AppMotion.scrollDuration(context),
                                    curve: AppMotion.scrollCurve,
                                  );
                                }
                              }
                            },
                            onKey: (event) => _episodeKey(index, event),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    for (final node in [..._episodes.values, ..._groups.values]) {
      node.dispose();
    }
    _gridScroll.dispose();
    _groupScroll.dispose();
    super.dispose();
  }
}
