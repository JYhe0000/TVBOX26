import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/core/remote_search_server.dart';

/// 远程搜索服务的端到端契约：中文必须按 UTF-8 输出（曾经用 codeUnits 导致乱码），
/// 手机页面的热词 / 联想 / 提交接口都要能正常返回。
void main() {
  test('remote search server serves utf8 pages and json apis', () async {
    final queries = <String>[];
    final server = RemoteSearchServer(
      onQuery: queries.add,
      hotWords: () => ['凡人修仙传', '狂飙'],
      suggest: (query) async => ['$query 联想词'],
    );
    final base = await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    Future<String> get(String path) async {
      final request = await client.getUrl(Uri.parse('$base$path'));
      final response = await request.close();
      expect(response.statusCode, 200, reason: path);
      expect(response.headers.contentType?.charset, 'utf-8', reason: path);
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      return utf8.decode(bytes);
    }

    // 手机首页：中文标题与区块都必须正常解码。
    final page = await get('/');
    expect(page, contains('TVBOX 远程搜索'));
    expect(page, contains('热门搜索'));
    expect(page, contains('发送到电视'));

    final hot = jsonDecode(await get('/api/hot')) as Map<String, dynamic>;
    expect(hot['words'], ['凡人修仙传', '狂飙']);

    final suggest =
        jsonDecode(await get('/api/suggest?q=${Uri.encodeComponent('凡')}'))
            as Map<String, dynamic>;
    expect(suggest['words'], ['凡 联想词']);

    // 提交接口触发搜索，并返回 JSON 结果。
    final sent =
        jsonDecode(await get('/api/search?q=${Uri.encodeComponent('凡人')}'))
            as Map<String, dynamic>;
    expect(sent['ok'], isTrue);
    expect(queries, ['凡人']);

    // 直接带关键词的链接（分享/扫码）也能触发搜索并返回中文确认页。
    final direct = await get('/search?q=${Uri.encodeComponent('凡人')}');
    expect(direct, contains('凡人'));
    expect(queries, ['凡人', '凡人']);
  });
}
