import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/config_service.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';

void main() {
  group('VodItem play list parsing', () {
    test('parses multiple lines and episodes', () {
      final lines = VodItem.parsePlayData(
        r'线路一$$$线路二',
        r'第1集$https://a.test/1.m3u8#第2集$https://a.test/2.m3u8$$$'
            r'正片$https://b.test/movie.mp4',
      );
      expect(lines.length, 2);
      expect(lines.first.name, '线路一');
      expect(lines.first.episodes.length, 2);
      expect(lines.first.episodes.last.name, '第2集');
      expect(lines.first.episodes.last.isDirectVideo, isTrue);
      expect(lines.last.episodes.first.name, '正片');
    });

    test('creates fallback names when no name is present', () {
      final episodes = VodItem.parseEpisodes(
        'https://a.test/1.m3u8#https://a.test/2.m3u8',
      );
      expect(episodes.length, 2);
      expect(episodes.first.name, '第1集');
    });

    test('Spider 只接收剧集 ID，带美元符的签名和 ID 均保留', () {
      final line = VodItem.fromJson({
        'vod_play_from': '线路A',
        'vod_play_url': r'正片$abc-1$token#https://a.test/play?sig=a$b',
      }).lines.single;
      expect(line.name, '线路A');
      expect(line.episodes.first.name, '正片');
      expect(line.episodes.first.url, r'abc-1$token');
      expect(line.episodes.last.url, r'https://a.test/play?sig=a$b');
    });

    test('保留 URL 中的美元符和 fragment，再切分下一集', () {
      final episodes = VodItem.parseEpisodes(
        r'第1集$https://a.test/play?token=a$b#section#第2集$https://a.test/2.m3u8',
      );
      expect(episodes.map((episode) => episode.name), ['第1集', '第2集']);
      expect(episodes.first.url, r'https://a.test/play?token=a$b#section');
      expect(episodes.last.url, 'https://a.test/2.m3u8');
    });

    test('不透明播放 ID 仍按旧格式切分', () {
      final episodes = VodItem.parseEpisodes(r'片段A$opaque-1#片段B$opaque-2');
      expect(episodes.map((episode) => episode.name), ['片段A', '片段B']);
      expect(episodes.map((episode) => episode.url), ['opaque-1', 'opaque-2']);
    });

    test('VodItem sourceKey/sourceName 可序列化往返', () {
      const item = VodItem(
        id: 'v1',
        name: '影片',
        sourceKey: 'site-key',
        sourceName: '站点名称',
      );
      final restored = VodItem.fromStoredJson(item.toJson());
      expect(restored.sourceKey, 'site-key');
      expect(restored.sourceName, '站点名称');
    });
  });

  group('LiveParser', () {
    test('parses m3u and groups channels', () {
      const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV-1" tvg-logo="https://logo.test/1.png" group-title="News",CCTV-1 HD
https://live.test/cctv1.m3u8
#EXTINF:-1 group-title="News",CCTV-2
https://live.test/cctv2.m3u8
''';
      final result = LiveParser.parse(
        m3u,
        baseUrl: 'https://live.test/list.m3u',
      );
      expect(result.groups.length, 1);
      expect(result.groups.first.name, '新闻');
      expect(result.groups.first.channels.length, 2);
      expect(result.groups.first.channels.first.name, 'CCTV-1');
      expect(result.channelCount, 2);
    });

    test('parses txt groups and multiple sources', () {
      const txt = '''
央视,#genre#
CCTV-1,https://live.test/1.m3u8#https://live.test/2.m3u8
CCTV-2,https://live.test/3.m3u8
''';
      final result = LiveParser.parse(txt);
      expect(result.channelCount, 2);
      expect(result.groups.first.channels.first.urls.length, 2);
    });

    test('M3U 支持属性逗号、单引号和显示名逗号，并单遍保留分组顺序', () {
      const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-name="频道,A" group-title='News',显示名,带逗号
https://live.test/a.m3u8
#EXTINF:-1 group-title=Sports,体育频道
https://live.test/b.m3u8
''';
      final result = LiveParser.parse(m3u);
      expect(result.groups.map((group) => group.name), ['新闻', '体育']);
      expect(result.groups.first.channels.single.name, '频道,A');
      expect(
        result.groups.first.channels.single.urls.single,
        'https://live.test/a.m3u8',
      );
    });

    test('TXT 保留 URL fragment，只在下一个 URL 边界切分', () {
      const txt = '频道,https://live.test/a.m3u8#frag#https://live.test/b.m3u8';
      final channel = LiveParser.parse(txt).groups.single.channels.single;
      expect(channel.urls, [
        'https://live.test/a.m3u8#frag',
        'https://live.test/b.m3u8',
      ]);
    });

    test('JSON 直播支持顶层 data 数组、数组 URL、同名合并和分组翻译', () {
      const body = '''
{
  "data": [
    {"name":"频道一","group":"news","url":["/a.m3u8","/b.m3u8"]},
    {"name":"频道一","group":"news","url":"/b.m3u8"},
    {"name":"频道二","group":"sports","url":"/c.m3u8"}
  ]
}
''';
      final result = LiveParser.parse(body, baseUrl: 'https://live.test/list');
      expect(result.groups.map((group) => group.name), ['新闻', '体育']);
      expect(result.groups.first.channels.single.urls, [
        'https://live.test/a.m3u8',
        'https://live.test/b.m3u8',
      ]);
      expect(result.channelCount, 2);
    });
  });

  group('SiteApi JSON parsing', () {
    test('supports top-level data array for VOD responses', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '{"data":[{"vod_id":"v1","vod_name":"影片"}]}',
              ),
            ),
          ),
        );
      const site = SiteConfig(
        key: 'site-key',
        name: '站点名称',
        api: 'https://site.test/api',
      );
      final result = await SiteApi(dio: dio).latest(site, 1);
      expect(result.videos.single.id, 'v1');
      expect(result.videos.single.sourceKey, 'site-key');
      expect(result.videos.single.sourceName, '站点名称');
    });
  });

  group('ConfigService', () {
    test('parses sites, lives and relative urls', () {
      final config = ConfigService().parse('''
{
  "name": "Test",
  "wallpaper": "./bg.jpg",
  "video": {"sites": [
    {"key":"a","name":"A","type":1,"api":"./api.php/provide/vod/","searchable":1}
  ]},
  "lives": [{"name":"Live","type":0,"url":"https://live.test/cn.m3u"}],
  "parses": [{"name":"P","type":1,"url":"https://parse.test/?url="}]
}
''', baseUrl: 'https://config.test/tvbox/config.json');
      expect(config.sites.length, 1);
      expect(
        config.sites.first.api,
        'https://config.test/tvbox/api.php/provide/vod/',
      );
      expect(config.lives.length, 1);
      expect(config.parses.length, 1);
      expect(config.wallpaper, 'https://config.test/tvbox/bg.jpg');
    });

    test('built-in demo config is valid', () {
      final raw = File('assets/default_config.json').readAsStringSync();
      final config = ConfigService().parse(raw);
      expect(config.sites.length, 3);
      expect(config.lives.single.url, startsWith('https://'));
      expect(config.sites.first.categories, isNotEmpty);
    });

    test('accepts base64 encoded config', () {
      const raw =
          '{"sites":[{"key":"a","name":"A","type":1,"api":"https://a.test/api"}]}';
      final encoded = base64Encode(raw.codeUnits);
      final config = ConfigService().parse(encoded);
      expect(config.sites.single.name, 'A');
    });
  });
}
