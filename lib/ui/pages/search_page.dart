import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/library_store.dart';
import '../../core/remote_search_server.dart';
import '../../data/models.dart';
import '../../data/search_batch.dart';
import '../../data/site_api.dart';
import '../../data/search_suggest.dart';
import '../../theme/ui.dart';
import '../pages/detail_page.dart';
import '../widgets/common.dart';
import '../tv_canvas.dart';
import '../widgets/poster_card.dart';
import '../widgets/remote_search_dialog.dart';
import '../widgets/site_row.dart';
import '../widgets/tv_keyboard.dart';
import '../widgets/tv_notice.dart';
import '../widgets/tv_sheet.dart';

/// 搜索页：布局移植自主软件参考 Box 的 SearchActivity。
///
/// 三栏结构：
/// - 左栏：搜索范围按钮、输入框、搜索/清空、遥控器字母键盘（A–Z + 0–9）；
/// - 中栏：搜索历史与结果列表；
/// - 右栏：热门搜索（腾讯热榜）/ 输入联想（拼音→中文词）。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    this.standalone = false,
    this.entryFocus,
    this.topRequest,
    this.tabFocus,
    this.onExitToNav,
    this.initialQuery = '',
  });

  final bool standalone;
  final String initialQuery;

  /// Focus target when the user presses Down on the top tab bar.
  final FocusNode? entryFocus;

  /// Fires when the top tab bar takes focus; the page scrolls back to the top.
  final ValueListenable<int>? topRequest;

  /// The active tab's button node; Up from the field returns here instead of
  /// letting geometric traversal pick a neighbouring tab.
  final FocusNode? tabFocus;

  /// 内容层向上退出（页头行再按 UP）：把焦点交回导航栏。
  /// 独立挂载（测试/无 shell）时为 null——UP 放行默认遍历兜底。
  final VoidCallback? onExitToNav;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 输入框 Down 落到「搜索」按钮，避免几何遍历选到旁边的「清空」。
  final FocusNode _searchBtnFocus = FocusNode(debugLabel: 'search-submit');

  /// 搜索框 UP 的明确落点：搜索范围选择器。
  final FocusNode _searchScopeFocus = FocusNode(debugLabel: 'search-scope');

  /// 搜索范围与输入框之间的辅助操作焦点。
  final FocusNode _sourceSelectionFocus = FocusNode(
    debugLabel: 'search-source-selection',
  );

  /// 输入框 Right 落到中栏第一项（历史/来源筛选），符合三栏布局的空间直觉。
  final FocusNode _middleFocus = FocusNode(debugLabel: 'search-middle');

  final SearchSuggest _suggestApi = SearchSuggest();
  final Map<String, List<VodItem>> _results = {};
  final Map<String, String> _errors = {};
  bool _aggregate = true;
  bool _searching = false;
  bool _posterResults = false;
  bool _searched = false;
  String _filterSite = '';
  String _singleSiteKey = '';
  String _query = '';
  int _requestToken = 0;
  SearchCancellation? _searchCancellation;
  int _searchTargetCount = 0;

  // 右栏联想面板状态。
  List<String> _hotWords = const [];
  List<String> _suggestions = const [];
  bool _suggesting = false;
  Timer? _suggestTimer;
  int _suggestToken = 0;

  // 手机远程搜索（扫码）状态。
  RemoteSearchServer? _remote;
  bool _remoteOpen = false;

  /// 非键盘来源改写输入后 +1，通知 T9 键盘重置多击循环（remote_input P1-3）。
  final ValueNotifier<int> _kbReset = ValueNotifier<int>(0);

  /// 搜索框实际使用的焦点节点：接入 shell 时由 top bar 直接下移到这里。
  FocusNode get _fieldFocus => widget.entryFocus ?? _focus;

  /// The search field is a Focus ancestor of the editable, so D-pad events
  /// bubble here before TextField's caret movement can swallow them.
  KeyEventResult _handleFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _fieldFocus.unfocus();
      return KeyEventResult.handled;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    if (direction != null) {
      if (direction == TraversalDirection.up) {
        // 搜索框正上方是「勾选聚合搜索源」，先落到最近的操作项；再按
        // UP 才回「搜索范围」，最后才回壳层侧栏。
        _sourceSelectionFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (direction == TraversalDirection.down) {
        // 明确落到「搜索」按钮，几何遍历会把焦点给到右侧的「清空」。
        _searchBtnFocus.requestFocus();
        return KeyEventResult.handled;
      }
      final context = node.context;
      if (context != null) {
        FocusScope.of(context).focusInDirection(direction);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      // 右栏方向进入中栏内容，而不是跳到顶部导航条。
      if (_middleFocus.context != null) {
        _middleFocus.requestFocus();
      } else {
        final context = node.context;
        if (context != null) {
          FocusScope.of(context).focusInDirection(TraversalDirection.right);
        }
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      // 输入框已经是左栏最左侧，Left 停住，避免焦点飞到顶部导航。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleSearchScopeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _sourceSelectionFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final tab = widget.tabFocus;
      if (tab != null && tab.canRequestFocus) {
        tab.requestFocus();
      } else if (node.context case final context?) {
        FocusScope.of(context).focusInDirection(TraversalDirection.up);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleSourceSelectionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _searchScopeFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _fieldFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    widget.topRequest?.addListener(_onTopRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadHotWords();
        if (widget.initialQuery.isNotEmpty) _submit(widget.initialQuery);
      }
    });
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topRequest != widget.topRequest) {
      oldWidget.topRequest?.removeListener(_onTopRequest);
      widget.topRequest?.addListener(_onTopRequest);
    }
  }

  /// The tab bar owns focus when this fires; spring the page all the way back
  /// so the search field is visible again.
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
    _searchCancellation?.cancel();
    widget.topRequest?.removeListener(_onTopRequest);
    _suggestTimer?.cancel();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    _searchBtnFocus.dispose();
    _searchScopeFocus.dispose();
    _sourceSelectionFocus.dispose();
    _middleFocus.dispose();
    _kbReset.dispose();
    final remote = _remote;
    if (remote != null) unawaited(remote.stop());
    super.dispose();
  }

  // ---------------------------------------------------------------- 联想词

  Future<void> _loadHotWords() async {
    final words = await _suggestApi.hotWords();
    if (!mounted || words.isEmpty) return;
    setState(() => _hotWords = words);
  }

  /// 输入变化后 320ms 去抖请求联想词（Box 的 loadRec 同款接口与时机）。
  void _scheduleSuggest() {
    _suggestTimer?.cancel();
    final text = _input.text.trim();
    if (text.isEmpty) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    _suggestTimer = Timer(const Duration(milliseconds: 320), () async {
      final token = ++_suggestToken;
      setState(() => _suggesting = true);
      final words = await _suggestApi.suggest(text);
      if (!mounted || token != _suggestToken) return;
      setState(() {
        _suggestions = words;
        _suggesting = false;
      });
    });
  }

  // ---------------------------------------------------------------- 键盘

  void _onKeyboardKey(String key, {bool replace = false}) {
    if (key == TvSearchKeyboard.scan) {
      _openRemoteSearch();
      return;
    }
    if (key == TvSearchKeyboard.backspace) {
      if (_input.text.isEmpty) return;
      _input.text = _input.text.substring(0, _input.text.length - 1);
    } else if (replace && _input.text.isNotEmpty) {
      // T9 多击循环：同键连按替换末位字符。
      _input.text = _input.text.substring(0, _input.text.length - 1) + key;
    } else {
      _input.text = _input.text + key;
    }
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    // 输入框文本由 ValueListenableBuilder 局部订阅刷新，这里不整页 setState
    // （remote_input P1-4）；联想面板走 _scheduleSuggest 的去抖。
    _scheduleSuggest();
  }

  /// 非键盘来源改写输入后调用，重置 T9 多击循环（remote_input P1-3）。
  void _resetKeyboardCycle() {
    _kbReset.value++;
  }

  /// 扫码远程搜索：起局域网服务并弹二维码（Box 的 Remote 同款功能）。
  Future<void> _openRemoteSearch() async {
    try {
      final remote = _remote ??= RemoteSearchServer(
        onQuery: _onRemoteQuery,
        hotWords: () => _hotWords,
        suggest: (query) => _suggestApi.suggest(query),
      );
      final url = await remote.start();
      // start() 期间退出页面 → dispose 的 stop 可能落空（_server 未赋值），
      // 这里补一次停服，避免孤儿服务常驻（remote_input P1-1）。
      if (!mounted) {
        await remote.stop();
        return;
      }
      if (url.isEmpty) return;
      _remoteOpen = true;
      await showRemoteSearchDialog(context, url);
      _remoteOpen = false;
      // 服务生命周期绑定浮层：浮层关闭即停服，杜绝「幽灵搜索/孤儿服务」。
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

  void _onRemoteQuery(String query) {
    if (!mounted) return;
    if (_remoteOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      _remoteOpen = false;
    }
    _input.text = query;
    _resetKeyboardCycle();
    _submit(query);
  }

  void _clearInput() {
    _suggestTimer?.cancel();
    _input.clear();
    _resetKeyboardCycle();
    // 清空即失效：递增 token 让在途请求的结果全部作废（live_search_deep P2-1）。
    ++_requestToken;
    _searchCancellation?.cancel();
    _searchCancellation = null;
    setState(() {
      _suggestions = const [];
      _query = '';
      _searching = false;
      _searched = false;
      _filterSite = '';
      _results.clear();
      _errors.clear();
    });
  }

  // ---------------------------------------------------------------- 搜索

  Future<void> _chooseSearchSites(AppController controller) async {
    final sites = controller.searchSites
        .where((site) => site.isSearchable && controller.siteApi.supports(site))
        .toList();
    await showTvSheet<void>(
      context,
      title: '聚合搜索源',
      subtitle: '确定键切换勾选，返回保存',
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final skin = TvSkin.of(context);
          final text = AppText.of(context);
          return ListView.builder(
            padding: EdgeInsets.all(skin.spaceLg),
            scrollCacheExtent: const ScrollCacheExtent.pixels(
              kTvListCacheExtent,
            ),
            addAutomaticKeepAlives: false,
            itemCount: sites.length,
            itemBuilder: (_, index) {
              final site = sites[index];
              final enabled = !controller.excludedSearchSites.contains(
                site.key,
              );
              return TvFocusable(
                autofocus: index == 0,
                semanticLabel: '${site.name}，${enabled ? '已选' : '未选'}',
                onTap: () async {
                  await controller.toggleSearchSite(site.key);
                  if (context.mounted) update(() {});
                },
                child: Padding(
                  padding: EdgeInsets.all(skin.spaceMd),
                  child: Row(
                    children: [
                      Icon(
                        enabled
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        color: Colors.white,
                      ),
                      SizedBox(width: skin.spaceSm),
                      Text(
                        site.name,
                        style: text.bodyStrong.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  List<SiteConfig> _targets(AppController controller) {
    if (!_aggregate) {
      final site = _singleSiteKey.isEmpty
          ? controller.selectedSite
          : controller.siteByKey(_singleSiteKey);
      return site == null ||
              !site.isSearchable ||
              !controller.siteApi.supports(site)
          ? const []
          : [site];
    }
    final sites = controller.searchSites
        .where(
          (e) =>
              e.isSearchable &&
              controller.siteApi.supports(e) &&
              !controller.excludedSearchSites.contains(e.key),
        )
        .toList();
    final homeKey = controller.selectedSite?.key;
    final home = sites.indexWhere((site) => site.key == homeKey);
    if (home > 0) sites.insert(0, sites.removeAt(home));
    return sites;
  }

  Future<void> _submit(String value, {bool scopeChanged = false}) async {
    final query = value.trim();
    if (query.isEmpty || (!scopeChanged && _searching && query == _query)) {
      return;
    }
    _fieldFocus.unfocus();
    _input.text = query;
    _input.selection = TextSelection.collapsed(offset: query.length);
    _resetKeyboardCycle();
    final controller = context.read<AppController>();
    final library = context.read<LibraryStore>();
    library.addSearchKeyword(query).ignore();
    final sites = _targets(controller);
    final token = ++_requestToken;
    _searchCancellation?.cancel();
    final cancellation = SearchCancellation();
    _searchCancellation = cancellation;
    setState(() {
      _query = query;
      _searchTargetCount = sites.length;
      _searching = true;
      _searched = true;
      _filterSite = '';
      _results.clear();
      _errors.clear();
    });
    if (sites.isEmpty) {
      _searchCancellation = null;
      setState(() => _searching = false);
      return;
    }
    await runSearchBatch(
      sites,
      isCurrent: () => mounted && token == _requestToken,
      laneFor: (site) {
        // -1：无队列限制（可并发），0-4：对应 Android 的 JAR 队列号（同队列串行）
        if (!SiteApi.supportsJar(site)) return -1;
        final key = [site.key, site.jar, site.api, site.ext];
        var hash = 1;
        for (final s in key) {
          for (final u in s.codeUnits) {
            hash = (31 * hash + u).toSigned(32);
          }
        }
        return ((hash % 5) + 5) % 5;
      },
      search: (site) async {
        try {
          final videos = await controller.siteApi.search(
            site,
            query,
            cancellation: cancellation,
          );
          if (!mounted || token != _requestToken) return;
          setState(() => _results[site.key] = videos);
        } catch (error) {
          if (!mounted || token != _requestToken) return;
          setState(() => _errors[site.key] = _friendly(error));
        }
      },
    );
    if (mounted && token == _requestToken) {
      _searchCancellation = null;
      setState(() => _searching = false);
    }
  }

  /// 原始异常转中文可操作文案（对照 site_api 的 `_friendlyError`）。
  String _friendly(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('域名解析失败') ||
        message.contains('UnknownHostException') ||
        message.contains('Failed host lookup')) {
      return '站点域名解析失败，请在设置中更换 DNS 后重试。';
    }
    return '$message\n请检查网络后重试，或切换站点。';
  }

  void _openDetail(VodItem vod) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DetailPage(vod: vod)));
  }

  /// Box 的 filterBtn 同款：侧栏选择「全局搜索」或指定站点。
  Future<void> _showFilterSheet(AppController controller) async {
    final sites = controller.searchSites
        .where((e) => e.isSearchable && controller.siteApi.supports(e))
        .toList();
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final result = await showTvSheet<String>(
      context,
      title: '搜索范围',
      subtitle: '选择聚合全部站点或只搜单一站点 · 返回键关闭',
      width: 560,
      builder: (sheetContext) {
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(
            skin.spaceMd + 2,
            skin.spaceMd,
            skin.spaceMd + 2,
            skin.spaceLg + 4,
          ),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          itemCount: sites.length + 1,
          separatorBuilder: (_, _) => SizedBox(height: skin.spaceSm - 2),
          itemBuilder: (context, index) {
            if (index == 0) {
              return TvFocusable(
                radius: skin.radiusSm + 2,
                scale: 1.02,
                autofocus: _aggregate,
                semanticLabel: '全局搜索',
                onTap: () => Navigator.of(sheetContext).pop(''),
                // 「全局搜索」不是站点，没有 SiteConfig；这里补一行与
                // SiteRow 同参数的外观，视觉完全对齐（AGENTS.md §2.9）。
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: skin.spaceMd,
                    vertical: skin.spaceSm + 4,
                  ),
                  decoration: BoxDecoration(
                    color: _aggregate ? skin.accentSoft : skin.surfaceSubtle,
                    borderRadius: BorderRadius.circular(skin.radiusSm + 2),
                    border: Border.all(
                      color: _aggregate ? skin.accent : skin.borderSoft,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: _aggregate
                              ? skin.accent.withValues(alpha: 0.2)
                              : skin.surfaceSubtle,
                          borderRadius: BorderRadius.circular(
                            skin.radiusSm - 1,
                          ),
                        ),
                        child: Icon(
                          Icons.hub_rounded,
                          size: 20,
                          color: _aggregate ? skin.accent : skin.textSecondary,
                        ),
                      ),
                      SizedBox(width: skin.spaceSm + 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '全局搜索',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyLarge.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _aggregate
                                    ? skin.accent
                                    : skin.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '聚合 ${sites.length} 个可用站点，结果更全',
                              style: text.label.copyWith(color: skin.textMuted),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: skin.spaceSm),
                      if (_aggregate)
                        Text(
                          '当前',
                          style: text.label.copyWith(
                            color: skin.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      else
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 22,
                          color: skin.textMuted,
                        ),
                    ],
                  ),
                ),
              );
            }
            final site = sites[index - 1];
            final selected = !_aggregate && site.key == _singleSiteKey;
            return TvFocusable(
              radius: skin.radiusSm + 2,
              scale: 1.02,
              autofocus: !_aggregate && selected,
              onTap: () => Navigator.of(sheetContext).pop(site.key),
              child: SiteRow(site: site, selected: selected),
            );
          },
        );
      },
    );
    if (result == null || !mounted) return;
    if (result.isEmpty ? _aggregate : !_aggregate && result == _singleSiteKey) {
      return;
    }
    setState(() {
      if (result.isEmpty) {
        _aggregate = true;
      } else {
        _aggregate = false;
        _singleSiteKey = result;
      }
      _filterSite = '';
    });
    if (_searched) unawaited(_submit(_query, scopeChanged: true));
  }

  int get _totalCount =>
      _results.values.fold(0, (count, list) => count + list.length);

  // ---------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final library = context.watch<LibraryStore>();
    final skin = TvSkin.of(context);
    final content = _buildContent(context, controller, library);
    if (!widget.standalone) return content;
    return Scaffold(
      backgroundColor: skin.bg,
      body: AppBackground(wallpaper: controller.wallpaper, child: content),
    );
  }

  Widget _buildContent(
    BuildContext context,
    AppController controller,
    LibraryStore library,
  ) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    const hPad = TvCanvas.pagePad;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(hPad, skin.spaceMd, hPad, skin.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (widget.standalone) ...[
                  TvFocusable(
                    radius: skin.radiusPill,
                    semanticLabel: '返回',
                    onTap: () => Navigator.maybePop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: skin.surfaceSubtle,
                        shape: BoxShape.circle,
                        border: Border.all(color: skin.borderSoft),
                      ),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 20,
                        color: skin.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(width: skin.spaceSm + 2),
                ],
                Text('搜索', style: text.section),
                const Spacer(),
                if (_searched)
                  Text(
                    '$_totalCount 条结果',
                    style: text.label.copyWith(color: skin.textMuted),
                  ),
              ],
            ),
            SizedBox(height: skin.spaceSm + 2),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 三栏宽度：左右栏定宽、中栏自适应，三栏结构不动。
                  SizedBox(
                    width: 380,
                    child: _buildControlPanel(context, controller),
                  ),
                  SizedBox(width: skin.spaceMd - 2),
                  Expanded(child: _buildMiddle(context, controller, library)),
                  SizedBox(width: skin.spaceMd - 2),
                  SizedBox(width: 210, child: _buildSuggestPanel(library)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左栏：搜索范围、输入框、搜索/清空、字母键盘。
  Widget _buildControlPanel(BuildContext context, AppController controller) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final sites = _targets(controller);
    final singleSite = _aggregate
        ? null
        : controller.siteByKey(_singleSiteKey) ?? controller.selectedSite;
    return Column(
      children: [
        TvFocusable(
          radius: skin.radiusSm + 1,
          scale: 1.02,
          focusNode: _searchScopeFocus,
          semanticLabel: '搜索范围',
          onKeyEvent: (event) =>
              _handleSearchScopeKey(_searchScopeFocus, event),
          onTap: () => _showFilterSheet(controller),
          child: Container(
            height: 46,
            padding: EdgeInsets.symmetric(horizontal: skin.spaceMd - 2),
            decoration: BoxDecoration(
              color: skin.surfaceSubtle,
              borderRadius: BorderRadius.circular(skin.radiusSm + 1),
              border: Border.all(color: skin.borderSoft),
            ),
            child: Row(
              children: [
                Icon(
                  _aggregate ? Icons.hub_rounded : Icons.dns_rounded,
                  size: 18,
                  color: skin.textSecondary,
                ),
                SizedBox(width: skin.spaceSm),
                Expanded(
                  child: Text(
                    _aggregate
                        ? '全局搜索 · ${sites.length} 个源'
                        : '指定源 · ${singleSite?.name ?? '当前站点'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: skin.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: skin.textMuted,
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: skin.spaceSm - 2),
        TvFocusable(
          focusNode: _sourceSelectionFocus,
          onKeyEvent: (event) =>
              _handleSourceSelectionKey(_sourceSelectionFocus, event),
          semanticLabel: '勾选聚合搜索源',
          onTap: () => _chooseSearchSites(controller),
          child: Padding(
            padding: EdgeInsets.all(skin.spaceXs),
            child: Text('勾选聚合搜索源', style: text.label),
          ),
        ),
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _handleFieldKey,
          // 输入框文本只局部刷新：T9 每键不整页 setState（remote_input P1-4），
          // 由 ValueListenableBuilder 订阅 _input 单独重建输入框。
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (context, value, _) => TextField(
              controller: _input,
              focusNode: _fieldFocus,
              autofocus: widget.standalone,
              // 电视端输入全部走 T9 键盘与手机扫码，焦点落在框上时不拉系统输入法。
              readOnly: true,
              showCursor: false,
              style: text.bodyLarge.copyWith(fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: '输入影片名或拼音首字母',
                hintStyle: text.bodyLarge.copyWith(
                  color: skin.textMuted,
                  fontWeight: FontWeight.w400,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 21,
                  color: skin.textSecondary,
                ),
                isDense: true,
                filled: true,
                fillColor: skin.surfaceSubtle,
                contentPadding: EdgeInsets.symmetric(
                  vertical: skin.spaceSm + 5,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(skin.radiusSm + 1),
                  borderSide: BorderSide(color: skin.borderSoft),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(skin.radiusSm + 1),
                  borderSide: BorderSide(color: skin.accent, width: 1.4),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: skin.spaceSm - 2),
        Row(
          children: [
            Expanded(
              child: TvFocusable(
                radius: skin.radiusSm + 1,
                scale: 1.02,
                focusNode: _searchBtnFocus,
                semanticLabel: '搜索',
                onTap: () => _submit(_input.text),
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: skin.accentGradient,
                    borderRadius: BorderRadius.circular(skin.radiusSm + 1),
                  ),
                  child: Text(
                    '搜 索',
                    style: text.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: skin.textOnAccent,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: skin.spaceSm - 2),
            Expanded(
              child: TvFocusable(
                radius: skin.radiusSm + 1,
                scale: 1.02,
                semanticLabel: '清空',
                onTap: _clearInput,
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: skin.surfaceSubtle,
                    borderRadius: BorderRadius.circular(skin.radiusSm + 1),
                    border: Border.all(color: skin.borderSoft),
                  ),
                  child: Text(
                    '清 空',
                    style: text.bodyStrong.copyWith(
                      fontWeight: FontWeight.w600,
                      color: skin.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: skin.spaceSm),
        Expanded(
          child: TvSearchKeyboard(onKey: _onKeyboardKey, resetSignal: _kbReset),
        ),
      ],
    );
  }

  /// 中栏：搜索历史 / 结果。
  Widget _buildMiddle(
    BuildContext context,
    AppController controller,
    LibraryStore library,
  ) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    if (!_searched) {
      return CustomScrollView(
        controller: _scroll,
        physics: const ClampingScrollPhysics(),
        scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: SectionHeader(
                        title: '搜索历史',
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    if (library.searchHistory.isNotEmpty)
                      TvFocusable(
                        radius: skin.radiusSm - 2,
                        semanticLabel: '清空历史',
                        onTap: () => library.clearSearchHistory(),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: skin.spaceSm,
                            vertical: skin.spaceXs,
                          ),
                          child: Text(
                            '清空历史',
                            style: text.meta.copyWith(color: skin.textMuted),
                          ),
                        ),
                      ),
                  ],
                ),
                if (library.searchHistory.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: skin.spaceLg),
                    child: const EmptyState(
                      message: '还没有搜索记录。\n用左侧键盘输入片名或拼音首字母，右侧会给出中文联想。',
                      icon: Icons.search_rounded,
                    ),
                  )
                else ...[
                  SizedBox(height: skin.spaceSm),
                  Wrap(
                    spacing: skin.spaceSm - 2,
                    runSpacing: skin.spaceSm - 2,
                    children: library.searchHistory.indexed
                        .map(
                          (entry) => GlassChip(
                            key: ValueKey('history-${entry.$2}'),
                            label: entry.$2,
                            icon: Icons.history_rounded,
                            // 输入框按 Right 落到第一条历史记录。
                            focusNode: entry.$1 == 0 ? _middleFocus : null,
                            onTap: () {
                              _input.text = entry.$2;
                              _resetKeyboardCycle();
                              _submit(entry.$2);
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
                SizedBox(height: skin.spaceLg),
                SkinSurface(
                  radius: skin.radiusMd,
                  padding: EdgeInsets.all(skin.spaceMd),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.tips_and_updates_rounded,
                        color: skin.warning,
                        size: 20,
                      ),
                      SizedBox(width: skin.spaceSm),
                      Expanded(
                        child: Text(
                          '遥控器操作：用左侧 T9 键盘按字母（连按同键换字母），'
                          '输入拼音首字母（如 3 3 → DD）右侧会给出中文联想词；'
                          '也可按「扫码」用手机输入中文片名远程搜索。',
                          style: text.label.copyWith(
                            height: 1.7,
                            color: skin.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final visibleResults = _filterSite.isEmpty
        ? [for (final results in _results.values) ...results]
        : _results[_filterSite] ?? const <VodItem>[];
    return CustomScrollView(
      controller: _scroll,
      physics: const ClampingScrollPhysics(),
      scrollCacheExtent: const ScrollCacheExtent.pixels(kTvGridCacheExtent),
      slivers: [
        if (_searching)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: skin.spaceSm),
              child: LinearProgressIndicator(
                minHeight: 2,
                value: _searchTargetCount == 0
                    ? null
                    : (_results.length + _errors.length) / _searchTargetCount,
                semanticsLabel: '搜索站点进度',
              ),
            ),
          ),
        if (_totalCount > 0)
          SliverToBoxAdapter(
            child: SizedBox(
              // 高度要容得下 GlassChip（约 44 高）加上焦点放大 1.06×，
              // 否则胶囊会被裁掉下半截；用皮肤间距算，保证 ≥ 52。
              height: skin.spaceXl + skin.spaceMd + 4,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                scrollCacheExtent: const ScrollCacheExtent.pixels(
                  kTvListCacheExtent,
                ),
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: skin.spaceSm - 2),
                    child: GlassChip(
                      label: '全部 $_totalCount',
                      selected: _filterSite.isEmpty,
                      // 输入框按 Right 落到来源筛选第一项。
                      focusNode: _middleFocus,
                      onTap: () => setState(() => _filterSite = ''),
                    ),
                  ),
                  GlassChip(
                    label: _posterResults ? '切换列表' : '切换海报',
                    selected: _posterResults,
                    onTap: () =>
                        setState(() => _posterResults = !_posterResults),
                  ),
                  ..._results.entries
                      .where((e) => e.value.isNotEmpty)
                      .map(
                        (entry) => Padding(
                          padding: EdgeInsets.only(right: skin.spaceSm - 2),
                          child: GlassChip(
                            label:
                                '${controller.siteByKey(entry.key)?.name ?? entry.key} ${entry.value.length}',
                            selected: _filterSite == entry.key,
                            onTap: () =>
                                setState(() => _filterSite = entry.key),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        if (_posterResults && _totalCount > 0)
          SliverPadding(
            padding: EdgeInsets.all(skin.spaceSm),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.58,
                crossAxisSpacing: 16,
                mainAxisSpacing: 24,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final vod = visibleResults[index];
                  return PosterCard(
                    vod: vod,
                    showSource: true,
                    onTap: () => _openDetail(vod),
                  );
                },
                childCount: visibleResults.length,
                addAutomaticKeepAlives: false,
              ),
            ),
          )
        else if (_totalCount > 0)
          SliverPadding(
            padding: const EdgeInsets.only(top: 4),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final vod = visibleResults[index];
                  return Padding(
                    padding: EdgeInsets.only(bottom: skin.spaceSm - 2),
                    child: WideVodCard(vod: vod, onTap: () => _openDetail(vod)),
                  );
                },
                childCount: visibleResults.length,
                addAutomaticKeepAlives: false,
              ),
            ),
          )
        else if (!_searching)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: skin.spaceLg),
              child: _errors.isEmpty
                  ? EmptyState(
                      message: '没有找到「$_query」相关内容。\n试试更换关键词或切换全局搜索。',
                      icon: Icons.search_off_rounded,
                    )
                  : ErrorState(
                      message: _errors.values.first,
                      onRetry: () => _submit(_query),
                    ),
            ),
          ),
        if (_errors.isNotEmpty && _totalCount > 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 20),
              child: Text(
                '部分站点请求失败：${_errors.keys.map((key) => controller.siteByKey(key)?.name ?? key).join('、')}'
                '${_errors.values.any((message) => message.contains('域名解析失败')) ? '。有站点域名解析失败，可在设置中更换 DNS。' : ''}',
                style: text.label.copyWith(color: skin.textMuted),
              ),
            ),
          ),
      ],
    );
  }

  /// 右栏：热门搜索 / 猜你想搜。
  Widget _buildSuggestPanel(LibraryStore library) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final typing = _input.text.trim().isNotEmpty;
    // 联想词为空（接口失败或还在请求）时退回热词，右栏不要空着。
    final showSuggest = typing && _suggestions.isNotEmpty;
    final words = showSuggest
        ? _suggestions
        : (_hotWords.isEmpty ? library.searchHistory : _hotWords);
    final title = showSuggest ? '猜你想搜' : (_hotWords.isEmpty ? '最近搜索' : '热门搜索');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: skin.spaceXs - 2,
            bottom: skin.spaceSm - 2,
          ),
          child: Text(
            title,
            style: text.bodyStrong.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: words.isEmpty
              ? Center(
                  child: Text(
                    typing && _suggesting ? '正在联想…' : '暂无内容',
                    style: text.meta.copyWith(color: skin.textMuted),
                  ),
                )
              : ListView.separated(
                  physics: const ClampingScrollPhysics(),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(
                    kTvListCacheExtent,
                  ),
                  addAutomaticKeepAlives: false,
                  padding: EdgeInsets.only(bottom: skin.spaceSm - 2),
                  itemCount: words.length,
                  separatorBuilder: (_, _) => SizedBox(height: skin.spaceXs),
                  itemBuilder: (context, index) {
                    final word = words[index];
                    return TvFocusable(
                      radius: skin.radiusSm - 2,
                      scale: 1.03,
                      semanticLabel: word,
                      onTap: () {
                        _input.text = word;
                        _resetKeyboardCycle();
                        _submit(word);
                      },
                      child: Container(
                        height: 42,
                        padding: EdgeInsets.symmetric(
                          horizontal: skin.spaceSm + 2,
                        ),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: skin.surfaceSubtle,
                          borderRadius: BorderRadius.circular(
                            skin.radiusSm - 2,
                          ),
                          border: Border.all(color: skin.borderSoft),
                        ),
                        child: Row(
                          children: [
                            if (!showSuggest)
                              Text(
                                '${index + 1}',
                                style: text.meta.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: skin.textMuted,
                                ),
                              ),
                            if (!showSuggest) SizedBox(width: skin.spaceSm),
                            Expanded(
                              child: Text(
                                word,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.body.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
