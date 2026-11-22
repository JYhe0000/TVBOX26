import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/data/danmaku_match.dart';
import 'package:tvbox_flutter/data/danmaku_service.dart';
import 'package:tvbox_flutter/data/danmaku_store.dart';
import 'package:tvbox_flutter/data/storage.dart';

/// 弹幕自动匹配回归：归一化 / 集数解析 / 模板候选 / 记忆命中。
/// 弹幕站用本地 HttpServer 伪造，不起外网。
void main() {
  const danmakuXml = '<i><d p="1,1,25,1670000,1,25,1 2 ,0">你好</d></i>';

  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
  });

  group('标题归一化', () {
    test('去空白/全半角并剔剧场版/季数/年份后缀', () {
      expect(normalizeTitle('神探夏洛克 · 第1季 剧场版 2016'), '神探夏洛克');
    });
    test('中点分隔多语种保留主标题', () {
      expect(normalizeTitle('流浪地球2 · The Wandering Earth'), '流浪地球2');
      // 空格分隔的多语种同样只保留第一段（主标题）。
      expect(normalizeTitle('The Matrix · 骇客帝国'), 'The Matrix');
      expect(normalizeTitle('Test Show'), 'Test Show');
    });
    test('全角字符与括号杂质清理', () {
      expect(normalizeTitle('三体 ４Ｋ 【中字】'), '三体');
    });
    test('归一化结果为空时退回原标题（片名恰为年份）', () {
      expect(normalizeTitle('2012'), '2012');
    });
    test('空标题安全返回空串', () {
      expect(normalizeTitle('   '), '');
    });
  });

  group('集数解析', () {
    test('S01E02 形态', () {
      expect(parseEpisode('S01E02'), 2);
      expect(parseEpisode('s1e5'), 5);
    });
    test('第N集 / 第N话 / 中文数字 / 全角数字', () {
      expect(parseEpisode('第1集'), 1);
      expect(parseEpisode('第１２集'), 12);
      expect(parseEpisode('第十二话'), 12);
    });
    test('尾部 - 02 分隔形态', () {
      expect(parseEpisode('剧名 - 02'), 2);
    });
    test('EP02 / 纯数字序号', () {
      expect(parseEpisode('EP02'), 2);
      expect(parseEpisode('05'), 5);
    });
    test('无集数信息返回 0', () {
      expect(parseEpisode('全集打包'), 0);
    });
  });

  group('季号与集号文案', () {
    test('parseSeason 识别第N季/S01', () {
      expect(parseSeason('第3季'), 3);
      expect(parseSeason('S02'), 2);
      expect(parseSeason('无季号'), 0);
    });
    test('episodeLabel 输出标准第N集', () {
      expect(episodeLabel(7), '第7集');
    });
  });

  group('模板候选与记忆', () {
    late HttpServer server;
    final requests = <String>[];
    late DanmakuStore store;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      requests.clear();
      server.listen((request) async {
        requests.add(request.uri.path);
        // 约定：除 Nope / 小写 ep 路径外，.xml 一律回合法弹幕 XML。
        final serve =
            request.uri.path.endsWith('.xml') &&
            !request.uri.path.contains('Nope') &&
            !request.uri.path.contains('/ep');
        if (serve) {
          request.response.write(danmakuXml);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      store = DanmakuStore(storage);
    });

    tearDown(() => server.close(force: true));

    Dio newDio() =>
        Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));

    DanmakuMatcher matcher(Dio client, List<String> templates) =>
        DanmakuMatcher(
          service: DanmakuService(dio: client),
          store: store,
          baseUrl: '',
          templates: templates,
        );

    test('首条命中即返回并写入记忆', () async {
      final m = matcher(newDio(), [
        '{title}/{title} EP{episode}.xml',
        '{title}/{title} {episode}.xml',
      ]);
      final result = await m.match(
        title: 'TestShow',
        episode: 2,
        siteKey: 'c1',
        vodId: 'v1',
      );
      expect(result.matched, isTrue);
      expect(result.fromCache, isFalse);
      expect(result.url, '/TestShow/TestShow%20EP2.xml');
      // 服务端 uri.path 保留百分号编码形态，与 result.url 一致。
      expect(requests, ['/TestShow/TestShow%20EP2.xml']);
      expect(await store.lookup('c1', 'v1', 2), '/TestShow/TestShow%20EP2.xml');
    });

    test('集号未知时跳过带 {episode} 的模板', () async {
      final m = matcher(newDio(), ['{title}/ep{episode}.xml', '{title}.xml']);
      final result = await m.match(title: 'Movie', siteKey: 'c1', vodId: 'v1');
      expect(result.matched, isTrue);
      expect(requests, ['/Movie.xml']);
    });

    test('全部失败返回未命中与原因列表且不写记忆', () async {
      final m = matcher(newDio(), ['{title}/ep{episode}.xml', '{title}.xml']);
      final result = await m.match(
        title: 'Nope',
        episode: 1,
        siteKey: 'c1',
        vodId: 'v1',
      );
      expect(result.matched, isFalse);
      expect(result.url, isNull);
      expect(result.reasons.length, 2);
      expect(result.reasons[0], contains('/Nope/ep1.xml'));
      expect(await store.lookup('c1', 'v1', 1), isNull);
    });

    test('记忆命中免网络直接返回', () async {
      await store.remember('c1', 'v2', 3, 'https://dm.test/cached.xml');
      final m = matcher(newDio(), ['{title}/{title} EP{episode}.xml']);
      final result = await m.match(
        title: 'Whatever',
        episode: 3,
        siteKey: 'c1',
        vodId: 'v2',
      );
      expect(result.matched, isTrue);
      expect(result.fromCache, isTrue);
      expect(result.url, 'https://dm.test/cached.xml');
      expect(requests, isEmpty);
    });

    test('清除支持全清与按影片/集号定向清除', () async {
      await store.remember('c1', 'v3', 1, 'https://dm.test/a.xml');
      await store.clear();
      expect(await store.lookup('c1', 'v3', 1), isNull);

      await store.remember('c1', 'v4', 1, 'https://dm.test/b.xml');
      await store.remember('c1', 'v4', 2, 'https://dm.test/c.xml');
      await store.clearFor('c1', 'v4', episode: 1);
      expect(await store.lookup('c1', 'v4', 1), isNull);
      expect(await store.lookup('c1', 'v4', 2), 'https://dm.test/c.xml');
    });
  });
}
