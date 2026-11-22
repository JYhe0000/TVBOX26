import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/library_store.dart';
import '../../core/utils.dart';
import '../../data/models.dart';
import '../../theme/ui.dart';
import '../../ui/tv_canvas.dart';
import '../widgets/common.dart';
import '../widgets/tv_sheet.dart';
import 'detail_page.dart';

/// 历史页焦点投递表（docs/focus-system-spec.md §4/§5；行 = 当前焦点
/// 所在区块，列 = 方向）：
///
/// | 区块＼方向 | UP | DOWN | LEFT | RIGHT |
/// | --- | --- | --- | --- | --- |
/// | 页头（返回/清空） | 吞键（顶缘） | 记忆行（空态放行→空态按钮） | 清空→返回；返回吞键（页面左缘） | 返回→清空；清空吞键（行尾） |
/// | 行卡 i | i−1；首行→返回键 | i+1；末行以下吞键（页面底） | 吞键（页面左缘，单列行卡） | 本行删除钮 |
/// | 删除钮 i | 行卡 i−1（首行→返回键） | 行卡 i+1（末行以下吞键） | 行卡 i | 吞键（行尾） |
///
/// 「吞键」格子的说明：本页是从「我的」push 出来的**推入式路由**，壳层
/// （含侧栏 LEFT 通道）不在本页的按键链上——页面左缘的 LEFT 没有可去处，
/// 按 spec §4.4 的边界吞键处理（焦点原地不动）；若后续要把「LEFT 回壳层
/// 侧栏」接上，需要壳层/导航侧加通道（见交付报告的待协调项）。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.entryFocus});

  /// 入口焦点（壳层注入；当前无调用方传——mine_page 冻结期内保留参数
  /// 位，spec §4.1 契约）。缺省时首行靠 autofocus 落焦点。
  final FocusNode? entryFocus;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  /// 行卡的 [FocusNode] 按影片 key 登记（下标会在删除后整体前移，
  /// 用 key 才能在列表重建后找回同一行）。删除后焦点落到
  /// `min(_lastIndex, length - 1)` 那一行，空了退回返回键（AGENTS.md §3
  /// 硬性规则 3）。
  final Map<String, FocusNode> _rowFocus = {};
  final FocusNode _backFocus = FocusNode(debugLabel: 'history-back');

  /// 页头「清空」钮的焦点节点（页头行显式左右投递要按下标找邻居）。
  final FocusNode _clearFocus = FocusNode(debugLabel: 'history-clear');

  /// 行内删除钮的焦点节点（按影片 key 登记，与行卡同键）。
  final Map<String, FocusNode> _deleteFocus = {};

  /// 首行的兜底入口节点（未注入 entryFocus 时用）。
  final FocusNode _rowEntryFocus = FocusNode(debugLabel: 'history-entry');

  /// 行列表滚动位置 → 列表记忆行（页头 DOWN 的落点）。
  int _rowMemory = 0;
  int _focusRequest = 0;
  int? _pendingRowIndex;
  bool _pendingDeleteFocus = false;
  FocusNode? _pendingFocusNode;
  FocusNode? _pendingFocusOrigin;
  VoidCallback? _pendingScrollListener;
  bool _pendingScrollRunning = false;

  /// 最近一次操作的行下标（删除后焦点落 min(_lastIndex, length - 1)
  /// 那一行的依据）。
  int _lastIndex = 0;

  final ScrollController _scroll = ScrollController();

  /// 页面根按键捕获（skipTraversal）：区块内未消费的方向键冒泡到这里，
  /// 按投递表显式派送（spec §5）。
  final FocusNode _navKeyFocus = FocusNode(debugLabel: 'history-nav-key');

  /// 内容区 FocusScope（spec §4.2）。
  final FocusScopeNode _pageScope = FocusScopeNode(debugLabel: 'page-history');

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  FocusNode _nodeFor(HistoryEntry entry) => _rowFocus.putIfAbsent(
    stableKey(entry.vod),
    () => FocusNode(debugLabel: 'history-row'),
  );

  /// 删除钮节点（按影片 key 登记）。
  FocusNode _deleteNodeFor(HistoryEntry entry) => _deleteFocus.putIfAbsent(
    stableKey(entry.vod),
    () => FocusNode(debugLabel: 'history-del'),
  );

  /// 第 [index] 行的行卡节点（index 0 = 入口节点，不入表、不重复
  /// dispose）。
  FocusNode _rowNodeAt(int index, List<HistoryEntry> entries) {
    if (index == 0) return widget.entryFocus ?? _rowEntryFocus;
    return _nodeFor(entries[index]);
  }

  /// 行卡节点反查行下标（只有行卡内节点参与投递判定）。
  int? _rowIndexOf(FocusNode node, List<HistoryEntry> entries) {
    if (identical(node, widget.entryFocus) || identical(node, _rowEntryFocus)) {
      return entries.isEmpty ? null : 0;
    }
    for (var i = 0; i < entries.length; i++) {
      if (_nodeFor(entries[i]) == node) return i;
    }
    return null;
  }

  /// 删除钮节点反查行下标（按 key 找，再回列表里定位当前下标）。
  int? _deleteIndexOf(FocusNode node, List<HistoryEntry> entries) {
    for (final MapEntry<String, FocusNode> entry in _deleteFocus.entries) {
      if (entry.value != node) continue;
      return entries.indexWhere((e) => stableKey(e.vod) == entry.key);
    }
    return null;
  }

  /// 行高（行卡 = 竖版海报高 + 上下 padding，跨皮肤固定的设计常量，
  /// 见 `_HistoryTile._posterHeight`）。
  double _rowHeight(TvSkin skin) => _posterHeight + 2 * skin.spaceMd;

  void _clearPendingFocus() {
    final listener = _pendingScrollListener;
    if (listener != null) _scroll.removeListener(listener);
    _pendingScrollListener = null;
    _pendingFocusNode = null;
    _pendingFocusOrigin = null;
    _pendingRowIndex = null;
    _pendingDeleteFocus = false;
    _pendingScrollRunning = false;
  }

  void _cancelFocusRequest() {
    _focusRequest++;
    _stopPendingScroll();
    _clearPendingFocus();
  }

  void _stopPendingScroll() {
    if (!_pendingScrollRunning) return;
    _pendingScrollRunning = false;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    position.jumpTo(position.pixels);
  }

  void _schedulePendingFocusCheck(int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryPendingFocus(request);
    });
  }

  void _tryPendingFocus(int request) {
    if (!mounted || request != _focusRequest) return;
    final node = _pendingFocusNode;
    if (node == null) return;
    if (ModalRoute.of(context)?.isCurrent == false) {
      _cancelFocusRequest();
      return;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (identical(primary, node)) {
      if (!_pendingScrollRunning) _clearPendingFocus();
      return;
    }
    if (!_isPendingFocusOrigin(primary)) {
      _cancelFocusRequest();
      return;
    }
    final target = node.context;
    if (target == null || !target.mounted || !node.canRequestFocus) return;
    // 目标节点挂载后立即接管焦点；动画剩余时间内的连续按键按意图行索引派送。
    node.requestFocus();
    _schedulePendingFocusCheck(request);
  }

  void _onFocusChanged() {
    final node = _pendingFocusNode;
    if (node == null) return;
    final primary = FocusManager.instance.primaryFocus;
    if (identical(primary, node)) {
      if (!_pendingScrollRunning) _clearPendingFocus();
    } else if (!_isPendingFocusOrigin(primary)) {
      _cancelFocusRequest();
    }
  }

  bool _isPendingFocusOrigin(FocusNode? focus) =>
      focus == null ||
      identical(focus, _pendingFocusOrigin) ||
      identical(focus, _pageScope) ||
      identical(focus, _navKeyFocus);

  /// 按 index 确定性投递焦点到行卡（spec §3 规则 7 的单列版 + §5 范式）：
  /// 目标行需要预滚动时使用非线性动画；未挂载行一旦挂载就立即落焦，
  /// 连续按键沿最近的目标行继续，而不是重复使用旧焦点下标。
  void _focusRow(int index, {bool focusDelete = false}) {
    final entries = context.read<LibraryStore>().history;
    if (index < 0 || index >= entries.length) return;
    final request = ++_focusRequest;
    _stopPendingScroll();
    _clearPendingFocus();
    _rowMemory = index;
    final node = focusDelete
        ? _deleteNodeFor(entries[index])
        : _rowNodeAt(index, entries);
    final skin = TvSkin.of(context);
    final rowHeight = _rowHeight(skin);
    final stride = rowHeight + skin.spaceLg - 4; // + separator
    if (_scroll.hasClients) {
      final position = _scroll.position;
      final rowTop = skin.spaceSm + index * stride;
      final viewportBottom = position.pixels + position.viewportDimension;
      double target = position.pixels;
      if (rowTop + rowHeight > viewportBottom) {
        target = rowTop + rowHeight - position.viewportDimension;
      } else if (rowTop < position.pixels) {
        target = rowTop;
      }
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((position.pixels - target).abs() > 0.5) {
        _pendingRowIndex = index;
        _pendingDeleteFocus = focusDelete;
        _pendingFocusNode = node;
        _pendingFocusOrigin = FocusManager.instance.primaryFocus;
        void onScroll() => _schedulePendingFocusCheck(request);
        _pendingScrollListener = onScroll;
        _scroll.addListener(onScroll);
        final duration = AppMotion.scrollDuration(context);
        _pendingScrollRunning = duration != Duration.zero;
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
                if (request != _focusRequest) return;
                _pendingScrollRunning = false;
                _schedulePendingFocusCheck(request);
              });
        }
        _schedulePendingFocusCheck(request);
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
    }
    _clearPendingFocus();
    if (node.context != null && node.canRequestFocus) {
      node.requestFocus();
    } else {
      _pendingRowIndex = index;
      _pendingDeleteFocus = focusDelete;
      _pendingFocusNode = node;
      _pendingFocusOrigin = FocusManager.instance.primaryFocus;
      void onScroll() => _schedulePendingFocusCheck(request);
      _pendingScrollListener = onScroll;
      if (_scroll.hasClients) _scroll.addListener(onScroll);
      _schedulePendingFocusCheck(request);
    }
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 静态区块（页头按钮）的焦点投递：不滚动，requestFocus 即达。
  void _focusNear(FocusNode node) {
    _cancelFocusRequest();
    if (node.canRequestFocus) node.requestFocus();
  }

  /// 页面根方向键分发（投递表见文件头注）。
  KeyEventResult _handlePageKey(FocusNode node, KeyEvent event) {
    // keydown 与长按 repeat 都走显式投递：repeat 放给框架会落回几何
    // 遍历，落点不可控（死键 / 跳丢的根因之一）。
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
    final entries = context.read<LibraryStore>().history;
    final count = entries.length;

    // 分区判定按节点身份（不靠几何）：删除钮 > 行卡 > 页头。
    final pendingIndex = _pendingRowIndex;
    final deleteIndex = pendingIndex == null
        ? _deleteIndexOf(focus, entries)
        : (_pendingDeleteFocus ? pendingIndex : null);
    if (deleteIndex != null) {
      if (isLeft) {
        // 删除钮 LEFT → 本行行卡。
        _focusRow(deleteIndex);
        return KeyEventResult.handled;
      }
      if (isRight) {
        // 行尾吞键。
        return KeyEventResult.handled;
      }
      if (isUp && deleteIndex == 0) {
        // 首行删除钮 UP → 页头返回键。
        _focusNear(_backFocus);
        return KeyEventResult.handled;
      }
      if (isDown && deleteIndex == count - 1) {
        // 末行删除钮 DOWN：吞键（页面底）。
        return KeyEventResult.handled;
      }
      // 其余：相邻行卡（UP → 上一行，DOWN → 下一行）。
      _focusRow(isUp ? deleteIndex - 1 : deleteIndex + 1);
      return KeyEventResult.handled;
    }

    final rowIndex = pendingIndex ?? _rowIndexOf(focus, entries);
    if (rowIndex != null) {
      if (isRight) {
        // RIGHT → 本行删除钮（行尾的删除入口）。
        _focusRow(rowIndex, focusDelete: true);
        return KeyEventResult.handled;
      }
      if (isLeft) {
        // 单列行卡，页面左缘：吞键（见投递表头注）。
        return KeyEventResult.handled;
      }
      if (isUp && rowIndex == 0) {
        // 首行 UP → 页头返回键。
        _focusNear(_backFocus);
        return KeyEventResult.handled;
      }
      if (isDown && rowIndex == count - 1) {
        // 末行以下 DOWN：吞键（页面底，spec §4.4）。
        return KeyEventResult.handled;
      }
      _focusRow(isUp ? rowIndex - 1 : rowIndex + 1);
      return KeyEventResult.handled;
    }

    // 页头（返回 / 清空）。
    if (isDown) {
      // DOWN → 记忆行；空态放行（空态里的返回按钮可达）。
      if (count > 0) {
        _focusRow(_rowMemory.clamp(0, count - 1));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (isUp) {
      // 顶缘吞键。
      return KeyEventResult.handled;
    }
    if (isLeft) {
      if (focus == _clearFocus) {
        _focusNear(_backFocus);
        return KeyEventResult.handled;
      }
      // 返回键 LEFT：页面左缘吞键。
      return KeyEventResult.handled;
    }
    // isRight：返回 → 清空（清空键仅在非空态存在）；清空 RIGHT 行尾吞键。
    if (focus == _backFocus && _clearFocus.canRequestFocus) {
      _clearFocus.requestFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _stopPendingScroll();
    _clearPendingFocus();
    _backFocus.dispose();
    _clearFocus.dispose();
    _rowEntryFocus.dispose();
    _scroll.dispose();
    _navKeyFocus.dispose();
    _pageScope.dispose();
    for (final node in _rowFocus.values) {
      node.dispose();
    }
    for (final node in _deleteFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final t = AppText.of(context);
    final controller = context.watch<AppController>();
    final library = context.watch<LibraryStore>();
    final entries = library.history;
    return Scaffold(
      backgroundColor: skin.bg,
      body: AppBackground(
        wallpaper: controller.wallpaper,
        child: SafeArea(
          child: Focus(
            focusNode: _navKeyFocus,
            skipTraversal: true,
            onKeyEvent: _handlePageKey,
            child: FocusScope(
              node: _pageScope,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      TvCanvas.pagePad,
                      skin.spaceSm,
                      TvCanvas.pagePad,
                      skin.spaceSm,
                    ),
                    child: Row(
                      children: [
                        TvFocusable(
                          radius: skin.radiusPill,
                          focusNode: _backFocus,
                          // FOCUS-06：历史为空时没有行列表可落焦点，进页默认焦点
                          // 给返回键，避免掉到不可见的 FocusScope 根上（AGENTS.md §3）。
                          autofocus: entries.isEmpty,
                          semanticLabel: '返回',
                          onTap: () => Navigator.maybePop(context),
                          child: _CircleIconButton(
                            icon: Icons.arrow_back_rounded,
                          ),
                        ),
                        SizedBox(width: skin.spaceSm + 2),
                        Expanded(child: Text('播放历史', style: t.pageTitle)),
                        if (entries.isNotEmpty)
                          TvFocusable(
                            radius: skin.radiusPill,
                            focusNode: _clearFocus,
                            semanticLabel: '清空播放历史',
                            onTap: () => _confirmClear(context, library),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: skin.spaceMd,
                                vertical: skin.spaceSm,
                              ),
                              decoration: BoxDecoration(
                                color: skin.surfaceSubtle,
                                borderRadius: BorderRadius.circular(
                                  skin.radiusPill,
                                ),
                                border: Border.all(color: skin.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                    color: skin.danger,
                                  ),
                                  SizedBox(width: skin.spaceXs + 1),
                                  Text(
                                    '清空',
                                    style: t.label.copyWith(color: skin.danger),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: entries.isEmpty
                        ? EmptyState(
                            message: '还没有播放记录\n打开一部影片开始观看吧',
                            icon: Icons.history_toggle_off_rounded,
                            action: () => Navigator.maybePop(context),
                            actionLabel: '返回',
                          )
                        // 单列保留：`_HistoryTile` 是横向行卡片（144×216 竖版海报 +
                        // 标题/进度/操作），塞进网格会裁掉文字。`ListView.separated`
                        // 的 itemBuilder 是延迟构建的，100 条上限下只挂载可见行；
                        // UP/DOWN 由页面根 Focus 按 index 显式投递（spec §3 规则 7
                        // 的单列版），缓存区外的行先滚动再补投，不赌几何遍历。
                        : ListView.separated(
                            controller: _scroll,
                            physics: const ClampingScrollPhysics(),
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              kTvListCacheExtent,
                            ),
                            addAutomaticKeepAlives: false,
                            padding: EdgeInsets.fromLTRB(
                              TvCanvas.pagePad,
                              skin.spaceSm,
                              TvCanvas.pagePad,
                              skin.spaceLg,
                            ),
                            itemCount: entries.length,
                            separatorBuilder: (_, _) =>
                                SizedBox(height: skin.spaceLg - 4),
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              return _HistoryTile(
                                entry: entry,
                                // FOCUS-06：没有行获焦时默认焦点给第一行。
                                autofocus: index == 0,
                                focusNode: _rowNodeAt(index, entries),
                                deleteFocusNode: _deleteNodeFor(entry),
                                onTap: () {
                                  _lastIndex = index;
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => DetailPage(
                                        vod: entry.vod,
                                        resume: entry,
                                      ),
                                    ),
                                  );
                                },
                                onDelete: () => _remove(library, entry, index),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _remove(
    LibraryStore library,
    HistoryEntry entry,
    int index,
  ) async {
    _cancelFocusRequest();
    _lastIndex = index;
    await library.removeHistory(entry);
    if (!mounted) return;
    final remaining = library.history.length;
    // 删完后列表已重建：回收已消失影片的节点（仍挂树的不杀）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final alive = library.history.map((e) => stableKey(e.vod)).toSet();
      _rowFocus.removeWhere((key, node) {
        if (alive.contains(key)) return false;
        final context = node.context;
        if (context != null && context.mounted) return false;
        node.dispose();
        return true;
      });
      _deleteFocus.removeWhere((key, node) {
        if (alive.contains(key)) return false;
        final context = node.context;
        if (context != null && context.mounted) return false;
        node.dispose();
        return true;
      });
    });
    if (remaining == 0) {
      _backFocus.requestFocus();
      return;
    }
    // 删完后列表已重建：把焦点交给 min(_lastIndex, length - 1) 那一行。
    final target = _lastIndex < remaining ? _lastIndex : remaining - 1;
    _focusRow(target);
  }

  Future<void> _confirmClear(BuildContext context, LibraryStore library) async {
    final count = library.history.length;
    final confirmed = await showTvSheet<bool>(
      context,
      title: '清空播放历史',
      subtitle: '此操作无法撤销',
      width: 520,
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        final t = AppText.of(sheetContext);
        return Padding(
          padding: EdgeInsets.all(skin.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '将删除全部 $count 条播放记录，之后无法恢复。',
                style: t.bodyLarge.copyWith(color: skin.textSecondary),
              ),
              SizedBox(height: skin.spaceLg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      autofocus: true,
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: const Text('取消'),
                    ),
                  ),
                  SizedBox(width: skin.spaceMd),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: const Text('清空'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await library.clearHistory();
    if (!mounted) return;
    _backFocus.requestFocus();
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: skin.surfaceSubtle,
        shape: BoxShape.circle,
        border: Border.all(color: skin.border),
      ),
      child: Icon(icon, size: 22, color: skin.textPrimary),
    );
  }
}

/// 竖版海报 2:3（AGENTS.md §2.7）。跨皮肤固定的设计常量：不随间距 token
/// 漂移，保证三皮肤下列宽/行高一致（§9.1）。比原 76×104 放大到 144×216，
/// 10 英尺外片名与人脸可辨。行高 = 海报高 + 上下 padding，页面侧
/// `_focusRow` 的预滚动定位要用，故放文件级。
const double _posterHeight = 216;

class _HistoryTile extends StatefulWidget {
  const _HistoryTile({
    required this.entry,
    required this.onTap,
    required this.onDelete,
    required this.focusNode,
    required this.deleteFocusNode,
    this.autofocus = false,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// 行卡焦点节点（页面侧按 index 显式投递）。
  final FocusNode focusNode;

  /// 行内删除钮的焦点节点（页面侧持有：RIGHT 从行卡直达删除钮）。
  final FocusNode deleteFocusNode;
  final bool autofocus;

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
  /// 删除钮是否获焦。删除钮嵌在行卡内部，未获焦时视觉降级（低透明度 + 弱描边），
  /// 避免与整行焦点视觉重叠成「两个焦点态」（AGENTS.md §9 不变量 3：焦点唯一）。
  bool _deleteFocused = false;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final t = AppText.of(context);
    final entry = widget.entry;
    return TvFocusable(
      radius: skin.radiusLg,
      scale: 1.015,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      semanticLabel: '继续播放 ${entry.vod.name}',
      onTap: widget.onTap,
      child: Container(
        padding: EdgeInsets.all(skin.spaceMd),
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusLg),
          border: Border.all(color: skin.borderSoft),
        ),
        // 行高锁定为竖版海报高度（_posterHeight）：让右侧 Column 拿到有界高度，
        // 否则 ListView 的无界高度会传进 Column，`Spacer`（Expanded flex）在
        // debug 抛 unbounded 约束异常、release 塌缩导致进度条/时间行贴顶。
        child: SizedBox(
          height: _posterHeight,
          child: Row(
            children: [
              SizedBox(
                width: 144,
                height: _posterHeight,
                child: NetworkPoster(
                  url: entry.vod.pic,
                  radius: skin.radiusSm + 2,
                ),
              ),
              SizedBox(width: skin.spaceLg - 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.vod.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.cardTitle,
                    ),
                    SizedBox(height: skin.spaceSm),
                    Row(
                      children: [
                        SiteBadge(label: entry.sourceName),
                        SizedBox(width: skin.spaceXs + 1),
                        Flexible(
                          child: Text(
                            '${entry.lineName} · ${entry.episodeName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.body.copyWith(color: skin.textSecondary),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(skin.radiusSm),
                      child: LinearProgressIndicator(
                        value: entry.progress,
                        minHeight: 4,
                        backgroundColor: skin.borderSoft,
                        valueColor: AlwaysStoppedAnimation(skin.accent),
                      ),
                    ),
                    SizedBox(height: skin.spaceSm),
                    Row(
                      children: [
                        Text(
                          formatRelativeTime(entry.updatedAt),
                          style: t.meta,
                        ),
                        SizedBox(width: skin.spaceMd),
                        Expanded(
                          child: Text(
                            entry.durationMs > 0
                                ? '${formatMilliseconds(entry.positionMs)} / ${formatMilliseconds(entry.durationMs)}'
                                : '观看至 ${entry.episodeName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.meta.copyWith(color: skin.textMuted),
                          ),
                        ),
                        SizedBox(width: skin.spaceMd),
                        Icon(
                          Icons.play_circle_fill_rounded,
                          size: 18,
                          color: skin.accent,
                        ),
                        SizedBox(width: skin.spaceXs - 2),
                        Text('继续', style: t.label.copyWith(color: skin.accent)),
                        SizedBox(width: skin.spaceMd),
                        TvFocusable(
                          radius: skin.radiusPill,
                          focusNode: widget.deleteFocusNode,
                          semanticLabel: '删除历史记录 ${entry.vod.name}',
                          onFocusChange: (focused) {
                            if (focused != _deleteFocused && mounted) {
                              setState(() => _deleteFocused = focused);
                            }
                          },
                          onTap: widget.onDelete,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _deleteFocused
                                  ? skin.surface
                                  : skin.surface.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _deleteFocused
                                    ? skin.borderSoft
                                    : skin.borderSoft.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: _deleteFocused
                                  ? skin.textMuted
                                  : skin.textMuted.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
