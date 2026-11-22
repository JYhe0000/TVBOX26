import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'network_policy.dart';

class DanmakuComment {
  const DanmakuComment(this.timeMs, this.text);
  final int timeMs;
  final String text;
}

class DanmakuService {
  DanmakuService({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
              ),
            ),
          );
  final Dio _dio;
  Future<List<DanmakuComment>> load(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    return parse(response.data ?? '');
  }

  static List<DanmakuComment> parse(String body) {
    if (body.length > 4 * 1024 * 1024) throw const FormatException('弹幕文件超过4MB');
    final comments = <DanmakuComment>[];
    void add(num? seconds, Object? text) {
      final value = text?.toString().trim() ?? '';
      if (seconds == null || !seconds.isFinite || seconds < 0 || value.isEmpty) {
        return;
      }
      comments.add(
        DanmakuComment(
          (seconds * 1000).round(),
          value.length > 120 ? value.substring(0, 120) : value,
        ),
      );
    }

    if (body.trimLeft().startsWith('<')) {
      for (final node in XmlDocument.parse(
        body,
      ).findAllElements('d').take(20000)) {
        add(
          double.tryParse((node.getAttribute('p') ?? '').split(',').first),
          node.innerText,
        );
      }
    } else {
      final root = jsonDecode(body);
      final entries = root is List
          ? root
          : root is Map
          ? root['comments']
          : null;
      if (entries is! List) {
        throw const FormatException('请使用 XML 或 comments JSON 弹幕');
      }
      for (final entry in entries.take(20000)) {
        if (entry is! Map) continue;
        final parameter = entry['p']?.toString().split(',').first;
        final seconds = entry['time'] is num
            ? entry['time'] as num
            : double.tryParse(parameter ?? '');
        add(seconds, entry['text'] ?? entry['m']);
      }
    }
    comments.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return comments;
  }
}
