import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/library_store.dart';
import '../../data/models.dart';
import '../../theme/ui.dart';
import '../../ui/tv_canvas.dart';
import '../widgets/common.dart';
import '../widgets/poster_card.dart';
import 'detail_page.dart';

/// 收藏页焦点投递表（docs/focus-system-spec.md §4/§5；行 = 当前焦点
/// 所在区块，列 = 方向）：
///
/// | 区块＼方向 | UP | DOWN | LEFT | RIGHT |
/// | --- | --- | --- | --- | --- |
/// | 页头（返回/编辑） | 吞键（顶缘） | 网格记忆格（空态放行→空态按钮） | 编辑→返回；返回吞键（页面左缘） | 返回→编辑；编辑吞键（行尾） |
/// | 海报 i | index−列数；首行→返回键 | index+列数；末行以下吞键（页面底） | 最左列吞键（页面左缘）；其余 index−1 | 编辑态→本卡删除钮；非编辑最右列吞键、其余 index+1 |
/// | 删除钮 i（编辑态） | index−列数；首行→返回键 | index+列数；末行以下吞键 | 本卡海报 i | 下一张海报 i+1；末张吞键（行尾） |
///
/// 「吞键」格子的说明：本页是从「我的」push 出来的**推入式路由**，壳层
/// （含侧栏 LEFT 通道）不在本页的按键链上——页面最左缘的 LEFT 没有可去
/// 处，按 spec §4.4 的边界吞键处理（焦点原地不动）；若后续要把「LEFT
/// 回壳层侧栏」接上，需要壳层/导航侧加通道（见交付报告的待协调项）。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, this.entryFocus});

  /// 入口焦点（壳层注入；当前无调用方传——mine_page 冻结期内保留参数
  /// 位，spec §4.1 契约）。缺省时网格第 0 张海报靠 autofocus 落焦点。
  final FocusNode? entryFocus;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  bool _editing = false;

  /// 「编辑」模式下删掉一张海报后，焦点要落到相邻那张（AGENTS.md §3
  /// 硬性规则 3）。这里按 index 保存海报的 [FocusNode]，删除完成后直接
  /// 对 `min(_lastIndex, length - 1)` 那一格 `requestFocus`；列表空了就把
  /// 焦点还给返回键，不让它掉到 `FocusScope` 根上。
  final Map<int, FocusNode> _posterFocus = {};
  int _lastIndex = 0;

  /// 网格当前记忆格（页头 DOWN 的落点）。
  int _posterMemory = 0;

  /// 编辑模式每张海报右上角「取消收藏」钮的焦点节点（按影片 key 登记：
  /// 删除后下标整体前移，用 key 才能在列表重建后找回同一张卡的钮）。
  final Map<String, FocusNode> _deleteFocus = {};

  final FocusNode _backFocus = FocusNode(debugLabel: 'favorites-back');
  final FocusNode _editFocus = FocusNode(debugLabel: 'favorites-edit');

  /// 网格第 0 张海报的兜底入口节点（未注入 entryFocus 时用）。
  final FocusNode _posterEntryFocus = FocusNode(debugLabel: 'favorites-entry');

  final ScrollController _gridScroll = ScrollController();
  int _focusRequest = 0;
  int? _pendingPosterIndex;
  bool _pendingDeleteFocus = false;
  FocusNode? _pendingFocusNode;
  FocusNode? _pendingFocusOrigin;
  VoidCallback? _pendingScrollListener;
  bool _pendingScrollRunning = false;

  /// 页面根按键捕获（skipTraversal）：区块内未消费的方向键冒泡到这里，
  /// 按投递表显式派送（spec §5）。
  final FocusNode _navKeyFocus = FocusNode(debugLabel: 'favorites-nav-key');

  /// 内容区 FocusScope（spec §4.2）。
  final FocusScopeNode _pageScope = FocusScopeNode(
    debugLabel: 'page-favorites',
  );

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  /// 海报网格第 [index] 张的焦点节点（index 0 = 入口节点，不入表、
  /// 不重复 dispose）。
  FocusNode _posterNodeAt(int index) {
    if (index == 0) return widget.entryFocus ?? _posterEntryFocus;
    return _posterFocus.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'fav-$index'),
    );
  }

  /// 编辑模式删除钮节点（按影片 key 登记）。
  FocusNode _deleteNodeAt(int index, List<VodItem> favorites) =>
      _deleteFocus.putIfAbsent(
        stableKey(favorites[index]),
        () => FocusNode(debugLabel: 'fav-del-${favorites[index].name}'),
      );

  /// 焦点节点反查海报下标（只有网格内节点参与投递判定）。
  int? _posterIndexOf(FocusNode node, List<VodItem> favorites) {
    if (identical(node, widget.entryFocus) ||
        identical(node, _posterEntryFocus)) {
      return favorites.isEmpty ? null : 0;
    }
    for (final MapEntry<int, FocusNode> entry in _posterFocus.entries) {
      if (entry.value == node) return entry.key;
    }
    return null;
  }

  /// 删除钮节点反查行下标（按 key 找，再回列表里定位当前下标）。
  int? _deleteIndexOf(FocusNode node, List<VodItem> favorites) {
    for (final MapEntry<String, FocusNode> entry in _deleteFocus.entries) {
      if (entry.value != node) continue;
      return favorites.indexWhere((vod) => stableKey(vod) == entry.key);
    }
    return null;
  }

  /// 网格列数：与 `SliverGridDelegateWithMaxCrossAxisExtent` 同公式
  /// （max(1, ceil(网格宽 / (maxCrossAxisExtent + 交叉间距)))），供
  /// UP/DOWN 按「index ± 列数」算同列上/下行。
  int get _posterColumns {
    final skin = TvSkin.of(context);
    const gridWidth = TvCanvas.designWidth - 2 * TvCanvas.pagePad;
    final stride = 224 + skin.spaceMd; // maxCrossAxisExtent + crossAxisSpacing
    final columns = (gridWidth / stride).ceil();
    return columns < 1 ? 1 : columns;
  }

  /// 网格行高（与 delegate 的 childAspectRatio 0.57 同源）：预滚动定位
  /// 未挂载行时用。
  double get _posterRowHeight {
    final skin = TvSkin.of(context);
    final columns = _posterColumns;
    const gridWidth = TvCanvas.designWidth - 2 * TvCanvas.pagePad;
    final childWidth = (gridWidth - (columns - 1) * skin.spaceMd) / columns;
    return childWidth / 0.57; // childAspectRatio
  }

  /// 取消尚未完成的网格焦点投递与对应滚动监听。
  void _cancelFocusRequest() {
    _focusRequest++;
    _stopPendingScroll();
    _clearPendingFocus();
  }

  void _stopPendingScroll() {
    if (!_pendingScrollRunning) return;
    _pendingScrollRunning = false;
    if (!_gridScroll.hasClients) return;
    final position = _gridScroll.position;
    position.jumpTo(position.pixels);
  }

  void _clearPendingFocus() {
    final listener = _pendingScrollListener;
    if (listener != null) _gridScroll.removeListener(listener);
    _pendingScrollListener = null;
    _pendingFocusNode = null;
    _pendingFocusOrigin = null;
    _pendingPosterIndex = null;
    _pendingDeleteFocus = false;
    _pendingScrollRunning = false;
  }

  void _watchPendingFocus(int request) {
    void onScroll() => _schedulePendingFocusCheck(request);
    _pendingScrollListener = onScroll;
    _gridScroll.addListener(onScroll);
  }

  void _schedulePendingFocusCheck(int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryPendingFocus(request);
    });
  }

  bool _isPendingFocusOrigin(FocusNode? focus) =>
      focus == null ||
      identical(focus, _pendingFocusOrigin) ||
      identical(focus, _pageScope) ||
      identical(focus, _navKeyFocus);

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
      if (!_pendingScrollRunning) _finishPendingFocus(request);
      return;
    }
    if (!_isPendingFocusOrigin(primary)) {
      _cancelFocusRequest();
      return;
    }
    final target = node.context;
    if (target == null || !target.mounted || !node.canRequestFocus) return;
    // 目标刚挂载就投焦点，不等滚动动画结束；后续按键仍由意图索引接续。
    node.requestFocus();
    _schedulePendingFocusCheck(request);
  }

  void _finishPendingFocus(int request) {
    if (request != _focusRequest) return;
    _clearPendingFocus();
  }

  void _onFocusChanged() {
    final node = _pendingFocusNode;
    if (node == null) return;
    final primary = FocusManager.instance.primaryFocus;
    if (identical(primary, node)) {
      if (!_pendingScrollRunning) _finishPendingFocus(_focusRequest);
    } else if (!_isPendingFocusOrigin(primary)) {
      // 焦点已离开海报区；不让旧的异步滚动请求稍后抢回焦点。
      _cancelFocusRequest();
    }
  }

  /// 按 index 确定性投递焦点到海报格（spec §3 规则 7 + §5 范式）：
  /// 未挂载行先用非线性动画预滚动，目标一挂载便接管焦点；重复按键沿用
  /// 尚未完成的目标索引，避免动画期间按键仍从旧焦点起算。
  void _focusPosterIndex(int index, {bool focusDelete = false}) {
    final favorites = context.read<LibraryStore>().favorites;
    if (index < 0 || index >= favorites.length) return;
    final request = ++_focusRequest;
    _stopPendingScroll();
    _clearPendingFocus();
    _posterMemory = index;
    final node = focusDelete
        ? _deleteNodeAt(index, favorites)
        : _posterNodeAt(index);
    final skin = TvSkin.of(context);
    final rowHeight = _posterRowHeight;
    final stride = rowHeight + skin.spaceLg - 4; // + mainAxisSpacing
    if (_gridScroll.hasClients) {
      final position = _gridScroll.position;
      final rowTop = skin.spaceSm + (index ~/ _posterColumns) * stride;
      final viewportBottom = position.pixels + position.viewportDimension;
      double target = position.pixels;
      if (rowTop + rowHeight > viewportBottom) {
        target = rowTop + rowHeight - position.viewportDimension;
      } else if (rowTop < position.pixels) {
        target = rowTop;
      }
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((position.pixels - target).abs() > 0.5) {
        _pendingPosterIndex = index;
        _pendingDeleteFocus = focusDelete;
        _pendingFocusNode = node;
        _pendingFocusOrigin = FocusManager.instance.primaryFocus;
        _watchPendingFocus(request);
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
    // 已挂载目标同步 requestFocus，按键不必等滚动动画结束。
    if (node.context != null && node.canRequestFocus) {
      node.requestFocus();
    } else {
      _pendingPosterIndex = index;
      _pendingDeleteFocus = focusDelete;
      _pendingFocusNode = node;
      _pendingFocusOrigin = FocusManager.instance.primaryFocus;
      if (_gridScroll.hasClients) _watchPendingFocus(request);
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
    final favorites = context.read<LibraryStore>().favorites;
    final count = favorites.length;
    final columns = _posterColumns;

    // 分区判定按节点身份（不靠几何）：删除钮 > 海报 > 页头。
    final pendingIndex = _pendingPosterIndex;
    final deleteIndex = pendingIndex == null
        ? _deleteIndexOf(focus, favorites)
        : (_pendingDeleteFocus ? pendingIndex : null);
    if (deleteIndex != null) {
      if (isLeft) {
        // 删除钮 LEFT → 本卡海报。
        _focusPosterIndex(deleteIndex);
        return KeyEventResult.handled;
      }
      if (isRight) {
        // RIGHT → 下一张海报；末张吞键（行尾）。
        if (deleteIndex + 1 < count) {
          _focusPosterIndex(deleteIndex + 1);
        }
        return KeyEventResult.handled;
      }
      final target = isUp ? deleteIndex - columns : deleteIndex + columns;
      if (target >= 0 && target < count) {
        _focusPosterIndex(target);
        return KeyEventResult.handled;
      }
      if (isUp && deleteIndex < columns) {
        // 首行删除钮 UP → 页头返回键。
        _focusNear(_backFocus);
        return KeyEventResult.handled;
      }
      // 末行以下 DOWN：吞键（页面底）。
      return KeyEventResult.handled;
    }

    final posterIndex = pendingIndex ?? _posterIndexOf(focus, favorites);
    if (posterIndex != null) {
      if (isUp) {
        final target = posterIndex - columns;
        if (target >= 0) {
          _focusPosterIndex(target);
          return KeyEventResult.handled;
        }
        // 首行 UP → 页头返回键（层级上升，落点稳定）。
        _focusNear(_backFocus);
        return KeyEventResult.handled;
      }
      if (isDown) {
        final target = posterIndex + columns;
        if (target < count) {
          _focusPosterIndex(target);
          return KeyEventResult.handled;
        }
        // 末行以下 DOWN：吞键（页面底，spec §4.4）。
        return KeyEventResult.handled;
      }
      if (isLeft) {
        // 最左列 LEFT：吞键（页面左缘，见投递表头注）；其余列显式
        // 左移一格——编辑态下也不落邻卡的删除钮，落点确定。
        if (posterIndex % columns == 0) return KeyEventResult.handled;
        _focusPosterIndex(posterIndex - 1);
        return KeyEventResult.handled;
      }
      // isRight：编辑模式 → 本卡删除钮（删除入口贴卡片右上角）；
      // 非编辑模式 → 最右列（含末行不满列）吞键，其余右移一格。
      if (_editing) {
        _focusPosterIndex(posterIndex, focusDelete: true);
        return KeyEventResult.handled;
      }
      final atRowEnd =
          posterIndex % columns == columns - 1 || posterIndex == count - 1;
      if (atRowEnd) return KeyEventResult.handled;
      _focusPosterIndex(posterIndex + 1);
      return KeyEventResult.handled;
    }

    // 页头（返回 / 编辑）。
    if (isDown) {
      // DOWN → 网格记忆格；空态放行（空态里的返回按钮可达）。
      if (count > 0) {
        _focusPosterIndex(_posterMemory.clamp(0, count - 1));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (isUp) {
      // 顶缘吞键。
      return KeyEventResult.handled;
    }
    if (isLeft) {
      if (focus == _editFocus) {
        _focusNear(_backFocus);
        return KeyEventResult.handled;
      }
      // 返回键 LEFT：页面左缘吞键。
      return KeyEventResult.handled;
    }
    // isRight：返回 → 编辑（编辑键仅在非空态存在）；编辑 RIGHT 行尾吞键。
    if (focus == _backFocus && _editFocus.canRequestFocus) {
      _editFocus.requestFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _stopPendingScroll();
    _clearPendingFocus();
    _backFocus.dispose();
    _editFocus.dispose();
    _posterEntryFocus.dispose();
    _gridScroll.dispose();
    _navKeyFocus.dispose();
    _pageScope.dispose();
    for (final node in _posterFocus.values) {
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
    final favorites = library.favorites;
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
                          // FOCUS-06：收藏为空时没有海报网格可落焦点，进页默认焦点
                          // 给返回键，避免掉到不可见的 FocusScope 根上（AGENTS.md §3）。
                          autofocus: favorites.isEmpty,
                          semanticLabel: '返回',
                          onTap: () => Navigator.maybePop(context),
                          child: _CircleIconButton(
                            icon: Icons.arrow_back_rounded,
                          ),
                        ),
                        SizedBox(width: skin.spaceSm + 2),
                        Expanded(child: Text('我的收藏', style: t.pageTitle)),
                        if (favorites.isNotEmpty)
                          TvFocusable(
                            radius: skin.radiusPill,
                            focusNode: _editFocus,
                            semanticLabel: _editing ? '完成编辑' : '编辑收藏',
                            onTap: () => setState(() => _editing = !_editing),
                            child: AnimatedContainer(
                              duration: AppMotion.duration(
                                context,
                                skin.motionFast,
                              ),
                              curve: Curves.easeOutCubic,
                              padding: EdgeInsets.symmetric(
                                horizontal: skin.spaceMd,
                                vertical: skin.spaceSm,
                              ),
                              decoration: BoxDecoration(
                                color: _editing
                                    ? skin.accentSoft
                                    : skin.surfaceSubtle,
                                borderRadius: BorderRadius.circular(
                                  skin.radiusPill,
                                ),
                                border: Border.all(
                                  color: _editing ? skin.accent : skin.border,
                                ),
                              ),
                              child: Text(
                                _editing ? '完成' : '编辑',
                                style: t.label.copyWith(
                                  color: _editing
                                      ? skin.accent
                                      : skin.textSecondary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: favorites.isEmpty
                        ? EmptyState(
                            message: '还没有收藏任何影片\n在详情页点击心形按钮即可收藏',
                            icon: Icons.favorite_border_rounded,
                            action: () => Navigator.maybePop(context),
                            actionLabel: '返回',
                          )
                        : GridView.builder(
                            controller: _gridScroll,
                            physics: const ClampingScrollPhysics(),
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              kTvGridCacheExtent,
                            ),
                            addAutomaticKeepAlives: false,
                            padding: EdgeInsets.fromLTRB(
                              TvCanvas.pagePad,
                              skin.spaceSm,
                              TvCanvas.pagePad,
                              skin.spaceLg,
                            ),
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 224,
                                  mainAxisSpacing: skin.spaceLg - 4,
                                  crossAxisSpacing: skin.spaceMd,
                                  childAspectRatio: 0.57,
                                ),
                            itemCount: favorites.length,
                            itemBuilder: (context, index) {
                              final vod = favorites[index];
                              final node = _posterNodeAt(index);
                              // FOCUS-06：进页默认焦点落第一张海报。
                              return Stack(
                                children: [
                                  Positioned.fill(
                                    child: PosterCard(
                                      vod: vod,
                                      focusNode: node,
                                      autofocus: index == 0,
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => DetailPage(vod: vod),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_editing)
                                    Positioned(
                                      right: skin.spaceXs,
                                      top: skin.spaceXs,
                                      child: TvFocusable(
                                        radius: skin.radiusPill,
                                        scale: 1.12,
                                        focusNode: _deleteNodeAt(
                                          index,
                                          favorites,
                                        ),
                                        semanticLabel: '取消收藏 ${vod.name}',
                                        onTap: () => _remove(library, index),
                                        child: Container(
                                          padding: EdgeInsets.all(skin.spaceXs),
                                          decoration: BoxDecoration(
                                            color: skin.danger,
                                            shape: BoxShape.circle,
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.3,
                                                ),
                                                blurRadius: 8,
                                              ),
                                            ],
                                          ),
                                          child: Icon(
                                            Icons.close_rounded,
                                            size: 18,
                                            color: skin.textOnAccent,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
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

  Future<void> _remove(LibraryStore library, int index) async {
    final favorites = library.favorites;
    if (index < 0 || index >= favorites.length) return;
    _cancelFocusRequest();
    _lastIndex = index;
    await library.removeFavorite(favorites[index]);
    if (!mounted) return;
    // 删完后列表已重建：回收超界的删除钮节点（仍挂树的不杀）。
    final remaining = library.favorites.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deleteFocus.removeWhere((key, node) {
        if (library.favorites.any((vod) => stableKey(vod) == key)) {
          return false;
        }
        final context = node.context;
        if (context != null && context.mounted) return false;
        node.dispose();
        return true;
      });
      _posterFocus.removeWhere((index, node) {
        if (index < remaining) return false;
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
    // 删完后列表已重建：把焦点交给 min(_lastIndex, length - 1) 那张海报。
    final target = _lastIndex < remaining ? _lastIndex : remaining - 1;
    _focusPosterIndex(target);
  }
}

/// 页头返回键的玻璃圆钮，三皮肤共用。
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
