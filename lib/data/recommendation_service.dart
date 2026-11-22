import 'package:dio/dio.dart';

import 'models.dart';
import 'network_policy.dart';

/// 推荐内容聚合服务。
///
/// 多源聚合、按序叠加：豆瓣远程源为第一源，「本站相关」与「历史回退」
/// 两个本地源由调用方把候选列表通过 [load] 传入。单源失败隔离
/// （远程源异常只记入 [sourceErrors]，不拖垮整体），结果按
/// `stableKey`（站点 key + 影片 id）去重。
class RecommendationService {
  RecommendationService({Dio? dio})
    : _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 15),
              ),
            ),
          );
  final Dio _dio;

  /// 最近一次聚合中各外部源的失败原因（调试用，全部成功时为空）。
  final List<String> sourceErrors = [];

  /// 聚合推荐结果。
  ///
  /// - [localRelated]：本站相关候选（调用方传入，如详情页相关影片）；
  /// - [localFallback]：历史回退候选（调用方传入，如播放历史）；
  /// 远程源失败或形状非法时自动降级为仅本地源，不抛错。
  Future<List<VodItem>> load({
    List<VodItem> localRelated = const [],
    List<VodItem> localFallback = const [],
  }) async {
    sourceErrors.clear();
    final result = <VodItem>[];
    final seen = <String>{};
    void addAll(String source, Iterable<VodItem> items) {
      for (final item in items) {
        // 按站点 key + 影片 id 去重（stableKey），同源重复推荐只留一条。
        final key = stableKey(item);
        if (key.isEmpty || !seen.add(key)) continue;
        result.add(item);
      }
    }

    // 第一源：豆瓣远程（失败隔离，不拖垮整体）。
    try {
      addAll('@douban', await _loadDouban());
    } catch (error) {
      sourceErrors.add('豆瓣推荐源失败：${error.toString().split('\n').first}');
    }
    // 第二源：本站相关（本地候选，无网络依赖）。
    addAll('@related', localRelated);
    // 第三源：历史回退（本地候选，无网络依赖）。
    addAll('@history', localFallback);
    return result;
  }

  Future<List<VodItem>> _loadDouban() async {
    final response = await _dio.get<dynamic>(
      'https://movie.douban.com/j/search_subjects',
      queryParameters: {
        'type': 'movie',
        'tag': '热门',
        'sort': 'recommend',
        'page_limit': 40,
        'page_start': 0,
      },
      options: Options(
        headers: {
          'Referer': 'https://movie.douban.com/',
          'User-Agent': 'Mozilla/5.0',
        },
      ),
    );
    final root = response.data;
    if (root is! Map || root['subjects'] is! List) {
      throw const FormatException('推荐接口暂不可用，请切回站点内容');
    }
    return (root['subjects'] as List)
        .whereType<Map>()
        .where((entry) => asString(entry['title']).isNotEmpty)
        .map(
          (entry) => VodItem(
            id: asString(entry['id']),
            name: asString(entry['title']),
            pic: asString(entry['cover']),
            score: asString(entry['rate']),
            sourceKey: '@douban',
            sourceName: '豆瓣推荐',
          ),
        )
        .toList();
  }
}
