import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/recommendation_service.dart';

/// 推荐多源聚合回归：豆瓣第一源 + 本站相关 + 历史回退。
/// 远程源用 Dio 拦截器伪造，不起外网。
void main() {
  /// 伪造豆瓣远程源：按 [subjects] 应答或直接拒绝请求。
  Dio doubanDio({List<Map<String, dynamic>> subjects = const [], bool fail = false, dynamic malformed}) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              data: malformed ?? {'subjects': subjects},
            ),
          );
        },
      ),
    );
    return dio;
  }

  const doubanSubjects = [
    {'id': '1', 'title': '豆瓣片', 'cover': 'https://x/1.jpg', 'rate': '8.0'},
  ];

  group('多源聚合', () {
    test('豆瓣第一源 + 本站相关 + 历史回退，按站点key+id去重', () async {
      final related = [
        const VodItem(id: 'a', name: '本站相关', sourceKey: 'c1'),
        // 与豆瓣同 key 的重复项应被去掉。
        const VodItem(id: '1', name: '重复项', sourceKey: '@douban'),
      ];
      final history = [
        const VodItem(id: 'b', name: '历史回退', sourceKey: 'c1'),
        // 历史源内部重复。
        const VodItem(id: 'b', name: '历史回退', sourceKey: 'c1'),
      ];
      final items = await RecommendationService(dio: doubanDio(subjects: doubanSubjects)).load(
        localRelated: related,
        localFallback: history,
      );
      expect(items.map((e) => e.name), ['豆瓣片', '本站相关', '历史回退']);
      expect(items.map(stableKey).toSet().length, 3);
      expect(items.first.sourceKey, '@douban');
      expect(items.first.sourceName, '豆瓣推荐');
    });

    test('全源皆空返回空列表不抛错', () async {
      final service = RecommendationService(dio: doubanDio(subjects: const []));
      final items = await service.load();
      expect(items, isEmpty);
      expect(service.sourceErrors, isEmpty);
    });
  });

  group('单源失败隔离', () {
    test('豆瓣源超时不拖垮本地源', () async {
      final items = await RecommendationService(dio: doubanDio(fail: true)).load(
        localRelated: [const VodItem(id: 'r', name: '本站片', sourceKey: 'c2')],
        localFallback: [const VodItem(id: 'h', name: '历史片', sourceKey: 'c1')],
      );
      expect(items.map((e) => e.name), ['本站片', '历史片']);
    });

    test('豆瓣响应形状非法降级为本地候选并记录原因', () async {
      final service = RecommendationService(dio: doubanDio(malformed: 'oops'));
      final items = await service.load(
        localFallback: [const VodItem(id: 'h1', name: '历史片', sourceKey: 'c1')],
      );
      expect(items.single.name, '历史片');
      expect(service.sourceErrors.single, contains('豆瓣推荐源失败'));
    });

    test('远程失败且无本地源时返回空', () async {
      final items = await RecommendationService(dio: doubanDio(fail: true)).load();
      expect(items, isEmpty);
    });
  });
}
