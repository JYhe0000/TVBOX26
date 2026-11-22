import 'dart:convert';

import 'package:dio/dio.dart';

/// 搜索热词与输入联想服务，接口与主软件参考 Box 保持一致：
///
/// - 热门搜索：腾讯视频热榜 `node.video.qq.com/x/api/hot_search`，取前 10；
/// - 输入联想：`tv.aiseet.atianqi.com/.../get_search_smart_box`，
///   支持拼音首字母联想（遥控器字母键盘的关键）。
///
/// 两个接口均为公网只读数据，失败时静默返回空列表，不影响主搜索流程。
class SearchSuggest {
  SearchSuggest({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 6),
              headers: const {
                'User-Agent': 'okhttp/3.15',
                'Accept': 'application/json,text/plain,*/*',
              },
            ),
          );

  final Dio _dio;

  /// 热词接口不可用时的本地兜底，保证电视右栏与手机远程页不会空着。
  static const List<String> fallbackHotWords = [
    '凡人修仙传',
    '狂飙',
    '庆余年',
    '三体',
    '漫长的季节',
    '流浪地球',
    '甄嬛传',
    '琅琊榜',
    '长安十二时辰',
    '我的阿勒泰',
  ];

  /// 热门搜索词（腾讯视频热榜前 10，清洗《》等符号）。
  Future<List<String>> hotWords() async {
    try {
      final response = await _dio.get(
        'https://node.video.qq.com/x/api/hot_search',
        queryParameters: {
          'channdlId': '0',
          '_': DateTime.now().millisecondsSinceEpoch,
        },
      );
      final map = _asMap(_decode(response.data));
      final mapResult = _asMap(map['data']?['mapResult']);
      final first = _asMap(mapResult.values.isEmpty ? null : mapResult.values.first);
      final list = first['listInfo'];
      if (list is! List) return fallbackHotWords;
      final words = <String>[];
      for (final item in list) {
        if (words.length >= 10) break;
        if (item is! Map) continue;
        var title = '${item['title'] ?? ''}'.trim();
        title = title
            .replaceAll(RegExp(r'<|>|《|》|-'), '')
            .split(' ')
            .first
            .trim();
        if (title.isNotEmpty) words.add(title);
      }
      return words.isEmpty ? fallbackHotWords : words;
    } catch (_) {
      return fallbackHotWords;
    }
  }

  /// 输入联想词：key 支持中文与拼音（含首字母），Box 搜索页同款。
  Future<List<String>> suggest(String key) async {
    final query = key.trim();
    if (query.isEmpty) return const [];
    try {
      final response = await _dio.get(
        'https://tv.aiseet.atianqi.com/i-tvbin/qtv_video/search/get_search_smart_box',
        queryParameters: {
          'format': 'json',
          'page_num': 0,
          'page_size': 50,
          'key': query,
        },
      );
      final map = _decode(response.data);
      final group = map['data']?['search_data']?['vecGroupData'];
      if (group is! List || group.isEmpty) return const [];
      final entries = group.first is Map ? group.first['group_data'] : null;
      if (entries is! List) return const [];
      final words = <String>[];
      for (final entry in entries) {
        if (entry is! Map) continue;
        final report = _asMap(entry['dtReportInfo']);
        final word = '${_asMap(report['reportData'])['keyword_txt'] ?? ''}'.trim();
        if (word.isNotEmpty && !words.contains(word)) words.add(word);
      }
      return words;
    } catch (_) {
      return const [];
    }
  }

  static dynamic _decode(dynamic data) {
    if (data is Map || data is List) return data;
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Map _asMap(dynamic value) =>
      value is Map ? value : const <String, dynamic>{};
}
