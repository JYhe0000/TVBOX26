import 'danmaku_service.dart';
import 'danmaku_store.dart';

/// 内置候选地址模板（相对路径，拼接在 [DanmakuMatcher.baseUrl] 之后）。
/// 占位符：{title} 归一化主标题、{season} 季号（S01 形态）、{episode} 集号。
/// 集号未知（episode <= 0）时，含 {episode} 的模板自动跳过。
const List<String> kDefaultDanmakuTemplates = [
  '{title}/{title} EP{episode}.xml',
  '{title}/{title} {episode}.xml',
  '{title}/{title}第{episode}集.xml',
  '{title}/ep{episode}.xml',
  '{title}.xml',
];

/// 全角 → 半角（含全角空格与全角数字/字母）。
String _halfWidth(String input) {
  final buffer = StringBuffer();
  for (final unit in input.codeUnits) {
    if (unit == 0x3000) {
      buffer.write(' ');
    } else if (unit >= 0xFF01 && unit <= 0xFF5E) {
      buffer.writeCharCode(unit - 0xFEE0);
    } else {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}

/// 中文数字（小写）→ 阿拉伯数字，支持 一~九十九。
int? _chineseNumber(String text) {
  if (text.isEmpty) return null;
  const digits = {
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
  if (text == '十') return 10;
  if (text.length == 2 && text.startsWith('十')) {
    return 10 + (digits[text[1]] ?? 0);
  }
  if (text.length == 2 && text.endsWith('十')) {
    return (digits[text[0]] ?? 0) * 10;
  }
  if (text.length == 3 && text[1] == '十') {
    return (digits[text[0]] ?? 0) * 10 + (digits[text[2]] ?? 0);
  }
  return digits[text];
}

/// 标题归一化：全半角统一 → 去括号/年份/版本后缀 → 多语种分段保留主标题。
///
/// 输入 "神探夏洛克 · 第1季 剧场版 2016" 输出 "神探夏洛克"；
/// 输入 "流浪地球2 · The Wandering Earth" 输出 "流浪地球2"。
String normalizeTitle(String raw) {
  var text = _halfWidth(raw).trim();
  if (text.isEmpty) return text;
  // 去掉【】[]（）() 释放组（多为「中字/国语/年份」等干扰信息）。
  text = text
      .replaceAll(RegExp(r'【[^】]*】'), ' ')
      .replaceAll(RegExp(r'\[[^]]*]'), ' ')
      .replaceAll(RegExp(r'（[^）]*）'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ');
  // 去年份（独立 19xx/20xx）。
  text = text.replaceAll(RegExp(r'\b(19|20)\d{2}\b'), ' ');
  // 只在显式多语种分隔符处分段，英文片名中的普通空格必须保留。
  text = text.split(RegExp(r'\s+[·•‧・]\s+')).first;
  text = text.replaceAll(RegExp(r'[·•‧・．.]'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final junk = RegExp(
    r'^(第[0-9一二两三四五六七八九十]+季|[ST]\d+|S\d+E\d+|HD|4K|2K|8K|1080P|720P|'
    r'REMUX|HDR|杜比|OVA|OAD|TV版|剧场版|先行|国语|国语版|粤语|粤语版|中字|'
    r'中文字幕|简体|繁体|字幕|未删减|无删减|导演剪辑|加长|加长版|完整版|高清|'
    r'超清|完结|全集|全[0-9]+集)$',
    caseSensitive: false,
  );
  final kept = text
      .split(' ')
      .where((segment) => segment.isNotEmpty && !junk.hasMatch(segment))
      .toList();
  if (kept.isEmpty) {
    // 全被剔空（如片名恰为年份）时退回半角化后的原标题，保底可用。
    return _halfWidth(raw).trim();
  }
  var title = kept.join(' ');
  // 收尾：去掉残留的冒号/连字符/点号等标点。
  title = title.replaceAll(RegExp(r'[:：、.\-_·•\-]+$'), '');
  title = title.replaceAll(RegExp(r'^[:：、.\-_·•\-]+'), '');
  return title.isEmpty ? _halfWidth(raw).trim() : title;
}

/// 集数解析：支持 S01E02 / 第1集 / 第十二话 / - 02 / EP02 / 纯数字序号。
/// 输出集号（1 起），未识别返回 0。
int parseEpisode(String raw) {
  final text = _halfWidth(raw);
  // S01E02（先判，避免被后面的裸 E\d+ 误伤）。
  var match = RegExp(
    r'S(\d{1,2})\s*E(\d{1,2})',
    caseSensitive: false,
  ).firstMatch(text);
  if (match != null) return int.tryParse(match.group(2) ?? '') ?? 0;
  // 第N集 / 第N话（阿拉伯数字）。
  match = RegExp(r'第\s*(\d{1,4})\s*[集話话]').firstMatch(text);
  if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
  // 第N集 / 第N话（中文数字）。
  match = RegExp(r'第\s*([一二两三四五六七八九十]+)\s*[集話话]').firstMatch(text);
  if (match != null) return _chineseNumber(match.group(1) ?? '') ?? 0;
  // EP02 / Episode 02 / E02。
  match = RegExp(
    r'(?:EP|Episode|E)\s*(\d{1,4})',
    caseSensitive: false,
  ).firstMatch(text);
  if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
  // 尾部「- 02」分隔的集号。
  match = RegExp(r'[-–—]\s*(\d{1,3})\s*$').firstMatch(text);
  if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
  // 纯数字序号（整段就是集号）。
  if (RegExp(r'^\d{1,4}$').hasMatch(text.trim())) {
    return int.tryParse(text.trim()) ?? 0;
  }
  return 0;
}

/// 季号解析：第N季 / S01 / Season N，未识别返回 0。
int parseSeason(String raw) {
  final text = _halfWidth(raw);
  var match = RegExp(r'第\s*(\d{1,2})\s*季').firstMatch(text);
  if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
  match = RegExp(r'第\s*([一二两三四五六七八九十]+)\s*季').firstMatch(text);
  if (match != null) return _chineseNumber(match.group(1) ?? '') ?? 0;
  match = RegExp(
    r'S[eason]*\s*(\d{1,2})',
    caseSensitive: false,
  ).firstMatch(text);
  if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
  return 0;
}

/// 标准集号文案（第 N 集）。
String episodeLabel(int episode) => '第$episode集';

/// 模板渲染：占位符 {title} / {season} / {episode} 替换为实际值。
///
/// [episode] <= 0 时返回空串（集号未知无法渲染带集号的模板）。
String renderTemplate(
  String template, {
  required String title,
  int season = 0,
  int episode = 0,
}) {
  if (template.contains('{episode}') && episode <= 0) return '';
  return template
      .replaceAll('{title}', title)
      .replaceAll(
        '{season}',
        season > 0 ? 'S${season.toString().padLeft(2, '0')}' : '',
      )
      .replaceAll('{episode}', episode > 0 ? '$episode' : '');
}

/// 一次弹幕匹配的结果。
class DanmakuMatchResult {
  const DanmakuMatchResult.hit(
    this.url, {
    required this.title,
    required this.episode,
    this.fromCache = false,
  }) : reasons = const [];

  const DanmakuMatchResult.miss({
    required this.title,
    required this.episode,
    required this.reasons,
  }) : url = null,
       fromCache = false;

  /// 命中地址（未命中为 null）。
  final String? url;

  /// 归一化后的主标题。
  final String title;

  /// 解析出的集号（0 = 未识别）。
  final int episode;

  /// 是否来自本地记忆（免网络）。
  final bool fromCache;

  /// 未命中时逐条模板的失败原因。
  final List<String> reasons;

  bool get matched => url != null;
}

/// 弹幕自动匹配器：标题归一化 + 集数解析 + 模板试探 + 本地记忆。
class DanmakuMatcher {
  DanmakuMatcher({
    DanmakuService? service,
    this.store,
    this.baseUrl = '',
    List<String>? templates,
  }) : service = service ?? DanmakuService(),
       templates = templates ?? kDefaultDanmakuTemplates;

  final DanmakuService service;

  /// 记忆库；为 null 时跳过记忆读写（纯试探）。
  final DanmakuStore? store;

  /// 弹幕站基础地址（模板拼在其后，末尾斜杠可选）。
  final String baseUrl;

  /// 候选地址模板，可调用方自定义。
  final List<String> templates;

  /// 自动匹配当前影片当前集的弹幕地址。
  ///
  /// [episode] 显式传入时优先；否则从 [title] 里解析。命中记忆直接返回，
  /// 否则按 [templates] 顺序逐条尝试 [DanmakuService.load]，首个成功即
  /// 返回并写入记忆；全部失败返回未命中 + 原因列表。
  Future<DanmakuMatchResult> match({
    required String title,
    int episode = 0,
    int season = 0,
    required String siteKey,
    required String vodId,
  }) async {
    final normalized = normalizeTitle(title);
    final resolvedEpisode = episode > 0 ? episode : parseEpisode(title);

    // 记忆命中即免匹配。
    if (store != null) {
      final cached = await store!.lookup(siteKey, vodId, resolvedEpisode);
      if (cached != null && cached.isNotEmpty) {
        return DanmakuMatchResult.hit(
          cached,
          title: normalized,
          episode: resolvedEpisode,
          fromCache: true,
        );
      }
    }

    final reasons = <String>[];
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    for (final template in templates) {
      final path = renderTemplate(
        template,
        title: normalized,
        season: season,
        episode: resolvedEpisode,
      );
      if (path.isEmpty) {
        reasons.add('集号未知，跳过模板：$template');
        continue;
      }
      final url = Uri.encodeFull('$base/$path');
      try {
        await service.load(url);
        // 首个加载成功即命中（空弹幕文件也算该地址有效）。
        if (store != null) {
          await store!.remember(siteKey, vodId, resolvedEpisode, url);
        }
        return DanmakuMatchResult.hit(
          url,
          title: normalized,
          episode: resolvedEpisode,
        );
      } catch (error) {
        reasons.add('$url 加载失败：${error.toString().split('\n').first}');
      }
    }
    return DanmakuMatchResult.miss(
      title: normalized,
      episode: resolvedEpisode,
      reasons: reasons,
    );
  }
}
