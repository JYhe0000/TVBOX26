import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/library_store.dart';
import '../../core/utils.dart';
import '../../data/models.dart';
import '../../data/recommendation_service.dart';
import '../../theme/ui.dart';
import '../pages/detail_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../tv_canvas.dart';
import '../widgets/common.dart';
import '../widgets/home_hero_carousel.dart';
import '../widgets/poster_card.dart';
import '../widgets/shelf_row.dart';
import '../widgets/site_row.dart';
import '../widgets/tv_sheet.dart';

// 首页焦点体系（docs/focus-system-spec.md §4/§5，2026-11-19 重建）。
//
// 方向键投递表（行 = 焦点所在区块 `_HomeZone`，列 = 方向；登记代码在
// `_HomePageState._buildDispatchTable`，每格要么投递、要么边界吞键、
// 要么 pass 放行——不存在「落到默认几何遍历但没测过」的格子）：
//
// | 区块＼方向 | UP | DOWN | LEFT | RIGHT |
// | --- | --- | --- | --- | --- |
// | 页头行 | onExitToNav 壳层通道（表前拦截；无则 pass） | hero CTA（无 hero→「全部」chip） | 行内左移；行首（站点 chip）→ pass 进侧栏 | 行内右移；行尾（设置）吞键 |
// | hero CTA | 站点 chip | 「全部」chip | 轮播翻页（CTA 钩子 `_onHeroCtaKey`，首项 pass→壳层进侧栏） | 轮播翻页（同款钩子） |
// | 分类栏 | hero CTA（无 hero→站点 chip） | 推荐行记忆项（无推荐行→网格首项） | 行内左移；行首「全部」→ pass 进侧栏 | 行内右移；行尾吞键 |
// | 为你推荐 | 「全部」chip | 网格首项 | 行内左移；行首→ pass 进侧栏 | 行内右移；行尾吞键 |
// | 海报网格 | index−列数；首行→推荐行记忆项（无→「全部」） | index+列数；末行以下→吞键（页面底） | index−1；最左列→ pass 进侧栏 | index+1；行尾吞键 |
//
// 要点（spec §3 矩阵）：
// - OK 只由 TvFocusable 消费一次（组件层加固）；方向键组件层 ignored；
// - 行内 LEFT/RIGHT 必须显式投递——壳层根 Focus 拦截一切未消费的
//   LEFT（「内容 → 侧栏」唯一入口），放行 = 跳丢进侧栏（重建前的
//   推荐行/分类栏/网格 LEFT 死键根因）；
// - 网格节点表 `_posterNodes` 按 index 确定性投递（AGENTS.md §3 规则 7，
//   缓存区外的行也能落位）；
// - hero CTA 上 LEFT 翻页是 izuko 行为（非首项），首项放行回壳层进侧栏。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.entryFocus,
    this.siteFocus,
    this.topRequest,
    this.onExitToNav,
  });

  /// 顶栏下键优先聚焦的首张海报。
  final FocusNode? entryFocus;

  /// 首张海报未挂载时，顶栏下键落到页头的站点按钮。
  final FocusNode? siteFocus;

  /// Fires when the top tab bar takes focus; the page scrolls back to the top.
  final ValueListenable<int>? topRequest;

  /// 页头行再按 UP 的退出通道（shell 注入）：把焦点交回导航栏。
  /// 独立挂载（测试/无 shell）时为 null——UP 放行默认遍历兜底。
  final VoidCallback? onExitToNav;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 焦点所在区块（首页方向键投递表的行索引，spec §5；投递表见
/// `_HomePageState._buildDispatchTable` 头注）。页头行 → hero → 分类栏
/// → 为你推荐 → 海报网格，与版式自上而下的顺序一致。
enum _HomeZone { header, hero, chips, shelf, wall }

class _HomePageState extends State<HomePage> {
  final ScrollController _scroll = ScrollController();
  Timer? _clock;
  DateTime _now = DateTime.now();
  AppController? _controller;
  SiteConfig? _site;
  String? _siteKey;
  bool _bound = false;

  /// 记录内容区上次认领的默认落点，避免每次重建都重新投焦。
  FocusNode? _entryOwner;

  /// 热门轮播（hero）当前项下标。页面持有：轮播本体、氛围底层与
  /// 自动轮播计时共用同一份状态。
  final ValueNotifier<int> _heroIndex = ValueNotifier<int>(0);

  /// hero「查看详情」的本地焦点节点（shell 没注入 entryFocus 的独立挂载
  /// 场景用它；shell 场景 entryFocus 直接挂 CTA）。
  final FocusNode _heroCtaFocus = FocusNode(debugLabel: 'home-hero-cta');

  /// 已挂焦点监听的 hero 节点（entryFocus 与本地节点之间切换时重挂）。
  FocusNode? _boundHeroFocus;

  /// 焦点是否在 hero 内（CTA 获焦）：展开信息区 + 启停自动轮播。
  bool _heroExpanded = false;

  /// 自动轮播计时（展开态才存在；减弱动态 / 非当前路由时不启动）。
  Timer? _heroTimer;
  ModalRoute<Object?>? _heroRoute;
  bool _heroReducedMotion = false;

  /// 「为你推荐」横排名的焦点记忆（公共实现 ShelfFocusMemory，spec §4-3）：
  /// 网格首行 UP / 分类栏 DOWN 直接投到记忆项（`home-shelf-memory`）。
  /// itemExtent/separator 在 build 里按皮肤同步（syncSeparator）。
  final ShelfFocusMemory _shelfMemory = ShelfFocusMemory(
    debugLabel: 'home-shelf-memory',
    itemExtent: _kShelfItemExtent,
  );

  /// 分类栏首项「全部」的稳定落点。
  final FocusNode _allChipFocus = FocusNode(debugLabel: 'home-cat-all');

  /// 分类栏其余项（categoryId → 节点）的页面侧记账表（spec §5：分类栏
  /// LEFT/RIGHT 显式投递需要「index → 节点」映射）。itemBuilder 把
  /// ShelfRow 的形参 node 记进来（记忆项形参即受控记忆节点，天然一致）。
  final Map<String, FocusNode> _chipNodes = {};

  /// 「为你推荐」行卡片的页面侧记账表（index → 节点，spec §5：行内
  /// LEFT/RIGHT 显式投递——壳层根 Focus 拦截一切未消费的 LEFT，行内
  /// 放行会被吃掉跳丢进侧栏，所以卡片节点必须由页面持有）。
  final Map<int, FocusNode> _shelfPosterNodes = {};

  /// 网格首项的稳定落点（FOCUS-08）：独立挂载（shell 没传入口节点）时，
  /// 加载完成后网格第一项拿着的落点节点。shell 场景由 shell 注入的
  /// entryFocus 挂同一网格首项，无需本节点。autofocus 在懒加载的 SliverGrid
  /// 里抢不过已获焦的「全部」chip（scope focusedChild 链优先），所以落点
  /// 必须由 _claimEntry 显式投递，而不是靠 autofocus。
  final FocusNode _firstPosterFocus = FocusNode(
    debugLabel: 'home-first-poster',
  );

  /// 页头行「站点 chip」的稳定落点（UP 层级投递的目标）：页头层的
  /// 方向键落点若交给几何遍历，会随焦点列的 x 漂移（审计实证同一排
  /// 五个落点），固定投到这里。
  final FocusNode _localSiteFocus = FocusNode(debugLabel: 'home-site-chip');
  FocusNode get _siteChipFocus => widget.siteFocus ?? _localSiteFocus;

  /// 页头行右侧三个圆形动作的稳定节点（spec §5：页头行 LEFT/RIGHT 显式
  /// 投递——行内放行会被壳层 LEFT 通道吃掉跳丢进侧栏，所以由页面持有）。
  final FocusNode _searchFocus = FocusNode(debugLabel: 'home-header-search');
  final FocusNode _refreshFocus = FocusNode(debugLabel: 'home-header-refresh');
  final FocusNode _settingsFocus = FocusNode(
    debugLabel: 'home-header-settings',
  );

  /// 内容层方向键捕获的根 Focus（skipTraversal，拦截四方向键）。
  /// 子层（网格/分类栏/页头行）按键冒泡到这里查投递表（[FocusDispatchMap]，
  /// spec §5）。页面顶部注释写有全量投递表。
  final FocusNode _navKeyFocus = FocusNode(debugLabel: 'home-nav-key');

  /// 首页方向键投递表（spec §5 显式投递范式的公共实现）。登记的格子
  /// 见页面 build 里的 `_buildDispatchTable()` 与类头投递表注释；
  /// handle 返回 null（未登记/非方向键/焦点缺失）时 ignored 交壳层或
  /// 框架兜底。
  final FocusDispatchMap _dispatch = FocusDispatchMap(
    debugLabel: 'home-dispatch',
  );

  /// 海报网格每个卡片的焦点节点（按 index 持有，detail_page 的
  /// `_relatedNodes` 同款范式）。方向遍历只能看到已挂载且 onstage 的
  /// 节点，缓存区里的行会被几何遍历漏掉（「第 2 行 DOWN 死键」根因）；
  /// 页面侧持有节点后，UP/DOWN 按 index 直接投递（行内同列），不再依赖
  /// 几何遍历找目标。index 0 复用 FOCUS-08 的落点节点（shell 注入的
  /// entryFocus / _firstPosterFocus），与 [_claimEntry] 共用同一节点。
  final Map<int, FocusNode> _posterNodes = {};

  /// 网格第 [index] 项的焦点节点（懒创建；index 0 固定为落点节点，
  /// 不入表、不重复 dispose）。hero 可见时 shell 入口焦点挂在 hero CTA
  /// 上，网格首项退 page 持有的 [_firstPosterFocus]。
  FocusNode _posterNodeAt(int index) {
    if (index == 0) return _wallEntryFocus;
    return _posterNodes.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'home-poster-$index'),
    );
  }

  /// 焦点节点反查 index（只有网格内的节点会参与 UP/DOWN 投递）。
  int? _posterIndexOf(FocusNode node) {
    if (node == _wallEntryFocus) return 0;
    for (final MapEntry<int, FocusNode> entry in _posterNodes.entries) {
      if (entry.value == node) return entry.key;
    }
    return null;
  }

  /// 海报网格列数：与 `SliverGridDelegateWithMaxCrossAxisExtent` 同一公式
  /// （ceil(网格宽 / (maxCrossAxisExtent + 交叉间距))），供 UP/DOWN 按
  /// 「index ± 列数」算同列上/下行。网格宽用设计画布宽减 SliverPadding 的
  /// 左右 pagePad（TvCanvas 固定 1280 画布），token 换成哪个皮肤都成立。
  int get _posterColumns {
    if (_controller?.homeRows == true) return 1;
    final skin = TvSkin.of(context);
    const gridWidth = TvCanvas.designWidth - 2 * TvCanvas.pagePad;
    final stride =
        skin.spaceXl * 7 +
        skin.spaceMd; // maxCrossAxisExtent + crossAxisSpacing
    final columns = (gridWidth / stride).ceil();
    return columns < 1 ? 1 : columns;
  }

  /// 列表被整体替换（切分类/换站点/刷新）后，超出新长度的节点一并释放，
  /// 避免索引映射滞留旧数据。分页追加（_loadMore）不动旧索引，节点保留。
  void _prunePosterNodes() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _posterNodes.removeWhere((index, node) {
        if (index < _videos.length) return false;
        node.dispose();
        return true;
      });
    });
  }

  /// 回收远离当前焦点的网格节点：只保留焦点行 ±2 行（约 3 屏）范围，
  /// 其余且已不在树里（`context == null`）的节点 dispose。焦点逐行移动、
  /// 窗口随焦点滑动；仍挂树的节点一律不杀，避免 Focus 拿着已 dispose
  /// 节点触发框架断言。切分类/换站由 [_prunePosterNodes] 全量兜底。
  void _reclaimPosterNodes(int focusedIndex) {
    if (!mounted) return;
    final keep = _posterColumns * 2;
    for (final entry in _posterNodes.entries.toList()) {
      if ((entry.key - focusedIndex).abs() <= keep) continue;
      final ctx = entry.value.context;
      if (ctx != null && ctx.mounted) continue;
      _posterNodes.remove(entry.key);
      entry.value.dispose();
    }
  }

  /// 顶层是否还停在顶部：在顶部时让位是「加内边距」，离开顶部后收回，
  /// 否则把内容钉在视口顶部、向上的滚动会被 padding 吃掉。
  bool _atTop = true;

  List<CategoryItem> _categories = [];
  Map<String, List<CategoryFilter>> _filters = {};
  final Map<String, String> _filterValues = {};
  List<VodItem> _videos = [];
  List<VodItem> _latestVideos = [];
  bool _historyMode = false;
  bool _recommendMode = false;
  String _categoryId = '';
  int _page = 1;
  int _pageCount = 1;
  int _requestToken = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  SiteConfig? get _currentSite => _controller?.selectedSite ?? _site;

  /// 热门轮播条目：首页「最新上线」的前 [_kHeroMaxItems] 条（豆瓣推荐 /
  /// 观看历史是任务视图，不展示轮播）。
  List<VodItem> get _trending {
    if (_historyMode || _recommendMode) return const <VodItem>[];
    final latest = _latestVideos;
    if (latest.length <= _kHeroMaxItems) return List<VodItem>.of(latest);
    return latest.sublist(0, _kHeroMaxItems);
  }

  /// 「为你推荐」行条目：轮播之后的最新条目（不足整行感知则不渲染，
  /// 避免半行孤卡）。
  List<VodItem> get _shelfItems {
    if (_trending.isEmpty) return const <VodItem>[];
    final rest = _latestVideos
        .skip(_trending.length)
        .take(_kShelfMaxItems)
        .toList(growable: false);
    return rest.length >= _kShelfMinItems ? rest : const <VodItem>[];
  }

  bool get _heroVisible => _trending.isNotEmpty;

  /// hero CTA 的入口焦点：shell 注入的 entryFocus 优先（shell DOWN 落点
  /// 与 FOCUS-06 默认落点共用同一节点）。
  FocusNode get _heroEntryFocus => widget.entryFocus ?? _heroCtaFocus;

  /// 网格首项的入口焦点：hero 可见时被 CTA 占用 entryFocus，网格首项退
  /// [_firstPosterFocus]；hero 不可见时沿用原语义。
  FocusNode get _wallEntryFocus => _heroVisible
      ? _firstPosterFocus
      : (widget.entryFocus ?? _firstPosterFocus);

  /// 幂等挂接 hero CTA 的焦点监听（entryFocus 换人时重挂）。
  void _bindHeroFocus() {
    // 没有轮播时，壳层入口可能挂在网格首项上，不能把它当作 CTA 监听。
    final node = _heroVisible ? _heroEntryFocus : null;
    if (identical(_boundHeroFocus, node)) return;
    _boundHeroFocus?.removeListener(_onHeroFocusChanged);
    _boundHeroFocus = node;
    node?.addListener(_onHeroFocusChanged);
    _heroExpanded = node?.hasPrimaryFocus ?? false;
  }

  void _onHeroFocusChanged() {
    if (!mounted) return;
    final expanded = _boundHeroFocus?.hasPrimaryFocus ?? false;
    if (expanded == _heroExpanded) return;
    setState(() => _heroExpanded = expanded);
    _syncHeroTimer();
  }

  bool get _canAutoAdvanceHero =>
      _heroExpanded &&
      (_boundHeroFocus?.hasPrimaryFocus ?? false) &&
      !_heroReducedMotion &&
      (_heroRoute?.isCurrent ?? true) &&
      _trending.length > 1;

  void _cancelHeroTimer() {
    _heroTimer?.cancel();
    _heroTimer = null;
  }

  /// 焦点、数据、动效偏好及当前路由共同决定轮播是否计时。
  void _syncHeroTimer() {
    if (!_canAutoAdvanceHero) {
      _cancelHeroTimer();
      return;
    }
    if (_heroTimer != null) return;
    final trending = _trending;
    final reading = HomeHeroCarousel.titleReadingDuration(
      context,
      trending[_heroIndex.value % trending.length].name,
    );
    final dwell = reading > _kHeroAutoAdvance ? reading : _kHeroAutoAdvance;
    _heroTimer = Timer(dwell, () {
      _heroTimer = null;
      // 路由入栈与下一帧之间也可能正好到期，重新检查后再切换。
      if (mounted && _canAutoAdvanceHero) _switchHero(1);
    });
  }

  /// 手动 / 自动切换轮播（delta = ±1，循环）。
  void _switchHero(int delta) {
    final count = _trending.length;
    if (count <= 1) return;
    _heroIndex.value = ((_heroIndex.value + delta) % count + count) % count;
    // 手动操作即重置自动轮播计时（izuko：carouselInteraction 作计时 key）。
    _cancelHeroTimer();
    _syncHeroTimer();
  }

  /// hero CTA 上的左右键：手动切换轮播（izuko 同款——第一项按 LEFT
  /// 不翻页，放行给壳层根 Focus 的「LEFT 进侧栏」通道；RIGHT 在最后
  /// 一项循环回第一项）。其余键放行给层级投递。
  KeyEventResult _onHeroCtaKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final count = _trending.length;
    if (count == 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_heroIndex.value % count == 0) {
        // 长按左键翻到首项后停住，再单独按一次左键才进侧栏。
        return event is KeyRepeatEvent || widget.onExitToNav == null
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      _switchHero(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _switchHero(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    widget.topRequest?.addListener(_onTopRequest);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topRequest != widget.topRequest) {
      oldWidget.topRequest?.removeListener(_onTopRequest);
      widget.topRequest?.addListener(_onTopRequest);
    }
  }

  /// 从侧栏或相邻区块返回轮播时，回到能完整显示页头和轮播的首屏。
  void _onTopRequest() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final target = position.minScrollExtent;
    final atTop = (position.pixels - target).abs() <= 0.5;
    // 动画刚开始时滚动像素仍可能在顶部，反向也要取消上一趟滚动。
    if (atTop && !position.isScrollingNotifier.value) return;
    final duration = AppMotion.scrollDuration(context);
    if (atTop || duration == Duration.zero) {
      position.jumpTo(target);
    } else {
      position.animateTo(
        target,
        duration: duration,
        curve: AppMotion.scrollCurve,
      );
    }
  }

  bool get _heroCanReceiveFocus =>
      _heroVisible &&
      mounted0(_heroEntryFocus) &&
      _heroEntryFocus.canRequestFocus;

  /// 轮播是完整的视觉区块；对 CTA 做常规顶对齐会把画面和标题滚出视口。
  /// 表项在这里自行投递，返回 null 让 [FocusDispatchMap] 消费按键。
  Null _focusHero() {
    final target = _heroEntryFocus;
    target.requestFocus();
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(target, _boundHeroFocus)) return;
      if (target.hasPrimaryFocus) _onTopRequest();
    });
    return null;
  }

  /// 焦点所在区块（方向键投递表的行索引，spec §5）：从焦点 context
  /// 沿 element 祖先链找最近的区块包装。返回 null（页头行以外，如警告
  /// 横幅 / 空态按钮）→ 投递表 miss → ignored 框架兜底（与重建前一致）。
  ///
  /// 「为你推荐」行的卡片也是 [PosterCard]：卡片先记为候选 [wall]，
  /// 继续向上找到的 [_RecommendRow] 包装**覆盖**为 [shelf]——推荐行
  /// 的卡片按推荐行的 UP/DOWN/LEFT/RIGHT 语义走，不能当网格卡处理。
  _HomeZone? _zoneOf(BuildContext context) {
    _HomeZone? zone;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is _HomeHeader) {
        zone = _HomeZone.header;
        return false; // 最近的分区包装即区块。
      }
      if (widget is HomeHeroCarousel) {
        zone = _HomeZone.hero;
        return false;
      }
      if (widget is _RecommendRow) {
        zone = _HomeZone.shelf;
        return false;
      }
      if (widget is _CategoryBar) {
        zone = _HomeZone.chips;
        return false;
      }
      if (widget is PosterCard || widget is WideVodCard) {
        // 卡片是候选（网格卡），继续向上找分区包装覆盖判定。
        zone ??= _HomeZone.wall;
        return true;
      }
      return true;
    });
    return zone;
  }

  /// 内容层四方向键分发（spec §5 显式投递范式的公共实现）：区块内未消费
  /// 的方向键冒泡到根 Focus（[_navKeyFocus]），按「区块 × 方向」投递表
  /// 显式派送——每格要么投递（deliverFocusNode）、要么边界吞键（null）、
  /// 要么放行（[FocusDispatchMap.pass] → 壳层 LEFT 通道）。不存在
  /// 「落到默认几何遍历但没测过」的格子（类头投递表注释全量列出）。
  ///
  /// 页头行 UP 是特殊通道（[HomePage.onExitToNav] 壳层回调，非节点
  /// 投递）：在表前拦截——无 shell 的独立挂载（回调为 null）时放行，
  /// 焦点停在页头（框架几何遍历无上方目标，行为不变）。
  KeyEventResult _handleNavKey(FocusNode node, KeyEvent event) {
    // TvFocusable 默认只送 keydown 给 CTA 的钩子。方向长按也走轮播，
    // 同时保留 OK 只响应一次的组件默认行为。
    if (event is KeyRepeatEvent &&
        _heroVisible &&
        _heroEntryFocus.hasPrimaryFocus) {
      final result = _onHeroCtaKey(event);
      if (result != KeyEventResult.ignored) return result;
    }
    // 页头行 UP 特殊通道：壳层回调（非节点投递）。取当前主焦点判区块；
    // 焦点缺失时 _zoneOf 收不到 context，直接放行。
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowUp &&
        focusContext != null &&
        _zoneOf(focusContext) == _HomeZone.header &&
        widget.onExitToNav != null) {
      widget.onExitToNav!();
      return KeyEventResult.handled;
    }
    return _dispatch.handle(event, _zoneOf) ?? KeyEventResult.ignored;
  }

  /// 构建方向键投递表（build 里调；区块结构变化时 clear 后重登，spec
  /// §5「每个格子要么显式投递、要么明确 ignored」）。三态语义见
  /// [FocusDispatchMap] 类文档：节点=投递、null=边界吞键、pass=放行。
  ///
  /// 首页投递表（行 = 焦点所在区块，列 = 方向）：
  ///
  /// | 区块＼方向 | UP | DOWN | LEFT | RIGHT |
  /// | --- | --- | --- | --- | --- |
  /// | 页头行 | onExitToNav 壳层通道（表前拦截；无则 pass） | hero CTA（无 hero→「全部」chip） | 行内左移；行首（站点 chip）→ pass 进侧栏 | 行内右移；行尾（设置）吞键 |
  /// | hero CTA | 站点 chip | 「全部」chip | 轮播翻页（`_onHeroCtaKey`，首项 pass→壳层） | 轮播翻页（同款钩子） |
  /// | 分类栏 | hero CTA（无 hero→站点 chip） | 推荐行记忆项（无推荐行→网格首项） | 行内左移；行首「全部」→ pass 进侧栏 | 行内右移；行尾吞键 |
  /// | 为你推荐 | 「全部」chip | 网格首项 | 行内左移；行首→ pass 进侧栏 | 行内右移；行尾吞键 |
  /// | 海报网格 | index−列数；首行→推荐行记忆项（无→「全部」） | index+列数；末行以下→吞键（页面底） | index−1；最左列→ pass 进侧栏 | index+1；行尾吞键 |
  ///
  /// 未列出的格子（提示横幅 / 空态按钮等非登记区块）→ ignored 框架兜底。
  void _buildDispatchTable() {
    final skin = TvSkin.of(context);
    // 横排项间距跟皮肤同步（ShelfFocusMemory.focusHere 的位置换算用）。
    _shelfMemory.syncSeparator(skin.spaceMd);
    _dispatch.clear();

    // 页头行：[站点 chip, 搜索, 刷新, 设置]。
    _dispatch.bindAll(
      _HomeZone.header,
      down: (_) => _heroCanReceiveFocus
          ? _focusHero()
          : _allChipFocus.canRequestFocus
          ? _allChipFocus
          : FocusDispatchMap.pass,
      left: (f) {
        final nodes = _headerNodes();
        final i = nodes.indexOf(f);
        return i > 0 ? nodes[i - 1] : FocusDispatchMap.pass;
      },
      right: (f) {
        final nodes = _headerNodes();
        final i = nodes.indexOf(f);
        return i >= 0 && i < nodes.length - 1 ? nodes[i + 1] : null;
      },
    );

    // hero CTA：UP → 站点 chip；DOWN → 分类栏「全部」（没有子分类也有「全部」）。
    // LEFT/RIGHT 由 CTA 钩子与根层重复事件统一走 _onHeroCtaKey。
    _dispatch.bindAll(
      _HomeZone.hero,
      up: (_) => _siteChipFocus.canRequestFocus
          ? _siteChipFocus
          : FocusDispatchMap.pass,
      down: (_) =>
          _allChipFocus.canRequestFocus ? _allChipFocus : FocusDispatchMap.pass,
    );

    // 分类栏 chips：节点表 = [全部, ...分类]（记账式，见 _chipNodes）。
    _dispatch.bindAll(
      _HomeZone.chips,
      up: (_) => _heroCanReceiveFocus
          ? _focusHero()
          : _siteChipFocus.canRequestFocus
          ? _siteChipFocus
          : FocusDispatchMap.pass,
      down: (_) => _shelfItems.isNotEmpty
          ? _shelfMemory.focus
          : _videos.isNotEmpty
          ? _posterNodeAt(0)
          : FocusDispatchMap.pass,
      left: (f) {
        final nodes = _chipNodesList();
        final i = nodes.indexOf(f);
        return i > 0 ? nodes[i - 1] : FocusDispatchMap.pass;
      },
      right: (f) {
        final nodes = _chipNodesList();
        final i = nodes.indexOf(f);
        return i >= 0 && i < nodes.length - 1 ? nodes[i + 1] : null;
      },
    );

    // 「为你推荐」行：卡片记账表（_shelfPosterNodes）。
    _dispatch.bindAll(
      _HomeZone.shelf,
      up: (_) => _categories.isNotEmpty && _allChipFocus.canRequestFocus
          ? _allChipFocus
          : FocusDispatchMap.pass,
      down: (_) =>
          _videos.isNotEmpty ? _posterNodeAt(0) : FocusDispatchMap.pass,
      left: (f) {
        final i = _shelfIndexOf(f);
        return i > 0 ? _shelfPosterNodes[i - 1] : FocusDispatchMap.pass;
      },
      right: (f) {
        final i = _shelfIndexOf(f);
        return i >= 0 &&
                i < _shelfItems.length - 1 &&
                _shelfPosterNodes[i + 1] != null
            ? _shelfPosterNodes[i + 1]!
            : null;
      },
    );

    // 海报网格：节点表 _posterNodes（spec §3 规则 7 显式投递）。
    _dispatch.bindAll(
      _HomeZone.wall,
      up: (f) {
        final i = _posterIndexOf(f);
        if (i == null) return FocusDispatchMap.pass;
        final target = i - _posterColumns;
        if (target >= 0) return _posterNodeAt(target);
        return _shelfItems.isNotEmpty
            ? _shelfMemory.focus
            : _categories.isNotEmpty && _allChipFocus.canRequestFocus
            ? _allChipFocus
            : FocusDispatchMap.pass;
      },
      down: (f) {
        final i = _posterIndexOf(f);
        if (i == null) return FocusDispatchMap.pass;
        final target = i + _posterColumns;
        // 末行以下：页面底吞键（null）——焦点原地不动，消费事件防止
        // 框架几何遍历在页尾跳丢（spec §4-4 边界语义）。
        return target < _videos.length ? _posterNodeAt(target) : null;
      },
      left: (f) {
        final i = _posterIndexOf(f);
        if (i == null) return FocusDispatchMap.pass;
        // 最左列 LEFT：pass → 壳层根 Focus 投侧栏当前条目（spec §3
        // 唯一进侧栏入口）；其余列行内左移一格（显式——LEFT 放行会被
        // 壳层吃掉跳丢进侧栏）。
        return i % _posterColumns > 0
            ? _posterNodeAt(i - 1)
            : FocusDispatchMap.pass;
      },
      right: (f) {
        final i = _posterIndexOf(f);
        if (i == null) return FocusDispatchMap.pass;
        // 行尾（含末行不满列）RIGHT：吞键；其余列行内右移一格。
        final atRowEnd =
            i % _posterColumns == _posterColumns - 1 || i == _videos.length - 1;
        return !atRowEnd && i + 1 < _videos.length
            ? _posterNodeAt(i + 1)
            : null;
      },
    );
  }

  /// 页头行的可获焦元素（按视觉顺序）：站点 chip → 搜索 → 刷新 → 设置。
  /// LEFT/RIGHT 在这张表里按下标显式移动。
  List<FocusNode> _headerNodes() => [
    _siteChipFocus,
    _searchFocus,
    _refreshFocus,
    _settingsFocus,
  ];

  /// 分类栏的可获焦元素（按视觉顺序）：「全部」→ 各分类。记账表
  /// [_chipNodes] 由 [_CategoryBar] 的 itemBuilder 写入（键 = 分类 id）。
  List<FocusNode> _chipNodesList() => [
    _allChipFocus,
    for (final category in _categories)
      _chipNodes.putIfAbsent(
        category.id,
        () => FocusNode(debugLabel: 'home-chip-${category.id}'),
      ),
  ];

  /// 焦点节点反查推荐行下标（只有推荐行内的节点参与行内 LEFT/RIGHT）。
  int _shelfIndexOf(FocusNode node) {
    for (final MapEntry<int, FocusNode> entry in _shelfPosterNodes.entries) {
      if (entry.value == node) return entry.key;
    }
    return -1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _heroRoute = ModalRoute.of(context);
    _heroReducedMotion = AppMotion.reduced(context);
    final controller = context.read<AppController>();
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onControllerChanged);
    _controller = controller;
    controller.addListener(_onControllerChanged);
    _siteKey = controller.selectedSite?.key;
    _site = controller.selectedSite;
    if (!_bound) {
      _bound = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadInitial();
      });
    }
  }

  void _onControllerChanged() {
    final key = _controller?.selectedSite?.key;
    if (key != _siteKey) {
      _siteKey = key;
      _site = _controller?.selectedSite;
      _resetAndLoad();
    }
  }

  @override
  void dispose() {
    widget.topRequest?.removeListener(_onTopRequest);
    _controller?.removeListener(_onControllerChanged);
    _clock?.cancel();
    _cancelHeroTimer();
    _boundHeroFocus?.removeListener(_onHeroFocusChanged);
    _heroIndex.dispose();
    _heroCtaFocus.dispose();
    _shelfMemory.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _allChipFocus.dispose();
    _firstPosterFocus.dispose();
    _localSiteFocus.dispose();
    _searchFocus.dispose();
    _refreshFocus.dispose();
    _settingsFocus.dispose();
    _navKeyFocus.dispose();
    for (final node in _posterNodes.values) {
      node.dispose();
    }
    _posterNodes.clear();
    // 推荐行 / 分类栏记账表的形参节点归 ShelfRow 的内部回收表（_nodes）
    // 与受控记忆节点（_shelfMemory）所有——页面只记引用不 dispose
    // （unmount 时父 State 先 dispose，此时 ShelfRow 还活着，提前
    // dispose 会被 ShelfRow 的 dispose 二次释放）。
    _shelfPosterNodes.clear();
    for (final node in _chipNodes.values) {
      // 只有从未挂树的懒建占位节点需要页面回收（挂树形参归 ShelfRow）。
      if (node.context == null && !node.hasFocus) node.dispose();
    }
    _chipNodes.clear();
    super.dispose();
  }

  /// Hands the landing spot (the grid's first poster, or the 「全部」chip while
  /// the grid is not yet mounted) to whichever widget currently owns it, and
  /// frees the previous owner.
  void _claimEntry(FocusNode node) {
    // 焦点在顶栏（shell 的 tab 栏，位于本页 State 之外）时不抢焦：数据到达
    // 后由 shell 的 DOWN 把焦点投进内容，不能异步把顶栏持焦拽回内容区
    // （FOCUS-06/09：默认落点不应覆盖用户当前焦点）。
    final active = FocusManager.instance.primaryFocus;
    // 查询返回时，不打断用户在页头切站点。
    if (_siteChipFocus.hasFocus) return;
    final activeContext = active?.context;
    if (activeContext != null &&
        activeContext.findAncestorStateOfType<_HomePageState>() != this) {
      return;
    }
    if (identical(_entryOwner, node)) return;
    _entryOwner = node;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_entryOwner, node)) return;
      if (FocusManager.instance.primaryFocus != active) return;
      if (node.context != null && node.canRequestFocus) node.requestFocus();
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final offset = _scroll.position.pixels;
    final atTop = offset <= 0.5;
    if (atTop != _atTop) setState(() => _atTop = atTop);
    // 滚动后回收视口外远端节点（焦点行 ±2 行以外、且已不在树里的）。
    final focusedNode = FocusManager.instance.primaryFocus;
    _reclaimPosterNodes(
      focusedNode == null ? 0 : (_posterIndexOf(focusedNode) ?? 0),
    );
    if (offset >= _scroll.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  /// 顶栏焦点是否要让内容让位：只在页面回到顶部时给，滚起来之后让位
  /// 反而会把已经滚走的内容重新钉回视口顶部。
  ///
  /// 让位条件 = 「页头行获焦」或「shell 顶栏获焦」，二者同属顶部导航区：
  /// 焦点在页头行与顶栏之间上下移动时，让位保持一致，页头行不会被顶栏
  /// 遮住、也不会来回滑动（TAB-02 / FOCUS-01）。
  /// 内容是否给悬浮顶栏让位（TAB-02）：只看滚动位置——停在顶部时整条
  /// 页头（品牌字标 + 日期时间 + 站点 chip + 动作）都必须让出顶栏高度，
  /// 与焦点状态无关。旧实现把让位挂在「页头行/顶栏获焦」上，正常浏览
  /// （焦点在网格）时 padding=0，页头行常驻被顶栏盖住（真机复现：顶栏
  /// 盖住 tvbox 字标与时钟行）；焦点式让位只防「跳」，治不了「常驻盖」。
  /// 与 live_page 的 `_yieldTopBar => _gridAtTop` 同一语义。
  bool get _yieldTopBar => _atTop;

  void _resetAndLoad() {
    if (!mounted) return;
    setState(() {
      _videos = [];
      _categories = [];
      _filters = {};
      _filterValues.clear();
      _categoryId = '';
      _page = 1;
      _pageCount = 1;
      _error = null;
    });
    _prunePosterNodes();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    _historyMode = false;
    _recommendMode = false;
    final site = _currentSite;
    if (site == null) {
      setState(() {
        _loading = false;
        _error = '还没有可用站点，请先在设置中加载配置接口';
      });
      return;
    }
    final token = ++_requestToken;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
    });
    try {
      final home = await _controller!.siteApi.home(site);
      if (!mounted || token != _requestToken) return;
      setState(() {
        _categories = home.categories;
        _filters = home.filters;
        _videos = home.videos;
        _latestVideos = home.videos;
        _page = home.page;
        _pageCount = home.pageCount <= 0 ? 1 : home.pageCount;
        _categoryId = '';
        _loading = false;
      });
      // 轮播条目整体换新：下标归零，按新标题重新计时。
      _cancelHeroTimer();
      _heroIndex.value = 0;
      _prunePosterNodes();
    } catch (error) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = _friendly(error);
      });
    }
  }

  Future<void> _refresh() async {
    if (_categoryId.isEmpty) {
      await _loadInitial();
    } else {
      await _loadCategory(_categoryId, reset: true);
    }
  }

  Future<void> _selectCategory(String id) async {
    if (id == _categoryId && !_historyMode && !_recommendMode) return;
    _historyMode = false;
    _recommendMode = false;
    _filterValues.clear();
    if (id.isEmpty) {
      setState(() {
        _categoryId = '';
        _videos = [];
        _error = null;
        _loading = true;
      });
      _prunePosterNodes();
      await _loadInitial();
      return;
    }
    await _loadCategory(id, reset: true);
  }

  Future<void> _loadCategory(String id, {bool reset = false}) async {
    final site = _currentSite;
    if (site == null) return;
    final token = ++_requestToken;
    setState(() {
      _categoryId = id;
      _loading = true;
      _loadingMore = false;
      _error = null;
      _error = null;
      if (reset) {
        _videos = [];
        _page = 1;
      }
    });
    try {
      final data = await _controller!.siteApi.category(
        site,
        id,
        1,
        filters: Map.of(_filterValues),
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        _videos = data.videos;
        _page = data.page <= 0 ? 1 : data.page;
        _pageCount = data.pageCount <= 0 ? 1 : data.pageCount;
        _loading = false;
      });
      _prunePosterNodes();
    } catch (error) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = _friendly(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_historyMode || _recommendMode) return;
    final site = _currentSite;
    if (site == null || _loading || _loadingMore || _error != null) return;
    if (_page >= _pageCount) return;
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;
    final token = _requestToken;
    try {
      final CatalogData data = _categoryId.isEmpty
          ? await _controller!.siteApi.latest(site, nextPage)
          : await _controller!.siteApi.category(
              site,
              _categoryId,
              nextPage,
              filters: Map.of(_filterValues),
            );
      if (!mounted || token != _requestToken) return;
      final existing = _videos.map((e) => '${e.sourceKey}|${e.id}').toSet();
      setState(() {
        for (final vod in data.videos) {
          final key = '${vod.sourceKey}|${vod.id}';
          if (existing.add(key)) _videos.add(vod);
        }
        _page = data.page <= 0 ? nextPage : data.page;
        _pageCount = data.pageCount <= 0 ? _pageCount : data.pageCount;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      showAppSnack(context, _friendly(error), error: true);
    }
  }

  /// 原始异常转中文可操作文案（对照 site_api 的 `_friendlyError`：网络错误
  /// 已由 siteApi 包成友好 `ApiException`，这里剥掉 `Exception: ` 前缀并补
  /// 一句可操作的兜底建议）。
  String _friendly(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    return '$message\n请检查网络后重试，或切换站点。';
  }

  Future<void> _openDetail(VodItem vod) async {
    if (vod.sourceKey == '@douban') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SearchPage(standalone: true, initialQuery: vod.name),
        ),
      );
      return;
    }
    // FOCUS-07: remember the poster that opened the detail page and hand
    // focus back to it when the user returns.
    final previous = FocusManager.instance.primaryFocus;
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => DetailPage(vod: vod)));
    if (!mounted) return;
    if (previous != null && previous.context != null) {
      previous.requestFocus();
    }
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchPage(standalone: true)),
    );
  }

  Future<void> _loadRecommendations() async {
    final related = List<VodItem>.of(_videos);
    final history = context
        .read<LibraryStore>()
        .history
        .map((entry) => entry.vod)
        .toList();
    final token = ++_requestToken;
    setState(() {
      _recommendMode = true;
      _historyMode = false;
      _loading = true;
      _loadingMore = false;
      _videos = [];
      _error = null;
      _categoryId = '';
    });
    try {
      final videos = await RecommendationService().load(
        localRelated: related,
        localFallback: history,
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        _videos = videos;
        _error = videos.isEmpty ? '推荐暂不可用，且没有本地候选，请返回站点内容' : null;
        _loading = false;
        _pageCount = 1;
      });
    } catch (_) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _error = '豆瓣推荐暂不可用，请切回最新上线或稍后重试';
        _loading = false;
      });
    }
    _prunePosterNodes();
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  Future<void> _showSitePicker() async {
    final controller = _controller;
    if (controller == null) return;
    final sites = controller.sites;
    final skin = TvSkin.of(context);
    final selectedKey = await showTvSheet<String>(
      context,
      title: '选择视频站点',
      subtitle: '${sites.length} 个站点 · 返回键关闭',
      width: 600,
      builder: (sheetContext) {
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(
            skin.spaceMd,
            skin.spaceMd,
            skin.spaceMd,
            skin.spaceLg,
          ),
          itemCount: sites.length,
          separatorBuilder: (_, _) => SizedBox(height: skin.spaceXs),
          itemBuilder: (context, index) {
            final site = sites[index];
            final selected = site.key == controller.selectedSite?.key;
            return TvFocusable(
              radius: skin.radiusMd,
              scale: 1.02,
              autofocus: index == 0,
              semanticLabel:
                  '${site.name}${selected ? '，当前站点' : ''}${controller.siteApi.supports(site) ? '' : '，不兼容'}',
              onTap: () {
                if (!controller.siteApi.supports(site)) {
                  showAppSnack(sheetContext, '此站点格式不兼容，请切换站点', error: true);
                  return;
                }
                Navigator.of(sheetContext).pop(site.key);
              },
              child: SiteRow(site: site, selected: selected),
            );
          },
        );
      },
    );
    if (selectedKey != null) {
      if (!mounted) return;
      controller.selectSite(selectedKey);
    }
  }

  Future<void> _showFilters() async {
    final groups = _filters[_categoryId] ?? const <CategoryFilter>[];
    final draft = Map<String, String>.of(_filterValues);
    final applied = await showTvSheet<bool>(
      context,
      title: '分类筛选',
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final skin = TvSkin.of(context);
          final text = AppText.of(context);
          return ListView(
            padding: EdgeInsets.all(skin.spaceLg),
            children: [
              for (final group in groups) ...[
                Text(
                  group.name,
                  style: text.section.copyWith(color: Colors.white),
                ),
                SizedBox(height: skin.spaceSm),
                Wrap(
                  spacing: skin.spaceSm,
                  runSpacing: skin.spaceSm,
                  children: [
                    for (final option in {'': '全部', ...group.values}.entries)
                      TvFocusable(
                        onTap: () =>
                            update(() => draft[group.key] = option.key),
                        child: Padding(
                          padding: EdgeInsets.all(skin.spaceMd),
                          child: Text(
                            '${(draft[group.key] ?? '') == option.key ? '✓ ' : ''}${option.value}',
                            style: text.body.copyWith(color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: skin.spaceLg),
              ],
              TvFocusable(
                autofocus: true,
                semanticLabel: '应用筛选',
                onTap: () => Navigator.pop(context, true),
                child: Padding(
                  padding: EdgeInsets.all(skin.spaceMd),
                  child: Text(
                    '应用筛选',
                    style: text.bodyStrong.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || applied != true) return;
    _filterValues
      ..clear()
      ..addAll(draft);
    await _loadCategory(_categoryId, reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final site = controller.selectedSite;
    final skin = TvSkin.of(context);
    final hPad = TvCanvas.pagePad;
    final topInset = contentTopInset(context);
    final selectedCategory = _categories.firstWhere(
      (e) => e.id == _categoryId,
      orElse: () => const CategoryItem(id: '', name: '全部'),
    );
    // 幂等挂接 hero CTA 的焦点监听（entryFocus 换人时重挂）。
    _bindHeroFocus();
    _syncHeroTimer();
    // 方向键投递表重登（spec §5）：build 期登记表结构跟皮肤/数据联动，
    // clear + 重登幂等（FocusDispatchMap.bind 覆盖式登记）。
    _buildDispatchTable();
    // 内容区的默认落点独立于顶栏下键的页头兜底。仅在目标改变时投焦，
    // 避免重建时把用户刚移到顶栏的焦点拉回内容区。
    // 落点优先级：hero「查看详情」（首页主锚点）→ 网格首项 → 分类栏
    // 「全部」（网格还没挂上来时）。
    final FocusNode entryTarget = _heroVisible
        ? _heroEntryFocus
        : _videos.isEmpty
        ? _allChipFocus
        : _wallEntryFocus;
    if (!identical(_entryOwner, entryTarget)) {
      _claimEntry(entryTarget);
    }
    final trending = _trending;
    final shelfItems = _shelfItems;
    // 内容层 UP 的层级投递（FOCUS-UP）：子层按键冒泡到根 Focus，
    // 按「网格 → 推荐行 → 分类栏 → hero → 页头 → 导航」逐层上抛。
    // 根 Focus skipTraversal 不参与遍历，不抢焦点。
    return Focus(
      focusNode: _navKeyFocus,
      skipTraversal: true,
      onKeyEvent: _handleNavKey,
      child: AnimatedPadding(
        duration: AppMotion.duration(context, _kTopBarYield),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(top: _yieldTopBar ? topInset : 0),
        child: CustomScrollView(
          controller: _scroll,
          physics: const ClampingScrollPhysics(),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvGridCacheExtent),
          // 网格 UP/DOWN 已改为页面侧按 index 确定性投递（投递表
          // wall 行 → _posterNodeAt + deliverFocusNode），不依赖方向
          // 遍历是否看得到缓存区节点（那是「第 2 行 DOWN 死键」的
          // 根因）。这里仍预加载约 2 行（900px）：目标行提前挂载好，
          // ensureVisible 的滚动保持平滑。
          slivers: [
            SliverToBoxAdapter(
              child: _HomeHeader(
                now: _now,
                site: site,
                siteCount: controller.sites.length,
                onSiteTap: _showSitePicker,
                onSearch: _openSearch,
                onRefresh: _refresh,
                onSettings: _openSettings,
                siteFocus: _siteChipFocus,
                // 页头行动作节点由页面持有（spec §5：行内 LEFT/RIGHT
                // 显式投递的表项；壳层 LEFT 通道会吃掉放行的 LEFT）。
                searchFocus: _searchFocus,
                refreshFocus: _refreshFocus,
                settingsFocus: _settingsFocus,
              ),
            ),
            if (controller.warning != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hPad, skin.spaceXs, hPad, 0),
                  child: _WarningBanner(
                    message: controller.warning!,
                    onClose: controller.clearWarning,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: skin.spaceSm + 8,
                child: _loading && _videos.isEmpty
                    ? Padding(
                        padding: EdgeInsets.symmetric(horizontal: hPad),
                        child: const LinearProgressIndicator(minHeight: 2),
                      )
                    : null,
              ),
            ),
            // 热门轮播 hero（izuko 探索页轮播态）：首页主锚点。
            // 下标经 ValueNotifier 驱动只重建轮播本体。
            if (trending.isNotEmpty)
              SliverToBoxAdapter(
                child: ValueListenableBuilder<int>(
                  valueListenable: _heroIndex,
                  builder: (context, index, _) {
                    final safeIndex = index % trending.length;
                    final item = trending[safeIndex];
                    return HomeHeroCarousel(
                      item: item,
                      itemCount: trending.length,
                      index: safeIndex,
                      expanded: _heroExpanded,
                      ctaFocus: _heroEntryFocus,
                      onTapItem: () => _openDetail(item),
                      onCtaKeyEvent: _onHeroCtaKey,
                    );
                  },
                ),
              ),
            // 分类栏（弱化导航条）：贴 hero 下缘，作为全站频道入口；
            // 不配分区标题。水平方向交给分类行自己的滚动 padding
            // （首项光晕不裁切，见 _CategoryBar），外层只留垂直间距。
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(0, skin.spaceMd, 0, 0),
                child: _CategoryBar(
                  categories: _categories,
                  selectedId: _categoryId,
                  fallbackFocus: _allChipFocus,
                  onSelect: _selectCategory,
                  // 节点记账（spec §5）：分类栏 LEFT/RIGHT 显式投递
                  // 需要「index → 节点」映射；index 0 形参即
                  // fallbackFocus（「全部」），其余记 categoryId。
                  onNode: (index, node) {
                    if (index > 0) {
                      _chipNodes[_categories[index - 1].id] = node;
                    }
                  },
                ),
              ),
            ),
            // 「为你推荐」横排名（izuko「因为你喜欢」位）：分类栏之下、
            // 墙网格之上的内容行。焦点记忆走 ShelfRow 受控 memory。
            if (shelfItems.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    hPad,
                    skin.spaceMd,
                    hPad,
                    skin.spaceSm,
                  ),
                  child: const SectionHeader(
                    title: '为你推荐',
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _RecommendRow(
                  items: shelfItems,
                  onOpen: _openDetail,
                  // 焦点记忆走公共 ShelfFocusMemory（spec §4-3）：
                  // focusHere 投递 / syncIndex 回写 / scroll 滚远归零。
                  memoryFocus: _shelfMemory.focus,
                  memoryIndex: _shelfMemory.index,
                  scrollController: _shelfMemory.scroll,
                  onFocusIndex: _shelfMemory.syncIndex,
                  // 卡片节点记账（spec §5）：推荐行 LEFT/RIGHT 显式
                  // 投递的表项——ShelfRow 形参 node（记忆项即受控
                  // 记忆节点，天然与 focusHere 的落点一致）。
                  onNode: (index, node) => _shelfPosterNodes[index] = node,
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  hPad,
                  skin.spaceMd + 2,
                  hPad,
                  skin.spaceXs,
                ),
                child: SectionHeader(
                  title: _recommendMode
                      ? '豆瓣推荐'
                      : _historyMode
                      ? '观看历史'
                      : _categoryId.isEmpty
                      ? '最新上线'
                      : selectedCategory.name,
                  subtitle: _videos.isEmpty
                      ? null
                      : '共 ${formatCount(_pageCount > 0 ? _pageCount : _videos.length)} 页',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TvFocusable(
                        semanticLabel: _recommendMode ? '返回站点内容' : '豆瓣推荐',
                        onTap: _recommendMode
                            ? _loadInitial
                            : _loadRecommendations,
                        child: Padding(
                          padding: EdgeInsets.all(skin.spaceSm),
                          child: Text(
                            _recommendMode ? '站点内容' : '豆瓣推荐',
                            style: AppText.of(context).bodyStrong,
                          ),
                        ),
                      ),
                      TvFocusable(
                        semanticLabel: _historyMode ? '显示最新上线' : '显示观看历史',
                        onTap: () {
                          setState(() {
                            _requestToken++;
                            _recommendMode = false;
                            _error = null;
                            _historyMode = !_historyMode;
                            _videos = _historyMode
                                ? (context
                                          .read<LibraryStore?>()
                                          ?.history
                                          .map((entry) => entry.vod)
                                          .toList() ??
                                      [])
                                : List.of(_latestVideos);
                            _categoryId = '';
                            _loading = false;
                            _loadingMore = false;
                          });
                          _prunePosterNodes();
                        },
                        child: Padding(
                          padding: EdgeInsets.all(skin.spaceSm),
                          child: Text(
                            _historyMode ? '最新上线' : '观看历史',
                            style: AppText.of(context).bodyStrong,
                          ),
                        ),
                      ),
                      if (site?.filterable != 0 &&
                          (_filters[_categoryId]?.isNotEmpty ?? false))
                        TvFocusable(
                          semanticLabel: '分类筛选',
                          onTap: _showFilters,
                          child: Padding(
                            padding: EdgeInsets.all(skin.spaceSm),
                            child: Text(
                              '筛选',
                              style: AppText.of(context).bodyStrong,
                            ),
                          ),
                        )
                      else if (_loading)
                        SizedBox(
                          width: skin.spaceSm + 8,
                          height: skin.spaceSm + 8,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_loading && _videos.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 120),
                  child: LoadingState(label: '正在拉取片库…'),
                ),
              )
            else if (_error != null && _videos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 110),
                  child: ErrorState(
                    message: _error!,
                    onRetry: _categoryId.isEmpty
                        ? _loadInitial
                        : () => _loadCategory(_categoryId, reset: true),
                  ),
                ),
              )
            else if (_videos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 110),
                  child: EmptyState(
                    message: _categoryId.isEmpty
                        ? '这个站点暂时没有返回内容，试试切换站点或点右上角刷新。'
                        : '该分类下暂时没有影片',
                    icon: Icons.movie_filter_outlined,
                    actionLabel: '刷新',
                    action: _refresh,
                  ),
                ),
              )
            else if (controller.homeRows)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 128),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final vod = _videos[index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: skin.spaceMd),
                        child: SizedBox(
                          height: 150,
                          child: WideVodCard(
                            key: ValueKey('home-wall-$index'),
                            vod: vod,
                            focusNode: _posterNodeAt(index),
                            onTap: () => _openDetail(vod),
                          ),
                        ),
                      );
                    },
                    childCount: _videos.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 128),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: skin.spaceXl * 7,
                    mainAxisSpacing: skin.spaceMd,
                    crossAxisSpacing: skin.spaceMd,
                    childAspectRatio: 0.57,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final vod = _videos[index];
                      return PosterCard(
                        key: ValueKey('home-wall-$index'),
                        vod: vod,
                        // 落点由 _claimEntry 显式投递（FOCUS-08），不用
                        // autofocus——懒加载 SliverGrid 里 autofocus 抢不过
                        // 已获焦的「全部」chip。
                        autofocus: false,
                        // 节点统一由页面侧持有（_posterNodes）：UP/DOWN 按
                        // index 确定性投递，不依赖几何遍历；index 0 仍是
                        // FOCUS-08 的落点节点。
                        focusNode: _posterNodeAt(index),
                        onTap: () => _openDetail(vod),
                      );
                    },
                    childCount: _videos.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
              ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 130),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏获焦时内容让位的时长（TAB-02）。比焦点本身慢一点，让位不是弹跳。
const Duration _kTopBarYield = Duration(milliseconds: 220);

/// 热门轮播 hero 的条目上限（同时是圆点数上限，izuko TV_CAROUSEL_MAX_DOTS
/// 20 的电视端收敛——8 个圆点在 1280 画布下排不满半行）。
const int _kHeroMaxItems = 8;

/// 自动轮播切换间隔（izuko TV_CAROUSEL_AUTO_ADVANCE_MILLIS）。
const Duration _kHeroAutoAdvance = Duration(seconds: 6);

/// 「为你推荐」行最多展示的条目数。
const int _kShelfMaxItems = 12;

/// 「为你推荐」行最少展示的条目数：不足则不渲染该行（避免半行孤卡，
/// 分类栏直接贴网格）。
const int _kShelfMinItems = 4;

/// 「为你推荐」行高 / 卡片宽（竖版海报 2:3：图高 = 行高 − 文字块；
/// 140 宽 ≈ 1.46 高宽比，贴 2:3 不裁脸）。
const double _kShelfRowHeight = 260;
const double _kShelfItemExtent = 140;

/// 顶栏整条（品牌字标 + 站点 + 源数 + 时钟 + 三个动作）的焦点聚合（TAB-02）。
///
/// 品牌字标：字号是跨皮肤不变量（`AppText.displaySize`），字重与颜色
/// 跟随皮肤的标题语言（AGENTS.md §8）。
class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    return Text(
      'TVBOX 26',
      style: AppText.of(context).display.copyWith(letterSpacing: 0.8),
    );
  }
}

class _HomeHeader extends StatefulWidget {
  const _HomeHeader({
    required this.now,
    required this.site,
    required this.siteCount,
    required this.onSiteTap,
    required this.onSearch,
    required this.onRefresh,
    required this.onSettings,
    this.siteFocus,
    this.searchFocus,
    this.refreshFocus,
    this.settingsFocus,
  });

  final DateTime now;
  final SiteConfig? site;
  final int siteCount;
  final VoidCallback onSiteTap;
  final VoidCallback onSearch;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  /// 站点 chip 的稳定焦点节点（FOCUS-UP：分类栏 UP 的投递目标）。
  final FocusNode? siteFocus;

  /// 页头行右侧三个圆形动作的稳定节点（spec §5：页头行 LEFT/RIGHT
  /// 显式投递的表项，由页面持有——TvFocusable 自持节点拿不到）。
  final FocusNode? searchFocus;
  final FocusNode? refreshFocus;
  final FocusNode? settingsFocus;

  @override
  State<_HomeHeader> createState() => _HomeHeaderState();
}

class _HomeHeaderState extends State<_HomeHeader> {
  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    // 顶栏不额外加顶内边距：shell 的 MediaQuery 已经把内容推到顶栏下方，
    // 让位时 AnimatedPadding 再补一次 kTopBarHeight，这里重复加会双倍留白。
    return Padding(
      padding: EdgeInsets.fromLTRB(
        TvCanvas.pagePad,
        skin.spaceXs,
        TvCanvas.pagePad,
        0,
      ),
      child: Row(
        children: [
          const _BrandTitle(),
          SizedBox(width: skin.spaceMd),
          Flexible(
            child: TvFocusable(
              radius: skin.radiusMd,
              scale: 1.03,
              focusNode: widget.siteFocus,
              onTap: widget.onSiteTap,
              semanticLabel: '切换视频站点，当前 ${widget.site?.name ?? '暂无站点'}',
              child: Container(
                constraints: const BoxConstraints(maxWidth: 260),
                padding: EdgeInsets.symmetric(
                  horizontal: skin.spaceMd - 2,
                  vertical: skin.spaceSm,
                ),
                decoration: BoxDecoration(
                  color: skin.surfaceSubtle,
                  borderRadius: BorderRadius.circular(skin.radiusMd - 3),
                  border: Border.all(color: skin.borderSoft),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: skin.spaceXs + 1,
                      height: skin.spaceXs + 1,
                      decoration: BoxDecoration(
                        color: skin.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: skin.spaceSm),
                    Flexible(
                      child: Text(
                        widget.site?.name ?? '暂无站点',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyStrong,
                      ),
                    ),
                    SizedBox(width: skin.spaceXs),
                    Icon(
                      Icons.expand_more_rounded,
                      size: skin.spaceMd + 3,
                      color: skin.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: skin.spaceSm),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: skin.spaceSm + 1,
              vertical: skin.spaceSm - 2,
            ),
            decoration: BoxDecoration(
              color: skin.surfaceSubtle,
              borderRadius: BorderRadius.circular(skin.radiusSm),
            ),
            child: Text('${widget.siteCount} 个源', style: text.muted),
          ),
          const Spacer(),
          Text(
            formatClock(widget.now),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.muted,
          ),
          SizedBox(width: skin.spaceMd),
          _HeaderAction(
            icon: Icons.search_rounded,
            semanticLabel: '搜索',
            onTap: widget.onSearch,
            focusNode: widget.searchFocus,
          ),
          SizedBox(width: skin.spaceSm),
          _HeaderAction(
            icon: Icons.refresh_rounded,
            semanticLabel: '刷新',
            onTap: widget.onRefresh,
            focusNode: widget.refreshFocus,
          ),
          SizedBox(width: skin.spaceSm),
          _HeaderAction(
            icon: Icons.settings_rounded,
            semanticLabel: '设置',
            onTap: widget.onSettings,
            focusNode: widget.settingsFocus,
          ),
        ],
      ),
    );
  }
}

/// 顶栏右侧的圆形动作（搜索/刷新/设置）。尺寸、图标色跟皮肤走。
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
    this.focusNode,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  /// 页面持有的稳定节点（spec §5：页头行 LEFT/RIGHT 显式投递的表项；
  /// null 时 TvFocusable 自持节点，仅供独立/预览场合）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return TvFocusable(
      radius: skin.radiusPill,
      focusNode: focusNode,
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Container(
        width: skin.spaceLg + skin.spaceMd,
        height: skin.spaceLg + skin.spaceMd,
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          shape: BoxShape.circle,
          border: Border.all(color: skin.borderSoft),
        ),
        child: Icon(icon, size: skin.spaceMd + 7, color: skin.textSecondary),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return SkinSurface(
      radius: skin.radiusMd,
      padding: EdgeInsets.fromLTRB(
        skin.spaceSm + 3,
        skin.spaceSm,
        skin.spaceSm - 2,
        skin.spaceSm,
      ),
      tint: skin.warning.withValues(alpha: 0.2),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: skin.spaceMd + 2,
            color: skin.warning,
          ),
          SizedBox(width: skin.spaceSm),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.body.copyWith(
                color: skin.textSecondary,
                height: 1.45,
              ),
            ),
          ),
          TvFocusable(
            radius: skin.radiusPill,
            semanticLabel: '关闭提示',
            onTap: onClose,
            child: Container(
              width: skin.spaceLg + skin.spaceMd,
              height: skin.spaceLg + skin.spaceMd,
              decoration: BoxDecoration(
                color: skin.surfaceSubtle,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.close_rounded,
                size: skin.spaceMd + 4,
                color: skin.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.categories,
    required this.selectedId,
    required this.onSelect,
    this.fallbackFocus,
    this.onNode,
  });

  final List<CategoryItem> categories;
  final String selectedId;
  final ValueChanged<String> onSelect;

  /// 首项「全部」的稳定落点：网格还没挂上来（加载中/空/出错）时，
  /// 顶栏 DOWN 落到这里而不是几何遍历的随机项（FOCUS-08）。
  final FocusNode? fallbackFocus;

  /// 节点记账回调（spec §5：分类栏 LEFT/RIGHT 显式投递的节点表来源）。
  /// 每项 build 时以 (index, node) 上报——页面按 categoryId 记下。
  final void Function(int index, FocusNode node)? onNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    // 分类栏接入 ShelfRow（横向模式）获得逐行焦点记忆（FOCUS-02）：
    // 从网格 UP 回来时焦点投回行内记忆项而不是第一项。行根包着整行做
    // 「行外→行内」侦测，项间距走 separator。
    return ShelfRow(
      itemCount: 1 + categories.length,
      // index 0 的 node 即 entryFocus（fallbackFocus 原样注入），
      // 「全部」胶囊与页面兜底落点仍是同一个节点。
      entryFocus: fallbackFocus,
      itemBuilder: (context, index, node) {
        onNode?.call(index, node);
        if (index == 0) {
          return GlassChip(
            label: '全部',
            selected: selectedId.isEmpty,
            focusNode: node,
            onTap: () => onSelect(''),
            icon: Icons.apps_rounded,
          );
        }
        final category = categories[index - 1];
        return GlassChip(
          label: category.name,
          selected: selectedId == category.id,
          focusNode: node,
          onTap: () => onSelect(category.id),
        );
      },
      // 胶囊每项自决宽度，itemExtent 为 null。
      itemExtent: null,
      height: skin.spaceLg + skin.spaceXl + skin.spaceXs,
      // 水平 pagePad 做进滚动内容区：原 ListView 贴 viewport 左缘，获焦
      // 光晕向左溢出会被 RenderViewport 裁掉（AGENTS.md §9.8）；首项距
      // viewport 左缘 40 > ios26 光晕 28，不裁。垂直保持原 ListView
      // padding。外层页面 Padding 的水平分量已同步归零，总留白不变。
      padding: EdgeInsets.symmetric(
        horizontal: TvCanvas.pagePad,
        vertical: skin.spaceXs,
      ),
      separator: skin.spaceSm,
      focusTraversalGroup: true,
    );
  }
}

/// 「为你推荐」横排名（izuko 探索页推荐行的单行版）：[ShelfRow] 承载
/// 逐行焦点记忆（受控 [memoryFocus] / [memoryIndex]，页面持有），卡片
/// 复用 [PosterCard]（key 带 `home-shelf-` 前缀，与墙网格 `home-wall-`
/// 区分，测试与焦点投递各自定位）。
class _RecommendRow extends StatelessWidget {
  const _RecommendRow({
    required this.items,
    required this.onOpen,
    required this.memoryFocus,
    required this.memoryIndex,
    required this.scrollController,
    this.onFocusIndex,
    this.onNode,
  });

  final List<VodItem> items;
  final ValueChanged<VodItem> onOpen;

  /// 页面持有的受控记忆节点 / 下标（ShelfRow 契约：外部节点不入回收表；
  /// 首页走公共 [ShelfFocusMemory] 的 focus/index/scroll）。
  final FocusNode memoryFocus;
  final ValueNotifier<int> memoryIndex;
  final ScrollController scrollController;

  /// 行内移动回写记忆（`ShelfRow.onFocusIndex` 透传，ShelfFocusMemory
  /// .syncIndex 直挂；缺省回写 memoryIndex 保持旧契约）。
  final ValueChanged<int>? onFocusIndex;

  /// 卡片节点记账回调（spec §5：推荐行 LEFT/RIGHT 显式投递的节点表
  /// 来源；itemBuilder 形参 node——记忆项即受控记忆节点，天然一致）。
  final void Function(int index, FocusNode node)? onNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return ShelfRow(
      key: const ValueKey('home-recommend-shelf'),
      itemCount: items.length,
      height: _kShelfRowHeight,
      itemExtent: _kShelfItemExtent,
      separator: skin.spaceMd,
      padding: EdgeInsets.symmetric(
        horizontal: TvCanvas.pagePad,
        vertical: skin.spaceXs,
      ),
      controller: scrollController,
      memoryFocus: memoryFocus,
      memoryIndex: memoryIndex,
      onFocusIndex: onFocusIndex ?? (index) => memoryIndex.value = index,
      itemBuilder: (context, index, node) {
        onNode?.call(index, node);
        final vod = items[index];
        return PosterCard(
          key: ValueKey('home-shelf-$index'),
          vod: vod,
          focusNode: node,
          onTap: () => onOpen(vod),
        );
      },
    );
  }
}
