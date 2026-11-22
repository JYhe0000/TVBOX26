import 'dart:convert';

import 'package:xml/xml.dart';

/// Small helpers used by the very forgiving TVBox config/API formats.
String asString(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return fallback;
}

int asInt(dynamic value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim()) ?? fallback;
}

bool asBool(dynamic value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value.toString().toLowerCase().trim();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

String stripHtml(String input) {
  if (input.isEmpty) return input;
  var text = input
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// Every site entry in a TVBox config.
class SiteConfig {
  const SiteConfig({
    required this.key,
    required this.name,
    required this.api,
    this.type = 1,
    this.searchable = 1,
    this.quickSearch = 1,
    this.filterable = 0,
    this.hide = 0,
    this.playerType = -1,
    this.ext = '',
    this.headers = const {},
    this.jar = '',
    this.playUrl = '',
    this.click = '',
    this.style = '',
    this.categories = const [],
  });

  final String key;
  final String name;
  final String api;
  final int type;
  final int searchable;
  final int quickSearch;
  final int filterable;
  final int hide;
  final int playerType;
  final String ext;
  final Map<String, String> headers;
  final String jar;
  final String playUrl;
  final String click;
  final String style;
  final List<String> categories;

  bool get isSearchable => searchable != 0;
  bool get isQuickSearch => quickSearch != 0;
  bool get isHidden => hide == 1;
  bool get isSpider => type == 3 || jar.isNotEmpty || api.startsWith('csp_');
  bool get isHttpSite {
    if (isSpider) return false;
    final uri = Uri.tryParse(api);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  SiteConfig withKeyAndJar(String key, String jar) => SiteConfig(
    key: key,
    name: name,
    api: api,
    type: type,
    searchable: searchable,
    quickSearch: quickSearch,
    filterable: filterable,
    hide: hide,
    playerType: playerType,
    ext: ext,
    headers: headers,
    jar: jar,
    playUrl: playUrl,
    click: click,
    style: style,
    categories: categories,
  );

  String get typeLabel {
    if (isSpider) return 'Spider';
    return switch (type) {
      0 => 'XML',
      1 => 'JSON',
      2 => 'Web',
      4 => 'JSON',
      _ => 'API',
    };
  }

  factory SiteConfig.fromJson(Map<String, dynamic> json) {
    String key = asString(json['key']).trim();
    if (key.isEmpty) key = asString(json['name']).trim();
    if (key.isEmpty) key = 'site_${json.hashCode}';
    final ext = _configExt(json['ext']);
    return SiteConfig(
      key: key,
      name: asString(json['name'], key).trim(),
      api: asString(json['api']).trim(),
      type: asInt(json['type'], 1),
      searchable: asInt(json['searchable'], 1),
      quickSearch: asInt(json['quickSearch'], 1),
      filterable: asInt(json['filterable'], 0),
      hide: asInt(json['hide'], 0),
      playerType: asInt(json['playerType'], -1),
      ext: ext,
      headers: _parseExtHeaders(ext),
      jar: asString(json['jar']),
      playUrl: asString(json['playUrl']),
      click: asString(json['click']),
      style: asString(json['style']),
      categories: _stringList(json['categories']),
    );
  }

  /// 从站点 `ext`（扩展参数）里解析自定义播放头。
  ///
  /// TVBox 常用 `ext` 携带防盗链头，如 `{"header": {"Referer": "..."}}` 或
  /// `{"headers": {...}}`，也可能整段 base64 编码。解析失败一律返回空表，
  /// 不影响其它字段——`ext` 本身还可能是筛选参数等非 JSON 内容。
  static Map<String, String> _parseExtHeaders(String ext) {
    final raw = ext.trim();
    if (raw.isEmpty) return const {};
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = _tryBase64Json(raw);
    }
    if (decoded is! Map) return const {};
    final map = Map<String, dynamic>.from(decoded);
    final headerNode = map['header'] ?? map['headers'];
    if (headerNode is! Map) return const {};
    final result = <String, String>{};
    headerNode.forEach((key, value) {
      if (value == null) return;
      result[key.toString()] = value.toString();
    });
    return result;
  }

  /// 尝试把整段字符串按 base64(JSON) 解码；失败返回 null。
  static dynamic _tryBase64Json(String raw) {
    try {
      var text = raw.replaceAll(RegExp(r'\s'), '');
      text = text.replaceAll('-', '+').replaceAll('_', '/');
      while (text.length % 4 != 0) {
        text += '=';
      }
      return jsonDecode(utf8.decode(base64Decode(text), allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  static List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }
}

/// A play/parse API entry.
class ParseConfig {
  const ParseConfig({
    required this.name,
    required this.url,
    this.type = 0,
    this.ext = '',
    this.jar = '',
  });

  final String name;
  final String url;
  final int type;
  final String ext;
  final String jar;

  factory ParseConfig.fromJson(Map<String, dynamic> json) => ParseConfig(
    name: asString(json['name'], '解析').trim(),
    url: asString(json['url']).trim(),
    type: asInt(json['type'], 0),
    ext: _configExt(json['ext']),
    jar: asString(json['jar']),
  );
}

String _configExt(dynamic value) =>
    value is Map || value is List ? jsonEncode(value) : asString(value);

/// A live source declared inside a config.
class LiveSource {
  const LiveSource({
    required this.name,
    required this.url,
    this.type = 0,
    this.epg = '',
    this.logo = '',
    this.ua = '',
    this.playerType = -1,
  });

  final String name;
  final String url;
  final int type;
  final String epg;
  final String logo;
  final String ua;
  final int playerType;

  factory LiveSource.fromJson(Map<String, dynamic> json) {
    return LiveSource(
      name: asString(json['name'], '直播源').trim(),
      url: asString(json['url']).trim(),
      type: asInt(json['type'], 0),
      epg: asString(json['epg']).trim(),
      logo: asString(json['logo']).trim(),
      ua: asString(json['ua']).trim(),
      playerType: asInt(json['playerType'], -1),
    );
  }
}

class AppConfig {
  const AppConfig({
    required this.sites,
    required this.parses,
    required this.lives,
    this.spider = '',
    this.wallpaper = '',
    this.flags = const [],
    this.name = 'TVBOX26',
  });

  final List<SiteConfig> sites;
  final List<ParseConfig> parses;
  final List<LiveSource> lives;
  final String spider;
  final String wallpaper;
  final List<String> flags;
  final String name;

  List<SiteConfig> get visibleSites => sites.where((s) => !s.isHidden).toList();

  static const empty = AppConfig(sites: [], parses: [], lives: []);
}

class CategoryItem {
  const CategoryItem({required this.id, required this.name, this.flag = ''});

  final String id;
  final String name;
  final String flag;

  factory CategoryItem.fromDynamic(dynamic value) {
    if (value is String) {
      return CategoryItem(id: value, name: value);
    }
    if (value is Map) {
      return CategoryItem(
        id: asString(value['type_id'] ?? value['id'] ?? value['tid']).trim(),
        name: asString(value['type_name'] ?? value['name'] ?? value['title'])
            .trim(),
        flag: asString(value['type_flag'] ?? value['flag']),
      );
    }
    return const CategoryItem(id: '', name: '全部');
  }

  bool get isValid => id.isNotEmpty && name.isNotEmpty;
}

class Episode {
  const Episode({required this.name, required this.url, this.index = 0});

  final String name;
  final String url;
  final int index;

  bool get isDirectVideo => isDirectVideoUrl(url);

  /// 集名里的集数（`第12集` / `EP12` / `12` / `第十二集`）；解析不出为 null。
  int? get number => parseEpisodeNumber(name);

  Episode copyWith({String? name, String? url, int? index}) => Episode(
    name: name ?? this.name,
    url: url ?? this.url,
    index: index ?? this.index,
  );
}

/// 从集名解析集数。覆盖常见命名：`第12集`、`第12话`、`EP12`、`12`、
/// `第十二集`、`第百零一集`。
int? parseEpisodeNumber(String name) {
  final text = name.trim();
  if (text.isEmpty) return null;
  // S01E02（先判，避免被裸 E 匹配误伤）。
  final season = RegExp(
    r'S(\d{1,2})\s*E(\d{1,2})',
    caseSensitive: false,
  ).firstMatch(text);
  if (season != null) return int.tryParse(season.group(2) ?? '');
  final arabic = RegExp(
    r'(?:第\s*([0-9]{1,4})\s*[集话話期])'
    r'|(?:^|[^A-Za-z])(?:EP|Ep|ep|episode|Episode)\s*([0-9]{1,4})'
    r'|^[（(\[]?([0-9]{1,4})[）)\].、:：]?$'
    r'|^[（(\[]?([0-9]{1,4})[）)\].、:：]\s*\S'
    r'|^.*[-–—]\s*([0-9]{1,4})\s*$',
  ).firstMatch(text);
  if (arabic != null) {
    for (var i = 1; i <= 4; i++) {
      final value = arabic.group(i);
      if (value != null && value.isNotEmpty) return int.tryParse(value);
    }
  }
  final chinese = RegExp(r'第\s*([零〇一二两三四五六七八九十百]+)\s*[集话話期]').firstMatch(text);
  if (chinese != null) return _chineseNumber(chinese.group(1)!);
  return null;
}

int? _chineseNumber(String text) {
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var section = 0;
  var number = 0;
  for (final char in text.split('')) {
    final digit = digits[char];
    if (digit != null) {
      number = digit;
    } else if (char == '十') {
      section += (number == 0 ? 1 : number) * 10;
      number = 0;
    } else if (char == '百') {
      section += (number == 0 ? 1 : number) * 100;
      number = 0;
    } else {
      return null;
    }
  }
  final total = section + number;
  return total > 0 ? total : null;
}

/// 部分源的剧集是倒序（第10集 → 第1集），首集排在最底。
///
/// 仅当「能解析集数的条目过半」且这些集数**严格递减**时整列翻转；
/// 升序、乱序、全是无集数名（预告/花絮）都保持原样。
List<Episode> normalizeEpisodeOrder(List<Episode> episodes) {
  if (episodes.length < 2) return episodes;
  final numbers = [for (final episode in episodes) episode.number];
  final known = numbers.whereType<int>().length;
  if (known < 2 || known * 2 < numbers.length) return episodes;
  var descending = true;
  var ascending = true;
  for (var i = 1; i < numbers.length; i++) {
    final previous = numbers[i - 1];
    final current = numbers[i];
    if (previous == null || current == null) continue;
    if (current > previous) descending = false;
    if (current < previous) ascending = false;
  }
  final ordered = descending && !ascending
      ? episodes.reversed.toList()
      : List<Episode>.of(episodes);
  // 翻转后重建序号，选集面板/播放器按 index 定位不会错位。
  for (var i = 0; i < ordered.length; i++) {
    ordered[i] = ordered[i].copyWith(index: i);
  }
  return List.unmodifiable(ordered);
}

class PlayLine {
  const PlayLine({required this.name, required this.episodes});

  final String name;
  final List<Episode> episodes;

  bool get isEmpty => episodes.isEmpty;
}

class VodItem {
  static final _episodeNamePattern = RegExp(
    r'^(?:第\s*[0-9零〇一二两三四五六七八九十百]+\s*[集话話期]|'
    r'(?:ep|episode)\s*[0-9]+|正片|片头|片尾|花絮|预告)$',
    caseSensitive: false,
  );

  const VodItem({
    required this.id,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.typeId = '',
    this.typeName = '',
    this.year = '',
    this.area = '',
    this.lang = '',
    this.actor = '',
    this.director = '',
    this.content = '',
    this.score = '',
    this.sourceKey = '',
    this.sourceName = '',
    this.lines = const [],
  });

  final String id;
  final String name;
  final String pic;
  final String remarks;
  final String typeId;
  final String typeName;
  final String year;
  final String area;
  final String lang;
  final String actor;
  final String director;
  final String content;
  final String score;
  final String sourceKey;
  final String sourceName;
  final List<PlayLine> lines;

  bool get hasPlayLines => lines.any((line) => line.episodes.isNotEmpty);
  bool get hasPoster => pic.trim().isNotEmpty;

  String get subtitle {
    final values = [year, area, typeName].where((e) => e.trim().isNotEmpty);
    return values.join(' · ');
  }

  VodItem copyWith({
    String? id,
    String? name,
    String? pic,
    String? remarks,
    String? typeId,
    String? typeName,
    String? year,
    String? area,
    String? lang,
    String? actor,
    String? director,
    String? content,
    String? score,
    String? sourceKey,
    String? sourceName,
    List<PlayLine>? lines,
  }) {
    return VodItem(
      id: id ?? this.id,
      name: name ?? this.name,
      pic: pic ?? this.pic,
      remarks: remarks ?? this.remarks,
      typeId: typeId ?? this.typeId,
      typeName: typeName ?? this.typeName,
      year: year ?? this.year,
      area: area ?? this.area,
      lang: lang ?? this.lang,
      actor: actor ?? this.actor,
      director: director ?? this.director,
      content: content ?? this.content,
      score: score ?? this.score,
      sourceKey: sourceKey ?? this.sourceKey,
      sourceName: sourceName ?? this.sourceName,
      lines: lines ?? this.lines,
    );
  }

  factory VodItem.fromJson(
    Map<String, dynamic> json, {
    String sourceKey = '',
    String sourceName = '',
  }) {
    final rawFrom = asString(
      json['vod_play_from'] ?? json['play_from'] ?? json['playFrom'],
    );
    final rawUrl = asString(
      json['vod_play_url'] ??
          json['play_url'] ??
          json['playUrl'] ??
          json['urls'],
    );
    final lines = <PlayLine>[];
    if (rawUrl.trim().isNotEmpty) {
      lines.addAll(parsePlayData(rawFrom, rawUrl));
    }
    final rawLines = json['lines'];
    if (rawLines is List) {
      for (final line in rawLines) {
        if (line is! Map) continue;
        final eps = <Episode>[];
        final rawEpisodes = line['episodes'];
        if (rawEpisodes is List) {
          for (final ep in rawEpisodes) {
            if (ep is Map) {
              eps.add(
                Episode(
                  name: asString(ep['name'], '第${eps.length + 1}集'),
                  url: asString(ep['url']),
                  index: eps.length,
                ),
              );
            }
          }
        }
        lines.add(
          PlayLine(
            name: asString(line['name'], '线路${lines.length + 1}'),
            // 历史缓存里可能存着旧版倒序数据，读取时同样翻正。
            episodes: eps.isEmpty ? eps : normalizeEpisodeOrder(eps),
          ),
        );
      }
    }

    return VodItem(
      id: asString(json['vod_id'] ?? json['id'] ?? json['ids']).trim(),
      name: stripHtml(
        asString(json['vod_name'] ?? json['name'] ?? json['title']),
      ).trim(),
      pic: asString(json['vod_pic'] ?? json['pic'] ?? json['poster']).trim(),
      remarks: stripHtml(
        asString(json['vod_remarks'] ?? json['note'] ?? json['remarks']),
      ).trim(),
      typeId: asString(json['type_id'] ?? json['tid'] ?? json['typeId']).trim(),
      typeName: asString(json['type_name'] ?? json['type'] ?? json['class'])
          .trim(),
      year: asString(json['vod_year'] ?? json['year']).trim(),
      area: asString(json['vod_area'] ?? json['area']).trim(),
      lang: asString(json['vod_lang'] ?? json['lang']).trim(),
      actor: stripHtml(asString(json['vod_actor'] ?? json['actor'])).trim(),
      director: stripHtml(asString(json['vod_director'] ?? json['director']))
          .trim(),
      content: stripHtml(
        asString(
          json['vod_content'] ??
              json['vod_blurb'] ??
              json['content'] ??
              json['des'],
        ),
      ),
      score: asString(json['vod_score'] ?? json['score']).trim(),
      // 序列化往返对称（P0-9）：参数优先、JSON 兜底。toJson 已写入
      // sourceKey/sourceName，恢复时若不读回，重启后收藏/历史的来源标识
      // 会退化为空串（心形恒灭、重复收藏、续播错源）。
      sourceKey: sourceKey.isNotEmpty ? sourceKey : asString(json['sourceKey']),
      sourceName: sourceName.isNotEmpty
          ? sourceName
          : asString(json['sourceName']),
      lines: lines,
    );
  }

  Map<String, dynamic> toJson({bool includeLines = false}) {
    final json = <String, dynamic>{
      'id': id,
      'name': name,
      'pic': pic,
      'remarks': remarks,
      'typeId': typeId,
      'typeName': typeName,
      'year': year,
      'area': area,
      'lang': lang,
      'actor': actor,
      'director': director,
      'content': content,
      'score': score,
      'sourceKey': sourceKey,
      'sourceName': sourceName,
    };
    if (includeLines) {
      json['lines'] = lines
          .map(
            (line) => {
              'name': line.name,
              'episodes': line.episodes
                  .map((ep) => {'name': ep.name, 'url': ep.url})
                  .toList(),
            },
          )
          .toList();
    }
    return json;
  }

  factory VodItem.fromStoredJson(Map<String, dynamic> json) => VodItem.fromJson(
    json,
    sourceKey: asString(json['sourceKey']),
    sourceName: asString(json['sourceName']),
  );

  static List<PlayLine> parsePlayData(String from, String urls) {
    if (urls.trim().isEmpty) return const [];
    final flags = from.split(r'$$$');
    final groups = urls.split(r'$$$');
    final lines = <PlayLine>[];
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i].trim();
      if (group.isEmpty) continue;
      final lineName = i < flags.length && flags[i].trim().isNotEmpty
          ? flags[i].trim()
          : '线路${i + 1}';
      final episodes = parseEpisodes(group);
      if (episodes.isNotEmpty) {
        lines.add(PlayLine(name: lineName, episodes: episodes));
      }
    }
    return lines;
  }

  static List<Episode> parseEpisodes(String input) {
    final result = <Episode>[];
    final parts = _splitEpisodeParts(input);
    for (final rawPart in parts) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      String name = '';
      String url = part;
      final split = part.indexOf(r'$');
      if (split >= 0) {
        final left = part.substring(0, split).trim();
        final right = part.substring(split + 1).trim();
        // 集名后面可以是插件专用 ID。仅当整段已经是直链时保留签名里的 `$`。
        if (!_looksLikeUrl(left)) {
          name = left;
          url = right;
        }
      }
      if (url.isEmpty) continue;
      if (name.isEmpty) name = '第${result.length + 1}集';
      result.add(Episode(name: name, url: url, index: result.length));
    }
    // 倒序源自动翻正（第10集…第1集 → 第1集…第10集）。
    return normalizeEpisodeOrder(result);
  }

  /// 按剧集边界切分播放列表。
  ///
  /// `#` 同时是常见的剧集分隔符和 URL fragment 起始符，因此只有在后续
  /// 内容明确像下一集（直链，或常见集名 `$` URL 形式）时才切分。这样既
  /// 保留 `https://.../$token#section`，也兼容 `第1集$url#第2集$url`。
  static List<String> _splitEpisodeParts(String input) {
    final parts = <String>[];
    var start = 0;
    for (var i = 0; i < input.length; i++) {
      if (input[i] != '#') continue;
      final nextStart = i + 1;
      final nextEnd = input.indexOf('#', nextStart);
      final candidate = input
          .substring(nextStart, nextEnd < 0 ? input.length : nextEnd)
          .trim();
      if (!_looksLikeEpisodeBoundary(candidate, input.substring(start, i))) {
        continue;
      }
      parts.add(input.substring(start, i));
      start = nextStart;
    }
    parts.add(input.substring(start));
    return parts;
  }

  static bool _looksLikeEpisodeBoundary(String candidate, String previous) {
    if (candidate.isEmpty || _looksLikeUrl(candidate)) return true;
    final split = candidate.indexOf(r'$');
    if (split <= 0 || split == candidate.length - 1) return false;
    final name = candidate.substring(0, split).trim();
    final url = candidate.substring(split + 1).trim();
    if (url.isEmpty || _looksLikeUrl(url)) return true;
    if (_episodeNamePattern.hasMatch(name)) return true;
    // 旧格式也允许使用不透明的非 URL ID（如 `片段A$opaque-2`）。
    // 只有前一段本身不是 URL 时才沿用这种宽松切分，避免把 URL fragment
    // 中形如 `#fragment$token` 的内容误当成下一集。
    final previousSplit = previous.indexOf(r'$');
    final previousUrl = previousSplit >= 0
        ? previous.substring(previousSplit + 1).trim()
        : previous.trim();
    return !_looksLikeUrl(previousUrl);
  }

  static VodItem? fromXmlElement(
    XmlElement? element, {
    String sourceKey = '',
    String sourceName = '',
  }) {
    if (element == null) return null;
    String text(String name) {
      for (final child in element.children.whereType<XmlElement>()) {
        if (child.name.local == name) {
          return child.innerText.trim();
        }
      }
      return '';
    }

    final lines = <PlayLine>[];
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.name.local != 'dl') continue;
      for (final dd in child.children.whereType<XmlElement>()) {
        if (dd.name.local != 'dd') continue;
        final flag = dd.getAttribute('flag') ?? '';
        final urls = dd.innerText.trim();
        final episodes = parseEpisodes(urls);
        if (episodes.isNotEmpty) {
          lines.add(
            PlayLine(
              name: flag.isNotEmpty ? flag : '线路${lines.length + 1}',
              episodes: episodes,
            ),
          );
        }
      }
    }

    final json = <String, dynamic>{
      'id': text('id'),
      'name': text('name'),
      'pic': text('pic'),
      'remarks': text('note'),
      'type_id': text('tid'),
      'type': text('type'),
      'year': text('year'),
      'area': text('area'),
      'lang': text('lang'),
      'actor': text('actor'),
      'director': text('director'),
      'content': text('des'),
    };
    final item = VodItem.fromJson(
      json,
      sourceKey: sourceKey,
      sourceName: sourceName,
    );
    if (item.id.isEmpty && item.name.isEmpty) return null;
    return item.copyWith(lines: lines);
  }
}

class HomeData {
  const HomeData({
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

  bool get isEmpty => videos.isEmpty;
  bool get hasMore => page < pageCount;
}

class CategoryFilter {
  const CategoryFilter({
    required this.key,
    required this.name,
    required this.values,
  });
  final String key;
  final String name;
  final Map<String, String> values;

  static Map<String, List<CategoryFilter>> parse(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, List<CategoryFilter>>{};
    raw.forEach((category, groups) {
      if (groups is! List) return;
      final filters = <CategoryFilter>[];
      for (final group in groups.whereType<Map>()) {
        final key = asString(group['key']);
        final options = group['value'];
        if (key.isEmpty || options is! List) continue;
        final values = <String, String>{};
        for (final option in options.whereType<Map>()) {
          values[asString(option['v'])] = asString(option['n']);
        }
        if (values.isNotEmpty) {
          filters.add(
            CategoryFilter(
              key: key,
              name: asString(group['name'], key),
              values: values,
            ),
          );
        }
      }
      result[category.toString()] = filters;
    });
    return result;
  }
}

class CatalogData {
  const CatalogData({
    required this.videos,
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
  });

  final List<VodItem> videos;
  final int page;
  final int pageCount;
  final int total;

  bool get hasMore => page < pageCount;
}

class LiveChannel {
  LiveChannel({
    required this.name,
    required this.urls,
    required this.sourceNames,
    this.logo = '',
    this.group = '未分组',
    this.number = 0,
    this.password = '',
    this.epgId = '',
    this.catchupSource = '',
    this.catchupDays = 0,
  });

  final String name;
  final List<String> urls;
  final List<String> sourceNames;
  final String logo;
  final String group;
  final int number;
  final String password;
  final String epgId;
  final String catchupSource;
  final int catchupDays;

  String? replayUrl(DateTime start, DateTime end, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    if (catchupSource.isEmpty ||
        catchupDays <= 0 ||
        !end.isAfter(start) ||
        start.isAfter(clock) ||
        start.isBefore(clock.subtract(Duration(days: catchupDays)))) {
      return null;
    }
    final duration = end.difference(start).inSeconds;
    return catchupSource
        .replaceAll('{utc}', '${start.millisecondsSinceEpoch ~/ 1000}')
        .replaceAll('{utcend}', '${end.millisecondsSinceEpoch ~/ 1000}')
        .replaceAll('{duration}', '$duration')
        .replaceAll('{lutc}', '${clock.millisecondsSinceEpoch ~/ 1000}')
        .replaceAll(r'${start}', '${start.millisecondsSinceEpoch ~/ 1000}')
        .replaceAll(r'${end}', '${end.millisecondsSinceEpoch ~/ 1000}')
        .replaceAll('{Y}', '${start.year}')
        .replaceAll('{m}', '${start.month}'.padLeft(2, '0'))
        .replaceAll('{d}', '${start.day}'.padLeft(2, '0'))
        .replaceAll('{H}', '${start.hour}'.padLeft(2, '0'))
        .replaceAll('{M}', '${start.minute}'.padLeft(2, '0'))
        .replaceAll('{S}', '${start.second}'.padLeft(2, '0'));
  }

  String get url => urls.isEmpty ? '' : urls.first;
  bool get hasLogo => logo.trim().isNotEmpty;
}

class LiveGroup {
  const LiveGroup({required this.name, required this.channels});

  final String name;
  final List<LiveChannel> channels;
}

class HistoryEntry {
  const HistoryEntry({
    required this.vod,
    required this.sourceKey,
    required this.sourceName,
    required this.lineName,
    required this.lineIndex,
    required this.episodeName,
    required this.episodeUrl,
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final VodItem vod;
  final String sourceKey;
  final String sourceName;
  final String lineName;
  final int lineIndex;
  final String episodeName;
  final String episodeUrl;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  double get progress {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  HistoryEntry copyWith({
    int? positionMs,
    int? durationMs,
    DateTime? updatedAt,
    String? episodeName,
    String? episodeUrl,
    String? lineName,
    int? lineIndex,
    int? episodeIndex,
  }) {
    return HistoryEntry(
      vod: vod,
      sourceKey: sourceKey,
      sourceName: sourceName,
      lineName: lineName ?? this.lineName,
      lineIndex: lineIndex ?? this.lineIndex,
      episodeName: episodeName ?? this.episodeName,
      episodeUrl: episodeUrl ?? this.episodeUrl,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'vod': vod.toJson(),
    'sourceKey': sourceKey,
    'sourceName': sourceName,
    'lineName': lineName,
    'lineIndex': lineIndex,
    'episodeName': episodeName,
    'episodeUrl': episodeUrl,
    'episodeIndex': episodeIndex,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      vod: VodItem.fromStoredJson(
        Map<String, dynamic>.from(json['vod'] as Map? ?? const {}),
      ),
      sourceKey: asString(json['sourceKey']),
      sourceName: asString(json['sourceName']),
      lineName: asString(json['lineName']),
      lineIndex: asInt(json['lineIndex']),
      episodeName: asString(json['episodeName']),
      episodeUrl: asString(json['episodeUrl']),
      episodeIndex: asInt(json['episodeIndex']),
      positionMs: asInt(json['positionMs']),
      durationMs: asInt(json['durationMs']),
      updatedAt:
          DateTime.tryParse(asString(json['updatedAt'])) ?? DateTime.now(),
    );
  }
}

bool isDirectVideoUrl(String url) {
  final lower = url.toLowerCase();
  if (!lower.startsWith('http')) return false;
  if (lower.contains('.m3u8') ||
      lower.contains('.mp4') ||
      lower.contains('.flv') ||
      lower.contains('.mkv') ||
      lower.contains('.m4v') ||
      lower.contains('.mov') ||
      lower.contains('.ts') ||
      lower.contains('.mpd')) {
    return true;
  }
  return lower.contains('video/tos') ||
      lower.contains('/hls/') ||
      lower.contains('m3u8?');
}

/// 判断字符串是否以常见流媒体 scheme 开头。用于区分「集名」与「URL」，
/// 见 `VodItem.parseEpisodes` 对 `$` 分隔符的歧义处理。
bool _looksLikeUrl(String value) {
  final v = value.trim();
  return v.startsWith('http://') ||
      v.startsWith('https://') ||
      v.startsWith('rtmp://') ||
      v.startsWith('rtsp://') ||
      v.startsWith('//');
}

String decodeJsonish(String body) {
  var text = body.trim();
  if (text.startsWith('\ufeff')) text = text.substring(1);
  return text;
}

String stableKey(VodItem vod) => '${vod.sourceKey}__${vod.id}';

String prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}
