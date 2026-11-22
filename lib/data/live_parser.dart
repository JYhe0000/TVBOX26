import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';
import 'network_policy.dart';
import 'site_api.dart' show ApiException;

class LiveParseResult {
  const LiveParseResult({
    required this.groups,
    required this.title,
    this.warning,
  });

  final List<LiveGroup> groups;
  final String title;
  final String? warning;

  int get channelCount =>
      groups.fold(0, (sum, group) => sum + group.channels.length);
}

class LiveParser {
  static const _ignoredGroups = <String>{'更新时间', '公告', '提示'};

  static final _m3uAttributePattern = RegExp(
    r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))''',
    caseSensitive: false,
  );
  static final _txtUrlSeparator = RegExp(r'#(?=(?:https?|rtmp|rtsp)://|//)');

  static const _groupNames = <String, String>{
    'general': '综合',
    'news': '新闻',
    'sports': '体育',
    'movies': '电影',
    'movie': '电影',
    'music': '音乐',
    'kids': '少儿',
    'children': '少儿',
    'religious': '宗教',
    'undefined': '其他',
    'entertainment': '娱乐',
    'documentary': '纪录',
    'education': '教育',
    'lifestyle': '生活',
    'family': '家庭',
    'culture': '文化',
    'shop': '购物',
    'shopping': '购物',
    'travel': '旅游',
    'weather': '天气',
    'business': '财经',
    'animation': '动画',
    'auto': '汽车',
    'comedy': '喜剧',
    'cooking': '美食',
    'science': '科学',
    'legislative': '政务',
    'local': '地方',
    'public': '公共',
    'relax': '休闲',
    'series': '剧集',
  };

  static LiveParseResult parse(
    String content, {
    String baseUrl = '',
    String title = '直播源',
  }) {
    var body = content.trim();
    if (body.startsWith('\ufeff')) body = body.substring(1);
    if (body.isEmpty) {
      return LiveParseResult(
        groups: const [],
        title: title,
        warning: '直播源内容为空',
      );
    }
    if (body.startsWith('{') || body.startsWith('[')) {
      final jsonResult = _parseJson(body, baseUrl: baseUrl, title: title);
      if (jsonResult != null) return jsonResult;
    }
    if (body.startsWith('#EXTM3U') || body.contains('#EXTINF')) {
      return _parseM3u(body, baseUrl: baseUrl, title: title);
    }
    return _parseTxt(body, baseUrl: baseUrl, title: title);
  }

  static LiveParseResult _parseM3u(
    String body, {
    required String baseUrl,
    required String title,
  }) {
    final channels = <String, LiveChannel>{};
    final groupOrder = <String>[];
    final channelsByGroup = <String, List<LiveChannel>>{};
    final lines = const LineSplitter().convert(body);
    String? pendingName;
    String? pendingLogo;
    String? pendingGroup;
    Map<String, String> pendingAttrs = {};
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        // M3U 规范：#EXTINF:时长 属性...,显示名。显示名是「属性段之后」的
        // 内容，可能自身含逗号（如「CCTV-1,综合」）；属性值（group-title 等）
        // 引号内也可能含逗号。因此不能简单 lastIndexOf(',')：先定位第一个
        // 不在引号内的逗号作为分隔点，其左为属性段、其右整体为显示名。
        final metaEnd = _firstCommaOutsideQuotes(line);
        final meta = metaEnd >= 0 ? line.substring(0, metaEnd) : line;
        final attrs = <String, String>{};
        for (final match in _m3uAttributePattern.allMatches(meta)) {
          final value =
              match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
          attrs[match.group(1)!.toLowerCase()] = value;
        }
        final display = metaEnd >= 0 ? line.substring(metaEnd + 1).trim() : '';
        pendingName = (attrs['tvg-name']?.trim().isNotEmpty ?? false)
            ? attrs['tvg-name']!.trim()
            : display;
        if (pendingName.isEmpty) pendingName = '未命名频道';
        pendingLogo = attrs['tvg-logo'] ?? '';
        pendingAttrs = attrs;
        final group = _translateGroup(attrs['group-title'] ?? '');
        pendingGroup = group;
        if (!channelsByGroup.containsKey(group)) {
          groupOrder.add(group);
          channelsByGroup[group] = <LiveChannel>[];
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      final pending = pendingName;
      if (pending == null || pending.isEmpty) continue;
      final url = _resolveUrl(line, baseUrl);
      if (url.isEmpty) continue;
      final group = pendingGroup ?? '未分组';
      // 用「组名|频道名」作 key 去重：不同分组下同名频道各自保留，
      // 否则跨组同名频道会被合并到先出现的分组里，导致后一组整组消失。
      final key = '$group|$pending';
      final existing = channels[key];
      if (existing != null) {
        if (!existing.urls.contains(url)) {
          existing.urls.add(url);
          existing.sourceNames.add(title);
        }
      } else {
        final channel = LiveChannel(
          name: pending,
          urls: [url],
          sourceNames: [title],
          logo: pendingLogo ?? '',
          group: group,
          number: asInt(pendingAttrs['tvg-chno'], channels.length + 1),
          epgId: pendingAttrs['tvg-id'] ?? '',
          password: pendingAttrs['password'] ?? '',
          catchupSource: pendingAttrs['catchup-source'] ?? '',
          catchupDays: asInt(pendingAttrs['catchup-days']),
        );
        channels[key] = channel;
        channelsByGroup[group]!.add(channel);
      }
      pendingName = null;
      pendingLogo = null;
      pendingGroup = null;
    }
    final groups = <LiveGroup>[];
    for (final groupName in groupOrder) {
      if (_ignoredGroups.contains(groupName)) continue;
      final items = channelsByGroup[groupName]!;
      if (items.isNotEmpty) {
        groups.add(LiveGroup(name: groupName, channels: items));
      }
    }
    return LiveParseResult(
      groups: groups,
      title: title,
      warning: groups.isEmpty ? '没有从 M3U 中解析到频道' : null,
    );
  }

  static LiveParseResult _parseTxt(
    String body, {
    required String baseUrl,
    required String title,
  }) {
    final channels = <String, LiveChannel>{};
    final groups = <String, List<String>>{};
    var currentGroup = '未分组';
    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      if (line.contains(',#genre#')) {
        currentGroup = line.split(',#genre#').first.trim();
        if (currentGroup.isEmpty) currentGroup = '未分组';
        groups.putIfAbsent(currentGroup, () => []);
        continue;
      }
      if (line.startsWith('#')) continue;
      final comma = line.indexOf(',');
      if (comma <= 0) continue;
      final name = line.substring(0, comma).trim();
      final rawUrls = line.substring(comma + 1).trim();
      if (name.isEmpty || rawUrls.isEmpty) continue;
      groups.putIfAbsent(currentGroup, () => []);
      // `#` 在 TXT 里既是多源分隔符，也可能出现在加密/带签 URL 自身（如
      // get.php?token=abc#frag）。只在 `#` 后紧跟 URL scheme 时才切分，
      // 其余 `#` 保留在 URL 内，避免把合法地址截成残串。
      final urls = rawUrls
          .split(_txtUrlSeparator)
          .map((e) => _resolveUrl(e.trim(), baseUrl))
          .where((e) => e.isNotEmpty)
          .toList();
      if (urls.isEmpty) continue;
      final key = '$currentGroup|$name';
      final existing = channels[key];
      if (existing != null) {
        for (var i = 0; i < urls.length; i++) {
          if (existing.urls.contains(urls[i])) continue;
          existing.urls.add(urls[i]);
          existing.sourceNames.add('$title ${existing.urls.length}');
        }
      } else {
        channels[key] = LiveChannel(
          name: name,
          urls: urls,
          sourceNames: List.generate(
            urls.length,
            (i) => i == 0 ? title : '$title ${i + 1}',
          ),
          group: currentGroup,
        );
        groups[currentGroup]!.add(key);
      }
    }
    final result = <LiveGroup>[];
    for (final entry in groups.entries) {
      final items = entry.value
          .map((key) => channels[key])
          .whereType<LiveChannel>()
          .toList();
      if (items.isNotEmpty) {
        result.add(LiveGroup(name: entry.key, channels: items));
      }
    }
    return LiveParseResult(
      groups: result,
      title: title,
      warning: result.isEmpty ? '没有从 TXT 中解析到频道' : null,
    );
  }

  static LiveParseResult? _parseJson(
    String body, {
    required String baseUrl,
    required String title,
  }) {
    try {
      final decoded = jsonDecode(body);
      List? list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map) {
        final root = Map<String, dynamic>.from(decoded);
        final value =
            root['lives'] ?? root['channels'] ?? root['list'] ?? root['data'];
        if (value is List) list = value;
      }
      if (list == null) return null;
      final channels = <String, LiveChannel>{};
      for (final entry in list) {
        if (entry is! Map) continue;
        final name = asString(entry['name'] ?? entry['title']).trim();
        final rawUrls = entry['urls'] ?? entry['url'];
        final urlValues = rawUrls is List ? rawUrls : [rawUrls];
        final urls = <String>[];
        for (final rawUrl in urlValues) {
          final url = _resolveUrl(asString(rawUrl), baseUrl);
          if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
        }
        if (name.isEmpty || urls.isEmpty) continue;
        final rawGroup = asString(
          entry['group'] ?? entry['group-title'] ?? entry['groupName'],
        ).trim();
        final group = rawGroup.isEmpty ? '直播' : _translateGroup(rawGroup);
        final logo = asString(entry['logo']).trim();
        // 与 M3U/TXT 一致用「组名|频道名」去重：同名频道跨组各自保留。
        // 合并时 URL 去重追加；logo 只在已有为空且新值非空时补上，避免
        // 后到的空 logo 把先前的有效 logo 顶掉。
        final key = '$group|$name';
        final existing = channels[key];
        if (existing != null) {
          final mergedUrls = <String>[...existing.urls];
          final mergedNames = <String>[...existing.sourceNames];
          for (final url in urls) {
            if (mergedUrls.contains(url)) continue;
            mergedUrls.add(url);
            mergedNames.add(title);
          }
          channels[key] = LiveChannel(
            name: existing.name,
            urls: mergedUrls,
            sourceNames: mergedNames,
            logo: existing.logo.isNotEmpty ? existing.logo : logo,
            group: existing.group,
            number: existing.number,
            password: existing.password,
            epgId: existing.epgId,
            catchupSource: existing.catchupSource,
            catchupDays: existing.catchupDays,
          );
        } else {
          channels[key] = LiveChannel(
            name: name,
            urls: urls,
            sourceNames: List<String>.filled(urls.length, title),
            logo: logo,
            group: group,
            number: asInt(entry['number'], channels.length + 1),
            password: asString(entry['password']),
            epgId: asString(entry['tvg-id'] ?? entry['epgId']),
            catchupSource: asString(
              entry['catchup-source'] ?? entry['catchupSource'],
            ),
            catchupDays: asInt(entry['catchup-days'] ?? entry['catchupDays']),
          );
        }
      }
      if (channels.isEmpty) return null;
      final groups = <String, List<LiveChannel>>{};
      for (final channel in channels.values) {
        groups.putIfAbsent(channel.group, () => []).add(channel);
      }
      return LiveParseResult(
        title: title,
        groups: groups.entries
            .map((e) => LiveGroup(name: e.key, channels: e.value))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  static String _resolveUrl(String url, String baseUrl) {
    final value = url.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('rtmp')) {
      return value;
    }
    if (baseUrl.isEmpty) return value;
    try {
      if (value.startsWith('//')) {
        final base = Uri.parse(baseUrl);
        return '${base.scheme}:$value';
      }
      return Uri.parse(baseUrl).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  static String _translateGroup(String group) {
    final value = group.trim();
    if (value.isEmpty) return '未分组';
    final translated = _groupNames[value.toLowerCase()];
    if (translated != null) return translated;
    return value;
  }

  /// 返回第一个不在双引号内的逗号下标；没有则返回 -1。
  ///
  /// 用于 `#EXTINF` 行切分属性段与显示名：属性值（引号内）允许含逗号，
  /// 显示名也可能含逗号，只有属性段末尾的那个逗号才是分隔点。
  static int _firstCommaOutsideQuotes(String line) {
    String? quote;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quote == null && (c == '"' || c == "'")) {
        quote = c;
      } else if (quote == c) {
        quote = null;
      } else if (c == ',' && quote == null) {
        return i;
      }
    }
    return -1;
  }
}

class LiveService {
  LiveService({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                followRedirects: true,
                headers: const {'User-Agent': 'okhttp/3.15'},
              ),
            ),
          );

  final Dio _dio;

  Future<LiveParseResult> load(LiveSource source) async {
    final String body;
    try {
      final response = await _dio.get<String>(
        source.url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': source.ua.isNotEmpty ? source.ua : 'okhttp/3.15',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if ((response.statusCode ?? 0) >= 400) {
        throw ApiException('直播源请求失败：HTTP ${response.statusCode}');
      }
      body = response.data ?? '';
    } on DioException catch (error) {
      // 把 Dio 异常映射成可操作中文提示，避免把英文堆栈直接甩给用户。
      throw ApiException(_friendlyError(error));
    }
    return LiveParser.parse(body, baseUrl: source.url, title: source.name);
  }

  Future<LiveParseResult> loadUrl(String url, {String title = '直播源'}) async {
    final String body;
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if ((response.statusCode ?? 0) >= 400) {
        throw ApiException('直播源请求失败：HTTP ${response.statusCode}');
      }
      body = response.data ?? '';
    } on DioException catch (error) {
      throw ApiException(_friendlyError(error));
    }
    return LiveParser.parse(body, baseUrl: url, title: title);
  }

  /// 把 Dio 异常映射成可操作的中文提示（超时/断网/HTTP 错误分别措辞）。
  static String _friendlyError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return '连接直播源超时，请检查网络';
      case DioExceptionType.sendTimeout:
        return '请求发送超时，请检查网络';
      case DioExceptionType.receiveTimeout:
        return '直播源响应超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '无法连接直播源，请检查网络设置';
      case DioExceptionType.badResponse:
        return '直播源返回异常（HTTP ${error.response?.statusCode ?? '未知'}）';
      case DioExceptionType.badCertificate:
        return '直播源证书校验失败';
      default:
        return '直播源请求失败，请检查网络或换一个源';
    }
  }
}
