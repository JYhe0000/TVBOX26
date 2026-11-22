import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/library_store.dart';
import '../../core/app_controller.dart';
import '../../core/utils.dart';
import '../../data/models.dart';
import '../../theme/ui.dart';
import '../widgets/common.dart';
import '../widgets/detail_backdrop.dart';
import '../widgets/episode_selector.dart';
import '../tv_canvas.dart';
import '../widgets/poster_card.dart';
import 'player_page.dart';

// detail_page.dart — 详情页焦点投递表（focus-system-spec §4/§5，重建于
// 2026-11-19）。详情页是全屏路由（不在壳层内），壳层根 Focus 收不到按键，
// 页面根挂一个 `canRequestFocus: false` 的 Focus 兜底分发；区块内部的键
// （网格/胶囊/推荐行的左右移动）由各自组件先消费，冒泡到页面根的只有
// 「跨区块」与「边界」键。投递表（→ 显式投递；吞 = 显式 handled 防几何
// 兜底甩焦点；几 = 交给框架几何遍历）：
//
// | 焦点位置 \ 键   | UP                  | DOWN                          | LEFT                          | RIGHT                         |
// | --------------- | ------------------- | ----------------------------- | ----------------------------- | ----------------------------- |
// | 页头返回浮钮    | 吞（页面最上）      | 错误横幅「重试」→ hero 播放键 | 吞                            | 吞                            |
// | 错误横幅重试    | 页头返回浮钮        | hero 播放键                   | 吞                            | 吞                            |
// | hero 操作行     | 页头返回浮钮        | 简介                          | 行内左移；行首吞（无处可去）  | 行内右移；行尾 → 选集网格     |
// | 简介            | hero 播放键         | 线路胶囊（单线路 → 网格；无线路 → 推荐行） | 吞             | 吞                            |
// | 线路胶囊        | 简介（冒泡到页面）  | 选集网格选中集（组件内处理）  | 行内左移；行首吞              | 行内右移；行尾吞              |
// | 选集网格        | 首行 → 触发者（组件 onExitUp） | 末行 → 推荐行（组件 onExitDown） | 行内（组件）      | 行内（组件）                  |
// | 推荐横排        | 选集网格选中集（无线路 → 简介） | 吞（页面最底）      | 行内左移；行首吞              | 行内右移；行尾吞              |
//
// LEFT 全页无去处（详情页全屏路由、壳层侧栏在页面之下不可达），页面根对
// 未消费的 LEFT 一律显式吞掉——放行几何遍历会把焦点甩到左上角返回浮钮
// （真机「跳丢」）。BACK：详情页没有页内覆盖层，默认 pop；RouteAware
// didPopNext 重投入口节点（_claimEntryFocus）。

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.vod, this.site, this.resume});

  final VodItem vod;
  final SiteConfig? site;
  final HistoryEntry? resume;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with RouteAware {
  late VodItem _detail = widget.vod;
  SiteConfig? _site;
  HistoryEntry? _resume;
  bool _loading = false;
  bool _descExpanded = false;
  String? _error;
  int _lineIndex = 0;
  int _episodeIndex = 0;
  int _requestToken = 0;
  bool _booted = false;
  List<VodItem> _related = [];
  bool _relatedLoading = false;

  /// 详情页焦点入口（FOCUS-06）：进页默认落在 hero 操作行的「立即播放」上。
  /// 详情是边下边 `setState` 换数据的页面，把节点交给 State 持有，
  /// 让 hero 的播放按钮拿到同一个节点（`autofocus` 只在首次挂载生效）。
  final FocusNode _playFocus = FocusNode(debugLabel: 'detail-play');

  // 相关推荐行的**行内**焦点记忆（FOCUS-07）：第 N 张卡获焦时写进来，
  // 行重新获焦（从别处 DOWN/UP 回来）时按它 `requestFocus` 还原。
  // Flutter 自带的「回到第一个可获焦项」是单行浏览器行为，不是 TV 记忆，
  // 所以这一层必须显式做（`ShelfRow` 的 `_lastFocused` 同一套机制）。
  final ValueNotifier<int> _lastRelatedIndex = ValueNotifier<int>(0);

  /// 相关推荐横向行的滚动控制器：记忆项被 `ListView` 回收（滚出视口）后，
  /// 先 `jumpTo` 滚回它应在的位置，再投递焦点。
  final ScrollController _relatedScroll = ScrollController();
  final _relatedRowKey = GlobalKey();
  int _relatedFocusRequest = 0;

  /// 行根焦点：`onFocusChange` 从 false→true 代表「焦点从行外进入」。
  final FocusNode _relatedRowFocus = FocusNode(debugLabel: 'related-row');

  /// 从相关推荐进详情再返回（FOCUS-07）：记下触发那张卡的 index，
  /// 回到本页后把焦点还给它（与 `home_page._openDetail` 同一个范式）。
  int? _returnIndex;

  /// 每个卡片的焦点节点（懒创建、随 `_related` 换列表回收）。
  final Map<int, FocusNode> _relatedNodes = {};

  /// 共享选集组件负责区间及组内滚动，页面只传递原始集数索引。
  final _episodeGridKey = GlobalKey<EpisodeSelectorState>();
  FocusNode? _episodeReturnFocus;
  final _linesKey = GlobalKey();
  final Map<int, FocusNode> _lineNodes = {};
  FocusNode _lineNode(int index) => _lineNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'detail-line-$index'),
  );

  // —— 页面焦点投递表（顶部注释）用到的各区块入口节点。全部由 State
  // 持有：详情页边下边 setState 换数据，节点交给 State 才能保证重建后
  // 投递目标不变（autofocus 只在首次挂载生效）。——
  final FocusNode _backFocus = FocusNode(debugLabel: 'detail-back');
  final FocusNode _retryFocus = FocusNode(debugLabel: 'detail-retry');
  final FocusNode _restartFocus = FocusNode(debugLabel: 'detail-restart');
  final FocusNode _favoriteFocus = FocusNode(debugLabel: 'detail-favorite');
  final FocusNode _infoFocus = FocusNode(debugLabel: 'detail-info');

  /// 页面纵向滚动控制器：把焦点投到滚动区之外的返回浮钮时直接回顶
  /// （Scrollable.ensureVisible 管不到 Stack 里的悬浮按钮）。
  final ScrollController _scroll = ScrollController();

  /// 「第一集」按钮是否展示（与 build 里的 showRestart 同一判定）。
  bool get _showRestart =>
      _resume != null &&
      _line != null &&
      _resume!.lineName == _line!.name &&
      _resume!.lineIndex == _lineIndex;

  /// 显式投递焦点并把目标滚进视口：向上投备用 keepVisibleAtStart（目标
  /// 在视口上方时最小上滚），向下用 keepVisibleAtEnd（最小下滚）；横向
  /// 行（线路胶囊/推荐行）与页面纵向滚动由 ensureVisible 沿祖先链逐层
  /// 处理——requestFocus 本身不滚动，不补这一手焦点会落在暗处。
  void _moveFocus(FocusNode target, {required bool up}) {
    if (!target.canRequestFocus) return;
    target.requestFocus();
    if (identical(target, _backFocus)) {
      // 返回浮钮在滚动区外（Stack 的 Positioned）：直接回顶。
      if (_scroll.hasClients && _scroll.position.pixels > 0.5) {
        _scroll.animateTo(
          0,
          duration: AppMotion.scrollDuration(context),
          curve: AppMotion.scrollCurve,
        );
      }
      return;
    }
    final ctx = target.context;
    if (ctx != null && ctx.mounted) {
      Scrollable.ensureVisible(
        ctx,
        alignmentPolicy: up
            ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
            : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: AppMotion.scrollDuration(context),
        curve: AppMotion.scrollCurve,
      );
    }
  }

  void _enterEpisodes({bool rememberReturn = true}) {
    if (rememberReturn) {
      _episodeReturnFocus = FocusManager.instance.primaryFocus;
    }
    _episodeGridKey.currentState?.reveal(_episodeIndex, focus: true);
  }

  void _exitEpisodes() {
    final context = _linesKey.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: AppMotion.scrollDuration(this.context),
        curve: AppMotion.scrollCurve,
      );
    }
    final node = _episodeReturnFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = node != null && node.context != null ? node : _playFocus;
      target.requestFocus();
      if (target.context != null) {
        Scrollable.ensureVisible(
          target.context!,
          duration: AppMotion.scrollDuration(this.context),
          curve: AppMotion.scrollCurve,
        );
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 页面级方向键分发（挂在页面根 `canRequestFocus: false` 的 Focus 上，
  /// 只收到组件层没消费的键）。投递表见文件头注释；每个格子要么显式
  /// 投递、要么显式吞（防几何兜底甩焦点），没有「没测过的几何格子」。
  KeyEventResult _handlePageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final primary = FocusManager.instance.primaryFocus;

    // —— 页头（返回浮钮，左上角悬浮）——
    if (_backFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveFocus(_error != null ? _retryFocus : _playFocus, up: false);
      }
      // UP 是页面最上；LEFT/RIGHT 详情页全屏路由无处可去：全吞。
      return KeyEventResult.handled;
    }

    // —— 错误横幅「重试」（在 hero 操作行之上）——
    if (_retryFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveFocus(_backFocus, up: true);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _moveFocus(_playFocus, up: false);
      }
      return KeyEventResult.handled;
    }

    // —— hero 操作行（立即播放 / 第一集 / 收藏）——
    if (_playFocus.hasFocus ||
        _restartFocus.hasFocus ||
        _favoriteFocus.hasFocus) {
      final atFirst = identical(primary, _playFocus);
      final atLast = identical(primary, _favoriteFocus);
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveFocus(_backFocus, up: true);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _moveFocus(_infoFocus, up: false);
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        if (atLast) {
          _moveFocus(_showRestart ? _restartFocus : _playFocus, up: false);
        } else if (!_playFocus.hasFocus) {
          _moveFocus(_playFocus, up: false);
        }
        // 行首（立即播放）LEFT：吞——详情页 LEFT 无处可去，显式吞掉
        // 防止几何遍历把焦点甩到左上角返回浮钮（跳丢）。
      } else if (key == LogicalKeyboardKey.arrowRight) {
        if (atFirst && _showRestart) {
          _moveFocus(_restartFocus, up: false);
        } else if (atFirst || identical(primary, _restartFocus)) {
          _moveFocus(_favoriteFocus, up: false);
        } else if (_episode != null) {
          // 行尾（收藏）RIGHT → 选集网格选中集：详情页「下一步」语义，
          // 与原 _HeroActions 的 RIGHT 拦截一致（details_episode_focus
          // 用例依赖的入口），只是从「整行拦截」收窄为「行尾才出」。
          _enterEpisodes();
        }
        // 无剧集时行尾 RIGHT：吞（没有可进的选集）。
      }
      return KeyEventResult.handled;
    }

    // —— 简介（整块可获焦；线路胶囊的 UP 也冒泡到这里）——
    if (_infoFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveFocus(_playFocus, up: true);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        final lines = _detail.lines;
        if (lines.length > 1) {
          _moveFocus(_lineNode(_lineIndex), up: false);
        } else if (_line != null && _episode != null) {
          _enterEpisodes();
        } else {
          _focusRelatedMemory();
        }
      }
      return KeyEventResult.handled;
    }

    // —— 线路胶囊行（DOWN/LEFT/RIGHT 由胶囊自己处理，这里只有 UP）——
    if (_lineNodes.values.any((n) => n.hasFocus)) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveFocus(_infoFocus, up: true);
      }
      return KeyEventResult.handled;
    }

    // —— 推荐横排（LEFT/RIGHT 由行根处理，这里只有 UP/DOWN）——
    if (_relatedRowFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowUp) {
        // UP 逐层回：回选集网格选中集（无线路时回简介）。
        if (_line != null && _episode != null) {
          _enterEpisodes(rememberReturn: false);
        } else {
          _moveFocus(_infoFocus, up: true);
        }
      }
      // DOWN：页面最底，显式吞（防止几何遍历乱跳）。
      return KeyEventResult.handled;
    }

    // —— 兜底 ——
    // LEFT 全页无去处（详情页是全屏路由不在壳层内）：一律吞掉。
    if (key == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    // 焦点不在任何已知区块（理论上不可达）：UP/DOWN/RIGHT 放行几何。
    return KeyEventResult.ignored;
  }

  /// 推荐横排行根 onKeyEvent 的行内投递（LEFT/RIGHT）：按记忆下标显式
  /// 移动 + ensureVisible；行首/行尾显式吞（详情页 LEFT 无处可去，防
  /// 几何遍历甩到网格/页头等未按契约的落点）。UP/DOWN 放行给页面上抛。
  void _moveRelatedBy(int delta) {
    if (_related.isEmpty) return;
    _relatedFocusRequest++;
    final target = _lastRelatedIndex.value + delta;
    if (target < 0 || target >= _related.length) return; // 行边界：吞
    _lastRelatedIndex.value = target;
    final node = _relatedNodes[target];
    if (node == null || node.context == null || !node.canRequestFocus) {
      // 目标卡被横向列表回收（滚远）：先按常量滚回应在位置再投焦。
      _scrollRelatedTo(target);
      return;
    }
    node.requestFocus();
    Scrollable.ensureVisible(
      node.context!,
      alignmentPolicy: delta > 0
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      duration: AppMotion.scrollDuration(context),
      curve: AppMotion.scrollCurve,
    );
  }

  /// 选集网格末行 DOWN 的落点（组件 onExitDown）：推荐行记忆项；没有
  /// 推荐内容时吞（焦点留在网格末行，无下一个区块）。
  void _focusRelatedMemory() {
    if (_related.isEmpty) return;
    _restoreRelatedFocus();
  }

  @override
  void initState() {
    super.initState();
    _relatedRowFocus.addListener(_onRelatedRowFocusChanged);
  }

  FocusNode _relatedNodeAt(int index) => _relatedNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'related-$index'),
  );

  /// 卡片宽度与间距常量，供焦点记忆的滚回定位使用（与下方 itemBuilder 一致）。
  static const double _relatedCardWidth = 132.0;

  /// 让焦点落在 `node` 上，但先把它滚进视口。
  ///
  /// Flutter 只按几何位置移动焦点（`requestFocus` 不会滚动）：推荐行滚出
  /// 视口后焦点落到看不见的卡片上，来回按方向键就成了「焦点在暗处」。
  /// 横向记忆（下行再上行）靠 [FocusTraversalGroup] 内的方向遍历按几何
  /// 位置还原，返回还焦靠这里的 `ensureVisible`。
  ///
  /// 先投递焦点让节点挂树拿到 context，再 `ensureVisible` 把它滚进视口。
  void _focusSoon(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.canRequestFocus) return;
      node.requestFocus();
      final target = node.context;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.0,
          // keepVisibleAtEnd：只在目标真正滚出视口下方时才往下滚一点把它
          // 拉回来；已经在视口内（含进页时播放键尚在左栏、标题页头可见）
          // 则不动主滚动。旧 `alignment: 0.5` 会把播放键强行居中，把顶部
          // 标题页头推出视口（进页即「标题被滚没」的回退），故弃用。
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: AppMotion.scrollDuration(context),
          curve: AppMotion.scrollCurve,
        );
      }
    });
  }

  /// 切换线路后：选中胶囊的焦点由 `TvFocusable` 自己保住，唯一要修的是
  /// 剧集网格换了数据后，当前焦点元素可能被挤出视口——下一帧补一次
  /// 「滚进视口」。`Scrollable.ensureVisible` 对「焦点在视口内」是空操作，
  /// 对「在视口外」会滚到可见区。
  void _ensureFocusVisibleNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = FocusManager.instance.primaryFocus?.context;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: AppMotion.scrollDuration(context),
          curve: AppMotion.scrollCurve,
        );
      }
    });
  }

  /// 定位到原始集数所在区间，只移动选集内部滚动。
  void _scrollEpisodesTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _episodeGridKey.currentState?.reveal(index);
    });
  }

  /// 从相关推荐进详情：先记 index 再 push，返回时还给它（FOCUS-07）。
  ///
  /// 推荐行的卡片会被横向列表回收（`ListView` 只建可见项），所以这里保存
  /// 的是 **index** 而不是 `FocusNode`：返回后 `_relatedNodes[index]` 仍
  /// 在，配合 `ensureVisible` 把行滚回原位再把焦点投回去。
  Future<void> _openRelated(VodItem vod, int index) async {
    _returnIndex = index;
    // FOCUS-07（与 `home_page._openDetail` 同一范式）：push 前记下触发
    // 那张卡的节点，返回时优先还给它——比按 index 找节点更准（行可能已
    // 滚动、节点可能被回收）。
    final previous = FocusManager.instance.primaryFocus;
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => DetailPage(vod: vod)));
    if (!mounted) return;
    if (previous != null &&
        previous.context != null &&
        previous.canRequestFocus) {
      // 触发行仍在树里：直接还焦，并补一次 ensureVisible 把行滚回原位。
      // 消费掉 _returnIndex，避免行焦点记忆被一次性旧值劫持（detail_deep P2-1）。
      _returnIndex = null;
      _focusSoon(previous);
      return;
    }
    _restoreRelatedFocus();
  }

  /// 把焦点投递到 hero 的「立即播放」：焦点不在本页子树时直接抢；焦点落
  /// 在本页首帧的被动节点（hero 内抢焦点项）上且用户没动过时，也补投——
  /// 首帧操作区未挂载时 `stillInside` 守卫会误判「焦点已在本页」而放弃
  /// 补投，遥控器随后全打偏（真机复现：OK 进不了播放器）。用户手动移动
  /// 过（active != _entryStale）后不再劫持。
  /// 数据到位、从子页面返回这类场景都用它兜底（FOCUS-06）。
  FocusNode? _entryStale;

  void _claimEntryFocus() {
    final active = FocusManager.instance.primaryFocus;
    final stillInside =
        active != null &&
        active.context?.findAncestorStateOfType<_DetailPageState>() == this;
    if (!stillInside) {
      _entryStale = null;
      _focusSoon(_playFocus);
      return;
    }
    if (_entryStale == null) {
      _entryStale = active; // 记下首帧被动落点，供数据到达后识别「用户未动」。
      return;
    }
    if (identical(active, _entryStale)) _focusSoon(_playFocus);
  }

  /// 行重新获焦（从别的区块 DOWN/UP 回来）：把焦点投回记忆项。
  ///
  /// 行根 `Focus` 包在 `ListView` 外层，`false→true` 就是「焦点从行外进入」；
  /// 行内左右移动时行根不变化，记忆项按 `_lastRelatedIndex` 还原。
  void _onRelatedRowFocusChanged() {
    if (!_relatedRowFocus.hasFocus) {
      // 退出相关推荐行时使未完成的滚动揭示失效，避免旧回调重新抢焦。
      _relatedFocusRequest++;
      return;
    }
    // 只有显式进入行根才恢复记忆。子卡获焦也会通知祖先 hasFocus，
    // 此时再排队恢复旧卡会覆盖用户紧接着按下的 RIGHT。
    if (!_relatedRowFocus.hasPrimaryFocus || !mounted) return;
    _restoreRelatedFocus();
  }

  /// 把焦点投回行内记忆项。
  ///
  /// 记忆项滚出视口（横向滚远、`ListView` 回收）时：先 `jumpTo` 滚回它
  /// 应在的位置，post-frame 里再 `requestFocus`；节点仍拿不到就落 index 0
  /// （宁可退回首项，也不让焦点在暗处）。
  void _restoreRelatedFocus() {
    final target = _returnIndex ?? _lastRelatedIndex.value;
    _returnIndex = null;
    var index = target;
    if (index < 0 || index >= _related.length) index = 0;
    _scrollRelatedTo(index);
  }

  /// 按卡片宽度/间距把记忆项滚回视口（横向行回收后的定位）。
  void _scrollRelatedTo(int index, {bool retry = false, int? request}) {
    final token = request ?? ++_relatedFocusRequest;
    // 横向列表位于页面底部；整行尚未进入纵向缓存时，没有卡片节点。
    // 先揭示行容器，使 ListView 在下一帧真实挂载，而不是退回第零项。
    final rowContext = _relatedRowKey.currentContext;
    final Future<void>? rowReveal = rowContext == null
        ? null
        : Scrollable.ensureVisible(
            rowContext,
            duration: AppMotion.scrollDuration(context),
            curve: AppMotion.scrollCurve,
          );
    if (!_relatedScroll.hasClients) {
      if (retry) return;
      void retryAfterReveal() {
        if (!mounted ||
            token != _relatedFocusRequest ||
            ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && token == _relatedFocusRequest) {
            _scrollRelatedTo(index, retry: true, request: token);
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }

      if (rowReveal != null) {
        rowReveal.then((_) => retryAfterReveal());
      } else {
        retryAfterReveal();
      }
      return;
    }
    final skin = TvSkin.of(context);
    final position = _relatedScroll.position;
    final extent = position.viewportDimension;
    // 每张卡的占位 = 132 宽 + spaceSm + 2 的间距；与 itemBuilder 的
    // SizedBox(width: 132) 与 separatorBuilder 的宽度一致。
    final step = _relatedCardWidth + skin.spaceSm + 2;
    // 让记忆项落在视口水平居中，并 clamp 到合法滚动范围。
    final target = (index * step - (extent - _relatedCardWidth) / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final duration = AppMotion.scrollDuration(context);
    void focusTarget() {
      if (!mounted ||
          token != _relatedFocusRequest ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      deliverFocusNode(_relatedNodeAt(index));
    }

    if ((position.pixels - target).abs() < 0.5) {
      focusTarget();
    } else if (duration == Duration.zero) {
      position.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) => focusTarget());
    } else {
      position
          .animateTo(target, duration: duration, curve: AppMotion.scrollCurve)
          .then((_) => focusTarget());
    }
  }

  PlayLine? get _line {
    if (_detail.lines.isEmpty) return null;
    final index = _lineIndex.clamp(0, _detail.lines.length - 1);
    return _detail.lines[index];
  }

  Episode? get _episode {
    final line = _line;
    if (line == null || line.episodes.isEmpty) return null;
    final index = _episodeIndex.clamp(0, line.episodes.length - 1);
    return line.episodes[index];
  }

  /// 路由观察订阅标记（didChangeDependencies 可能多次触发）。
  bool _routeSubscribed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeSubscribed) {
      _routeSubscribed = true;
      kRouteObserver.subscribe(
        this,
        ModalRoute.of(context)! as ModalRoute<dynamic>,
      );
    }
    if (_booted) return;
    _booted = true;
    final controller = context.read<AppController>();
    final library = context.read<LibraryStore>();
    _site =
        widget.site ??
        controller.siteByKey(widget.vod.sourceKey) ??
        controller.selectedSite;
    // 以共享库中的值为准：调用方传入的 resume 可能是在进入详情前生成的
    // 快照，而播放器会在返回前更新同一条历史。
    _resume = library.historyFor(widget.vod) ?? widget.resume;
    // FOCUS-06：从列表/首页进入详情时，hero 操作区（`autofocus`）在本页
    // 第一帧就已经挂上树并拿到焦点；只有在从播放页返回、页面被重建的场景
    // 下焦点才会掉到别处，这里才补一次投递（`_claimEntryFocus` 会先判断
    // 是否已在本页子树里，避免每次都抢）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _claimEntryFocus();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadDetail();
    });
  }

  /// 从播放器/设置等子路由返回：先刷新共享库里的续播快照，再重投落点，
  /// 避免焦点停在路由 scope 上（死焦点：方向键全失灵，真机复现）。
  @override
  void didPopNext() {
    _refreshResume();
    _claimEntryFocus();
  }

  /// 播放页在 dispose/切集时会同步更新 [LibraryStore] 的内存状态。详情页
  /// 不能继续使用进入时的旧快照，否则「继续播放」文案、第一集入口和下次
  /// 播放位置都会落后一次。仅在值确实变化时 setState，避免每次 pop 都重建
  /// 整个详情页。
  void _refreshResume() {
    final fresh = context.read<LibraryStore>().historyFor(widget.vod);
    if (_sameResume(_resume, fresh)) return;
    setState(() {
      _resume = fresh;
      _applyResumeSelection();
    });
    _scrollEpisodesTo(_episodeIndex);
  }

  bool _sameResume(HistoryEntry? a, HistoryEntry? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return stableKey(a.vod) == stableKey(b.vod) &&
        a.lineName == b.lineName &&
        a.lineIndex == b.lineIndex &&
        a.episodeName == b.episodeName &&
        a.episodeUrl == b.episodeUrl &&
        a.episodeIndex == b.episodeIndex &&
        a.positionMs == b.positionMs &&
        a.durationMs == b.durationMs &&
        a.updatedAt == b.updatedAt;
  }

  Future<void> _loadDetail() async {
    final site = _site;
    if (site == null || widget.vod.id.isEmpty) {
      setState(() => _error = '缺少站点信息，无法加载详情');
      return;
    }
    final token = ++_requestToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await context.read<AppController>().siteApi.detail(
        site,
        widget.vod.id,
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        _detail = detail.copyWith(
          pic: detail.pic.isEmpty ? widget.vod.pic : detail.pic,
        );
        _loading = false;
        _applyResumeSelection();
      });
      // 详情与推荐是异步补齐的：hero 播放按钮的 `autofocus` 只在挂载时
      // 生效，首帧若还没有操作区，焦点会落到别处。数据到了以后补投一次，
      // 让首帧之后到达的内容有明确落点（FOCUS-06）。
      _claimEntryFocus();
      // 续播定位：把选集网格滚到续播那一集（千集懒加载下选中集默认在首屏
      // 之外，这里按 `_applyResumeSelection` 选出的 index 跳过去）。
      _scrollEpisodesTo(_episodeIndex);
      _loadRelated();
    } catch (error) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = _friendly(error);
      });
      // 出错时操作区可能是空的（没有剧集），把焦点收到播放按钮兜底。
      _claimEntryFocus();
    }
  }

  /// 原始异常转中文可操作文案（对照 site_api 的 `_friendlyError`）。
  String _friendly(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    return '$message\n请检查网络后重试，或切换站点。';
  }

  Future<void> _loadRelated() async {
    final site = _site;
    final typeId = _detail.typeId;
    if (site == null || typeId.isEmpty) return;
    setState(() => _relatedLoading = true);
    try {
      final data = await context.read<AppController>().siteApi.category(
        site,
        typeId,
        1,
      );
      if (!mounted) return;
      setState(() {
        _related = data.videos
            .where((vod) => vod.id != _detail.id)
            .take(14)
            .toList();
        _relatedLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _relatedLoading = false);
    }
  }

  void _applyResumeSelection() {
    final resume = _resume;
    if (_detail.lines.isEmpty) {
      _lineIndex = 0;
      _episodeIndex = 0;
      return;
    }
    if (resume == null) {
      final directLine = _detail.lines.indexWhere(
        (line) => line.episodes.any((episode) => episode.isDirectVideo),
      );
      _lineIndex = directLine >= 0 ? directLine : 0;
      _episodeIndex = 0;
      return;
    }
    var lineIndex = _detail.lines.indexWhere((e) => e.name == resume.lineName);
    if (lineIndex < 0) {
      lineIndex = resume.lineIndex.clamp(0, _detail.lines.length - 1);
    }
    _lineIndex = lineIndex;
    final episodes = _detail.lines[_lineIndex].episodes;
    if (episodes.isEmpty) {
      _episodeIndex = 0;
      return;
    }
    var episodeIndex = episodes.indexWhere((e) => e.url == resume.episodeUrl);
    if (episodeIndex < 0) {
      episodeIndex = resume.episodeIndex.clamp(0, episodes.length - 1);
    }
    _episodeIndex = episodeIndex;
  }

  void _selectLine(int index) {
    if (index == _lineIndex) return;
    // 选中胶囊的焦点由 `TvFocusable` 自己保住；唯一需要修的是剧集网格
    // 换了数据后，当前焦点元素可能被挤出视口。
    setState(() {
      _lineIndex = index;
      _episodeIndex = 0;
    });
    _ensureFocusVisibleNextFrame();
    // 切线路后选集网格回到第一集所在行（新线路的选集从头看）。
    _scrollEpisodesTo(0);
  }

  void _play() {
    final line = _line;
    final episode = _episode;
    if (line == null || episode == null) {
      showAppSnack(context, '该影片暂时没有可播放的剧集', error: true);
      return;
    }
    // 只有历史记录的线路与集都对得上当前选择，才从记忆位置续播
    // （切线路后 lineName/URL 都对不上，从头开始）。
    var startPosition = 0;
    final resume = _resume;
    if (resume != null &&
        resume.lineName == line.name &&
        resume.episodeUrl == episode.url) {
      startPosition = resume.positionMs;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              vod: _detail,
              site: _site!,
              lineIndex: _lineIndex,
              episodeIndex: _episodeIndex,
              startPositionMs: startPosition,
            ),
          ),
        )
        .then((_) {
          // 从播放页返回时把焦点还给触发按钮（AGENTS.md §3.3）。操作区
          // 在首帧就挂上这个节点，所以这里直接投递，不靠下一次 autofocus。
          if (!mounted) return;
          // 播放页会写历史（进度/集数），返回后重读一遍，让「继续播放」
          // 标签、选集定位与下次起播位置跟上最新值；没有历史时也允许清空
          // 旧快照，不能用旧值回填。
          _refreshResume();
          _focusSoon(_playFocus);
        });
  }

  void _playEpisode(int index) {
    setState(() => _episodeIndex = index);
    _play();
  }

  Future<void> _toggleFavorite() async {
    final library = context.read<LibraryStore>();
    final added = await library.toggleFavorite(_detail);
    if (!mounted) return;
    showAppSnack(context, added ? '已加入收藏' : '已取消收藏');
  }

  @override
  void dispose() {
    kRouteObserver.unsubscribe(this);
    _playFocus.dispose();
    _backFocus.dispose();
    _retryFocus.dispose();
    _restartFocus.dispose();
    _favoriteFocus.dispose();
    _infoFocus.dispose();
    _scroll.dispose();
    for (final node in _lineNodes.values) {
      node.dispose();
    }
    _relatedRowFocus.dispose();
    _relatedScroll.dispose();
    _lastRelatedIndex.dispose();
    for (final node in _relatedNodes.values) {
      node.dispose();
    }
    _relatedNodes.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final library = context.watch<LibraryStore>();
    final favorite = library.isFavorite(_detail);
    // 操作区/面板统一左右内缩 8：让获焦放大 1.03–1.05× 的按钮不贴
    // 内容列边（1120 - 2×8 仍在 48 视觉安全区内，AGENTS.md §4）。
    const hPad = TvCanvas.detailPad;
    final inset = hPad - _EpisodesPanel._inset;
    final resume = _resume;
    final line = _line;
    final pic = _detail.pic;

    // 详情页双栏首屏 → 分集区（线路胶囊 + 选集网格）→ 相关推荐。
    // 氛围背景由 DetailBackdrop 提供，内容与焦点顺序保持三套皮肤一致。
    return FocusTraversalGroup(
      // FOCUS-02：整页按阅读顺序（hero → 简介 → 线路 → 选集 → 推荐）
      // 分组遍历（Tab 语义）。方向键不走几何：页面根 Focus 的
      // _handlePageKey 按文件头的投递表显式分发，组件只消费行/网格内部键。
      child: Focus(
        canRequestFocus: false,
        debugLabel: 'detailPageKeys',
        onKeyEvent: _handlePageKey,
        child: Scaffold(
          backgroundColor: skin.bg,
          body: AppBackground(
            wallpaper: context.watch<AppController>().wallpaper,
            child: DetailBackdrop(
              imageUrl: pic,
              child: Stack(
                children: [
                  CustomScrollView(
                    controller: _scroll,
                    physics: const ClampingScrollPhysics(),
                    scrollCacheExtent: const ScrollCacheExtent.pixels(
                      kTvListCacheExtent,
                    ),
                    slivers: [
                      // —— 详情首屏：左侧海报与片名，右侧元信息、操作和简介。
                      // 背景仍由 DetailBackdrop 提供氛围图；清晰内容不再被一张
                      // 满版剧照切成上下两段，电视端的阅读顺序更明确。
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            inset,
                            skin.spaceLg,
                            inset,
                            0,
                          ),
                          child: _DetailLead(
                            vod: _detail,
                            site: _site,
                            resume: resume,
                            line: line,
                            favorite: favorite,
                            error: _error,
                            retryFocusNode: _retryFocus,
                            playFocusNode: _playFocus,
                            restartFocusNode: _restartFocus,
                            favoriteFocusNode: _favoriteFocus,
                            infoFocusNode: _infoFocus,
                            expanded: _descExpanded,
                            onRetry: _loadDetail,
                            onPlay: _play,
                            onRestart: () {
                              setState(() => _episodeIndex = 0);
                              _play();
                            },
                            onFavorite: _toggleFavorite,
                            onToggleInfo: () =>
                                setState(() => _descExpanded = !_descExpanded),
                          ),
                        ),
                      ),
                      // —— 分集区：线路胶囊 + 选集网格（焦点投递逻辑不变，
                      // §3 规则 7；EpisodeSelector 冻结只复用）。 ——
                      if (line != null) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              inset,
                              skin.spaceMd - 1,
                              inset,
                              0,
                            ),
                            child: _EpisodesPanel(
                              key: _linesKey,
                              lines: _detail.lines,
                              lineIndex: _lineIndex,
                              resume: resume,
                              onLine: _selectLine,
                              onEnterEpisodes: _enterEpisodes,
                              lineNode: _lineNode,
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              inset,
                              skin.spaceSm - 1,
                              inset,
                              0,
                            ),
                            child: _EpisodesGrid(
                              selectorKey: _episodeGridKey,
                              episodes: line.episodes,
                              lineName: line.name,
                              episodeIndex: _episodeIndex,
                              resume: resume,
                              onEpisode: _playEpisode,
                              onExitUp: _exitEpisodes,
                              onExitDown: _focusRelatedMemory,
                              onSelect: (index) =>
                                  setState(() => _episodeIndex = index),
                            ),
                          ),
                        ),
                      ] else if (!_loading)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              inset,
                              skin.spaceMd - 1,
                              inset,
                              0,
                            ),
                            child: _InlineNote(
                              icon: Icons.link_off_rounded,
                              iconColor: skin.textMuted,
                              message: _detail.hasPlayLines
                                  ? '播放列表暂时为空'
                                  : '没有解析到播放地址，可尝试切换其他站点搜索此片。',
                              messageStyle: AppText.of(context).bodyStrong
                                  .copyWith(color: skin.textMuted),
                            ),
                          ),
                        ),
                      // —— 相关推荐横向行 ——
                      if (_related.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            // 相关推荐横向行也用同一个 inset：卡片获焦放大
                            // 1.06× 后不贴内容列边（AGENTS.md §4）。
                            padding: EdgeInsets.fromLTRB(
                              inset,
                              skin.spaceLg,
                              inset,
                              0,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SectionHeader(
                                  title: '相关推荐',
                                  subtitle: _detail.typeName,
                                  padding: EdgeInsets.zero,
                                ),
                                SizedBox(height: skin.spaceSm + 2),
                                FocusTraversalGroup(
                                  // FOCUS-02：推荐行自成一组（Tab 语义）。
                                  // 方向键不走几何：行根的 onKeyEvent 显式
                                  // 处理 LEFT/RIGHT（记忆项投递 + 边界吞），
                                  // UP/DOWN 放行给页面投递表（回网格/吞底）。
                                  child: SizedBox(
                                    key: _relatedRowKey,
                                    // 232 容纳 2:3 海报 + 两行标题（§2.7），
                                    // 加 2×10 纵向呼吸给获焦放大与光晕（§3
                                    // FOCUS-01）：不贴分区标题，也不压下个区块。
                                    height: 232 + (skin.spaceSm + 2) * 2,
                                    // FOCUS-07：行根焦点包在 ListView 外层，
                                    // `false→true` 即「焦点从行外进入」，此时把
                                    // 焦点投回记忆项（`_lastRelatedIndex`）。
                                    child: Focus(
                                      focusNode: _relatedRowFocus,
                                      skipTraversal: true,
                                      onKeyEvent: (_, event) {
                                        if (event is! KeyDownEvent) {
                                          return KeyEventResult.ignored;
                                        }
                                        final key = event.logicalKey;
                                        if (key ==
                                            LogicalKeyboardKey.arrowLeft) {
                                          _moveRelatedBy(-1);
                                          return KeyEventResult.handled;
                                        }
                                        if (key ==
                                            LogicalKeyboardKey.arrowRight) {
                                          _moveRelatedBy(1);
                                          return KeyEventResult.handled;
                                        }
                                        // UP/DOWN 放行给页面投递表。
                                        return KeyEventResult.ignored;
                                      },
                                      child: ListView.separated(
                                        controller: _relatedScroll,
                                        scrollDirection: Axis.horizontal,
                                        physics: const ClampingScrollPhysics(),
                                        scrollCacheExtent:
                                            const ScrollCacheExtent.pixels(
                                              kTvListCacheExtent,
                                            ),
                                        // 左右各留 spaceSm + 2：首末卡片获焦放大
                                        // 与光晕不出内容列（AGENTS.md §4）。
                                        padding: EdgeInsets.symmetric(
                                          horizontal: skin.spaceSm + 2,
                                          vertical: skin.spaceSm + 2,
                                        ),
                                        itemCount: _related.length,
                                        separatorBuilder: (_, _) =>
                                            SizedBox(width: skin.spaceSm + 2),
                                        itemBuilder: (context, index) {
                                          final vod = _related[index];
                                          return SizedBox(
                                            // 132 宽 → 2:3 海报约 198 高，加两行
                                            // 文字刚好落在 232 的行高里。
                                            width: 132,
                                            child: PosterCard(
                                              vod: vod,
                                              // 获焦写记忆（行内移动）+
                                              // 返回还焦（FOCUS-02/07）。
                                              focusNode: _relatedNodeAt(index),
                                              onFocusChange: (focused) {
                                                if (focused) {
                                                  _lastRelatedIndex.value =
                                                      index;
                                                }
                                              },
                                              onTap: () =>
                                                  _openRelated(vod, index),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (_relatedLoading)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.only(top: skin.spaceLg),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: skin.spaceXl + skin.spaceMd),
                      ),
                    ],
                  ),
                  Positioned(
                    // 画布 padding 已由 TvCanvas 置零：16 就是离屏幕上边缘 16
                    // （旧写法拿 MediaQuery.paddingOf 当状态栏高度用，在画布里
                    // 恒为 0）。左右 16 落在内容列（80）外侧的黑边上，两个按钮
                    // 本体 48，不与 1120 的内容列抢边距（AGENTS.md §4）。
                    // 没有 SafeArea：画布模式下 padding 恒为 0，加了也是空操作。
                    top: skin.spaceMd,
                    left: skin.spaceMd,
                    child: _RoundButton(
                      icon: Icons.arrow_back_rounded,
                      focusNode: _backFocus,
                      onTap: () => Navigator.maybePop(context),
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
}

/// 详情页首屏双栏 lead：左边保留完整 2:3 海报并承载片名，右边集中展示
/// 元信息、主操作和剧情简介。清晰封面不再铺成横幅；氛围图仍由
/// [DetailBackdrop] 统一绘制在内容下方。
class _DetailLead extends StatelessWidget {
  const _DetailLead({
    required this.vod,
    required this.site,
    required this.resume,
    required this.line,
    required this.favorite,
    required this.error,
    required this.retryFocusNode,
    required this.playFocusNode,
    required this.restartFocusNode,
    required this.favoriteFocusNode,
    required this.infoFocusNode,
    required this.expanded,
    required this.onRetry,
    required this.onPlay,
    required this.onRestart,
    required this.onFavorite,
    required this.onToggleInfo,
  });

  final VodItem vod;
  final SiteConfig? site;
  final HistoryEntry? resume;
  final PlayLine? line;
  final bool favorite;
  final String? error;
  final FocusNode retryFocusNode;
  final FocusNode playFocusNode;
  final FocusNode restartFocusNode;
  final FocusNode favoriteFocusNode;
  final FocusNode infoFocusNode;
  final bool expanded;
  final VoidCallback onRetry;
  final VoidCallback onPlay;
  final VoidCallback onRestart;
  final VoidCallback onFavorite;
  final VoidCallback onToggleInfo;

  static const double posterWidth = 256;
  static const double posterHeight = posterWidth * 1.5;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final selectedLine = line;
    final resumeLabel =
        resume != null && line != null && resume!.lineName == line!.name
        ? '继续播放  ${resume!.episodeName}'
        : null;
    final showRestart =
        resume != null &&
        selectedLine != null &&
        resume!.lineName == selectedLine.name &&
        resume!.lineIndex == vod.lines.indexOf(selectedLine);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: posterWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(skin.radiusMd),
                child: SizedBox(
                  width: posterWidth,
                  height: posterHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetworkPoster(url: vod.pic, radius: skin.radiusMd),
                      if (vod.score.isNotEmpty)
                        Positioned(
                          top: skin.spaceSm,
                          right: skin.spaceSm,
                          child: _ScoreChip(score: vod.score),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: skin.spaceMd),
              Text(
                vod.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.display.copyWith(
                  // 左栏标题收至 30px：为两行片名留出呼吸，同时维持主标题层级。
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: skin.textPrimary,
                ),
              ),
              if (vod.subtitle.isNotEmpty || vod.remarks.isNotEmpty) ...[
                SizedBox(height: skin.spaceXs),
                Text(
                  vod.subtitle.isNotEmpty ? vod.subtitle : vod.remarks,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.body.copyWith(color: skin.textMuted),
                ),
              ],
            ],
          ),
        ),
        SizedBox(width: skin.spaceXl),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: skin.spaceSm,
                runSpacing: skin.spaceSm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SiteBadge(
                    label: site?.name ?? vod.sourceName,
                    icon: Icons.dns_rounded,
                  ),
                  if (vod.typeName.isNotEmpty) _MetaChip(text: vod.typeName),
                  if (vod.year.isNotEmpty)
                    _Meta(icon: Icons.calendar_today_rounded, text: vod.year),
                  if (vod.area.isNotEmpty)
                    _Meta(icon: Icons.public_rounded, text: vod.area),
                  if (vod.lang.isNotEmpty)
                    _Meta(icon: Icons.translate_rounded, text: vod.lang),
                  if (vod.remarks.isNotEmpty)
                    _Meta(
                      icon: Icons.update_rounded,
                      text: vod.remarks,
                      color: skin.warning,
                    ),
                ],
              ),
              if (vod.actor.isNotEmpty) ...[
                SizedBox(height: skin.spaceMd),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.person_rounded,
                      size: AppText.bodySize,
                      color: skin.textMuted,
                    ),
                    SizedBox(width: skin.spaceXs),
                    Expanded(
                      child: Text(
                        '主演  ${vod.actor}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.body.copyWith(
                          color: skin.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (error != null) ...[
                SizedBox(height: skin.spaceMd),
                _InlineNote(
                  icon: Icons.warning_amber_rounded,
                  iconColor: skin.danger,
                  tint: skin.danger.withValues(alpha: 0.16),
                  message: error!,
                  messageStyle: text.body.copyWith(color: skin.textSecondary),
                  action: TvFocusable(
                    radius: skin.radiusPill,
                    focusNode: retryFocusNode,
                    semanticLabel: '重试',
                    onTap: onRetry,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: skin.spaceSm + 2,
                        vertical: skin.spaceXs - 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.refresh_rounded,
                            size: 16,
                            color: skin.accent,
                          ),
                          SizedBox(width: skin.spaceXs - 1),
                          Text(
                            '重试',
                            style: text.bodyStrong.copyWith(color: skin.accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              SizedBox(height: skin.spaceLg),
              _HeroActions(
                vod: vod,
                focusNode: playFocusNode,
                restartFocusNode: restartFocusNode,
                favoriteFocusNode: favoriteFocusNode,
                hasEpisode: line?.episodes.isNotEmpty ?? false,
                resumeLabel: resumeLabel,
                onPlay: onPlay,
                showRestart: showRestart,
                onRestart: onRestart,
                favorite: favorite,
                onFavorite: onFavorite,
              ),
              SizedBox(height: skin.spaceLg),
              _InfoPanel(
                vod: vod,
                focusNode: infoFocusNode,
                expanded: expanded,
                onToggle: onToggleInfo,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// hero 操作行（izuko「圆钮行 + 播放按钮」的本仓表达）：
/// 立即播放（主按钮，入口焦点）→ 第一集（续播时）→ 收藏。
///
/// 方向键不走几何、也没有行级拦截：三个按钮的 LEFT/RIGHT 行内移动与
/// 「行尾 RIGHT → 选集网格」「行首 LEFT → 吞」全部由页面投递表
/// （`_handlePageKey`）显式处理，组件只负责把外部焦点节点接到按钮上。
class _HeroActions extends StatelessWidget {
  const _HeroActions({
    required this.vod,
    required this.focusNode,
    required this.restartFocusNode,
    required this.favoriteFocusNode,
    required this.hasEpisode,
    required this.resumeLabel,
    required this.onPlay,
    required this.showRestart,
    required this.onRestart,
    required this.favorite,
    required this.onFavorite,
  });

  final VodItem vod;
  final FocusNode focusNode;
  final FocusNode restartFocusNode;
  final FocusNode favoriteFocusNode;
  final bool hasEpisode;
  final String? resumeLabel;
  final VoidCallback onPlay;
  final bool showRestart;
  final VoidCallback onRestart;
  final bool favorite;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return Row(
      children: [
        _PlayButton(
          hasEpisode: hasEpisode,
          resumeLabel: resumeLabel,
          focusNode: focusNode,
          onTap: onPlay,
        ),
        if (showRestart) ...[
          SizedBox(width: skin.spaceSm - 2),
          _RestartButton(focusNode: restartFocusNode, onTap: onRestart),
        ],
        SizedBox(width: skin.spaceSm - 2),
        _FavoriteButton(
          favorite: favorite,
          focusNode: favoriteFocusNode,
          onTap: onFavorite,
        ),
      ],
    );
  }
}

/// hero 播放主按钮。皮肤强调色 + 皮肤焦点语言（AGENTS.md §2.8），
/// `autofocus` 让进页焦点直接落在它上面（FOCUS-06）。
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.hasEpisode,
    required this.resumeLabel,
    required this.focusNode,
    required this.onTap,
  });

  final bool hasEpisode;
  final String? resumeLabel;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final scale = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusSm,
      focusNode: focusNode,
      autofocus: true,
      semanticLabel: resumeLabel ?? '立即播放',
      // 常传 onTap（不因 hasEpisode 置 null）：禁用态只改视觉；若传 null，
      // TvFocusable 会消费 select/enter 后空转，OK 键零反馈（detail_deep P2-2）。
      onTap: onTap,
      child: Container(
        height: skin.spaceXl + skin.spaceSm,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: skin.spaceLg),
        decoration: BoxDecoration(
          // 按钮主题化到皮肤强调色上（smartisan 的 accent 是亮色，
          // 配 textOnAccent 才读得出字）。
          gradient: hasEpisode ? skin.accentGradient : null,
          color: hasEpisode ? null : skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_arrow_rounded,
              size: 24,
              color: hasEpisode ? skin.textOnAccent : skin.textMuted,
            ),
            SizedBox(width: skin.spaceXs),
            Flexible(
              child: Text(
                resumeLabel ?? '立即播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: scale.bodyLarge.copyWith(
                  fontWeight: FontWeight.w700,
                  color: hasEpisode ? skin.textOnAccent : skin.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// hero 次按钮「第一集」：描边按钮，只有历史记录对应当前线路时才出现。
class _RestartButton extends StatelessWidget {
  const _RestartButton({required this.focusNode, required this.onTap});

  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final scale = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusSm,
      focusNode: focusNode,
      semanticLabel: '第一集',
      onTap: onTap,
      child: Container(
        height: skin.spaceXl + skin.spaceSm,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: skin.spaceMd),
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusSm),
          border: Border.all(color: skin.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.replay_rounded, size: 20, color: skin.textPrimary),
            SizedBox(width: skin.spaceXs),
            Text(
              '第一集',
              style: scale.bodyLarge.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// hero 收藏按钮（izuko 圆钮行的收藏胶囊）：与播放行同高、图标 + 文案，
/// 激活态图标/描边走皮肤强调色（已裁决例外②同款语义）。
class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({
    required this.favorite,
    required this.focusNode,
    required this.onTap,
  });

  final bool favorite;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final scale = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusSm,
      focusNode: focusNode,
      semanticLabel: favorite ? '取消收藏' : '收藏',
      onTap: onTap,
      child: Container(
        height: skin.spaceXl + skin.spaceSm,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: skin.spaceMd),
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusSm),
          border: Border.all(color: favorite ? skin.accent : skin.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 20,
              color: favorite ? skin.accent : skin.textSecondary,
            ),
            SizedBox(width: skin.spaceXs),
            Text(
              favorite ? '已收藏' : '收藏',
              style: scale.bodyLarge.copyWith(
                fontWeight: FontWeight.w600,
                color: favorite ? skin.accent : skin.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.focusNode,
    required this.onTap,
  });

  final IconData icon;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return TvFocusable(
      radius: skin.radiusPill,
      focusNode: focusNode,
      semanticLabel: '返回',
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          // 浮层按钮压在剧照/封面上，底色固定黑色系半透明，
          // 不跟皮肤（亮色皮肤的白按钮在图上看不见）。
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Icon(icon, size: 23, color: Colors.white),
      ),
    );
  }
}

class _EpisodesPanel extends StatelessWidget {
  const _EpisodesPanel({
    super.key,
    required this.lines,
    required this.lineIndex,
    required this.resume,
    required this.onLine,
    required this.onEnterEpisodes,
    required this.lineNode,
  });

  /// 获焦放大的安全内缩。页面用它把内容列从 1120 收到 1104，
  /// 让放大的胶囊/按钮不贴边（AGENTS.md §4）。
  static const double _inset = 8.0;

  final List<PlayLine> lines;
  final int lineIndex;
  final HistoryEntry? resume;
  final ValueChanged<int> onLine;
  final VoidCallback onEnterEpisodes;
  final FocusNode Function(int) lineNode;

  @override
  Widget build(BuildContext context) {
    final line = lines[lineIndex];
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return _FlushPanel(
      radius: skin.radiusLg,
      // 面板左右内缩 _inset 给获焦胶囊留位（AGENTS.md §4）。
      padding: EdgeInsets.fromLTRB(
        skin.spaceMd - _inset,
        skin.spaceMd - 1,
        skin.spaceMd - _inset,
        skin.spaceLg - 6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 面板头：选集 + 集数 + 「上次看到这里」提示（只跟当前线路
          // 的历史对上才显示）。
          Row(
            children: [
              Icon(
                Icons.format_list_bulleted_rounded,
                size: skin.spaceLg - 6,
                color: skin.accent,
              ),
              SizedBox(width: skin.spaceSm - 2),
              Text(
                '选集',
                style: text.bodyStrong.copyWith(fontWeight: FontWeight.w700),
              ),
              SizedBox(width: skin.spaceSm - 2),
              Text(
                '${line.episodes.length} 集',
                style: text.label.copyWith(color: skin.textMuted),
              ),
              const Spacer(),
              if (resume != null)
                Text('上次看到这里', style: text.label.copyWith(color: skin.warning)),
            ],
          ),
          if (lines.length > 1) ...[
            SizedBox(height: skin.spaceMd - 1),
            FocusTraversalGroup(
              // FOCUS-02：线路胶囊是操作区之后的第一组水平可选项，
              // 单独分组后 RIGHT/LEFT 只在胶囊之间移动，不会一路穿出面板。
              child: SizedBox(
                // 胶囊本体 40 高：内容 34 + 上下各 3 的呼吸，获焦放大不裁字。
                height: skin.spaceLg + skin.spaceMd,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(
                    kTvListCacheExtent,
                  ),
                  addAutomaticKeepAlives: false,
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => SizedBox(width: skin.spaceSm - 2),
                  itemBuilder: (context, index) {
                    final selected = index == lineIndex;
                    // 线路胶囊：选中态走皮肤强调色（smartisan 整块亮色 +
                    // textOnAccent），未选中走 surfaceSubtle + 描边。
                    // DOWN 进选集网格；LEFT/RIGHT 显式行内投递（行首/行尾
                    // 吞掉防几何甩焦点）；UP 放行给页面投递表回简介。
                    return TvFocusable(
                      focusNode: lineNode(index),
                      radius: skin.radiusPill,
                      semanticLabel: lines[index].name,
                      onTap: () => onLine(index),
                      onKeyEvent: (event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowDown) {
                          onEnterEpisodes();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.arrowLeft) {
                          if (index > 0) {
                            _focusCapsule(
                              context,
                              lineNode(index - 1),
                              start: true,
                            );
                          }
                          // 行首 LEFT：详情页全屏路由无处可去，显式吞。
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.arrowRight) {
                          if (index < lines.length - 1) {
                            _focusCapsule(
                              context,
                              lineNode(index + 1),
                              start: false,
                            );
                          }
                          // 行尾 RIGHT：显式吞（行内已无项）。
                          return KeyEventResult.handled;
                        }
                        // UP 放行给页面投递表。
                        return KeyEventResult.ignored;
                      },
                      child: Container(
                        margin: EdgeInsets.symmetric(
                          vertical: skin.spaceXs - 3,
                        ),
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(horizontal: skin.spaceMd),
                        decoration: BoxDecoration(
                          color: selected ? skin.accent : skin.surfaceSubtle,
                          borderRadius: BorderRadius.circular(skin.radiusPill),
                          border: Border.all(
                            color: selected ? skin.accent : skin.borderSoft,
                          ),
                        ),
                        child: Text(
                          lines[index].name,
                          style: text.body.copyWith(
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected
                                ? skin.textOnAccent
                                : skin.textSecondary,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 保留详情原有固定高度，区间和组内滚动交给共享组件管理。
class _EpisodesGrid extends StatelessWidget {
  const _EpisodesGrid({
    required this.episodes,
    required this.lineName,
    required this.episodeIndex,
    required this.resume,
    required this.onEpisode,
    required this.onSelect,
    required this.selectorKey,
    required this.onExitUp,
    required this.onExitDown,
  });

  final List<Episode> episodes;
  final String lineName;
  final int episodeIndex;
  final HistoryEntry? resume;
  final ValueChanged<int> onEpisode;

  /// 选中某集（`setState` 在页面层做，网格不持有状态）。
  final ValueChanged<int> onSelect;

  /// 续播与线路切换使用原始索引定位共享组件。
  final GlobalKey<EpisodeSelectorState> selectorKey;
  final VoidCallback onExitUp;

  /// 末行 DOWN 的出口（页面层：相关推荐行记忆项）。
  final VoidCallback onExitDown;

  // 网格几何是跨皮肤不变量（AGENTS.md §9.1）：固定设计常量，不用间距
  // token 推导——三皮肤 spaceXl 不同（32/36/36）会让列数与格子尺寸漂移
  // （detail_deep P1-1）。右栏保持 7 列，格高 34。
  static const double mainAxisSpacing = 8;
  static const double mainAxisExtent = 34;

  /// 网格四周呼吸（获焦放大/光晕不出槽位，AGENTS.md §3）。
  static const double padding = 4;

  /// 选集网格固定高度：约 5 行（5×34 + 4×8 + 上下 padding），右栏内
  /// 千集只滚这一块。
  static const double gridHeight =
      5 * mainAxisExtent + 4 * mainAxisSpacing + padding * 2;

  @override
  Widget build(BuildContext context) {
    final resumeIndex = resume?.lineName == lineName
        ? episodes.indexWhere(
            (episode) =>
                episode.url == resume!.episodeUrl ||
                episode.name == resume!.episodeName,
          )
        : -1;
    return SizedBox(
      height: gridHeight,
      child: EpisodeSelector(
        key: selectorKey,
        dataKey: lineName,
        episodes: episodes,
        selectedIndex: episodeIndex,
        onExitUp: onExitUp,
        onExitDown: onExitDown,
        resumeIndex: resumeIndex,
        onSelected: (index) {
          onSelect(index);
          onEpisode(index);
        },
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.vod,
    required this.focusNode,
    required this.expanded,
    required this.onToggle,
  });

  final VodItem vod;
  final FocusNode focusNode;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final content = vod.content.trim();
    return TvFocusable(
      radius: skin.radiusLg,
      focusNode: focusNode,
      // 简介做一整块可获焦控件（需求 7）：OK 展开/收起，语义标签「简介」。
      semanticLabel: '简介',
      onTap: onToggle,
      child: Builder(
        builder: (context) {
          // 获焦反白态（smartisan 整块换蓝 + 内容反白）：`TvFocusable` 的
          // fill 画在子内容之下，这里读 `TvFocusTint` 让出实色底、文字/图标
          // 切 `textOnAccent`（widgets_audit P1-3 同款）。
          final tinted = TvFocusTint.of(context);
          final titleColor = tinted ? skin.textOnAccent : skin.textPrimary;
          final bodyColor = tinted ? skin.textOnAccent : skin.textSecondary;
          final hintColor = tinted ? skin.textOnAccent : skin.textMuted;
          final iconColor = tinted ? skin.textOnAccent : skin.accent;

          final body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.notes_rounded,
                    size: skin.spaceLg - 6,
                    color: iconColor,
                  ),
                  SizedBox(width: skin.spaceSm - 2),
                  Text(
                    '剧情简介',
                    style: text.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: skin.spaceLg - 6,
                    color: hintColor,
                  ),
                ],
              ),
              SizedBox(height: skin.spaceSm - 2),
              if (content.isEmpty)
                Text('暂无简介', style: text.bodyStrong.copyWith(color: hintColor))
              else
                AnimatedCrossFade(
                  duration: AppMotion.duration(context, skin.motionPanel),
                  crossFadeState: expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  // 收起：标题 + 2 行摘要（超出省略）；展开：完整简介 +
                  // 导演/主演（10 英尺外仍可读，AGENTS.md §2.5）。
                  firstChild: Text(
                    content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyStrong.copyWith(
                      height: 1.7,
                      color: bodyColor,
                    ),
                  ),
                  secondChild: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        content,
                        style: text.bodyStrong.copyWith(
                          height: 1.7,
                          color: bodyColor,
                        ),
                      ),
                      if (vod.director.isNotEmpty || vod.actor.isNotEmpty) ...[
                        SizedBox(height: skin.spaceMd - 2),
                        Divider(
                          height: 1,
                          color: tinted
                              ? skin.textOnAccent.withValues(alpha: 0.3)
                              : skin.borderSoft,
                        ),
                        SizedBox(height: skin.spaceSm),
                        if (vod.director.isNotEmpty)
                          _InfoLine(
                            label: '导演',
                            value: vod.director,
                            tinted: tinted,
                          ),
                        if (vod.actor.isNotEmpty)
                          _InfoLine(
                            label: '主演',
                            value: vod.actor,
                            tinted: tinted,
                          ),
                      ],
                    ],
                  ),
                ),
            ],
          );

          final panelPadding = EdgeInsets.fromLTRB(
            skin.spaceLg - 6,
            skin.spaceMd,
            skin.spaceLg - 6,
            skin.spaceMd,
          );
          if (tinted) {
            // 获焦反白：让出实色底（fill 由 TvFocusable 画），只包透明 padding。
            return Padding(padding: panelPadding, child: body);
          }
          return _FlushPanel(
            radius: skin.radiusLg,
            padding: panelPadding,
            child: body,
          );
        },
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.label,
    required this.value,
    this.tinted = false,
  });
  final String label;
  final String value;

  /// 获焦反白态（smartisan）：文字切 `textOnAccent`。
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final labelColor = tinted
        ? skin.textOnAccent.withValues(alpha: 0.82)
        : skin.textMuted;
    final valueColor = tinted ? skin.textOnAccent : skin.textSecondary;
    return Padding(
      padding: EdgeInsets.only(bottom: skin.spaceXs + 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: skin.spaceLg + skin.spaceMd + skin.spaceXs,
            child: Text(label, style: text.body.copyWith(color: labelColor)),
          ),
          Expanded(
            child: Text(
              value,
              style: text.body.copyWith(color: valueColor, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 行内提示（错误横幅 / 空播放列表）。同样零 [BackdropFilter]：
/// 与 [_FlushPanel] 共用「纯色 + 渐变」的玻璃替代方案。
class _InlineNote extends StatelessWidget {
  const _InlineNote({
    required this.icon,
    required this.iconColor,
    required this.message,
    required this.messageStyle,
    this.tint,
    this.action,
  });

  final IconData icon;
  final Color iconColor;
  final String message;
  final TextStyle messageStyle;
  final Color? tint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final material = skin.surfaceSkin;
    final radius = skin.radiusMd + 2;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        gradient: tint == null
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  material.panelFill.withValues(
                    alpha: (material.panelFill.a * 0.7).clamp(0.0, 1.0),
                  ),
                  material.panelFill.withValues(
                    alpha: (material.panelFill.a * 0.5).clamp(0.0, 1.0),
                  ),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: tint ?? material.panelBorder,
          width: material.panelBorderWidth,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceMd,
          vertical: skin.spaceMd - 2,
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            SizedBox(width: skin.spaceSm),
            Expanded(
              child: Text(
                message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: messageStyle,
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// 半透明纯色 + 渐变模拟玻璃的贴面面板，**零 BackdropFilter**。
///
/// 详情页同屏的面板有 3–4 块（错误横幅、选集、简介、空态），全用
/// [SkinSurface] 会在 ios26 皮肤下同时挂 3–4 处模糊（AGENTS.md §5.4 的
/// 预算是 1–2 处）。这里用皮肤自己的 `panelGradient`（没有就用
/// `panelFill` 叠一层向下的白纱）画「玻璃观感」，低端电视盒上零成本。
///
/// `panelGradient` 为 null 的皮肤（netflix / smartisan）自然退回纯色，
/// 与它们的设计语言一致（前者的面板本来就是平的）。
class _FlushPanel extends StatelessWidget {
  const _FlushPanel({required this.child, required this.padding, this.radius});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final material = skin.surfaceSkin;
    final resolvedRadius = radius ?? skin.radiusLg;
    // `panelGradient` 为 null 的皮肤（smartisan / netflix）叠一层「上亮下淡」
    // 的白纱模拟玻璃；有渐变（ios26）的皮肤直接用它。
    final Gradient glass =
        material.panelGradient ??
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0x14FFFFFF),
            material.panelFill.withValues(
              alpha: (material.panelFill.a * 0.82).clamp(0.0, 1.0),
            ),
          ],
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: glass,
        borderRadius: BorderRadius.circular(resolvedRadius),
        border: Border.all(
          color: material.panelBorder,
          width: material.panelBorderWidth,
        ),
        boxShadow: material.panelShadow,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 线路胶囊 LEFT/RIGHT 行内移动的焦点投递：requestFocus 后 ensureVisible，
/// 横向 ListView + 页面纵向滚动都沿祖先链处理。
/// `start: true` 用 keepVisibleAtStart（向左滚），否则 keepVisibleAtEnd。
void _focusCapsule(
  BuildContext context,
  FocusNode target, {
  required bool start,
}) {
  if (!target.canRequestFocus) return;
  target.requestFocus();
  final ctx = target.context;
  if (ctx == null || !ctx.mounted) return;
  Scrollable.ensureVisible(
    ctx,
    alignmentPolicy: start
        ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
        : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    duration: AppMotion.scrollDuration(context),
    curve: AppMotion.scrollCurve,
  );
}

/// 元信息行的小件，颜色跟随当前皮肤。
class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;

  /// 覆盖颜色（如「更新至 X 集」的警示色）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final scale = AppText.of(context);
    final resolved = color ?? skin.textSecondary;
    final iconColor = color ?? skin.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppText.metaSize, color: iconColor),
        SizedBox(width: skin.spaceXs - 2),
        Text(text, style: scale.body.copyWith(color: resolved)),
      ],
    );
  }
}

/// 元信息行的类型小片。
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final scale = AppText.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: skin.spaceSm - 2,
        vertical: skin.spaceXs - 4,
      ),
      decoration: BoxDecoration(
        color: skin.accentSoft,
        borderRadius: BorderRadius.circular(skin.radiusSm - 1),
        border: Border.all(color: skin.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: scale.meta.copyWith(
          color: skin.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 元信息行的评分小片（izuko 的评分徽标：琥珀底深字，PosterCard 同款
/// 配色语义，不随皮肤——评分是跨皮肤恒定的语义色）。
class _ScoreChip extends StatelessWidget {
  const _ScoreChip({required this.score});
  final String score;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final scale = AppText.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: skin.spaceSm - 4,
        vertical: skin.spaceXs - 4,
      ),
      decoration: BoxDecoration(
        color: skin.warning,
        borderRadius: BorderRadius.circular(skin.radiusSm - 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 评分徽标的星与数字：琥珀底上的深字（PosterCard 同款语义色，
          // 压图/压色前景恒深色，与皮肤无关）。
          Icon(Icons.star_rounded, size: AppText.metaSize, color: _scoreInk),
          SizedBox(width: skin.spaceXs - 3),
          Text(
            score,
            style: scale.meta.copyWith(
              color: _scoreInk,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  /// 评分徽标前景（深棕黑，与 PosterCard 的评分角标同值同语义）。
  static const Color _scoreInk = Color(0xFF241300);
}
