import 'package:flutter/foundation.dart';

import '../data/config_service.dart';
import '../data/live_parser.dart';
import '../data/models.dart';
import '../data/play_resolver.dart';
import '../data/site_api.dart';
import '../data/site_probe.dart';
import '../data/storage.dart';
import '../data/vod_aggregation.dart';
import '../data/network_policy.dart';
import '../theme/skin.dart';
import '../theme/theme_controller.dart';
import 'playback_preferences.dart';
import 'live_preferences.dart';

import 'dart:convert';
import 'dart:async';

class AppController extends ChangeNotifier {
  /// 皮肤持久化的 SharedPreferences key（与 `ui_tab_index` 同族）。
  /// 定义在 `theme/theme_controller.dart`，这里只转发，避免重复字面量。
  static const String skinStorageKey = AppControllerSkinKeys.storageKey;

  /// 主题色持久化 key。
  static const String accentColorStorageKey = 'ui_accent_color';

  /// 全局壁纸覆盖的持久化 key（存本地图片绝对路径，空串 = 未设置）。
  static const String wallpaperStorageKey = 'ui_wallpaper_file';

  /// 背景图模糊开关的持久化 key（默认关闭——背景图直接铺，不模糊）。
  static const String blurBackgroundStorageKey = 'ui_background_blur';

  AppController({
    StorageService? storage,
    ConfigService? configService,
    SiteApi? siteApi,
    LiveService? liveService,
    PlayResolver? playResolver,
  }) : storage = storage ?? StorageService(),
       configService = configService ?? ConfigService(),
       siteApi = siteApi ?? SiteApi(),
       liveService = liveService ?? LiveService(),
       playResolver = playResolver ?? PlayResolver();

  final StorageService storage;
  final ConfigService configService;
  final SiteApi siteApi;
  final LiveService liveService;
  final PlayResolver playResolver;
  late final _vod = VodAggregationRepository(configService, storage);
  static const _vodUrlsKey = 'vod_aggregate_urls';
  static const maxVodSources = VodAggregationRepository.maxSources;
  List<String> _vodUrls = const [];
  List<String> get vodUrls => _vodUrls;
  AppConfig _baseConfig = AppConfig.empty;
  Map<String, VodSourceStatus> vodSourceStatuses = const {};
  Set<String> vodSourcesWithoutHttpSites = const {};
  bool vodAggregateActive = false;
  bool vodUpdating = false;

  /// 站点连通性测速结果（key = site.key）。在线 10 分钟 / 降级 5 分钟 /
  /// 离线 3 分钟过期，过期后下一轮测速自动重测。
  final Map<String, SiteProbe> _siteProbes = {};
  bool siteProbing = false;
  DateTime? siteProbesAt;
  int _siteProbeGeneration = 0;
  bool _disposed = false;
  bool get usingVodAggregate => _vodUrls.isNotEmpty;

  AppConfig config = AppConfig.empty;
  bool initialized = false;
  bool loading = false;
  String? initError;
  String? warning;
  String? actionError;

  String configUrl = '';
  String? selectedSiteKey;
  String liveUrlOverride = '';
  bool autoNext = true;
  bool autoPlay = true;
  bool useMediaKit = false;
  bool liveMediaKit = false;
  bool backgroundPlayback = false;

  /// 弹幕自动匹配：进播时按归一化片名 + 集号在弹幕站模板里试探，
  /// 命中后按「站点+影片+集号」记忆，下次免网络。需要 danmakuBaseUrl。
  bool danmakuAutoMatch = true;

  /// 弹幕站基础地址（空串 = 不启用自动匹配，仍可手动导入 XML/JSON）。
  String danmakuBaseUrl = '';

  LivePreferences livePreferences = const LivePreferences();
  double playbackSpeed = 1.0;
  int seekStepSeconds = 10;
  bool showSourceBadges = true;
  bool homeRows = false;
  String epgOverride = '';
  Set<String> excludedSearchSites = {};
  Set<String> disabledSites = {};
  List<String> siteOrder = [];
  PlaybackScale playbackScale = PlaybackScale.original;

  /// 当前皮肤与主题色都是构建 `MaterialApp.theme` 前需要的全局视觉状态，
  /// 因此和 tab 下标一样存在 [storage] 里，在 `_loadSettings` 阶段同步回读。
  TvSkinId skinId = TvSkinId.netflix;

  /// 当前主题强调色；默认跟随皮肤（新安装默认皮肤为 Netflix）。
  TvAccentColor accentColor = TvAccentColor.skinDefault;

  /// 全局壁纸覆盖：本地壁纸文件的绝对路径，空串表示未设置、回落到配置壁纸。
  String wallpaperOverride = '';

  /// 背景图是否做高斯模糊（全局外观设置，默认关闭——直接铺图）。
  bool blurBackground = false;

  /// 皮肤/主题色冷切换后触发的重启回调。由 `main.dart` 注入：对应 setter
  /// 持久化选择并调用它，`runApp` 重建整棵树，**不做**运行时
  /// 增量 rebuild（热切换会触发 `MaterialApp.theme` 变化 → 壳层 widget 类型
  /// 变化 → 整树 State 重建，P0-1 卡死根因）。
  VoidCallback? onRestartRequested;

  bool get usingBuiltIn => configUrl.isEmpty;
  bool get hasSites => config.visibleSites.isNotEmpty;
  String get wallpaper {
    if (wallpaperOverride.isNotEmpty) return wallpaperOverride;
    return config.wallpaper;
  }

  String get configLabel => usingVodAggregate && vodAggregateActive
      ? '本地点播聚合 · ${_vodUrls.length} 个源'
      : usingBuiltIn ? '内置演示配置' : configUrl;

  List<SiteConfig> get sites {
    final enabled = config.visibleSites
        .where((site) => !disabledSites.contains(site.key))
        .toList();
    if (enabled.isEmpty) return const [];
    final order = {for (var i = 0; i < siteOrder.length; i++) siteOrder[i]: i};
    final original = {for (var i = 0; i < enabled.length; i++) enabled[i].key: i};
    final now = DateTime.now();
    // 测速分桶：在线（按质量分）/ 未知（无数据或已过期）/ 离线。
    final online = <SiteConfig>[];
    final unknown = <SiteConfig>[];
    final offline = <SiteConfig>[];
    for (final site in enabled) {
      final probe = _siteProbes[site.key];
      if (probe == null || now.difference(probe.checkedAt) > _probeTtl(probe)) {
        unknown.add(site);
      } else if (probe.online) {
        online.add(site);
      } else {
        offline.add(site);
      }
    }
    int quality(SiteConfig site) {
      final probe = _siteProbes[site.key];
      if (probe == null || now.difference(probe.checkedAt) > _probeTtl(probe)) {
        return 1 << 20;
      }
      return probe.online ? probe.score : 1 << 21;
    }
    // 浏览列表保留离线站点（排在最后），避免用户浏览中被突然换站；
    // 搜索侧用 [searchSites] 明确排除离线站点。
    final result = [...online, ...unknown, ...offline];
    result.sort((a, b) {
      final byManual = (order[a.key] ?? siteOrder.length)
          .compareTo(order[b.key] ?? siteOrder.length);
      if (byManual != 0) return byManual;
      if (!order.containsKey(a.key)) {
        final byQuality = quality(a).compareTo(quality(b));
        if (byQuality != 0) return byQuality;
      }
      return original[a.key]!.compareTo(original[b.key]!);
    });
    return result;
  }

  /// 搜索候选：在线 / 未知优先；有明确在线或未知站点时排除离线站点。
  List<SiteConfig> get searchSites {
    final all = sites;
    final usable = all.where((site) => _siteUsable(site.key)).toList();
    return usable.isEmpty ? all : usable;
  }

  bool _siteUsable(String key) {
    final probe = _siteProbes[key];
    if (probe == null) return true;
    if (DateTime.now().difference(probe.checkedAt) > _probeTtl(probe)) return true;
    return probe.online;
  }

  Duration _probeTtl(SiteProbe probe) {
    if (!probe.online) return SiteProbeService.offlineTtl;
    final status = probe.status;
    if (status != null && status >= 400) return SiteProbeService.degradedTtl;
    return SiteProbeService.onlineTtl;
  }

  /// 设置页展示用的测速文案。
  String get siteProbeSummary {
    if (siteProbing) return '正在测速…';
    final now = DateTime.now();
    final fresh = _siteProbes.values
        .where((probe) => now.difference(probe.checkedAt) <= _probeTtl(probe))
        .toList();
    if (fresh.isEmpty) {
      return siteProbesAt == null ? '未测速，点击开始' : '测速结果已过期，点击重测';
    }
    final online = fresh.where((probe) => probe.online).length;
    final at = siteProbesAt;
    final clock = at == null
        ? ''
        : ' · ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return '在线 $online/${fresh.length}$clock';
  }

  String siteProbeLabel(SiteConfig site) {
    if (siteProbeUrl(site) == null) return '不支持测速';
    final probe = _siteProbes[site.key];
    if (probe == null) return '未测速';
    final now = DateTime.now();
    if (now.difference(probe.checkedAt) > _probeTtl(probe)) return '测速已过期';
    if (!probe.online) return '不可达';
    final status = probe.status;
    return status != null && status >= 400
        ? '${probe.latencyMs}ms · HTTP $status'
        : '${probe.latencyMs}ms';
  }

  /// 探测全部启用站点；[force] 为 false 时全部结果仍在有效期内则跳过。
  Future<void> probeSites({bool force = false}) async {
    if (siteProbing || _disposed) return;
    final candidates = config.visibleSites
        .where(
          (site) =>
              !disabledSites.contains(site.key) && siteProbeUrl(site) != null,
        )
        .take(64)
        .toList();
    if (candidates.isEmpty) return;
    final now = DateTime.now();
    if (!force) {
      final fresh = candidates.every((site) {
        final probe = _siteProbes[site.key];
        return probe != null &&
            now.difference(probe.checkedAt) <= _probeTtl(probe);
      });
      if (fresh) return;
    }
    final generation = ++_siteProbeGeneration;
    siteProbing = true;
    notifyListeners();
    try {
      await SiteProbeService().probeAll(
        candidates,
        // 只更新内存，结束时统一刷新 UI（避免测速期间高频重建首页）。
        onResult: (key, probe) {
          if (_disposed || generation != _siteProbeGeneration) return;
          _siteProbes[key] = probe;
          siteProbesAt = DateTime.now();
        },
      );
    } finally {
      if (!_disposed && generation == _siteProbeGeneration) {
        siteProbing = false;
        _persistSiteProbes();
        notifyListeners();
      }
    }
  }

  void _persistSiteProbes() {
    final payload = {
      'at': (siteProbesAt ?? DateTime.now()).millisecondsSinceEpoch,
      'items': [
        for (final entry in _siteProbes.entries)
          {
            'key': entry.key,
            'online': entry.value.online,
            'latency': entry.value.latencyMs,
            'status': entry.value.status,
            'at': entry.value.checkedAt.millisecondsSinceEpoch,
          },
      ],
    };
    storage.setString('site_probes', jsonEncode(payload));
  }

  void _loadSiteProbes() {
    final raw = storage.getString('site_probes');
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final items = decoded['items'];
      if (items is! List) return;
      for (final item in items) {
        if (item is! Map) continue;
        final key = asString(item['key']);
        if (key.isEmpty) continue;
        final at = asInt(item['at'], 0);
        if (at <= 0) continue;
        _siteProbes[key] = SiteProbe(
          online: item['online'] == true,
          latencyMs: asInt(item['latency'], 0),
          status: item['status'] is int ? item['status'] as int : null,
          checkedAt: DateTime.fromMillisecondsSinceEpoch(at),
        );
      }
      final at = asInt(decoded['at'], 0);
      if (at > 0) siteProbesAt = DateTime.fromMillisecondsSinceEpoch(at);
    } catch (_) {
      // 缓存损坏忽略，下一轮测速重建。
    }
  }

  SiteConfig? get selectedSite {
    final list = sites;
    if (list.isEmpty) return null;
    if (selectedSiteKey != null) {
      for (final site in list) {
        if (site.key == selectedSiteKey) return site;
      }
    }
    return list.first;
  }

  SiteConfig? siteByKey(String key) {
    for (final site in config.sites) {
      if (site.key == key) return site;
    }
    return null;
  }

  List<LiveSource> get liveSources {
    if (liveUrlOverride.trim().isEmpty) return config.lives;
    return [LiveSource(name: '自定义直播源', url: liveUrlOverride.trim(), type: 0)];
  }

  LiveSource? get activeLiveSource {
    final list = liveSources;
    if (list.isEmpty) return null;
    return list.first;
  }

  Future<void> initialize({bool notify = true}) async {
    loading = true;
    initError = null;
    actionError = null;
    warning = null;
    _baseConfig = AppConfig.empty;
    if (notify) notifyListeners();
    try {
      await storage.init();
      _loadSettings();
      if (configUrl.isNotEmpty) {
        try {
          final loaded = await configService.loadFromUrl(configUrl);
          _baseConfig = loaded.config;
          await _cacheRaw(loaded.raw, loaded.sourceUrl, loaded.baseUrl);
          warning = loaded.warning;
        } catch (error) {
          final cachedRaw = storage.getString('config_cache');
          final cachedUrl = storage.getString('config_cache_url');
          if (cachedRaw.isNotEmpty && cachedUrl == configUrl) {
            try {
              _baseConfig = configService.parse(cachedRaw,
                baseUrl: storage.getString('config_cache_base', configUrl));
              warning = '网络配置更新失败，已使用上次缓存：${_friendly(error)}';
            } catch (_) {
              initError = '配置缓存无效，请重新加载';
            }
          } else {
            initError = '配置加载失败：${_friendly(error)}';
            config = AppConfig.empty;
          }
        }
      } else {
        final loaded = await configService.loadBuiltIn();
        _baseConfig = loaded.config;
      }
      final aggregate = usingVodAggregate ? await _vod.refresh(_vodUrls) : null;
      final merged = aggregate?.applyTo(_baseConfig);
      if (aggregate != null) _reportVodStatus(aggregate, merged != null);
      if (merged != null) initError = null;
      _applyConfig(merged ?? _baseConfig);
      // 启动后异步测速：在线站点优先、不可达的放弃。
      unawaited(probeSites());
      initialized = true;
    } catch (error) {
      initError = _friendly(error);
      initialized = true;
    } finally {
      loading = false;
      if (notify) notifyListeners();
    }
  }

  void _loadSettings() {
    configUrl = storage.getString('config_url');
    try {
      final urls = _vod.normalizeUrls(storage.getJsonList(_vodUrlsKey)
          .map((entry) => asString(entry['url'])));
      _vodUrls = urls.length < 2 ? const [] : List.unmodifiable(urls);
    } on ConfigException {
      _vodUrls = const [];
    }
    _loadSiteProbes();
    NetworkPolicy.configure(
      doh: storage.getString('network_doh'),
      httpProxy: storage.getString('network_proxy'),
    );
    epgOverride = storage.getString('epg_url_override');
    showSourceBadges = storage.getBool('show_source_badges', true);
    homeRows = storage.getBool('home_rows', false);
    disabledSites = storage
        .getJsonList('disabled_sites')
        .map((e) => asString(e['key']))
        .toSet();
    siteOrder = storage
        .getJsonList('site_order')
        .map((e) => asString(e['key']))
        .toList();
    liveUrlOverride = storage.getString('live_url_override');
    autoNext = storage.getBool('auto_next', true);
    autoPlay = storage.getBool('auto_play', true);
    useMediaKit = storage.getBool('player_media_kit', false);
    liveMediaKit = storage.getBool('live_media_kit', false);
    backgroundPlayback = storage.getBool('background_playback', false);
    danmakuAutoMatch = storage.getBool('danmaku_auto_match', true);
    danmakuBaseUrl = storage.getString('danmaku_base_url');
    try {
      final raw = jsonDecode(storage.getString('live_preferences', '{}'));
      if (raw is Map) livePreferences = LivePreferences.fromJson(raw);
    } catch (_) {}
    final speed = storage.getDouble('playback_speed', 1.0);
    playbackSpeed = playbackSpeeds.contains(speed) ? speed : 1.0;
    final step = storage.getDouble('seek_step_seconds', 10).toInt();
    seekStepSeconds = [5, 10, 30].contains(step) ? step : 10;
    excludedSearchSites = storage
        .getJsonList('search_excluded_sites')
        .map((entry) => asString(entry['key']))
        .toSet();
    playbackScale = PlaybackScale.fromName(storage.getString('playback_scale'));
    selectedSiteKey = storage.getString('home_site_key');
    skinId = TvSkinId.fromName(storage.getString(skinStorageKey));
    accentColor = TvAccentColor.fromName(
      storage.getString(accentColorStorageKey),
    );
    wallpaperOverride = storage.getString(wallpaperStorageKey);
    blurBackground = storage.getBool(blurBackgroundStorageKey, false);
  }

  /// 切换皮肤（冷切换）。
  ///
  /// 只把新 skinId 写进内存 + 持久化，然后触发 [onRestartRequested] 冷重启：
  /// `main.dart` 用 `runApp` 销毁整棵树、以新 skinId 重新构建。**不调用
  /// `notifyListeners()`** —— 那是热切换，会让 `MaterialApp.theme` 增量 rebuild，
  /// 在切换皮肤时，`IndexedStack` 内 4 页 State 全重建 + 重拉数据 + 焦点全灭
  /// （P0-1 真机卡死根因）。冷切换从根上规避该问题。
  Future<void> setSkin(TvSkinId id) async {
    if (id == skinId) return;
    skinId = id;
    await storage.setString(skinStorageKey, id.name);
    onRestartRequested?.call();
  }

  /// 切换主题色也采用冷切换，避免 MaterialApp 主题变化时热重建整棵页面树。
  Future<void> setAccentColor(TvAccentColor color) async {
    if (color == accentColor) return;
    accentColor = color;
    await storage.setString(accentColorStorageKey, color.name);
    onRestartRequested?.call();
  }

  /// 设置全局壁纸覆盖：写字段 + 通知 + 持久化。传空串表示清除覆盖。
  Future<void> setWallpaperOverride(String path) async {
    wallpaperOverride = path;
    notifyListeners();
    await storage.setString(wallpaperStorageKey, path);
  }

  /// 切换背景图模糊：写字段 + 通知 + 持久化。默认关闭（直接铺图）。
  Future<void> setBlurBackground(bool value) async {
    blurBackground = value;
    notifyListeners();
    await storage.setBool(blurBackgroundStorageKey, value);
  }

  void _applyConfig(AppConfig next) {
    config = next;
    final list = config.visibleSites;
    if (list.isEmpty) {
      selectedSiteKey = null;
      return;
    }
    final usable = list.where(siteApi.supports).toList();
    final preferred = usable.isEmpty ? list : usable;
    final hasSelected = preferred.any((e) => e.key == selectedSiteKey);
    if (!hasSelected) {
      selectedSiteKey = preferred.first.key;
    }
    storage.setString('home_site_key', selectedSiteKey ?? '');
  }

  Future<void> _cacheRaw(String raw, String url, String? baseUrl) async {
    await storage.setString('config_cache', raw);
    await storage.setString('config_cache_base', baseUrl ?? url);
    await storage.setString('config_cache_url', url);
  }

  Future<bool> loadConfig(String input) async {
    if (loading) return false;
    final url = configService.normalizeUrl(input);
    if (url.isEmpty) {
      actionError = '请输入配置地址';
      notifyListeners();
      return false;
    }
    loading = true;
    actionError = null;
    notifyListeners();
    try {
      // 配置切换：清空原生侧旧 Spider/JAR 实例，避免旧站点实例与代际悬挂。
      await siteApi.resetSpider();
      late LoadedConfig loaded;
      try {
        loaded = await configService.loadFromUrl(url);
      } catch (error) {
        final raw = storage.getString('config_cache');
        if (raw.isEmpty || storage.getString('config_cache_url') != url) rethrow;
        final base = storage.getString('config_cache_base', url);
        loaded = LoadedConfig(
          config: configService.parse(raw, baseUrl: base),
          raw: raw,
          sourceUrl: url,
          baseUrl: base,
          warning: '配置更新失败，已使用此地址上次成功的缓存：${_friendly(error)}',
        );
      }
      configUrl = url;
      await storage.setString('config_url', url);
      final history = storage.getJsonList('config_url_history')
        ..removeWhere((entry) => entry['url'] == url);
      history.insert(0, {'url': url});
      await storage.setJsonList(
        'config_url_history',
        history.take(30).toList(),
      );
      await _cacheRaw(loaded.raw, url, loaded.baseUrl);
      final hadVod = usingVodAggregate;
      await _deactivateVod();
      _baseConfig = loaded.config;
      _applyConfig(_baseConfig);
      unawaited(probeSites(force: true));
      initError = null;
      warning =
          loaded.warning ??
          (hadVod ? '已载入新配置，点播聚合已暂停（源列表保留，可在「点播聚合」重新应用）' : null);
      return true;
    } catch (error) {
      actionError = '配置加载失败：${_friendly(error)}';
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> useBuiltInConfig() async {
    if (loading) return;
    loading = true;
    actionError = null;
    notifyListeners();
    try {
      await siteApi.resetSpider();
      final loaded = await configService.loadBuiltIn();
      configUrl = '';
      await storage.setString('config_url', '');
      final hadVod = usingVodAggregate;
      await _deactivateVod();
      _baseConfig = loaded.config;
      _applyConfig(_baseConfig);
      unawaited(probeSites(force: true));
      initError = null;
      warning = hadVod ? '已切换到内置演示配置，点播聚合已暂停（源列表保留）' : null;
    } catch (error) {
      actionError = '内置配置加载失败：${_friendly(error)}';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshCurrentConfig() async {
    // 聚合被「暂停」（换配置时保留源列表）时刷新应重载基础配置，
    // 不能顺手把聚合又合上。
    if (usingVodAggregate && vodAggregateActive) {
      await setVodSources(_vodUrls);
    } else if (usingBuiltIn) {
      await useBuiltInConfig();
    } else {
      await loadConfig(configUrl);
    }
  }

  Future<void> _disableVod() async {
    if (!usingVodAggregate) return;
    _vodUrls = const [];
    vodSourceStatuses = const {};
    vodSourcesWithoutHttpSites = const {};
    vodAggregateActive = false;
    await storage.remove(_vodUrlsKey);
  }

  /// 换基础配置时暂停聚合，但保留已保存的源列表与持久化数据。
  ///
  /// 与 [_disableVod] 的区别：后者是用户显式「关闭聚合」，会删掉源列表；
  /// 这里只把当前生效的配置回退到基础配置，用户可在「点播聚合」里一键重开。
  Future<void> _deactivateVod() async {
    if (!usingVodAggregate) return;
    vodSourceStatuses = const {};
    vodSourcesWithoutHttpSites = const {};
    vodAggregateActive = false;
  }

  Future<bool> setVodSources(Iterable<String> inputs) async {
    if (loading) return false;
    final List<String> urls;
    try {
      urls = _vod.normalizeUrls(inputs);
      if (urls.length == 1) throw ConfigException('请至少添加两个不同的点播配置地址');
    } on ConfigException catch (error) {
      actionError = error.message;
      notifyListeners();
      return false;
    }
    loading = true;
    vodUpdating = true;
    actionError = null;
    notifyListeners();
    try {
      if (urls.isEmpty) {
        if (!usingVodAggregate) return true;
        await _disableVod();
        _applyConfig(_baseConfig);
        warning = null;
        if (!_baseConfig.visibleSites.any(siteApi.supports)) {
          initError = '基础配置没有可用点播站点，请加载单源配置';
        }
        return true;
      }
      final aggregate = await _vod.refresh(urls);
      final merged = aggregate.applyTo(_baseConfig);
      if (merged == null) {
        actionError = '没有兼容的点播站点，已保留当前配置';
        return false;
      }
      await storage.setJsonList(_vodUrlsKey, [for (final url in urls) {'url': url}]);
      await _vod.retainCache(urls);
      _vodUrls = List.unmodifiable(urls);
      _applyConfig(merged);
      unawaited(probeSites(force: true));
      initError = null;
      warning = null;
      _reportVodStatus(aggregate, true);
      return true;
    } catch (error) {
      actionError = '点播聚合更新失败：${_friendly(error)}';
      return false;
    } finally {
      loading = false;
      vodUpdating = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _reportVodStatus(VodAggregate aggregate, bool usable) {
    vodAggregateActive = usable;
    vodSourceStatuses = Map.unmodifiable(aggregate.statuses);
    vodSourcesWithoutHttpSites = Set.unmodifiable([
      for (final entry in aggregate.sources.entries)
        if (!entry.value.sites.any((site) => !site.isHidden && siteApi.supports(site)))
          entry.key,
    ]);
    final cached = vodSourceStatuses.values.where((s) => s == VodSourceStatus.cached).length;
    final failed = vodSourceStatuses.values.where((s) => s == VodSourceStatus.unavailable).length;
    warning = !usable ? '点播聚合不可用，已回退到基础配置' : cached + failed == 0
        ? warning : '点播聚合：$cached 个源沿用缓存，$failed 个源暂不可用';
  }


  @override
  void dispose() {
    _disposed = true;
    siteApi.closeSpiderProxy();
    super.dispose();
  }

  void selectSite(String key) {
    selectedSiteKey = key;
    storage.setString('home_site_key', key);
    notifyListeners();
  }

  Future<void> setLiveUrl(String url) async {
    liveUrlOverride = url.trim();
    await storage.setString('live_url_override', liveUrlOverride);
    notifyListeners();
  }

  Future<void> setAutoNext(bool value) async {
    autoNext = value;
    await storage.setBool('auto_next', value);
    notifyListeners();
  }

  Future<void> setAutoPlay(bool value) async {
    autoPlay = value;
    await storage.setBool('auto_play', value);
    notifyListeners();
  }

  Future<void> clearCache() async {
    if (loading) return;
    await storage.remove('config_cache');
    await storage.remove('config_cache_url');
    await storage.remove('config_cache_base');
    await _vod.clearCache();
    notifyListeners();
  }

  Future<void> setPlaybackSpeed(double value) async {
    if (!playbackSpeeds.contains(value)) return;
    playbackSpeed = value;
    notifyListeners();
    await storage.setDouble('playback_speed', value);
  }

  Future<void> setSeekStep(int seconds) async {
    if (![5, 10, 30].contains(seconds)) return;
    seekStepSeconds = seconds;
    await storage.setDouble('seek_step_seconds', seconds.toDouble());
    notifyListeners();
  }

  Future<void> toggleSearchSite(String key) async {
    if (!excludedSearchSites.add(key)) excludedSearchSites.remove(key);
    await storage.setJsonList('search_excluded_sites', [
      for (final key in excludedSearchSites) {'key': key},
    ]);
    notifyListeners();
  }

  Future<void> toggleSite(String key) async {
    if (!disabledSites.add(key)) disabledSites.remove(key);
    await storage.setJsonList('disabled_sites', [
      for (final key in disabledSites) {'key': key},
    ]);
    notifyListeners();
  }

  Future<void> setShowSourceBadges(bool value) async {
    showSourceBadges = value;
    await storage.setBool('show_source_badges', value);
    notifyListeners();
  }

  Future<void> setHomeRows(bool value) async {
    homeRows = value;
    await storage.setBool('home_rows', value);
    notifyListeners();
  }

  Future<void> setEpgUrl(String url) async {
    epgOverride = url.trim();
    await storage.setString('epg_url_override', epgOverride);
    if (epgOverride.isNotEmpty) {
      final entries = storage.getJsonList('epg_url_history')
        ..removeWhere((entry) => entry['url'] == epgOverride);
      entries.insert(0, {'url': epgOverride});
      await storage.setJsonList('epg_url_history', entries.take(30).toList());
    }
    notifyListeners();
  }

  Future<void> setNetwork({String? doh, String? proxy}) async {
    if (doh != null) await storage.setString('network_doh', doh);
    if (proxy != null) await storage.setString('network_proxy', proxy);
    NetworkPolicy.configure(
      doh: storage.getString('network_doh'),
      httpProxy: storage.getString('network_proxy'),
    );
    notifyListeners();
    onRestartRequested?.call();
  }

  Future<void> promoteSite(String key) async {
    siteOrder = [
      key,
      ...sites.map((site) => site.key).where((value) => value != key),
      ...disabledSites.where((value) => value != key),
    ];
    await storage.setJsonList('site_order', [
      for (final key in siteOrder) {'key': key},
    ]);
    notifyListeners();
  }

  Future<void> setUseMediaKit(bool value) async {
    useMediaKit = value;
    await storage.setBool('player_media_kit', value);
    notifyListeners();
  }

  Future<void> setLiveMediaKit(bool value) async {
    liveMediaKit = value;
    await storage.setBool('live_media_kit', value);
    notifyListeners();
  }

  Future<void> setBackgroundPlayback(bool value) async {
    backgroundPlayback = value;
    await storage.setBool('background_playback', value);
    notifyListeners();
  }

  Future<void> setDanmakuAutoMatch(bool value) async {
    danmakuAutoMatch = value;
    await storage.setBool('danmaku_auto_match', value);
    notifyListeners();
  }

  Future<void> setDanmakuBaseUrl(String value) async {
    danmakuBaseUrl = value;
    await storage.setString('danmaku_base_url', value);
    notifyListeners();
  }

  Future<void> setLivePreferences(LivePreferences value) async {
    livePreferences = value;
    await storage.setString('live_preferences', jsonEncode(value.toJson()));
    notifyListeners();
  }

  Future<void> setPlaybackScale(PlaybackScale value) async {
    playbackScale = value;
    notifyListeners();
    await storage.setString('playback_scale', value.name);
  }

  void clearWarning() {
    warning = null;
    notifyListeners();
  }

  String _friendly(Object error) {
    if (error is ConfigException) return error.message;
    if (error is ApiException) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }
}
