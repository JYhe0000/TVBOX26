import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/library_store.dart';
import '../../core/utils.dart';
import '../../theme/ui.dart';
import '../pages/detail_page.dart';
import '../pages/favorites_page.dart';
import '../pages/history_page.dart';
import '../pages/settings_page.dart';
import '../tv_canvas.dart';
import '../widgets/common.dart';
import '../widgets/poster_card.dart';
import '../widgets/shelf_row.dart';
import '../widgets/site_row.dart';
import '../widgets/tv_sheet.dart';

/// 继续观看行（ShelfRow）行高。ContinueCard 自然高 ≈ 220：300 宽 16:9 图
/// 169 + 间距（spaceSm-1，9~11）+ 标题 21 + 分隔 3 + 副标题 17.55，smartisan
/// 的 spaceSm 最大按它算；再加 ios26 获焦放大 + 光晕的垂直余量（上 20 /
/// 下 36，BoxShadow blur 26 + spread 2 + offset 8 的扩散量级）后取 280。
/// 现状 186 的 tight 行高会把每张卡底部裁掉约 34px（RenderFlex overflow）。
const double _continueRowHeight = 280;

/// ContinueCard 固定宽（内部 SizedBox），itemExtent 同值，让焦点记忆项滚出
/// 视口时 ShelfRow 能按位置算滚动偏移。
const double _continueCardWidth = ContinueCard.cardWidth;

/// 光晕上方余量：卡片紧贴行顶时获焦光晕向上扩散会被裁；底部余量由行高
/// 富余自然给出（280 - 20 - 自然高 ≈ 40，大于需要的 36）。
const double _continueFocusPadTop = 20;

/// 左栏分类宽度。比 settings_page 的 240 窄 50：右面板要给「继续观看」
/// ShelfRow 留出 4 张 ContinueCard（300 宽 + 12 间距）的可见宽度——第 4
/// 张卡首缘在 shelf 内偏移 = spaceXs(6) + 3×312 = 942，右面板内容宽须
/// 严格大于它（flutter_test 下 viewport 外、cacheExtent 内的项被 finder
/// 默认 skipOffstage 跳过，只会数到可见项）。右面板宽 = 1200 − 190(rail)
/// − 18(gap) = 992，减面板水平内边距 spaceMd(16)×2 得内容 960，再减
/// shelf 自身 spaceXs×2 得视口 948 > 942，第 4 张卡可见（露 6px 提示可横滚）。
const double _railWidth = 190;

class MinePage extends StatefulWidget {
  const MinePage({
    super.key,
    this.entryFocus,
    this.topRequest,
    this.onExitToNav,
  });

  /// Focus target when the user presses Down on the top tab bar.
  final FocusNode? entryFocus;

  /// Fires when the top tab bar takes focus; the page scrolls back to the top.
  final ValueListenable<int>? topRequest;

  /// 内容层向上退出（页头行再按 UP）：把焦点交回导航栏。
  /// 独立挂载（测试/无 shell）时为 null——UP 放行默认遍历兜底。
  final VoidCallback? onExitToNav;

  @override
  State<MinePage> createState() => _MinePageState();
}

/// 左栏分类项。标签与首页/概览的统计卡文案错开，避免同屏出现两个
/// 完全相同的 `find.text` 命中（「站点」等），也避免遥控器遍历歧义。
class _MineCategory {
  const _MineCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _MinePageState extends State<MinePage> with RouteAware {
  static const List<_MineCategory> _categories = [
    _MineCategory('概览', Icons.space_dashboard_rounded),
    _MineCategory('我的收藏', Icons.favorite_rounded),
    _MineCategory('播放历史', Icons.history_rounded),
    _MineCategory('视频站点', Icons.dns_rounded),
    _MineCategory('主题皮肤', Icons.palette_rounded),
    _MineCategory('设置', Icons.settings_rounded),
  ];

  /// 分类栏的实际焦点项，明确建立「内容 → 分类栏 → 全局侧栏」层级。
  late final List<FocusNode> _categoryFocusNodes = List.generate(
    _categories.length,
    (index) => FocusNode(debugLabel: 'mine-category-$index'),
  );

  final ScrollController _scroll = ScrollController();
  FocusNode? _contentFocusBeforeCategory;
  int _index = 0;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    widget.topRequest?.addListener(_onTopRequest);
  }

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
  }

  /// 从收藏/历史/设置等子路由返回：入口节点在各分类首项恒挂载，重投即可，
  /// 避免焦点停在路由 scope 上（死焦点：方向键全失灵）。
  @override
  void didPopNext() {
    final entry = widget.entryFocus;
    if (entry != null && entry.canRequestFocus) entry.requestFocus();
  }

  /// 路由观察订阅标记（didChangeDependencies 可能多次触发）。
  bool _routeSubscribed = false;

  @override
  void didUpdateWidget(covariant MinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topRequest != widget.topRequest) {
      oldWidget.topRequest?.removeListener(_onTopRequest);
      widget.topRequest?.addListener(_onTopRequest);
    }
  }

  void _onTopRequest() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.offset <= 0.5) return;
    _scroll.animateTo(
      0,
      duration: AppMotion.scrollDuration(context),
      curve: AppMotion.scrollCurve,
    );
  }

  @override
  void dispose() {
    kRouteObserver.unsubscribe(this);
    widget.topRequest?.removeListener(_onTopRequest);
    _scroll.dispose();
    for (final node in _categoryFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final controller = context.read<AppController>();
    setState(() => _refreshing = true);
    await controller.refreshCurrentConfig();
    if (!mounted) return;
    setState(() => _refreshing = false);
    showAppSnack(
      context,
      controller.actionError ?? '配置已刷新',
      error: controller.actionError != null,
    );
  }

  KeyEventResult _onContentKey(FocusNode boundary, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final current = FocusManager.instance.primaryFocus;
    if (current == null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      // 先到「我的」页内分类栏；再按 LEFT 才由 ShellPage 进入全局侧栏。
      // 记录内容焦点，分类栏 RIGHT 时恢复到原位置。
      final target = _categoryFocusNodes[_index];
      if (!target.canRequestFocus) return KeyEventResult.ignored;
      _contentFocusBeforeCategory = current;
      target.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    // DOWN 只能继续沿右栏向下；末行没有目标时，禁止默认几何遍历
    // 把斜下方的左栏分类当成下一行。LEFT/UP 仍交给原有遍历处理。
    final hasNextRow = boundary.traversalDescendants.any(
      (node) => node != current && node.rect.center.dy >= current.rect.bottom,
    );
    return hasNextRow ? KeyEventResult.ignored : KeyEventResult.handled;
  }

  KeyEventResult _onCategoryKey(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final previous = _contentFocusBeforeCategory;
    _contentFocusBeforeCategory = null;
    final target =
        previous != null &&
            (previous.context?.mounted ?? false) &&
            previous.canRequestFocus
        ? previous
        : widget.entryFocus;
    if (target == null || !target.canRequestFocus) {
      return KeyEventResult.ignored;
    }
    target.requestFocus();
    final targetContext = target.context;
    if (targetContext != null && targetContext.mounted) {
      Scrollable.ensureVisible(
        targetContext,
        duration: AppMotion.scrollDuration(context),
        curve: AppMotion.scrollCurve,
      );
    }
    return KeyEventResult.handled;
  }

  void _selectCategory(int next) {
    if (next == _index) return;
    _contentFocusBeforeCategory = null;
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final t = AppText.of(context);
    final controller = context.watch<AppController>();
    final library = context.watch<LibraryStore>();
    const hPad = TvCanvas.pagePad;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(hPad, 18, hPad, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 页头行（tab 页头，不是路由页头）：头像 + 标题。
            Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    gradient: skin.accentGradient,
                    borderRadius: BorderRadius.circular(skin.radiusLg - 2),
                    boxShadow: !skin.accentGlow
                        ? null
                        : [
                            BoxShadow(
                              color: skin.accent.withValues(alpha: 0.34),
                              blurRadius: 22,
                              offset: const Offset(0, 7),
                            ),
                          ],
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    color: skin.textOnAccent,
                    size: 31,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('我的配置', style: t.pageTitle),
                      const SizedBox(height: 4),
                      Text(
                        controller.usingBuiltIn && !controller.usingVodAggregate
                            ? '内置演示配置 · ${controller.sites.length} 个视频源'
                            : controller.configLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.body.copyWith(color: skin.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: skin.spaceMd + 2),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onCategoryKey,
                    child: _CategoryRail(
                      categories: _categories,
                      focusNodes: _categoryFocusNodes,
                      index: _index,
                      onSelect: _selectCategory,
                    ),
                  ),
                  SizedBox(width: skin.spaceMd + 2),
                  Expanded(
                    child: SkinSurface(
                      radius: skin.radiusLg,
                      padding: EdgeInsets.fromLTRB(
                        skin.spaceMd,
                        skin.spaceMd + 2,
                        skin.spaceMd,
                        skin.spaceMd,
                      ),
                      child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: _onContentKey,
                        child: ListView(
                          // 右侧栏自己的滚动容器：整屏不套
                          // SingleChildScrollView，否则双栏会被撑成单列
                          // （AGENTS.md §2）。
                          controller: _scroll,
                          physics: const ClampingScrollPhysics(),
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            kTvListCacheExtent,
                          ),
                          addAutomaticKeepAlives: false,
                          padding: EdgeInsets.only(bottom: skin.spaceSm),
                          children: _buildCategory(controller, library),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCategory(AppController controller, LibraryStore library) {
    switch (_categories[_index].label) {
      case '我的收藏':
        return _favoritesSection(library);
      case '播放历史':
        return _historySection(library);
      case '视频站点':
        return _sitesSection(controller);
      case '主题皮肤':
        return _skinSection(controller);
      case '设置':
        return _settingsSection();
      default:
        return _overviewSection(controller, library);
    }
  }

  List<Widget> _overviewSection(
    AppController controller,
    LibraryStore library,
  ) {
    final skin = TvSkin.of(context);
    final t = AppText.of(context);
    final recent = library.history.take(6).toList();
    return [
      Row(
        children: [
          Expanded(
            child: _StatCard(
              value: '${library.favorites.length}',
              label: '收藏',
              icon: Icons.favorite_rounded,
              color: skin.accent,
              focusNode: widget.entryFocus,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const FavoritesPage())),
            ),
          ),
          SizedBox(width: skin.spaceSm),
          Expanded(
            child: _StatCard(
              value: '${library.history.length}',
              label: '历史',
              icon: Icons.history_rounded,
              color: skin.success,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const HistoryPage())),
            ),
          ),
          SizedBox(width: skin.spaceSm),
          Expanded(
            child: _StatCard(
              value: '${controller.sites.length}',
              label: '站点',
              icon: Icons.dns_rounded,
              color: skin.warning,
              onTap: () => _showSitePicker(context, controller),
            ),
          ),
        ],
      ),
      if (recent.isNotEmpty) ...[
        SizedBox(height: skin.spaceLg),
        SectionHeader(
          title: '继续观看',
          subtitle: '从上次看到的位置继续',
          trailing: TvFocusable(
            radius: skin.radiusPill,
            semanticLabel: '查看全部播放历史',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const HistoryPage())),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: skin.spaceMd,
                vertical: skin.spaceSm - 2,
              ),
              decoration: BoxDecoration(
                color: skin.surfaceSubtle,
                borderRadius: BorderRadius.circular(skin.radiusPill),
                border: Border.all(color: skin.border),
              ),
              child: Text('全部', style: t.label),
            ),
          ),
        ),
        SizedBox(height: skin.spaceSm),
        ShelfRow(
          height: _continueRowHeight,
          padding: EdgeInsets.symmetric(horizontal: skin.spaceXs),
          itemCount: recent.length,
          itemExtent: _continueCardWidth,
          separator: 12,
          itemBuilder: (context, index, node) {
            final entry = recent[index];
            // 获焦节点用 ShelfRow 提供的 node：焦点记忆（FOCUS-02）依赖
            // 「实际获焦的节点就是 ShelfRow 记录的节点」，卡片内部另起
            // 节点会让记忆写不进来。顶部留光晕余量。
            return Column(
              children: [
                const SizedBox(height: _continueFocusPadTop),
                ContinueCard(
                  entry: entry,
                  focusNode: node,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DetailPage(vod: entry.vod, resume: entry),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
      SizedBox(height: skin.spaceLg),
      const _Disclaimer(),
    ];
  }

  List<Widget> _favoritesSection(LibraryStore library) {
    return [
      _PanelHeader(
        title: '我的收藏',
        subtitle: '${library.favorites.length} 部影片',
        icon: Icons.favorite_rounded,
      ),
      _PanelAction(
        focusNode: widget.entryFocus,
        icon: Icons.favorite_rounded,
        title: '进入收藏',
        subtitle: '共 ${library.favorites.length} 部影片',
        trailing: '查看',
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const FavoritesPage())),
      ),
    ];
  }

  List<Widget> _historySection(LibraryStore library) {
    final skin = TvSkin.of(context);
    return [
      _PanelHeader(
        title: '播放历史',
        subtitle: '${library.history.length} 条记录',
        icon: Icons.history_rounded,
        tint: skin.success,
      ),
      _PanelAction(
        focusNode: widget.entryFocus,
        icon: Icons.history_rounded,
        title: '进入播放历史',
        subtitle: '共 ${library.history.length} 条记录',
        trailing: '查看',
        tint: skin.success,
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const HistoryPage())),
      ),
    ];
  }

  List<Widget> _sitesSection(AppController controller) {
    final skin = TvSkin.of(context);
    return [
      _PanelHeader(
        title: '视频站点',
        subtitle:
            '${controller.sites.length} 个站点 · '
            '当前 ${controller.selectedSite?.name ?? '未选择'}',
        icon: Icons.dns_rounded,
        tint: skin.warning,
      ),
      _PanelAction(
        focusNode: widget.entryFocus,
        icon: Icons.swap_horiz_rounded,
        title: '切换视频站点',
        subtitle: controller.selectedSite?.name ?? '未选择',
        trailing: '切换',
        tint: skin.warning,
        onTap: () => _showSitePicker(context, controller),
      ),
      _PanelAction(
        icon: Icons.refresh_rounded,
        title: '刷新配置',
        subtitle: controller.usingBuiltIn && !controller.usingVodAggregate
            ? '内置演示配置'
            : '从网络重新拉取',
        busy: _refreshing,
        onTap: _refresh,
      ),
    ];
  }

  List<Widget> _skinSection(AppController controller) {
    return [
      _PanelHeader(
        title: '主题皮肤',
        subtitle: controller.skinId.label,
        icon: Icons.palette_rounded,
      ),
      _PanelAction(
        focusNode: widget.entryFocus,
        icon: Icons.palette_rounded,
        title: controller.skinId.label,
        subtitle: controller.skinId.tagline,
        trailing: '前往切换',
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
      ),
    ];
  }

  List<Widget> _settingsSection() {
    final skin = TvSkin.of(context);
    return [
      _PanelHeader(
        title: '设置',
        subtitle: '配置接口、直播源与播放选项',
        icon: Icons.settings_rounded,
        tint: skin.textSecondary,
      ),
      _PanelAction(
        focusNode: widget.entryFocus,
        icon: Icons.settings_rounded,
        title: '打开设置',
        subtitle: '配置接口、直播源与播放选项',
        trailing: '进入',
        tint: skin.textSecondary,
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
      ),
    ];
  }

  Future<void> _showSitePicker(
    BuildContext context,
    AppController controller,
  ) async {
    final sites = controller.sites;
    final skin = TvSkin.of(context);
    final selectedKey = await showTvSheet<String>(
      context,
      title: '选择视频站点',
      subtitle: '${sites.length} 个站点 · 返回键关闭',
      width: 600,
      builder: (sheetContext) {
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          itemCount: sites.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final site = sites[index];
            final selected = site.key == controller.selectedSite?.key;
            return TvFocusable(
              radius: skin.radiusSm,
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
}

/// 左栏：分类导航（Compose TV `NavigationRail` 的等价物）。
class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.focusNodes,
    required this.index,
    required this.onSelect,
  });

  final List<_MineCategory> categories;
  final List<FocusNode> focusNodes;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return SizedBox(
      width: _railWidth,
      child: SkinSurface(
        radius: skin.radiusLg,
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceSm,
          vertical: skin.spaceMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < categories.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: skin.spaceXs),
                child: _CategoryItem(
                  label: categories[i].label,
                  icon: categories[i].icon,
                  selected: i == index,
                  focusNode: focusNodes[i],
                  // 进页默认焦点落在第一项（FOCUS-06）。
                  autofocus: i == 0,
                  onTap: () => onSelect(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryItem extends StatelessWidget {
  const _CategoryItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.focusNode,
    required this.autofocus,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusSm + 2,
      scale: 1.02,
      autofocus: autofocus,
      focusNode: focusNode,
      semanticLabel: label,
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, skin.motionFast),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceMd - 2,
          vertical: skin.spaceSm + 5,
        ),
        decoration: BoxDecoration(
          color: selected ? skin.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(skin.radiusSm + 2),
          border: Border.all(
            color: selected ? skin.accent : Colors.transparent,
            width: selected ? 1.4 : 0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 21,
              color: selected ? skin.accent : skin.textSecondary,
            ),
            SizedBox(width: skin.spaceSm + 2),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyLarge.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? skin.accent : skin.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右侧内容面板的小标题（分类上下文）。
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.title,
    this.subtitle,
    this.icon,
    this.tint,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 图标底色，默认用强调色。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final accent = tint ?? skin.accent;
    return Padding(
      padding: EdgeInsets.only(bottom: skin.spaceSm + 2),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(skin.radiusSm),
              ),
              child: Icon(icon, size: 20, color: accent),
            ),
            SizedBox(width: skin.spaceSm + 2),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.cardTitle),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.label.copyWith(color: skin.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板内的大功能卡：图标 + 标题/副标题 + 尾标/箭头。行高 ≥ 84，10 英尺外
/// 可读、可点（AGENTS.md §6.5）。
class _PanelAction extends StatelessWidget {
  const _PanelAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tint,
    this.trailing,
    this.busy = false,
    this.focusNode,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? tint;
  final String? trailing;
  final bool busy;

  /// 入口焦点节点（shell 顶栏 DOWN 的落点）。各分类首项都挂同一个
  /// `widget.entryFocus`，保证非概览分类下节点也已挂载——否则顶栏 DOWN
  /// 投递到一个不在树里的节点，焦点原地不动（「我的页焦点下不来」根因）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final accent = tint ?? skin.accent;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: skin.spaceXs),
      child: TvFocusable(
        radius: skin.radiusMd,
        scale: 1.02,
        focusNode: focusNode,
        semanticLabel: '$title，$subtitle',
        onTap: busy ? null : onTap,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, skin.motionFast),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 84),
          padding: EdgeInsets.symmetric(
            horizontal: skin.spaceMd,
            vertical: skin.spaceSm + 2,
          ),
          decoration: BoxDecoration(
            color: skin.surfaceSubtle,
            borderRadius: BorderRadius.circular(skin.radiusMd),
            border: Border.all(color: skin.borderSoft),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(skin.radiusSm),
                ),
                child: Icon(icon, size: 22, color: accent),
              ),
              SizedBox(width: skin.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: skin.spaceXs - 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.label.copyWith(color: skin.textMuted),
                    ),
                  ],
                ),
              ),
              if (busy)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              else ...[
                if (trailing != null)
                  Text(
                    trailing!,
                    style: text.label.copyWith(color: skin.textSecondary),
                  ),
                SizedBox(width: skin.spaceSm),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 24,
                  color: skin.textMuted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.focusNode,
  });

  final String value;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final t = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusMd,
      scale: 1.06,
      focusNode: focusNode,
      semanticLabel: '$label $value',
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceMd - 4,
          vertical: skin.spaceSm + 3,
        ),
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusMd),
          border: Border.all(color: skin.borderSoft),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(skin.radiusSm),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            SizedBox(width: skin.spaceSm - 1),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: t.cardTitle),
                Text(label, style: t.meta),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部免责声明。
class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Row(
      children: [
        Icon(Icons.info_outline_rounded, size: 14, color: skin.textMuted),
        SizedBox(width: skin.spaceXs + 1),
        Expanded(
          child: Text(
            '本应用不提供任何影片资源，内容均来自用户自行配置的第三方接口。',
            style: text.meta.copyWith(
              height: 1.5,
              color: skin.textMuted.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }
}
