import 'dart:convert';

import 'package:dio/dio.dart';

import 'network_policy.dart';

import 'package:xml/xml.dart';

class EpgProgramme {
  const EpgProgramme({
    required this.title,
    required this.start,
    required this.end,
  });
  final String title;
  final DateTime start;
  final DateTime end;
}

class EpgSchedule {
  const EpgSchedule(this.programmes);
  final List<EpgProgramme> programmes;

  EpgProgramme? current(DateTime now) => programmes
      .where((p) => !now.isBefore(p.start) && now.isBefore(p.end))
      .firstOrNull;

  EpgProgramme? next(DateTime now) =>
      programmes.where((p) => p.start.isAfter(now)).firstOrNull;
}

class EpgService {
  EpgService({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 10),
              ),
            ),
          );

  final Dio _dio;
  final Map<String, (DateTime, String)> _cache = {};

  Future<EpgSchedule> load(
    String template,
    String channel, {
    DateTime? now,
  }) async {
    final date = now ?? DateTime.now();
    final day =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    var url = template
        .replaceAll('{name}', Uri.encodeComponent(channel))
        .replaceAll('{channel}', Uri.encodeComponent(channel))
        .replaceAll('{date}', day);
    if (!template.contains('{') &&
        !Uri.parse(url).path.toLowerCase().endsWith('.xml')) {
      final uri = Uri.parse(url);
      url = uri
          .replace(
            queryParameters: {
              ...uri.queryParameters,
              'ch': channel,
              'date': day,
            },
          )
          .toString();
    }
    final cached = _cache[url];
    String body;
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 5)) {
      body = cached.$2;
    } else {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      body = response.data ?? '';
      if (_cache.length >= 32) _cache.remove(_cache.keys.first);
      _cache[url] = (DateTime.now(), body);
    }
    return parse(body, channel, date);
  }

  static EpgSchedule parse(String body, String channel, DateTime date) {
    final programmes = <EpgProgramme>[];
    if (body.trimLeft().startsWith('<')) {
      final doc = XmlDocument.parse(body);
      final ids = doc
          .findAllElements('channel')
          .where(
            (node) => node
                .findElements('display-name')
                .any((name) => name.innerText.trim() == channel),
          )
          .map((node) => node.getAttribute('id'))
          .toSet();
      ids.add(channel);
      for (final node in doc.findAllElements('programme')) {
        if (!ids.contains(node.getAttribute('channel'))) continue;
        final start = _xmlTime(node.getAttribute('start') ?? '');
        final end = _xmlTime(node.getAttribute('stop') ?? '');
        final title = node.getElement('title')?.innerText.trim() ?? '';
        if (start != null &&
            end != null &&
            end.isAfter(start) &&
            title.isNotEmpty) {
          programmes.add(EpgProgramme(title: title, start: start, end: end));
        }
      }
    } else {
      final decoded = jsonDecode(body);
      final root = decoded is Map ? decoded : const {};
      final raw = root['epg_data'] ?? root['data'] ?? decoded;
      final list = raw is Map ? raw['epg_data'] ?? raw['list'] : raw;
      final day = DateTime.tryParse('${root['date'] ?? ''}') ?? date;
      if (list is! List) throw const FormatException('节目单结构无法识别');
      for (final entry in list.whereType<Map>()) {
        final start = _clockTime('${entry['start'] ?? ''}', day);
        var end = _clockTime('${entry['end'] ?? ''}', day);
        final title = '${entry['title'] ?? entry['name'] ?? ''}'.trim();
        if (start == null || end == null || title.isEmpty) continue;
        if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
        programmes.add(EpgProgramme(title: title, start: start, end: end));
      }
    }
    programmes.sort((a, b) => a.start.compareTo(b.start));
    return EpgSchedule(programmes);
  }

  static DateTime? _clockTime(String value, DateTime day) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(value);
    if (match == null) return DateTime.tryParse(value);
    final hour = int.parse(match[1]!);
    final minute = int.parse(match[2]!);
    if (hour > 24 || minute > 59 || (hour == 24 && minute != 0)) return null;
    return DateTime(day.year, day.month, day.day, hour, minute);
  }

  static DateTime? _xmlTime(String value) {
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-]\d{4})?',
    ).firstMatch(value);
    if (match == null) return null;
    final iso =
        '${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}${match[7] ?? 'Z'}';
    return DateTime.tryParse(iso)?.toLocal();
  }
}
