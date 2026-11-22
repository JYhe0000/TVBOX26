import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/android_playback.dart';
import '../widgets/push_play_dialog.dart';
import '../widgets/cloud_browser.dart';
import '../widgets/native_pan_browser.dart';
import '../../core/backup_service.dart';
import '../../core/backup_server.dart';
import '../../core/config_url_server.dart';
import '../../core/library_store.dart';
import '../../core/utils.dart';
import '../../data/vod_aggregation.dart';
import '../../data/config_catalog.dart';
import '../../data/dns_presets.dart';
import '../../data/network_policy.dart';
import '../../core/wallpaper_upload_server.dart';
import '../../theme/ui.dart';
import '../tv_canvas.dart';
import '../widgets/common.dart';
import '../widgets/config_url_dialog.dart';
import '../widgets/site_row.dart';
import '../widgets/t9_search_dialog.dart';
import '../widgets/tv_sheet.dart';
import '../widgets/wallpaper_upload_dialog.dart';

import 'package:qr_flutter/qr_flutter.dart';

/// TV 设置屏：左侧分类栏 + 右侧列表行内容面板。
///
/// 旧版是「返回箭头 + 居中 780 宽单列 + 对话框」的手机表单，在 10 英尺外
/// 既读不清也不好操作（AGENTS.md §2 反模式）。现在与 Compose TV
/// `SettingsScreen` 等价：左栏选分类、右栏逐行设置，进页焦点落第一项
/// （FOCUS-06），返回键先退分类、在首个分类才退页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsCategory {
  const _SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _SettingsPageState extends State<SettingsPage> {
  static const List<_SettingsCategory> _categories = [
    _SettingsCategory('主题皮肤', Icons.palette_rounded),
    _SettingsCategory('配置接口', Icons.settings_ethernet_rounded),
    _SettingsCategory('直播源', Icons.live_tv_rounded),
    _SettingsCategory('播放', Icons.play_circle_outline_rounded),
    _SettingsCategory('关于', Icons.info_outline_rounded),
  ];

  final TextEditingController _config = TextEditingController();
  final TextEditingController _vodInput = TextEditingController();
  final TextEditingController _live = TextEditingController();
  final FocusNode _panelFocus = FocusNode(debugLabel: 'settings-panel');
  final FocusScopeNode _pageScope = FocusScopeNode(debugLabel: 'page-settings');
  final List<FocusNode> _categoryNodes = List.generate(
    _categories.length,
    (index) => FocusNode(debugLabel: 'settings-category-$index'),
  );
  int _index = 0;
  bool _booted = false;
  bool _savingLive = false;

  /// 上传对话框是否仍挂在路由栈上（用于收到图片时只 pop 对话框、不误 pop 本页）。
  bool _uploadDialogOpen = false;

  /// 扫码填地址对话框是否仍挂在路由栈上（用于收到 URL 时只 pop 对话框、
  /// 不误 pop 本页）。
  bool _scanDialogOpen = false;

  /// 「导入配置源」是否正在进行（防止遥控器连发 OK 起两个扫码服务）。
  bool _importing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_booted) return;
    _booted = true;
    final controller = context.read<AppController>();
    _config.text = controller.configUrl;
    _live.text = controller.liveUrlOverride;
  }

  @override
  void dispose() {
    _config.dispose();
    _vodInput.dispose();
    _live.dispose();
    _panelFocus.dispose();
    _pageScope.dispose();
    for (final node in _categoryNodes) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final controller = context.read<AppController>();
    // 并发加载时 controller 会直接返回 false，避免误报「配置加载失败」。
    if (controller.loading) return;
    final ok = await controller.loadConfig(_config.text);
    if (!mounted) return;
    if (ok) {
      _config.text = controller.configUrl;
      setState(() {});
      showAppSnack(context, '配置加载成功，已发现 ${controller.sites.length} 个站点');
    } else {
      showAppSnack(context, controller.actionError ?? '配置加载失败', error: true);
    }
  }

  Future<void> _probeSites(AppController controller) async {
    if (controller.siteProbing) return;
    showAppSnack(context, '正在测速…');
    await controller.probeSites(force: true);
    if (!mounted) return;
    showAppSnack(context, controller.siteProbeSummary);
  }

  Future<void> _useBuiltIn() async {
    final controller = context.read<AppController>();
    await controller.useBuiltInConfig();
    if (!mounted) return;
    _config.clear();
    setState(() {});
    showAppSnack(
      context,
      controller.actionError ?? '已切换到内置演示配置',
      error: controller.actionError != null,
    );
  }

  Future<void> _refresh() async {
    final controller = context.read<AppController>();
    await controller.refreshCurrentConfig();
    if (!mounted) return;
    showAppSnack(
      context,
      controller.actionError ?? controller.warning ?? '配置已刷新',
      error: controller.actionError != null,
    );
  }

  Future<void> _saveLive() async {
    setState(() => _savingLive = true);
    await context.read<AppController>().setLiveUrl(_live.text);
    if (!mounted) return;
    setState(() => _savingLive = false);
    showAppSnack(
      context,
      _live.text.trim().isEmpty ? '已恢复使用配置中的直播源' : '直播源已保存',
    );
  }

  /// 返回键语义（AGENTS.md §3.5）：侧栏/分类层先退分类，首个分类才退页。
  void _handleBack() {
    if (_index > 0) {
      setState(() => _index = 0);
      _categoryNodes.first.requestFocus();
      return;
    }
    Navigator.pop(context);
  }

  // 推入式路由没有壳层侧栏：左缘 LEFT 留在本页，BACK 在本层退分类/退页。
  KeyEventResult _handlePageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (event is KeyDownEvent) _handleBack();
      return KeyEventResult.handled;
    }
    final category = _categoryNodes.indexWhere((item) => item.hasFocus);
    if (category >= 0) {
      if (key == LogicalKeyboardKey.arrowDown &&
          category < _categoryNodes.length - 1) {
        _categoryNodes[category + 1].requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp && category > 0) {
        _categoryNodes[category - 1].requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) return KeyEventResult.handled;
    }
    // 面板内部保留已验证的几何遍历，包括同一行的输入框/扫码/操作按钮。
    // 不在根层统一截获 LEFT，否则右侧按钮将无法返回同一行的左侧控件。
    return KeyEventResult.ignored;
  }

  Future<void> _selectSkin(TvSkinId id) async {
    if (id == context.read<AppController>().skinId) return;
    await context.read<AppController>().setSkin(id);
  }

  Future<void> _selectAccentColor(TvAccentColor color) async {
    if (color == context.read<AppController>().accentColor) return;
    await context.read<AppController>().setAccentColor(color);
  }

  /// 手机上传背景图：起局域网服务 → 弹二维码对话框 → 收到图片后存本地文件。
  /// 收到图片的回调会 pop 对话框，从而让本方法在 `showWallpaperUploadDialog`
  /// 返回后统一停服务，避免「服务还在跑但对话框已关」的泄漏。
  Future<void> _pickWallpaper() async {
    final server = WallpaperUploadServer(
      onImageReceived: (bytes, filename) => _onWallpaperReceived(bytes),
    );
    final String url;
    try {
      url = await server.start();
    } catch (error) {
      if (!mounted) return;
      showAppSnack(context, '上传服务启动失败：$error', error: true);
      return;
    }
    if (!mounted) {
      await server.stop();
      return;
    }
    _uploadDialogOpen = true;
    try {
      await showWallpaperUploadDialog(context, url);
    } finally {
      _uploadDialogOpen = false;
      await server.stop();
    }
  }

  /// 收到图片：先落盘、更新覆盖，再关对话框。
  ///
  /// 顺序有讲究：落盘里的几次 `await` 会反复让出事件循环，给上传服务的
  /// `{ok:true}` 响应留出 flush 时间；等落盘完成再 pop 对话框，[_pickWallpaper]
  /// 才会去 `server.stop()`。若先 pop 再落盘，force close 可能在响应 flush 前
  /// 打断连接，手机端会误报「连接失败」。
  Future<void> _onWallpaperReceived(Uint8List bytes) async {
    if (!mounted) return;
    final controller = context.read<AppController>();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/wallpaper_override.jpg');
      await file.writeAsBytes(bytes, flush: true);
      await controller.setWallpaperOverride(file.path);
    } catch (error) {
      if (_uploadDialogOpen && mounted) Navigator.of(context).pop();
      if (mounted) showAppSnack(context, '保存背景图失败：$error', error: true);
      return;
    }
    if (_uploadDialogOpen && mounted) Navigator.of(context).pop();
    if (mounted) showAppSnack(context, '背景图已更新');
  }

  /// 恢复默认背景：删本地文件 + 清除覆盖。
  Future<void> _clearWallpaper() async {
    final controller = context.read<AppController>();
    final path = controller.wallpaperOverride;
    if (path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 删除失败不阻断清除覆盖状态。
      }
    }
    await controller.setWallpaperOverride('');
    if (!mounted) return;
    showAppSnack(context, '已恢复默认背景');
  }

  /// 手机扫码填地址：起局域网服务 → 弹二维码对话框 → 收到 URL 后填入 [target]
  /// 输入框并关对话框、停服务。
  ///
  /// 调用链与 [_pickWallpaper] 对齐：收到 URL 的回调会 pop 对话框，从而让本方法
  /// 在 `showConfigUrlDialog` 返回后统一停服务，避免「服务还在跑但对话框已关」
  /// 的泄漏。
  Future<void> _scanUrl(TextEditingController target, String title) async {
    final server = ConfigUrlServer(
      onUrl: (url) => _onConfigUrlReceived(target, url),
    );
    final String url;
    try {
      url = await server.start();
    } catch (error) {
      if (!mounted) return;
      showAppSnack(context, '扫码服务启动失败：$error', error: true);
      return;
    }
    if (!mounted) {
      await server.stop();
      return;
    }
    _scanDialogOpen = true;
    try {
      await showConfigUrlDialog(context, url, title);
    } finally {
      _scanDialogOpen = false;
      // 无论正常关闭还是异常退出，都必须停掉局域网服务（避免端口泄漏）。
      await server.stop();
    }
  }

  /// 收到手机提交的 URL：只关对话框、填输入框，不误 pop 本页。
  void _onConfigUrlReceived(TextEditingController target, String url) {
    if (!mounted) return;
    if (_scanDialogOpen) {
      Navigator.of(context).pop();
      _scanDialogOpen = false;
    }
    target.text = url;
    setState(() {});
    showAppSnack(context, '地址已填入，点击下方按钮即可生效');
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final library = context.watch<LibraryStore>();
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: FocusScope(
        node: _pageScope,
        onKeyEvent: _handlePageKey,
        child: FocusTraversalGroup(
          child: Scaffold(
            backgroundColor: skin.bg,
            body: AppBackground(
              wallpaper: controller.wallpaper,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    TvCanvas.pagePad,
                    18,
                    TvCanvas.pagePad,
                    22,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('设置', style: text.pageTitle),
                                const SizedBox(height: 2),
                                Text(
                                  '外观 · 接口 · 直播 · 播放',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.label.copyWith(
                                    color: skin.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: skin.spaceMd),
                          if (controller.loading)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                              ),
                            )
                          else
                            _HeaderAction(
                              icon: Icons.arrow_back_rounded,
                              label: '返回',
                              onTap: _handleBack,
                            ),
                        ],
                      ),
                      SizedBox(height: skin.spaceMd + 2),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _CategoryRail(
                              nodes: _categoryNodes,
                              categories: _categories,
                              index: _index,
                              onSelect: (next) => setState(() => _index = next),
                            ),
                            SizedBox(width: skin.spaceMd + 2),
                            Expanded(
                              child: _Panel(
                                focusNode: _panelFocus,
                                child: ListView(
                                  // 右侧栏自己的滚动容器：整屏不套
                                  // SingleChildScrollView，否则双栏会被撑成
                                  // 单列（AGENTS.md §2）。
                                  physics: const ClampingScrollPhysics(),
                                  scrollCacheExtent:
                                      const ScrollCacheExtent.pixels(
                                        kTvListCacheExtent,
                                      ),
                                  addAutomaticKeepAlives: false,
                                  padding: EdgeInsets.only(
                                    bottom: skin.spaceSm,
                                  ),
                                  children: _buildCategory(controller, library),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCategory(AppController controller, LibraryStore library) {
    switch (_categories[_index].label) {
      case '主题皮肤':
        return _skinSection(controller);
      case '配置接口':
        return _configSection(controller);
      case '直播源':
        return _liveSection(controller);
      case '播放':
        return _playSection(controller, library);
      default:
        return _aboutSection();
    }
  }

  // —— 主题皮肤 ——

  List<Widget> _skinSection(AppController controller) {
    final skin = TvSkin.of(context);
    return [
      _PanelHeader(title: '主题皮肤', subtitle: '切换后立即生效，三套皮肤共享同一套 1280×720 版式'),
      for (final id in TvSkinId.values)
        _SkinRow(
          id: id,
          selected: controller.skinId == id,
          onTap: () => _selectSkin(id),
        ),
      SizedBox(height: skin.spaceSm),
      _PanelHeader(title: '主题色', subtitle: '统一调整选中态、按钮与强调色；默认跟随皮肤'),
      Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.md,
        children: [
          for (final color in TvAccentColor.values)
            _AccentColorOption(
              color: color,
              selected: controller.accentColor == color,
              onTap: () => _selectAccentColor(color),
            ),
        ],
      ),
      SizedBox(height: skin.spaceSm),
      _PanelHeader(title: '背景底图', subtitle: '设置全局背景图，优先于配置壁纸'),
      _Row(
        icon: Icons.wallpaper_rounded,
        title: '自定义底图',
        subtitle: controller.wallpaperOverride.isEmpty
            ? '未设置，使用配置壁纸'
            : '已启用自定义背景图',
        child: _RowButtons(
          buttons: [
            _Btn(label: '上传背景图', filled: true, onTap: _pickWallpaper),
            _Btn(label: '恢复默认', onTap: _clearWallpaper),
          ],
        ),
      ),
      _ToggleRow(
        icon: Icons.blur_on_rounded,
        title: '背景模糊',
        subtitle: '背景图与氛围图高斯模糊（默认关闭，直接铺图）',
        value: controller.blurBackground,
        onChanged: controller.setBlurBackground,
      ),
      SizedBox(height: skin.spaceSm),
      _Hint(
        icon: Icons.lightbulb_outline_rounded,
        text:
            '焦点外观随皮肤变化：默认皮肤用白描边放大，'
            'Smartisan 整行换色并跟随主题色。',
      ),
    ];
  }

  // —— 配置接口 ——

  /// 当前首页站点的可读描述，供「首页站点」行显示。
  String _currentSiteSubtitle(AppController controller) {
    final supported = controller.sites
        .where(controller.siteApi.supports)
        .toList();
    if (supported.isEmpty) return '没有兼容的点播站点';
    final current =
        supported.any((site) => site.key == controller.selectedSite?.key)
        ? controller.selectedSite!
        : supported.first;
    return '${current.name} · ${current.typeLabel} · 共 ${supported.length} 个站点';
  }

  List<Widget> _configSection(AppController controller) {
    final skin = TvSkin.of(context);
    return [
      if (controller.actionError != null) ...[
        _Banner(
          message: controller.actionError!,
          color: skin.danger,
          icon: Icons.error_outline_rounded,
        ),
        SizedBox(height: skin.spaceSm),
      ],
      if (controller.warning != null) ...[
        _Banner(
          message: controller.warning!,
          color: skin.warning,
          icon: Icons.info_outline_rounded,
        ),
        SizedBox(height: skin.spaceSm),
      ],
      _PanelHeader(
        title: controller.usingVodAggregate
            ? controller.configLabel
            : controller.usingBuiltIn
            ? '内置演示配置'
            : '自定义配置',
        subtitle:
            '${controller.sites.length} 个站点 · ${controller.config.lives.length} 个直播源',
        icon: controller.usingBuiltIn
            ? Icons.offline_bolt_rounded
            : Icons.cloud_done_rounded,
        tint: controller.usingBuiltIn ? skin.success : skin.accent,
      ),
      const _GroupLabel('配置地址'),
      _Row(
        icon: Icons.link_rounded,
        title: '配置接口地址',
        subtitle: controller.usingBuiltIn
            ? '留空使用内置配置，或粘贴 TVBox 配置地址'
            : controller.configUrl,
        child: Row(
          children: [
            Expanded(
              child: _Field(
                controller: _config,
                hint: 'https://example.com/tvbox.json',
                onSubmit: _loadConfig,
              ),
            ),
            SizedBox(width: skin.spaceSm),
            _ScanButton(onTap: () => _scanUrl(_config, '手机填写配置地址')),
          ],
        ),
      ),
      _ActionRow(
        icon: Icons.playlist_add_rounded,
        title: '导入配置源',
        subtitle: '扫码粘贴 urls.json 地址（${ConfigCatalog.repo} 等）',
        onTap: () => _showConfigImport(controller),
      ),
      _ActionRow(
        icon: Icons.layers_rounded,
        title: '点播聚合',
        subtitle: _vodStatus(controller),
        onTap: () => _showVodSources(controller),
      ),
      const _GroupLabel('首页站点'),
      _ActionRow(
        icon: Icons.dns_rounded,
        title: 'DNS 与代理',
        subtitle: '当前使用$_networkLabel',
        onTap: () => _showNetwork(controller),
      ),
      _ActionRow(
        icon: Icons.history_rounded,
        title: '配置接口历史',
        subtitle: '最近成功加载的接口，可重新选择或清空',
        onTap: () => _showConfigHistory(controller),
      ),
      _ActionRow(
        icon: Icons.tune_rounded,
        title: '站点启用与排序',
        subtitle: '禁用站点不参与浏览和聚合搜索，可将常用站点置顶',
        onTap: () => _manageSites(controller),
      ),
      _ActionRow(
        icon: Icons.speed_rounded,
        title: '站点测速',
        subtitle: controller.siteProbeSummary,
        onTap: () => _probeSites(controller),
      ),
      _Row(
        icon: Icons.dns_rounded,
        title: '当前站点',
        subtitle: _currentSiteSubtitle(controller),
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 260,
            child: FilledButton.icon(
              onPressed: () => _pickSite(controller),
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('选择站点'),
            ),
          ),
        ),
      ),
      const _GroupLabel('操作'),
      _Row(
        icon: Icons.cloud_download_rounded,
        title: '加载配置',
        subtitle: '解析接口中的 video.sites / lives / parses',
        child: _RowButtons(
          buttons: [
            _Btn(
              label: '加载配置',
              filled: true,
              busy: controller.loading,
              onTap: _loadConfig,
            ),
            _Btn(label: '刷新当前', onTap: _refresh),
            _Btn(label: '内置源', onTap: _useBuiltIn),
          ],
        ),
      ),
      const _GroupLabel('格式说明'),
      _ToggleRow(
        icon: Icons.memory_rounded,
        title: '直播增强内核',
        subtitle: '启用 media_kit；下次播放或切换频道生效',
        value: controller.liveMediaKit,
        onChanged: controller.setLiveMediaKit,
      ),
      _ActionRow(
        icon: Icons.event_note_rounded,
        title: '节目单地址与历史',
        subtitle: controller.epgOverride.isEmpty
            ? '跟随直播源，可扫码设置独立 EPG'
            : controller.epgOverride,
        onTap: () => _showEpgHistory(controller),
      ),
      _Hint(
        icon: Icons.description_outlined,
        text:
            '支持标准 TVBox JSON 配置（video.sites / lives / parses）。'
            '支持 JSON / XML、type:4，以及兼容的 Android HTTPS JAR / JS Spider 站点。',
      ),
    ];
  }

  String _vodStatus(AppController controller) {
    if (controller.vodUpdating) return '更新中…';
    if (!controller.usingVodAggregate) return '未启用';
    if (!controller.vodAggregateActive) return '已回退到基础配置';
    final cached = controller.vodSourceStatuses.values
        .where((status) => status == VodSourceStatus.cached)
        .length;
    final unavailable = controller.vodSourceStatuses.values
        .where((status) => status == VodSourceStatus.unavailable)
        .length;
    return [
      '已启用 · ${controller.vodUrls.length} 个源',
      if (cached > 0) '$cached 个使用缓存',
      if (unavailable > 0) '$unavailable 个暂不可用',
    ].join(' · ');
  }

  /// 导入配置源：先弹二维码，手机粘贴 urls.json 地址后电视拉取列表并选一条。
  Future<void> _showConfigImport(AppController controller) async {
    if (controller.loading || _importing) return;
    _importing = true;
    try {
      // 先留个备份：用户取消扫码时恢复原地址，不清空已手输/已生效的地址。
      final previous = _config.text;
      _config.clear();
      await _scanUrl(_config, '扫码填写 urls.json 地址');
      if (!mounted) return;
      final indexUrl = _config.text.trim();
      if (indexUrl.isEmpty) {
        _config.text = previous;
        return;
      }
      await _importConfigList(indexUrl, previous);
    } finally {
      _importing = false;
    }
  }

  /// 拉取 urls.json 并以侧栏列出条目，选中后按普通配置地址加载。
  ///
  /// [previous] 是进入导入流程前的地址；中途失败/取消时还原，避免输入框
  /// 留下 urls.json 索引地址（用户点「加载」会去加载列表本身）。
  Future<void> _importConfigList(String indexUrl, String previous) async {
    showAppSnack(context, '正在读取配置列表…');
    final ConfigCatalogResult result;
    try {
      result = await ConfigCatalog().loadFromUrl(indexUrl);
    } catch (error) {
      if (!mounted) return;
      _config.text = previous;
      showAppSnack(context, '读取配置列表失败：$error', error: true);
      return;
    }
    if (!mounted) return;
    final host = Uri.tryParse(indexUrl)?.host ?? indexUrl;
    final picked = await showTvSheet<String>(
      context,
      title: '选择配置',
      subtitle: '${result.entries.length} 个配置 · 来自 $host',
      width: 640,
      // 侧栏内容自己有 autofocus，关掉关闭按钮的 autofocus 避免双焦点。
      autofocusClose: false,
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        final text = AppText.of(sheetContext);
        return ListView.builder(
          padding: EdgeInsets.all(skin.spaceLg),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          itemCount: result.entries.length,
          itemBuilder: (_, index) {
            final entry = result.entries[index];
            return TvFocusable(
              autofocus: index == 0,
              semanticLabel: entry.name,
              onTap: () => Navigator.of(sheetContext).pop(entry.url),
              child: Padding(
                padding: EdgeInsets.all(skin.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyStrong.copyWith(color: Colors.white),
                    ),
                    Text(
                      entry.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.meta.copyWith(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (picked == null || !mounted) {
      if (mounted) _config.text = previous;
      return;
    }
    final value = picked.trim();
    if (!value.startsWith('http://') &&
        !value.startsWith('https://') &&
        !value.startsWith('clan://')) {
      _config.text = previous;
      showAppSnack(context, '只支持 http(s) 或 clan:// 配置地址', error: true);
      return;
    }
    _config.text = value;
    await _loadConfig();
  }

  Future<void> _showVodSources(AppController controller) async {
    if (controller.loading) return;
    final sources = controller.vodUrls.toList();
    if (sources.isEmpty && controller.configUrl.isNotEmpty) {
      sources.add(controller.configUrl);
    }
    _vodInput.clear();
    String? error;
    var updating = false;
    await showTvSheet<void>(
      context,
      title: '点播聚合',
      width: 640,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final skin = TvSkin.of(context);
          final text = AppText.of(context);
          void add() {
            final value = _vodInput.text.trim();
            if (value.isEmpty) return;
            update(() {
              if (sources.contains(value)) {
                error = '该地址已添加';
              } else if (sources.length >= AppController.maxVodSources) {
                error = '已达到配置源数量上限';
              } else {
                sources.add(value);
                _vodInput.clear();
                error = null;
              }
            });
          }

          Future<void> apply(List<String> urls) async {
            update(() {
              error = null;
              updating = true;
            });
            final ok = await controller.setVodSources(urls);
            if (!sheetContext.mounted ||
                ModalRoute.of(sheetContext)?.isCurrent != true) {
              return;
            }
            if (ok) {
              Navigator.of(sheetContext).pop();
            } else {
              update(() {
                updating = false;
                error = controller.actionError ?? '暂时无法更新点播聚合';
              });
            }
          }

          return ListView(
            padding: EdgeInsets.all(skin.spaceLg),
            scrollCacheExtent: const ScrollCacheExtent.pixels(
              kTvListCacheExtent,
            ),
            addAutomaticKeepAlives: false,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  '聚合状态：${updating ? '更新中…' : _vodStatus(controller)}',
                  // 侧栏固定深色底，浅色文字在亮色皮肤下也保持可读。
                  style: text.bodyStrong.copyWith(color: Colors.white),
                ),
              ),
              SizedBox(height: skin.spaceMd),
              _RowButtons(
                buttons: [
                  _Btn(
                    label: '应用聚合',
                    filled: true,
                    busy: controller.loading || sources.length < 2,
                    onTap: () => apply(sources.toList()),
                  ),
                  if (controller.usingVodAggregate)
                    _Btn(
                      label: '关闭聚合',
                      busy: controller.loading,
                      onTap: () => apply([]),
                    ),
                ],
              ),
              SizedBox(height: skin.spaceMd),
              if (error != null)
                Text(error!, style: text.body.copyWith(color: Colors.white)),
              if (!controller.loading &&
                  sources.length < AppController.maxVodSources) ...[
                Row(
                  children: [
                    Expanded(
                      child: _Field(
                        controller: _vodInput,
                        hint: '输入 TVBox 配置地址',
                        onSubmit: add,
                      ),
                    ),
                    SizedBox(width: skin.spaceSm),
                    _ScanButton(
                      onTap: () async {
                        await _scanUrl(_vodInput, '手机填写点播配置地址');
                        if (context.mounted &&
                            ModalRoute.of(context)?.isCurrent == true) {
                          add();
                        }
                      },
                    ),
                  ],
                ),
                SizedBox(height: skin.spaceMd),
              ],
              for (final (index, url) in sources.indexed)
                Padding(
                  key: ValueKey(url),
                  padding: EdgeInsets.only(bottom: skin.spaceSm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${index + 1}. $url',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyStrong.copyWith(
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              switch (controller.vodSourceStatuses[url]) {
                                VodSourceStatus.online =>
                                  controller.vodSourcesWithoutHttpSites
                                          .contains(url)
                                      ? '已读取，但没有兼容的点播站点'
                                      : '配置已更新',
                                VodSourceStatus.cached => '沿用上次缓存',
                                VodSourceStatus.unavailable => '暂不可用',
                                null => '待应用',
                              },
                              style: text.body.copyWith(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      _RowButton(
                        button: _Btn(
                          label: '移除',
                          busy: controller.loading,
                          onTap: () {
                            update(() {
                              sources.remove(url);
                              error = null;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _manageSites(AppController controller) async {
    final sites = controller.config.visibleSites;
    await showTvSheet<void>(
      context,
      title: '站点启用与排序',
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
              final enabled = !controller.disabledSites.contains(site.key);
              return Padding(
                padding: EdgeInsets.only(bottom: skin.spaceSm),
                child: Row(
                  children: [
                    Expanded(
                      child: TvFocusable(
                        autofocus: index == 0,
                        semanticLabel:
                            '${site.name}，${enabled ? '已启用' : '已禁用'}，'
                            '${controller.siteProbeLabel(site)}',
                        onTap: () async {
                          await controller.toggleSite(site.key);
                          if (context.mounted) update(() {});
                        },
                        child: Padding(
                          padding: EdgeInsets.all(skin.spaceMd),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${enabled ? '☑' : '☐'} ${site.name}',
                                style: text.bodyStrong.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                controller.siteProbeLabel(site),
                                style: text.meta.copyWith(
                                  color: Colors.white.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    TvFocusable(
                      semanticLabel: '置顶${site.name}',
                      onTap: () async {
                        await controller.promoteSite(site.key);
                        if (context.mounted) {
                          showAppSnack(context, '已将${site.name}置顶');
                        }
                      },
                      child: Padding(
                        padding: EdgeInsets.all(skin.spaceMd),
                        child: Text(
                          '置顶',
                          style: text.body.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showConfigHistory(AppController controller) async {
    final entries = controller.storage.getJsonList('config_url_history');
    final selected = await showTvSheet<String>(
      context,
      title: '配置接口历史',
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        final text = AppText.of(sheetContext);
        return ListView(
          padding: EdgeInsets.all(skin.spaceLg),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          children: [
            for (var i = 0; i < entries.length; i++)
              TvFocusable(
                autofocus: i == 0,
                onTap: () =>
                    Navigator.pop(sheetContext, entries[i]['url'] as String),
                child: Padding(
                  padding: EdgeInsets.all(skin.spaceMd),
                  child: Text(
                    entries[i]['url'] as String,
                    style: text.body.copyWith(color: Colors.white),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            TvFocusable(
              autofocus: entries.isEmpty,
              onTap: () async {
                await controller.storage.remove('config_url_history');
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
              child: Padding(
                padding: EdgeInsets.all(skin.spaceMd),
                child: Text(
                  '清空历史',
                  style: text.bodyStrong.copyWith(color: Colors.white),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (selected != null && mounted) {
      _config.text = selected;
      await _loadConfig();
    }
  }

  Future<void> _showEpgHistory(AppController controller) async {
    final entries = controller.storage.getJsonList('epg_url_history');
    final selected = await showTvSheet<String>(
      context,
      title: '节目单地址与历史',
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        final text = AppText.of(sheetContext);
        Widget row(String label, String result, {bool first = false}) =>
            TvFocusable(
              autofocus: first,
              onTap: () => Navigator.pop(sheetContext, result),
              child: Padding(
                padding: EdgeInsets.all(skin.spaceMd),
                child: Text(
                  label,
                  style: text.body.copyWith(color: Colors.white),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
        return ListView(
          padding: EdgeInsets.all(skin.spaceLg),
          children: [
            row('扫码设置 EPG 地址', '@scan', first: true),
            row('跟随直播源', ''),
            for (final entry in entries)
              row(entry['url'] as String, entry['url'] as String),
            row('清空历史', '@clear'),
          ],
        );
      },
    );
    if (!mounted || selected == null) return;
    if (selected == '@clear') {
      await controller.storage.remove('epg_url_history');
      return;
    }
    if (selected != '@scan') {
      await controller.setEpgUrl(selected);
      return;
    }
    String? received;
    var open = false;
    final server = ConfigUrlServer(
      onUrl: (url) {
        received = url;
        if (mounted && open) {
          open = false;
          Navigator.of(context, rootNavigator: true).pop();
        }
      },
    );
    try {
      final address = await server.start();
      if (!mounted) return;
      open = true;
      await showConfigUrlDialog(context, address, '扫码设置节目单地址');
      open = false;
      if (received != null) await controller.setEpgUrl(received!);
    } catch (_) {
      if (mounted) showAppSnack(context, '远程输入启动失败，请检查局域网连接', error: true);
    } finally {
      await server.stop();
    }
  }

  /// 弹幕站基础地址：九宫格输入（§7 搜索类输入不拉软键盘），
  /// 关闭弹窗后把缓冲回写控制器并持久化。
  Future<void> _editDanmakuBaseUrl(AppController controller) async {
    var buffer = controller.danmakuBaseUrl;
    await showT9SearchDialog(
      context,
      title: '弹幕站地址',
      initial: controller.danmakuBaseUrl,
      hint: '输入弹幕站基础地址，如 https://dm.example.com',
      onChanged: (value) => buffer = value,
    );
    final value = buffer.trim();
    if (value == controller.danmakuBaseUrl) return;
    await controller.setDanmakuBaseUrl(value);
    if (!mounted) return;
    showAppSnack(context, value.isEmpty ? '已清除弹幕站地址' : '弹幕站地址已更新');
  }

  Future<void> _showApps() async {
    try {
      final apps = await AndroidPlayback.apps();
      if (!mounted) return;
      await showTvSheet<void>(
        context,
        title: '电视应用管理',
        subtitle: '系统管理页提供卸载、清理和应用信息',
        builder: (sheetContext) {
          final skin = TvSkin.of(sheetContext);
          final text = AppText.of(sheetContext);
          return ListView.builder(
            padding: EdgeInsets.all(skin.spaceLg),
            scrollCacheExtent: const ScrollCacheExtent.pixels(
              kTvListCacheExtent,
            ),
            addAutomaticKeepAlives: false,
            itemCount: apps.length,
            itemBuilder: (_, index) {
              final app = apps[index];
              Future<void> action(String method) async {
                final ok = await AndroidPlayback.appAction(
                  method,
                  app['package']!,
                );
                if (!ok && sheetContext.mounted) {
                  showAppSnack(sheetContext, '无法打开，请使用电视系统的应用管理', error: true);
                }
              }

              return Row(
                children: [
                  Expanded(
                    child: TvFocusable(
                      autofocus: index == 0,
                      onTap: () => action('launchApp'),
                      semanticLabel: '打开${app['name']}',
                      child: Padding(
                        padding: EdgeInsets.all(skin.spaceMd),
                        child: Text(
                          app['name']!,
                          style: text.bodyStrong.copyWith(color: Colors.white),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  TvFocusable(
                    onTap: () => action('appDetails'),
                    semanticLabel: '管理${app['name']}',
                    child: Padding(
                      padding: EdgeInsets.all(skin.spaceMd),
                      child: Text(
                        '管理',
                        style: text.body.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    } catch (_) {
      if (mounted) showAppSnack(context, '应用管理仅适用于 Android TV');
    }
  }

  String get _networkLabel {
    if (NetworkPolicy.proxy.isNotEmpty) return 'HTTP 代理';
    if (NetworkPolicy.dohEndpoints.isEmpty) return '系统 DNS';
    if (NetworkPolicy.dohEndpoints.length == 1) {
      for (final entry in dnsPresets.entries) {
        if (entry.value == NetworkPolicy.dohEndpoint) return entry.key;
      }
    }
    return '已保存的 DNS';
  }

  Future<void> _showNetwork(AppController controller) async {
    final current = _networkLabel;
    final choices = {
      for (final name in dnsPresets.keys) name: name == '关闭' ? '系统 DNS' : name,
      if (current == '已保存的 DNS') current: current,
      'proxy': 'HTTP 代理',
    };
    final selected = await showTvSheet<String>(
      context,
      title: 'DNS 与代理',
      subtitle: '当前使用$current · 确定键选择，返回键取消',
      autofocusClose: false,
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        final text = AppText.of(sheetContext);
        return ListView(
          padding: EdgeInsets.all(skin.spaceLg),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          children: [
            for (final entry in choices.entries)
              Semantics(
                selected: entry.value == current,
                child: TvFocusable(
                  autofocus: entry.value == current,
                  onTap: () => Navigator.pop(sheetContext, entry.key),
                  child: Padding(
                    padding: EdgeInsets.all(skin.spaceMd),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            switch (entry.key) {
                              '关闭' => '关闭（系统 DNS）',
                              'proxy' => '扫码设置 HTTP 代理',
                              _ => entry.key,
                            },
                            style: text.bodyStrong.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                        if (entry.value == current)
                          const Icon(Icons.check_rounded, color: Colors.white),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
    if (!mounted || selected == null) return;
    if (selected != 'proxy') {
      if (choices[selected] == current) return;
      await controller.setNetwork(doh: dnsPresets[selected]!, proxy: '');
      return;
    }
    String? received;
    var open = false;
    final server = ConfigUrlServer(
      onUrl: (url) {
        received = url;
        if (mounted && open) {
          open = false;
          Navigator.of(context, rootNavigator: true).pop();
        }
      },
    );
    try {
      final address = await server.start();
      if (!mounted) return;
      open = true;
      await showConfigUrlDialog(context, address, 'HTTP 代理（http://主机:端口）');
      open = false;
      final uri = Uri.tryParse(received ?? '');
      if (uri == null ||
          uri.scheme != 'http' ||
          uri.host.isEmpty ||
          !uri.hasPort ||
          uri.userInfo.isNotEmpty) {
        if (received != null && mounted) {
          showAppSnack(context, '请输入 http://主机:端口，暂不支持账号密码代理');
        }
        return;
      }
      await controller.setNetwork(proxy: uri.toString());
    } catch (_) {
      if (mounted) showAppSnack(context, '代理设置失败，请检查地址和局域网连接');
    } finally {
      await server.stop();
    }
  }

  // —— 直播源 ——

  List<Widget> _liveSection(AppController controller) {
    final skin = TvSkin.of(context);
    return [
      _PanelHeader(
        title: '电视直播',
        subtitle: controller.liveUrlOverride.isEmpty
            ? '当前使用配置中的直播源：'
                  '${controller.config.lives.isEmpty ? '无' : controller.config.lives.first.name}'
            : '当前使用自定义直播源',
        icon: Icons.live_tv_rounded,
      ),
      const _GroupLabel('直播源地址'),
      _Row(
        icon: Icons.link_rounded,
        title: 'M3U / TXT 地址',
        subtitle: '留空表示跟随配置中的默认直播源',
        child: Row(
          children: [
            Expanded(
              child: _Field(
                controller: _live,
                hint: 'https://example.com/live.m3u',
                onSubmit: _saveLive,
              ),
            ),
            SizedBox(width: skin.spaceSm),
            _ScanButton(onTap: () => _scanUrl(_live, '手机填写直播源地址')),
          ],
        ),
      ),
      const _GroupLabel('操作'),
      _Row(
        icon: Icons.save_rounded,
        title: '保存直播源',
        subtitle: '保存后直播页会立即改用新的直播源',
        child: _RowButtons(
          buttons: [
            _Btn(
              label: '保存直播源',
              filled: true,
              busy: _savingLive,
              onTap: _saveLive,
            ),
            _Btn(
              label: '恢复默认',
              onTap: () {
                _live.clear();
                _saveLive();
              },
            ),
          ],
        ),
      ),
      const _GroupLabel('格式说明'),
      _Hint(
        icon: Icons.info_outline_rounded,
        text: '支持 M3U 与「频道,#genre#」格式的 TXT 直播源，频道同名源会自动合并。',
      ),
    ];
  }

  // —— 播放 ——

  List<Widget> _playSection(AppController controller, LibraryStore library) {
    return [
      _PanelHeader(title: '播放与体验', subtitle: '播放行为与本地数据'),
      const _GroupLabel('播放'),
      _ToggleRow(
        icon: Icons.headphones_rounded,
        title: '后台继续播放',
        subtitle: '离开应用后保留点播音频；系统仍可能回收进程',
        value: controller.backgroundPlayback,
        onChanged: controller.setBackgroundPlayback,
      ),
      _ToggleRow(
        icon: Icons.view_list_rounded,
        title: '首页横版行布局',
        subtitle: '关闭使用海报网格，开启使用横版卡片行',
        value: controller.homeRows,
        onChanged: controller.setHomeRows,
      ),
      _ToggleRow(
        icon: Icons.label_outline_rounded,
        title: '显示来源角标',
        subtitle: '控制海报与影片卡片上的站点来源角标',
        value: controller.showSourceBadges,
        onChanged: controller.setShowSourceBadges,
      ),
      _ToggleRow(
        icon: Icons.play_circle_outline_rounded,
        title: '进入点播后自动播放',
        subtitle: '关闭后先显示画面，按确定键开始播放',
        value: controller.autoPlay,
        onChanged: controller.setAutoPlay,
      ),
      _ToggleRow(
        icon: Icons.skip_next_rounded,
        title: '自动播放下一集',
        subtitle: '当前剧集播放完毕后自动继续',
        value: controller.autoNext,
        onChanged: controller.setAutoNext,
      ),
      _ToggleRow(
        icon: Icons.chat_bubble_rounded,
        title: '弹幕自动匹配',
        subtitle: '进播按片名与集号自动获取当前集弹幕，需先配置弹幕站地址',
        value: controller.danmakuAutoMatch,
        onChanged: controller.setDanmakuAutoMatch,
      ),
      _ActionRow(
        icon: Icons.link_rounded,
        title: '弹幕站地址',
        subtitle: controller.danmakuBaseUrl.isEmpty
            ? '未配置，自动匹配不可用'
            : controller.danmakuBaseUrl,
        onTap: () => _editDanmakuBaseUrl(controller),
      ),
      _ToggleRow(
        icon: Icons.memory_rounded,
        title: '字幕与音轨增强内核',
        subtitle: '启用 media_kit，支持内嵌/外挂字幕与多音轨；下次打开点播生效',
        value: controller.useMediaKit,
        onChanged: controller.setUseMediaKit,
      ),
      const _GroupLabel('数据管理'),
      _ActionRow(
        icon: Icons.cloud_queue_rounded,
        title: '原生网盘（扫码登录）',
        subtitle: '阿里 / 夸克 / 百度手机扫码；凭据仅存本机，失败可手动粘贴',
        onTap: () => showNativePanBrowser(context),
      ),
      _ActionRow(
        icon: Icons.cloud_rounded,
        title: '网盘（WebDAV）',
        subtitle: '浏览 WebDAV / OpenList 网盘并播放；账号仅在本次会话使用',
        onTap: () => showCloudBrowser(context),
      ),
      _ActionRow(
        icon: Icons.cast_rounded,
        title: '手机投送播放',
        subtitle: '手机扫码发送视频地址，电视使用现有解析链路播放',
        onTap: () => showPushPlayDialog(context),
      ),
      _ActionRow(
        icon: Icons.apps_rounded,
        title: '电视应用管理',
        subtitle: '打开电视应用或进入系统管理页更新、卸载与清理',
        onTap: _showApps,
      ),
      _ActionRow(
        icon: Icons.backup_rounded,
        title: '备份与恢复',
        subtitle: '手机扫码下载或上传 JSON，包含设置、收藏与播放历史',
        onTap: _showBackup,
      ),
      _ActionRow(
        icon: Icons.cleaning_services_rounded,
        title: '清理配置缓存',
        subtitle: '下次启动将重新从网络拉取配置',
        onTap: () async {
          await controller.clearCache();
          if (!mounted) return;
          showAppSnack(context, '配置缓存已清理');
        },
      ),
      _ActionRow(
        icon: Icons.history_rounded,
        title: '清空播放历史',
        subtitle: '${library.history.length} 条记录',
        onTap: () => _confirm('清空播放历史', '播放历史', confirmLabel: '清空').then((ok) {
          if (ok) library.clearHistory();
        }),
      ),
      _ActionRow(
        icon: Icons.favorite_rounded,
        title: '清空收藏',
        subtitle: '${library.favorites.length} 部影片',
        onTap: () => _confirm('清空收藏', '收藏', confirmLabel: '清空').then((ok) {
          if (ok) library.clearFavorites();
        }),
      ),
    ];
  }

  // —— 关于 ——

  Future<void> _showBackup() async {
    final controller = context.read<AppController>();
    final library = context.read<LibraryStore>();
    final service = BackupService(controller.storage);
    String? pending;
    var open = false;
    final server = BackupServer(
      service,
      onRestore: (body) async {
        pending = body;
        if (mounted && open) {
          open = false;
          Navigator.of(context, rootNavigator: true).pop();
        }
      },
    );
    try {
      final address = await server.start();
      if (!mounted) return;
      open = true;
      await showTvSheet<void>(
        context,
        title: '备份与恢复',
        subtitle: '手机与电视连接同一 Wi-Fi',
        builder: (context) {
          final skin = TvSkin.of(context);
          final text = AppText.of(context);
          return Padding(
            padding: EdgeInsets.all(skin.spaceLg),
            child: Column(
              children: [
                Text(
                  '扫码下载备份，或选择 JSON 文件上传恢复。恢复前需要在电视上确认。',
                  style: text.bodyLarge.copyWith(color: Colors.white),
                ),
                SizedBox(height: skin.spaceLg),
                // 二维码固定黑码白底，确保所有皮肤下可扫描。
                ColoredBox(
                  color: Colors.white,
                  child: QrImageView(data: address, size: 220),
                ),
                SizedBox(height: skin.spaceMd),
                Text(address, style: text.body.copyWith(color: Colors.white)),
              ],
            ),
          );
        },
      );
      open = false;
      if (!mounted || pending == null) return;
      final confirmed = await _confirm(
        '恢复备份',
        '当前设置、收藏与播放历史（将被备份内容覆盖）',
        confirmLabel: '恢复',
      );
      if (!mounted || !confirmed) return;
      await service.restore(pending!);
      await library.initialize();
      await controller.initialize(notify: false);
      if (!mounted) return;
      controller.onRestartRequested?.call();
      if (controller.onRestartRequested == null) setState(() {});
    } catch (_) {
      if (mounted) showAppSnack(context, '备份恢复失败，请检查文件或局域网连接', error: true);
    } finally {
      await server.stop();
    }
  }

  List<Widget> _aboutSection() {
    final skin = TvSkin.of(context);
    return [
      _PanelHeader(title: '关于', subtitle: '版本与许可信息'),
      const _InfoRow(
        icon: Icons.live_tv_rounded,
        title: 'TVBOX 26 Flutter',
        subtitle: '版本 1.0.0 · 参考 TVBox 开源项目重制',
        tint: null,
      ),
      _ActionRow(
        icon: Icons.article_outlined,
        title: '开源许可',
        subtitle: '查看第三方依赖许可信息',
        onTap: _showLicenses,
      ),
      SizedBox(height: skin.spaceSm),
      _Hint(
        icon: Icons.gavel_outlined,
        text:
            '免责声明：本应用仅提供播放器与接口解析能力，不内置、不托管任何影视资源。'
            '请确保使用的接口与内容符合当地法律法规。',
      ),
    ];
  }

  /// 许可信息。用皮肤化侧栏承载，不走 `showLicensePage`：全屏 Material
  /// 许可页没有焦点态、也不读皮肤（AGENTS.md §2/§3）。
  Future<void> _showLicenses() async {
    final packages = await LicenseRegistry.licenses
        .map(
          (entry) =>
              '${entry.packages.join(', ')}\n${entry.paragraphs.map((p) => p.text.trim()).where((t) => t.isNotEmpty).join('\n')}',
        )
        .where((text) => text.trim().isNotEmpty)
        .join('\n\n');
    if (!mounted) return;
    await showTvSheet<void>(
      context,
      title: '开源许可',
      subtitle: '第三方依赖与其许可证',
      width: 680,
      builder: (sheetContext) {
        final sheetSkin = TvSkin.of(sheetContext);
        final sheetText = AppText.of(sheetContext);
        return ListView(
          padding: EdgeInsets.fromLTRB(
            sheetSkin.spaceLg,
            sheetSkin.spaceMd,
            sheetSkin.spaceLg,
            sheetSkin.spaceXl,
          ),
          scrollCacheExtent: const ScrollCacheExtent.pixels(kTvListCacheExtent),
          addAutomaticKeepAlives: false,
          children: [
            Text(
              packages.isEmpty ? '没有可用的许可信息。' : packages,
              style: sheetText.meta.copyWith(
                height: 1.6,
                color: sheetSkin.textSecondary,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 二次确认。TV 上不用 `AlertDialog`（10 英尺外按钮偏小、抢焦点后返回键
  /// 语义容易乱），改用皮肤化侧栏（AGENTS.md §2）。
  Future<bool> _confirm(
    String action,
    String object, {
    String confirmLabel = '确定',
  }) async {
    final confirmed = await showTvSheet<bool>(
      context,
      title: action,
      subtitle: '此操作无法撤销',
      width: 560,
      builder: (sheetContext) {
        final skin = TvSkin.of(sheetContext);
        final text = AppText.of(sheetContext);
        return Padding(
          padding: EdgeInsets.all(skin.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '将永久删除全部$object，之后无法恢复。',
                style: text.bodyLarge.copyWith(color: skin.textSecondary),
              ),
              SizedBox(height: skin.spaceLg),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: skin.spaceLg + skin.spaceMd,
                      child: OutlinedButton(
                        autofocus: true,
                        onPressed: () => Navigator.of(sheetContext).pop(false),
                        child: const Text('取消'),
                      ),
                    ),
                  ),
                  SizedBox(width: skin.spaceSm),
                  Expanded(
                    child: SizedBox(
                      height: skin.spaceLg + skin.spaceMd,
                      child: FilledButton(
                        onPressed: () => Navigator.of(sheetContext).pop(true),
                        child: Text(confirmLabel),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    return confirmed == true;
  }

  /// 站点选择面板：复用 [SiteRow]（已带「可搜索」等副标题）。
  Future<void> _pickSite(AppController controller) async {
    final sites = controller.sites.where(controller.siteApi.supports).toList();
    if (sites.isEmpty) {
      showAppSnack(context, '没有兼容的点播站点，请先加载配置', error: true);
      return;
    }
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
              radius: 14,
              scale: 1.02,
              autofocus: index == 0,
              semanticLabel: '${site.name}，当前站点：${selected ? '是' : '否'}',
              onTap: () => Navigator.of(sheetContext).pop(site.key),
              child: SiteRow(site: site, selected: selected),
            );
          },
        );
      },
    );
    if (selectedKey == null || !mounted) return;
    controller.selectSite(selectedKey);
  }
}

/// 左栏：分类导航（ Compose TV `NavigationRail` 的等价物）。
class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.index,
    required this.onSelect,
    required this.nodes,
  });

  final List<_SettingsCategory> categories;
  final int index;
  final ValueChanged<int> onSelect;
  final List<FocusNode> nodes;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return SizedBox(
      width: 240,
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
                  focusNode: nodes[i],
                  label: categories[i].label,
                  icon: categories[i].icon,
                  selected: i == index,
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
    required this.autofocus,
    required this.onTap,
    required this.focusNode,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      focusNode: focusNode,
      radius: skin.radiusSm + 2,
      scale: 1.02,
      autofocus: autofocus,
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

/// 右侧内容面板外壳。把焦点交给面板根，方向键在面板内部走，
/// 左边界回到分类栏（`TvFocusable` 的边界行为）。
class _Panel extends StatefulWidget {
  const _Panel({required this.focusNode, required this.child});

  final FocusNode focusNode;
  final Widget child;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return SkinSurface(
      radius: skin.radiusLg,
      padding: EdgeInsets.fromLTRB(
        skin.spaceLg,
        skin.spaceMd + 2,
        skin.spaceLg,
        skin.spaceMd,
      ),
      child: Focus(focusNode: widget.focusNode, child: widget.child),
    );
  }
}

/// 面板内的小标题（分组标签），与 [SectionHeader] 同风格但更轻。
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final textStyle = AppText.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: skin.spaceXs,
        top: skin.spaceMd - 4,
        bottom: skin.spaceXs,
      ),
      child: Text(text, style: textStyle.label.copyWith(color: skin.textMuted)),
    );
  }
}

/// 面板抬头：标题 + 一行说明 + 可选状态图标。
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
      padding: EdgeInsets.only(bottom: skin.spaceSm),
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

/// 列表行外壳：左侧图标 + 标题/副标题 + 右侧控件。行高 ≥ 64（AGENTS.md
/// §6.5 的可读下限在 10 英尺外要撑得住）。
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.tint,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 右侧控件（开关、输入框、按钮组、说明文字）。
  final Widget child;

  /// 图标与标题的强调色，默认 [TvSkin.accent]。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final accent = tint ?? skin.accent;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: skin.spaceXs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(skin.radiusSm),
              ),
              child: Icon(icon, size: 19, color: accent),
            ),
            SizedBox(width: skin.spaceSm + 2),
            SizedBox(
              width: 210,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.label.copyWith(color: skin.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: skin.spaceMd),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// 无右侧控件的只读行。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.tint,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final accent = tint ?? skin.accent;
    return _Row(
      icon: icon,
      title: title,
      subtitle: subtitle,
      tint: accent,
      child: Align(
        alignment: Alignment.centerRight,
        child: Text('已启用', style: text.label.copyWith(color: skin.textMuted)),
      ),
    );
  }
}

/// 可点击的导航行（清空数据、查看许可等）。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: skin.spaceXs),
      child: TvFocusable(
        radius: skin.radiusSm + 2,
        scale: 1.01,
        semanticLabel: title,
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, skin.motionFast),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 64),
          padding: EdgeInsets.symmetric(
            horizontal: skin.spaceSm,
            vertical: skin.spaceSm,
          ),
          decoration: BoxDecoration(
            color: skin.surfaceSubtle,
            borderRadius: BorderRadius.circular(skin.radiusSm + 2),
            border: Border.all(color: skin.borderSoft),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: skin.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(skin.radiusSm),
                ),
                child: Icon(icon, size: 19, color: skin.accent),
              ),
              SizedBox(width: skin.spaceSm + 2),
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
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.label.copyWith(color: skin.textMuted),
                    ),
                  ],
                ),
              ),
              SizedBox(width: skin.spaceSm),
              Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: skin.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 开关行。
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return _Row(
      icon: icon,
      title: title,
      subtitle: subtitle,
      child: Align(
        alignment: Alignment.centerRight,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: skin.accent,
        ),
      ),
    );
  }
}

/// 滑杆行：右侧滑杆 + 只读百分比，遥控器左右方向键步进调节。
/// 主题皮肤行：色块预览 + 名称 + 一句话说明 + 当前标记。
class _SkinRow extends StatelessWidget {
  const _SkinRow({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  final TvSkinId id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    // 预览色块用各自皮肤的真实 token，而不是当前皮肤的近似值。
    final preview = skinFor(id);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: skin.spaceXs),
      child: TvFocusable(
        radius: skin.radiusSm + 2,
        scale: 1.01,
        // ACCESS-01：焦点态要能读出皮肤名。
        semanticLabel: '皮肤 ${id.label}，${selected ? '当前皮肤' : '点击切换'}',
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, skin.motionFast),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 64),
          padding: EdgeInsets.symmetric(
            horizontal: skin.spaceMd - 2,
            vertical: skin.spaceSm,
          ),
          decoration: BoxDecoration(
            color: selected ? skin.accentSoft : skin.surfaceSubtle,
            borderRadius: BorderRadius.circular(skin.radiusSm + 2),
            border: Border.all(
              color: selected ? skin.accent : skin.borderSoft,
              width: selected ? 1.4 : 0.8,
            ),
          ),
          child: Row(
            children: [
              _SkinSwatch(skin: preview),
              SizedBox(width: skin.spaceMd - 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      id.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? skin.accent : skin.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      id.tagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.label.copyWith(color: skin.textMuted),
                    ),
                  ],
                ),
              ),
              SizedBox(width: skin.spaceSm),
              if (selected)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: skin.accent,
                    ),
                    SizedBox(width: skin.spaceXs),
                    Text(
                      '当前',
                      style: text.label.copyWith(
                        color: skin.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                )
              else
                Icon(
                  Icons.circle_outlined,
                  size: 18,
                  color: skin.textMuted.withValues(alpha: 0.6),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 皮肤预览：三个圆点，分别取该皮肤的背景 / 面板 / 强调色。
class _SkinSwatch extends StatelessWidget {
  const _SkinSwatch({required this.skin});

  final TvSkin skin;

  @override
  Widget build(BuildContext context) {
    // 预览块自身要跟皮肤圆角一起走，但比行内圆角小一档。
    final radius = TvSkin.of(context).radiusSm;
    final colors = [skin.bg, skin.surface, skin.accent];
    return Container(
      padding: EdgeInsets.symmetric(horizontal: radius, vertical: radius - 2),
      decoration: BoxDecoration(
        color: skin.bg,
        borderRadius: BorderRadius.circular(radius + 1),
        border: Border.all(color: skin.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < colors.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: colors[i],
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors[i] == skin.bg
                      ? skin.border
                      : Colors.transparent,
                  width: 0.8,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 主题强调色预设：色块与名称同时可见，遥控器焦点导航可逐项选择。
class _AccentColorOption extends StatelessWidget {
  const _AccentColorOption({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final TvAccentColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final swatch = skinFor(skin.id, accentColor: color).accent;
    return SizedBox(
      width: 152,
      child: TvFocusable(
        radius: skin.radiusSm,
        semanticLabel: '主题色 ${color.label}${selected ? '，当前选中' : '，按确认切换'}',
        onTap: onTap,
        child: Builder(
          builder: (context) {
            final tinted = TvFocusTint.of(context);
            final foreground = tinted ? skin.textOnAccent : skin.textPrimary;
            return ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: SkinSurface(
                radius: skin.radiusSm,
                padding: EdgeInsets.all(skin.spaceSm),
                enableBlur: false,
                tint: tinted
                    ? skin.focus.fillColor
                    : selected
                    ? skin.accentSoft
                    : skin.surfaceSubtle,
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: swatch,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: skin.textPrimary.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    SizedBox(width: skin.spaceXs),
                    Expanded(
                      child: Text(
                        color.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.label.copyWith(
                          color: foreground,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected) ...[
                      SizedBox(width: skin.spaceXs),
                      Icon(
                        Icons.check_circle_rounded,
                        size: 18,
                        color: foreground,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 底部说明块。
class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final textStyle = AppText.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: skin.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Icon(icon, size: 18, color: skin.textMuted),
          ),
          SizedBox(width: skin.spaceSm + 2),
          Expanded(
            child: Text(
              text,
              style: textStyle.label.copyWith(
                height: 1.55,
                color: skin.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 行内输入框：TV 侧栏 IME 场景下比嵌入输入行更稳，焦点由 [TvFocusable]
/// 管理，输入框自身只读（`enableInteractiveSelection: false` 保持焦点在
/// 外层，OK 键触发 `onSubmit`）。
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String hint;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Row(
      children: [
        Expanded(
          child: TvFocusable(
            radius: skin.radiusSm,
            scale: 1.0,
            onTap: () => showTvSheet<void>(
              context,
              title: '输入',
              subtitle: hint,
              width: 620,
              builder: (sheetContext) => _FieldSheet(
                controller: controller,
                hint: hint,
                onSubmit: () {
                  Navigator.of(sheetContext).pop();
                  onSubmit();
                },
              ),
            ),
            child: Container(
              height: skin.spaceLg + skin.spaceMd,
              padding: EdgeInsets.symmetric(horizontal: skin.spaceMd - 2),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: skin.surfaceSubtle,
                borderRadius: BorderRadius.circular(skin.radiusSm),
                border: Border.all(color: skin.border),
              ),
              child: Text(
                controller.text.trim().isEmpty ? hint : controller.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.body.copyWith(
                  color: controller.text.trim().isEmpty
                      ? skin.textMuted
                      : skin.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「扫码输入」按钮：紧贴输入框，遥控器可获焦（[TvFocusable]），点击起扫码
/// 填地址流程。视觉与 [_RowButton] 对齐（filled 主按钮走 accentGradient）。
class _ScanButton extends StatelessWidget {
  const _ScanButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusSm,
      semanticLabel: '扫码输入',
      onTap: onTap,
      child: Builder(
        builder: (context) {
          // smartisan 获焦时 TvFocusable 的填充画在子内容之下，这里的实色底
          // （accentGradient）会把它盖住、退化成细描边；获焦反白态下让出底色、
          // 文字图标切 textOnAccent（与 _RowButton 同一约定）。
          final tinted = TvFocusTint.of(context);
          return Container(
            height: skin.spaceLg + skin.spaceMd,
            padding: EdgeInsets.symmetric(horizontal: skin.spaceMd - 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(skin.radiusSm),
              gradient: tinted ? null : skin.accentGradient,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.qr_code_scanner_rounded,
                  size: 18,
                  color: skin.textOnAccent,
                ),
                SizedBox(width: skin.spaceXs),
                Text(
                  '扫码',
                  style: text.bodyStrong.copyWith(color: skin.textOnAccent),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 侧栏里的输入表单：真实 `TextField` + OK 键提交。
class _FieldSheet extends StatefulWidget {
  const _FieldSheet({
    required this.controller,
    required this.hint,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String hint;
  final VoidCallback onSubmit;

  @override
  State<_FieldSheet> createState() => _FieldSheetState();
}

class _FieldSheetState extends State<_FieldSheet> {
  late final FocusNode _node = FocusNode(debugLabel: 'settings-field');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Padding(
      padding: EdgeInsets.all(skin.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.controller,
            focusNode: _node,
            autofocus: true,
            keyboardType: TextInputType.url,
            style: text.bodyLarge,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => widget.onSubmit(),
          ),
          SizedBox(height: skin.spaceLg),
          FilledButton.icon(
            onPressed: widget.onSubmit,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 行内按钮组。每个按钮用 [TvFocusable] 承载遥控器焦点视觉（AGENTS.md §3
/// 硬性规则 1：可获焦 + 焦点视觉 + OK 响应），不再用裸 Material 按钮——
/// 后者在 TV 上没有焦点态、也点不到。
class _RowButtons extends StatelessWidget {
  const _RowButtons({required this.buttons});

  final List<_Btn> buttons;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return Wrap(
      spacing: skin.spaceSm,
      runSpacing: skin.spaceXs,
      children: [for (final button in buttons) _RowButton(button: button)],
    );
  }
}

/// 单个行内按钮：视觉与主题按钮对齐（filled 主按钮走 accentGradient，次按钮
/// 走 surfaceSubtle + 描边），busy 时降透明度且不响应。
class _RowButton extends StatelessWidget {
  const _RowButton({required this.button});

  final _Btn button;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusSm,
      semanticLabel: button.label,
      onTap: button.busy ? null : button.onTap,
      child: Builder(
        builder: (context) {
          // smartisan 获焦时 TvFocusable 的填充画在子内容之下，这里的实色底
          // （accentGradient / surfaceSubtle）会把它盖住、退化成细描边；获焦
          // 反白态下让出底色、文字切 textOnAccent（与 GlassChip 同一约定）。
          final tinted = TvFocusTint.of(context);
          final filled = button.filled;
          final content = Container(
            padding: EdgeInsets.symmetric(
              horizontal: skin.spaceLg,
              vertical: skin.spaceSm + 4,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(skin.radiusSm),
              gradient: filled && !tinted ? skin.accentGradient : null,
              color: !filled && !tinted ? skin.surfaceSubtle : null,
              border: !filled && !tinted
                  ? Border.all(color: skin.border)
                  : null,
            ),
            child: Text(
              button.label,
              style: text.bodyStrong.copyWith(
                color: tinted || filled ? skin.textOnAccent : skin.textPrimary,
              ),
            ),
          );
          return button.busy ? Opacity(opacity: 0.45, child: content) : content;
        },
      ),
    );
  }
}

class _Btn {
  const _Btn({
    required this.label,
    required this.onTap,
    this.filled = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool busy;
}

/// 顶部返回动作（只退页；分类切换在左栏）。
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return TvFocusable(
      radius: skin.radiusPill,
      semanticLabel: label,
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          shape: BoxShape.circle,
          border: Border.all(color: skin.border),
        ),
        child: Icon(icon, size: 22, color: skin.textSecondary),
      ),
    );
  }
}

/// 错误/警告横幅：读皮肤色，不用旧 `AppColors`。
class _Banner extends StatelessWidget {
  const _Banner({
    required this.message,
    required this.color,
    required this.icon,
  });

  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: skin.spaceMd,
        vertical: skin.spaceSm + 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(skin.radiusSm + 2),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          SizedBox(width: skin.spaceSm),
          Expanded(
            child: Text(
              message,
              style: text.label.copyWith(
                height: 1.45,
                color: skin.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
