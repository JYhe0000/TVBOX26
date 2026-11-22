import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import 'models.dart';
import 'network_policy.dart';
import 'spider_proxy.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.isUnsupported = false});
  final String message;
  final bool isUnsupported;
  @override
  String toString() => message;
}

class SearchCancellation {
  final _http = CancelToken();
  final _callbacks = <void Function()>{};
  bool get isCancelled => _http.isCancelled;

  void cancel() {
    if (isCancelled) return;
    _http.cancel();
    final callbacks = _callbacks.toList();
    _callbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void Function() _onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
    return () => _callbacks.remove(callback);
  }
}

class SiteApi {
  SiteApi({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 25),
                headers: const {
                  'User-Agent': 'okhttp/3.15',
                  'Accept': 'application/json,text/plain,*/*',
                },
                followRedirects: true,
              ),
            ),
          );

  final Dio _dio;
  static const _spiderChannel = MethodChannel('tvbox/spider');
  late final _proxy = SpiderProxy(_spiderChannel);

  Future<void> closeSpiderProxy() => _proxy.close();

  /// 配置切换后通知原生侧清空 Spider/JAR 实例与代际，避免旧站点实例悬挂。
  Future<void> resetSpider() async {
    try {
      await _spiderChannel.invokeMethod<void>('reset');
    } catch (_) {
      // 原生侧不可用或已销毁时忽略：实例会随 LRU 上限自然淘汰。
    }
  }

  Future<String> bindSpiderProxy(SiteConfig site, String url) =>
      _proxy.bind(_siteArgs(site), url);

  Map<String, String> _siteArgs(SiteConfig site) => {
    'key': site.key,
    'api': site.api,
    'jar': site.jar,
    'ext': site.ext,
  };

  static bool supportsJar(SiteConfig site) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !RegExp(r'^csp_[A-Za-z_][A-Za-z0-9_]*$').hasMatch(site.api)) {
      return false;
    }
    final jar = Uri.tryParse(site.jar.split(';md5;').first);
    return jar != null &&
        jar.scheme == 'https' &&
        jar.host.isNotEmpty &&
        jar.userInfo.isEmpty;
  }

  static bool supportsJs(SiteConfig site) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        site.type != 3) {
      return false;
    }
    final uri = Uri.tryParse(site.api);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.path.endsWith('.js');
  }

  bool supports(SiteConfig site) =>
      site.isHttpSite || supportsJar(site) || supportsJs(site);

  bool usesPluginPlayback(SiteConfig site) => site.isSpider || site.type == 4;

  static int _nextSearchRequest = 0;

  Future<String> _spider(
    SiteConfig site,
    String method, [
    Map<String, Object> args = const {},
    SearchCancellation? cancellation,
  ]) async {
    if (!supportsJar(site) && !supportsJs(site)) {
      throw ApiException(
        '此站需要兼容的 Android HTTPS JAR 或 JS Spider',
        isUnsupported: true,
      );
    }
    final requestId = method == 'search' ? '${++_nextSearchRequest}' : null;
    void cancelNative() {
      if (requestId != null) {
        _spiderChannel.invokeMethod<void>('cancelSearch', {
          'requestId': requestId,
        }).ignore();
      }
    }

    if (cancellation?.isCancelled == true) return '{}';
    void Function()? unregister;
    try {
      final pending = _spiderChannel.invokeMethod<String>(method, {
        ..._siteArgs(site),
        'dohEndpoints': NetworkPolicy.proxy.isEmpty
            ? NetworkPolicy.dohEndpoints
            : const <String>[],
        'filter': site.filterable != 0,
        'requestId': ?requestId,
        ...args,
      });
      if (cancellation != null) {
        unregister = cancellation._onCancel(cancelNative);
      }
      final raw = await pending.timeout(
        Duration(seconds: method == 'search' ? 45 : 20),
      );
      return raw ?? '{}';
    } on TimeoutException {
      cancelNative();
      throw ApiException('Spider 响应超时，请重试此站');
    } on PlatformException catch (error) {
      throw ApiException(error.message ?? 'Spider 运行失败');
    } on MissingPluginException {
      throw ApiException('当前设备没有 Spider 运行时', isUnsupported: true);
    } finally {
      unregister?.call();
    }
  }

  Future<({String url, Map<String, String> headers, bool parse, bool sniff})>
  spiderPlay(
    SiteConfig site,
    String flag,
    String id,
    List<String> flags,
  ) async {
    final raw = site.isSpider
        ? await _spider(site, 'player', {
            'flag': flag,
            'id': id,
            'flags': flags,
          })
        : await _get(site, {'play': id, 'flag': flag, 'extend': site.ext});
    dynamic data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      throw ApiException('站点返回的播放信息格式无效，请切换线路');
    }
    if (data is! Map) throw ApiException('站点返回的播放信息格式无效，请切换线路');
    final prefix = asString(data['playUrl']);
    final useParser =
        asBool(data['jx']) ||
        (prefix.isEmpty && flags.contains(flag) && asBool(data['parse'], true));
    final target = asString(data['url']).trim();
    if (target.isEmpty) throw ApiException('站点未返回播放地址，请重试或切换线路');
    var url = '${useParser ? '' : prefix}$target'.trim();
    final proxied = site.isSpider && url.startsWith('proxy://');
    if (proxied) url = await bindSpiderProxy(site, url);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw ApiException('站点返回的地址无法播放，请切换线路');
    }
    dynamic headers = data['header'] ?? data['headers'];
    if (headers is String) {
      try {
        headers = jsonDecode(headers);
      } catch (_) {
        headers = null;
      }
    }
    return (
      url: url,
      headers: {
        if (headers is Map)
          for (final entry in headers.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      },
      parse: !proxied && useParser,
      sniff: !proxied && !useParser && asBool(data['parse'], true),
    );
  }

  Future<int?> probeLatency(SiteConfig site) async {
    if (!site.isHttpSite) return null;
    const budget = Duration(seconds: 3);
    final token = CancelToken();
    final watch = Stopwatch()..start();
    try {
      final body =
          await _get(
            site,
            site.type == 4
                ? {'filter': 'true', 'extend': site.ext}
                : {'ac': 'list'},
            timeout: budget,
            cancelToken: token,
          ).timeout(
            budget,
            onTimeout: () {
              token.cancel();
              throw ApiException('站点测速超时');
            },
          );
      final payload = _parseBody(body, site);
      if (payload.categories.isEmpty && payload.videos.isEmpty) return null;
      return watch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<HomeData> home(SiteConfig site) async {
    if (site.isSpider || site.type == 4) {
      final raw = site.isSpider
          ? await _spider(site, 'home')
          : await _get(site, {'filter': 'true', 'extend': site.ext});
      final payload = _parseBody(raw, site);
      final first = payload.categories.firstOrNull;
      final fallback =
          site.type == 4 &&
              !site.isSpider &&
              payload.videos.isEmpty &&
              first != null
          ? await category(site, first.id, 1)
          : null;
      return HomeData(
        categories: payload.categories,
        videos: fallback?.videos ?? payload.videos,
        filters: payload.filters,
        page: payload.page,
        pageCount: site.type == 4 ? 1 : payload.pageCount,
        total: fallback?.total ?? payload.total,
      );
    }
    _ensureSupported(site);
    final attempts = <Map<String, String>>[
      {'ac': 'list'},
      {'ac': 'videolist', 'pg': '1'},
      {'ac': 'detail', 'pg': '1'},
      {},
    ];
    ApiPayload? best;
    Object? lastError;
    // 首屏整体预算 30s：4 组候选串行，单次最坏 15s 连接 + 25s 接收，超预算
    // 即放弃剩余候选并抛错，避免首页转圈 4-5 分钟（数据层无 skin，写死 Duration）。
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    for (final params in attempts) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      try {
        final body = await _get(site, params, timeout: remaining);
        final payload = _parseBody(body, site);
        best = payload;
        if (payload.videos.isNotEmpty) break;
        if (payload.categories.isNotEmpty) {
          // Categories were returned without a home list. Pull the first
          // category so the home page still has content.
          final first = payload.categories.firstWhere(
            (e) => e.isValid,
            orElse: () => const CategoryItem(id: '', name: ''),
          );
          if (first.id.isNotEmpty) {
            final catalog = await category(site, first.id, 1);
            if (catalog.videos.isNotEmpty) {
              return HomeData(
                categories: payload.categories,
                filters: payload.filters,
                videos: catalog.videos,
                page: catalog.page,
                pageCount: catalog.pageCount,
                total: catalog.total,
              );
            }
          }
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (best == null) {
      if (lastError is ApiException) throw lastError;
      throw ApiException(_friendlyError(lastError));
    }
    var categories = best.categories;
    if (categories.isEmpty) {
      categories = _categoriesFromVideos(best.videos);
    }
    if (site.categories.isNotEmpty) {
      final allowed = site.categories.toSet();
      final filtered = categories
          .where((item) => allowed.contains(item.name))
          .toList();
      if (filtered.isNotEmpty) categories = filtered;
    }
    return HomeData(
      categories: categories,
      filters: best.filters,
      videos: best.videos,
      page: best.page,
      pageCount: best.pageCount,
      total: best.total,
    );
  }

  Future<CatalogData> category(
    SiteConfig site,
    String categoryId,
    int page, {
    Map<String, String> filters = const {},
  }) async {
    if (site.isSpider) {
      if (categoryId.isEmpty) return latest(site, page);
      final payload = _parseBody(
        await _spider(site, 'category', {
          'id': categoryId,
          'page': '$page',
          'filters': filters,
        }),
        site,
      );
      return CatalogData(
        videos: payload.videos,
        page: page,
        pageCount: payload.pageCount,
        total: payload.total,
      );
    }
    if (site.type == 4) {
      if (categoryId.isEmpty) return latest(site, page);
      final selected = Map.of(filters)
        ..removeWhere((_, value) => value.trim().isEmpty || value == '全部');
      final payload = _parseBody(
        await _get(site, {
          'ac': 'detail',
          'filter': 'true',
          't': categoryId,
          'pg': '$page',
          'ext': selected.isEmpty
              ? ''
              : base64Encode(utf8.encode(jsonEncode(selected))),
        }),
        site,
      );
      return CatalogData(
        videos: payload.videos,
        page: page,
        pageCount: payload.pageCount,
        total: payload.total,
      );
    }
    _ensureSupported(site);
    if (categoryId.isEmpty) {
      final home = await this.home(site);
      return CatalogData(
        videos: home.videos,
        page: home.page,
        pageCount: home.pageCount,
        total: home.total,
      );
    }
    final base = <String, String>{'t': categoryId, 'pg': page.toString()};
    for (final entry in filters.entries) {
      if (entry.value.trim().isEmpty || entry.value == '全部') continue;
      base[entry.key] = entry.value;
    }
    final attempts = <Map<String, String>>[
      {'ac': 'videolist', ...base},
      {'ac': 'detail', ...base},
      base,
    ];
    Object? lastError;
    // 分类整体预算 30s：3 组候选串行，超预算即放弃剩余候选。
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    for (final params in attempts) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      try {
        final body = await _get(site, params, timeout: remaining);
        final payload = _parseBody(body, site);
        if (payload.videos.isNotEmpty || payload.pageCount > 1) {
          return CatalogData(
            videos: payload.videos,
            page: payload.page == 0 ? page : payload.page,
            pageCount: payload.pageCount == 0 ? page : payload.pageCount,
            total: payload.total,
          );
        }
      } catch (error) {
        lastError = error;
      }
    }
    // 区分「网络/接口故障」与「真空结果」：有异常就抛可操作提示，不要静默
    // 吞成空列表让用户误以为「没有内容」。
    if (lastError is ApiException) throw lastError;
    if (lastError != null) throw ApiException(_friendlyError(lastError));
    return CatalogData(videos: const [], page: page, pageCount: page, total: 0);
  }

  Future<CatalogData> latest(SiteConfig site, int page) async {
    if (site.isSpider || site.type == 4) {
      if (page > 1) {
        return CatalogData(videos: const [], page: page, pageCount: page);
      }
      final homeData = await home(site);
      return CatalogData(
        videos: homeData.videos,
        page: 1,
        pageCount: 1,
        total: homeData.total,
      );
    }
    _ensureSupported(site);
    final pageValue = page < 1 ? 1 : page;
    final attempts = <Map<String, String>>[
      {'ac': 'videolist', 'pg': pageValue.toString()},
      {'ac': 'detail', 'pg': pageValue.toString()},
      {'pg': pageValue.toString()},
    ];
    Object? lastError;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    for (final params in attempts) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      try {
        final body = await _get(site, params, timeout: remaining);
        final payload = _parseBody(body, site);
        if (payload.videos.isNotEmpty) {
          return CatalogData(
            videos: payload.videos,
            page: payload.page <= 0 ? pageValue : payload.page,
            pageCount: payload.pageCount <= 0 ? pageValue : payload.pageCount,
            total: payload.total,
          );
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError is ApiException) throw lastError;
    if (lastError != null) throw ApiException(_friendlyError(lastError));
    return CatalogData(videos: const [], page: pageValue, pageCount: pageValue);
  }

  Future<List<VodItem>> search(
    SiteConfig site,
    String keyword, {
    SearchCancellation? cancellation,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty || cancellation?.isCancelled == true) return const [];
    if (site.isSpider) {
      return _parseBody(
        await _spider(site, 'search', {'id': query}, cancellation),
        site,
      ).videos;
    }
    if (site.type == 4) {
      return _parseBody(
        await _get(
          site,
          {'wd': query, 'ac': 'detail', 'quick': 'false'},
          timeout: const Duration(seconds: 10),
          cancelToken: cancellation?._http,
        ),
        site,
      ).videos;
    }
    _ensureSupported(site);
    final attempts = <Map<String, String>>[
      if (site.type == 1) {'ac': 'detail', 'wd': query} else {'wd': query},
      {'ac': 'videolist', 'wd': query, 'pg': '1'},
      {'ac': 'detail', 'wd': query, 'pg': '1'},
      {'wd': query, 'pg': '1'},
      {'ac': 'videolist', 'search': query, 'pg': '1'},
    ];
    Object? lastError;
    // 参考 Box 的参数优先，只在接口报错或响应无法解析时尝试兼容参数。
    const requestTimeout = Duration(seconds: 10);
    const retryBudget = Duration(seconds: 20);
    final elapsed = Stopwatch()..start();
    for (final params in attempts) {
      final remaining = retryBudget - elapsed.elapsed;
      if (remaining <= Duration.zero || cancellation?.isCancelled == true) {
        break;
      }
      try {
        final body = await _get(
          site,
          params,
          timeout: remaining < requestTimeout ? remaining : requestTimeout,
          cancelToken: cancellation?._http,
        );
        return _parseBody(body, site).videos;
      } on DioException catch (error) {
        // 连接、读取或取消失败时，换查询参数也无法解决。
        if (cancellation?.isCancelled == true) {
          rethrow;
        }
        throw ApiException(_friendlyError(error));
      } catch (error) {
        lastError = error;
        if (cancellation?.isCancelled == true) {
          rethrow;
        }
      }
    }
    // 网络/接口故障要抛错，不能静默返回空列表让用户分不清「没搜到」和「故障」。
    if (lastError is ApiException) throw lastError;
    if (lastError != null) throw ApiException(_friendlyError(lastError));
    return const [];
  }

  Future<VodItem> detail(SiteConfig site, String id) async {
    if (id.isEmpty) throw ApiException('缺少影片 ID');
    if (site.isSpider || site.type == 4) {
      final raw = site.isSpider
          ? await _spider(site, 'detail', {'id': id})
          : await _get(site, {'ac': 'detail', 'ids': id, 'extend': site.ext});
      final videos = _parseBody(raw, site).videos;
      for (final video in videos) {
        if (video.id == id) return video;
      }
      if (videos.isNotEmpty) return videos.first;
      throw ApiException('Spider 未返回影片详情');
    }
    _ensureSupported(site);
    final attempts = <Map<String, String>>[
      {'ac': 'detail', 'ids': id},
      {'ac': 'detail', 'id': id},
      {'ac': 'videolist', 'ids': id},
      {'ac': 'videolist', 'id': id},
      {'ids': id},
    ];
    Object? lastError;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    for (final params in attempts) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      try {
        final body = await _get(site, params, timeout: remaining);
        final payload = _parseBody(body, site);
        if (payload.videos.isEmpty) continue;
        final match = payload.videos.firstWhere(
          (e) => e.id == id,
          orElse: () => payload.videos.first,
        );
        if (match.name.isNotEmpty) {
          return match.copyWith(sourceKey: site.key, sourceName: site.name);
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError is ApiException) throw lastError;
    if (lastError != null) throw ApiException(_friendlyError(lastError));
    throw ApiException('详情加载失败，接口没有返回影片信息');
  }

  void _ensureSupported(SiteConfig site) {
    if (site.isSpider || site.api.isEmpty || site.api.startsWith('csp_')) {
      throw ApiException(
        '「${site.name}」是 Spider 站点，需要 JAR/JS 运行时，Flutter 版暂不支持。'
        '请在设置中切换到 JSON/XML 站点。',
        isUnsupported: true,
      );
    }
    if (!site.api.startsWith('http')) {
      throw ApiException('站点「${site.name}」的 API 地址无效：${site.api}');
    }
  }

  Future<String> _get(
    SiteConfig site,
    Map<String, String> params, {
    Duration? timeout,
    CancelToken? cancelToken,
  }) async {
    final uri = _buildUri(site.api, params, keepEmpty: site.type == 4);
    final response = await _dio.get<String>(
      uri.toString(),
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
        // 用剩余预算截断单次请求，配合各入口的整体 deadline 使用；为 null 时
        // 走 Dio 全局默认（15s 连接 + 25s 接收）。
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        headers: {
          'User-Agent': 'okhttp/3.15',
          // 透传站点配置里显式声明的播放/防盗链头（从 ext JSON 解析得到），
          // 不再用 `site.ext.contains('http')` 猜测 Referer（那是误用）。
          ...site.headers,
        },
      ),
    );
    final code = response.statusCode ?? 0;
    if (code >= 400) throw ApiException('接口请求失败：HTTP $code');
    var body = response.data ?? '';
    if (body.isEmpty) throw ApiException('接口返回为空');
    return body;
  }

  Uri _buildUri(
    String api,
    Map<String, String> params, {
    bool keepEmpty = false,
  }) {
    final base = Uri.parse(api);
    final query = <String, String>{};
    base.queryParameters.forEach((key, value) => query[key] = value);
    for (final entry in params.entries) {
      if (!keepEmpty && entry.value.trim().isEmpty) continue;
      query[entry.key] = entry.value;
    }
    if (!keepEmpty) return base.replace(queryParameters: query);
    return base.replace(
      query: query.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
          )
          .join('&'),
    );
  }

  ApiPayload _parseBody(String rawBody, SiteConfig site) {
    var body = rawBody.trim();
    if (body.startsWith('\ufeff')) body = body.substring(1);
    if (body.isEmpty) throw ApiException('接口返回为空');
    if (body.startsWith('<')) {
      return _parseXml(body, site);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      final start = body.indexOf('{');
      final end = body.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          decoded = jsonDecode(body.substring(start, end + 1));
        } catch (_) {}
      }
      if (decoded == null) {
        throw ApiException('接口返回了非 JSON 内容，可能被防火墙拦截');
      }
    }
    return _parseJson(decoded, site);
  }

  ApiPayload _parseJson(dynamic decoded, SiteConfig site) {
    if (decoded is List) {
      final videos = _videosFromList(decoded, site);
      return ApiPayload(
        videos: videos,
        categories: _categoriesFromVideos(videos),
      );
    }
    if (decoded is! Map) {
      throw ApiException('接口 JSON 结构无法识别');
    }
    final root = Map<String, dynamic>.from(decoded);
    final rawData = root['data'];
    final data = rawData is Map ? Map<String, dynamic>.from(rawData) : null;

    dynamic rawList =
        root['list'] ?? root['videos'] ?? root['items'] ?? root['result'];
    if (rawList == null && rawData is List) {
      rawList = rawData;
    }
    if (rawList == null && data != null) {
      rawList = data['list'] ?? data['videos'] ?? data['items'] ?? data['data'];
    }
    if (rawList is Map) {
      rawList = rawList['list'] ?? rawList['videos'] ?? rawList['data'];
    }
    final videos = rawList is List
        ? _videosFromList(rawList, site)
        : <VodItem>[];

    dynamic rawClasses =
        root['class'] ?? root['classes'] ?? root['categories'] ?? root['types'];
    if (rawClasses == null && data != null) {
      rawClasses =
          data['class'] ??
          data['classes'] ??
          data['categories'] ??
          data['types'];
    }
    final categories = _categoriesFromDynamic(rawClasses);

    var page = asInt(root['page'] ?? data?['page'], 1);
    var pageCount = asInt(
      root['pagecount'] ?? root['page_count'] ?? data?['pagecount'],
      1,
    );
    final total = asInt(root['total'] ?? data?['total'], 0);
    if (page <= 0) page = 1;
    if (pageCount <= 0) pageCount = 1;
    if (pageCount < page) pageCount = page;

    final errorMsg = asString(root['msg'] ?? root['message']);
    if (videos.isEmpty && categories.isEmpty && root['code'] != null) {
      final code = asInt(root['code']);
      if (code != 1 && errorMsg.isNotEmpty) {
        throw ApiException(errorMsg);
      }
    }

    return ApiPayload(
      categories: categories.isEmpty
          ? _categoriesFromVideos(videos)
          : categories,
      videos: videos,
      page: page,
      pageCount: pageCount,
      total: total,
      filters: CategoryFilter.parse(root['filters'] ?? data?['filters']),
    );
  }

  ApiPayload _parseXml(String body, SiteConfig site) {
    XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } catch (error) {
      throw ApiException('XML 解析失败：$error');
    }
    final root = document.rootElement;
    final videos = <VodItem>[];
    for (final video in root.findAllElements('video')) {
      final item = VodItem.fromXmlElement(
        video,
        sourceKey: site.key,
        sourceName: site.name,
      );
      if (item != null) videos.add(item);
    }
    final categories = <CategoryItem>[];
    final classNode = root.findAllElements('class').isNotEmpty
        ? root.findAllElements('class').first
        : null;
    if (classNode != null) {
      for (final ty in classNode.findAllElements('ty')) {
        final id = ty.getAttribute('id') ?? '';
        final name = ty.innerText.trim();
        if (id.isNotEmpty && name.isNotEmpty) {
          categories.add(CategoryItem(id: id, name: name));
        }
      }
    }
    final listNode = root.findAllElements('list').isNotEmpty
        ? root.findAllElements('list').first
        : null;
    final page = asInt(listNode?.getAttribute('page'), 1);
    final pageCount = asInt(
      listNode?.getAttribute('pagecount') ??
          listNode?.getAttribute('page_count'),
      1,
    );
    final total = asInt(listNode?.getAttribute('recordcount'), videos.length);
    return ApiPayload(
      categories: categories.isEmpty
          ? _categoriesFromVideos(videos)
          : categories,
      videos: videos,
      page: page <= 0 ? 1 : page,
      pageCount: pageCount <= 0 ? 1 : pageCount,
      total: total,
    );
  }

  List<VodItem> _videosFromList(List list, SiteConfig site) {
    final result = <VodItem>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final item = VodItem.fromJson(
        map,
        sourceKey: site.key,
        sourceName: site.name,
      );
      if (item.name.isEmpty && item.id.isEmpty) continue;
      result.add(item);
    }
    return result;
  }

  List<CategoryItem> _categoriesFromDynamic(dynamic raw) {
    if (raw is List) {
      final result = raw
          .map(CategoryItem.fromDynamic)
          .where((e) => e.isValid)
          .toList();
      final seen = <String>{};
      return result.where((e) => seen.add(e.id)).toList();
    }
    if (raw is Map) {
      final result = <CategoryItem>[];
      raw.forEach((key, value) {
        if (value is Map) {
          result.add(
            CategoryItem(
              id: key.toString(),
              name: asString(value['name'], key.toString()),
            ),
          );
        } else if (value is String || value is num) {
          result.add(CategoryItem(id: key.toString(), name: value.toString()));
        }
      });
      return result;
    }
    return const [];
  }

  List<CategoryItem> _categoriesFromVideos(List<VodItem> videos) {
    final map = <String, String>{};
    for (final video in videos) {
      final id = video.typeId;
      final name = video.typeName;
      if (id.isEmpty || name.isEmpty || map.containsKey(id)) continue;
      map[id] = name;
    }
    return map.entries
        .map((e) => CategoryItem(id: e.key, name: e.value))
        .toList();
  }

  String _friendlyError(Object? error) {
    if (error is ApiException) return error.message;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
          return '连接站点超时，请检查网络或稍后重试';
        case DioExceptionType.sendTimeout:
          return '发送请求超时，请检查网络';
        case DioExceptionType.receiveTimeout:
          return '站点响应超时，请稍后重试或换一个源';
        case DioExceptionType.transformTimeout:
          return '站点响应处理超时，请稍后重试';
        case DioExceptionType.connectionError:
          return '网络连接失败，请检查网络设置';
        case DioExceptionType.badResponse:
          return '接口返回异常（HTTP ${error.response?.statusCode ?? '未知'}）';
        case DioExceptionType.badCertificate:
          return '站点证书校验失败';
        case DioExceptionType.cancel:
          return '请求已取消';
        case DioExceptionType.unknown:
          return '网络请求失败，请检查网络或换一个源';
      }
    }
    return error?.toString() ?? '未知错误';
  }
}

class ApiPayload {
  const ApiPayload({
    required this.categories,
    required this.videos,
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
    this.filters = const {},
  });

  final List<CategoryItem> categories;
  final Map<String, List<CategoryFilter>> filters;
  final List<VodItem> videos;
  final int page;
  final int pageCount;
  final int total;
}
