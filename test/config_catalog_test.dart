import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/config_catalog.dart';

void main() {
  group('parseIndex', () {
    test('解析对象、裸数组与 alias，跳过空地址并去重', () {
      final entries = ConfigCatalog.parseIndex('''
        {"urls": [
          {"url": "https://a.example/1.json", "name": "高天流云 No.1"},
          {"url": "https://a.example/2.json", "alias": "主流集合"},
          {"url": "https://a.example/1.json", "name": "重复项"},
          {"url": "", "name": "空地址"},
          {"name": "缺少地址"}
        ]}
      ''');
      expect(entries, hasLength(2));
      expect(entries.first.name, '高天流云 No.1');
      expect(entries.last.name, '主流集合');

      final bare = ConfigCatalog.parseIndex(
        '[{"url": "https://b.example/x/y.json"}]',
      );
      expect(bare.single.name, 'y');
    });

    test('非法内容返回空列表', () {
      expect(ConfigCatalog.parseIndex(''), isEmpty);
      expect(ConfigCatalog.parseIndex('<html></html>'), isEmpty);
      expect(ConfigCatalog.parseIndex('{"urls": "no"}'), isEmpty);
    });
  });

  group('loadFromUrl', () {
    test('拉取列表并保留条目顺序', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"urls": ['
          '{"url": "https://c.example/a.json", "name": "甲"},'
          '{"url": "https://c.example/b.json", "name": "乙"}'
          ']}',
        );
        await request.response.close();
      });
      final result = await ConfigCatalog().loadFromUrl(
        'http://127.0.0.1:${server.port}/urls.json',
      );
      expect(result.entries.map((e) => e.name), ['甲', '乙']);
      expect(result.indexUrl, contains('/urls.json'));
    });

    test('非 urls.json 内容与非法地址都给出可读错误', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('<html>404</html>');
        await request.response.close();
      });
      await expectLater(
        ConfigCatalog().loadFromUrl('http://127.0.0.1:${server.port}/x'),
        throwsA(
          isA<ConfigCatalogException>().having(
            (error) => error.message,
            'message',
            contains('urls.json'),
          ),
        ),
      );
      await expectLater(
        ConfigCatalog().loadFromUrl('配置地址'),
        throwsA(
          isA<ConfigCatalogException>().having(
            (error) => error.message,
            'message',
            contains('http'),
          ),
        ),
      );
    });
  });
}
