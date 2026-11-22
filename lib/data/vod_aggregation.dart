import 'dart:convert';

import 'config_service.dart';
import 'models.dart';
import 'site_api.dart';
import 'storage.dart';

enum VodSourceStatus { online, cached, unavailable }

class VodAggregate {
  const VodAggregate({required this.sources, required this.statuses});

  final Map<String, AppConfig> sources;
  final Map<String, VodSourceStatus> statuses;

  AppConfig? applyTo(AppConfig base) {
    final sites = <SiteConfig>[];
    final seen = <String>{};
    final usedKeys = <String>{};
    final parses = <ParseConfig>[];
    final parseIds = <String>{};
    final flags = <String>{};
    final baseKeys = <String, String>{};
    final reserved = base.sites.map((site) => site.key).toSet();
    for (final site in base.sites) {
      baseKeys.putIfAbsent(_identity(_bindJar(site, base)), () => site.key);
    }
    for (final source in sources.values) {
      for (final original in source.sites) {
        final site = _bindJar(original, source);
        final id = _identity(site);
        if (!seen.add(id)) continue;
        // 不把不同行为的站点复用为基础配置的收藏/历史 key。
        final baseKey = baseKeys[id];
        String key;
        if (baseKey != null && !usedKeys.contains(baseKey)) {
          key = baseKey;
        } else {
          final prefix = 'vod:${_fingerprint(id)}';
          key = prefix;
          var suffix = 2;
          while (reserved.contains(key) || usedKeys.contains(key)) {
            key = '$prefix:${suffix++}';
          }
        }
        usedKeys.add(key);
        sites.add(site.withKeyAndJar(key, site.jar));
      }
      for (final parse in source.parses) {
        if (parseIds.add(
          jsonEncode([parse.url, parse.type, parse.ext, parse.jar]),
        )) {
          parses.add(parse);
        }
      }
      flags.addAll(source.flags);
    }
    if (!sites.any(_compatible)) return null;
    return AppConfig(
      sites: List.unmodifiable(sites),
      parses: List.unmodifiable(parses),
      lives: base.lives,
      wallpaper: base.wallpaper,
      flags: List.unmodifiable(flags),
      name: base.name,
      // 依赖已经逐站绑定，不设置可能指向其他来源的全局默认 JAR。
    );
  }

  static SiteConfig _bindJar(SiteConfig site, AppConfig source) =>
      site.isSpider && site.jar.isEmpty
      ? site.withKeyAndJar(site.key, source.spider)
      : site;

  static String _identity(SiteConfig site) => jsonEncode([
    site.api.isEmpty ? site.key : site.api,
    site.type,
    site.ext,
    site.jar,
    site.playUrl,
    site.click,
    site.style,
    site.categories,
    site.playerType,
    site.hide,
    site.searchable,
    site.quickSearch,
    site.filterable,
    for (final header in (site.headers.keys.toList()..sort()))
      [header, site.headers[header]],
  ]);

  static String _fingerprint(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash = (hash ^ byte) * 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }
}

bool _compatible(SiteConfig site) =>
    !site.isHidden &&
    (site.isHttpSite || SiteApi.supportsJar(site) || SiteApi.supportsJs(site));

class VodAggregationRepository {
  VodAggregationRepository(this._config, this._storage);

  static const maxSources = 8;
  static const _cacheKey = 'vod_aggregate_cache';

  final ConfigService _config;
  final StorageService _storage;

  List<String> normalizeUrls(Iterable<String> inputs) {
    final urls = <String>{};
    for (final input in inputs) {
      final url = _config.normalizeUrl(input);
      if (url.isEmpty) continue;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !(uri.scheme == 'https' ||
              uri.scheme == 'http' ||
              (uri.scheme == 'clan' &&
                  uri.path.length > 1 &&
                  uri.userInfo.isEmpty)) ||
          uri.host.isEmpty) {
        throw ConfigException('点播源需要有效的 HTTP(S) 或 Box 局域网配置地址');
      }
      urls.add(uri.removeFragment().toString());
    }
    if (urls.length > maxSources) {
      throw ConfigException('最多可添加 $maxSources 个点播配置源');
    }
    return urls.toList(growable: false);
  }

  Future<VodAggregate> refresh(List<String> urls) async {
    final cache = {
      for (final entry in _storage.getJsonList(_cacheKey))
        if (entry['url'] is String) entry['url'] as String: entry,
    };
    var cursor = 0;
    final results = <String, (AppConfig?, VodSourceStatus)>{};
    Future<void> worker() async {
      while (cursor < urls.length) {
        final url = urls[cursor++];
        try {
          final next = await _config
              .loadFromUrl(url)
              .timeout(const Duration(seconds: 8));
          if (next.config.sites.isEmpty) throw ConfigException('配置没有点播站点');
          final previous = cache[url];
          if (previous != null && !next.config.sites.any(_compatible)) {
            final cached = _readCache(previous, url);
            if (cached != null && cached.sites.any(_compatible)) {
              results[url] = (cached, VodSourceStatus.cached);
              continue;
            }
          }
          cache[url] = {
            'url': url,
            'base': next.baseUrl ?? url,
            'raw': next.raw,
          };
          results[url] = (next.config, VodSourceStatus.online);
        } catch (_) {
          final entry = cache[url];
          final cached = entry == null ? null : _readCache(entry, url);
          if (cached != null && cached.sites.isNotEmpty) {
            results[url] = (cached, VodSourceStatus.cached);
            continue;
          }
          results[url] = (null, VodSourceStatus.unavailable);
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    // 保留已生效组的快照，直到调用方确认切换成功。
    await _storage.setJsonList(_cacheKey, cache.values.toList());
    return VodAggregate(
      sources: {for (final url in urls) url: ?results[url]!.$1},
      statuses: {for (final url in urls) url: results[url]!.$2},
    );
  }

  AppConfig? _readCache(Map<String, dynamic> entry, String url) {
    try {
      return _config.parse(
        asString(entry['raw']),
        baseUrl: asString(entry['base'], url),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> retainCache(List<String> urls) => _storage.setJsonList(
    _cacheKey,
    _storage
        .getJsonList(_cacheKey)
        .where((entry) => urls.contains(entry['url']))
        .toList(),
  );

  Future<void> clearCache() => _storage.remove(_cacheKey);
}
