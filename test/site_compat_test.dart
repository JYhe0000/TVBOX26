import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/config_service.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/data/playback_error.dart';

void main() {
  test('配置可经过六次跳转，遇到循环立即停止', () async {
    for (final cycle in [false, true]) {
      final requests = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              final path = o.uri.path;
              requests.add(path);
              final done = path == '/6';
              h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: done ? 200 : 302,
                  headers: done
                      ? null
                      : Headers.fromMap({
                          'location': [
                            cycle && path == '/1'
                                ? '/0#again'
                                : '/${requests.length}',
                          ],
                        }),
                  data: done ? '{"sites":[{"key":"test","api":"./api"}]}' : '',
                ),
              );
            },
          ),
        );
      final load = ConfigService(dio: dio).loadFromUrl('https://box.example/0');
      if (cycle) {
        await expectLater(
          load,
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              '原因',
              contains('循环跳转'),
            ),
          ),
        );
        expect(requests.length, 2);
      } else {
        expect((await load).baseUrl, 'https://box.example/6');
      }
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  test('站点只返回解析前缀时保留取址错误，不把前缀当作正片地址', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: '{"playUrl":"https://parse.example/?url=","url":""}',
            ),
          ),
        ),
      );
    const site = SiteConfig(
      key: 's',
      name: '站点',
      api: 'https://site.example',
      type: 4,
    );
    await expectLater(
      SiteApi(dio: dio).spiderPlay(site, '线路', '1', []),
      throwsA(
        isA<ApiException>().having(
          friendlyPlaybackError,
          '提示',
          contains('未返回播放地址'),
        ),
      ),
    );
  });

  test('Spider 搜索取消只影响对应请求', () async {
    const channel = MethodChannel('tvbox/spider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String, Completer<String>>{};
    final started = Completer<void>();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      final id = args['requestId'] as String;
      if (call.method == 'cancelSearch') {
        calls[id]!.completeError(
          PlatformException(code: 'spider_cancelled', message: '搜索已取消'),
        );
        return null;
      }
      expect(call.method, 'search');
      final result = calls[id] = Completer<String>();
      if (calls.length == 2) started.complete();
      return result.future;
    });
    const site = SiteConfig(
      key: 'a',
      name: '站点',
      api: 'csp_Test',
      type: 3,
      jar: 'https://site.example/test.jar',
    );
    final api = SiteApi();
    final cancellation = SearchCancellation();
    final oldResult = expectLater(
      api.search(site, '旧词', cancellation: cancellation),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          '搜索已取消',
        ),
      ),
    );
    final newResult = api.search(site, '新词');
    await started.future;
    cancellation.cancel();
    await oldResult;
    expect(calls.values.last.isCompleted, isFalse);
    calls.values.last.complete('{"list":[]}');
    expect(await newResult, isEmpty);
  });

  test('JSON 搜索按参考 Box 传参，正常空结果只请求一次', () async {
    final queries = <Map<String, String>>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            queries.add(options.uri.queryParameters);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '{"list":[]}',
              ),
            );
          },
        ),
      );
    const site = SiteConfig(
      key: 'a',
      name: '站点',
      api: 'https://site.example/api',
      type: 1,
    );
    expect(await SiteApi(dio: dio).search(site, '名侦探'), isEmpty);
    expect(queries, [
      {'wd': '名侦探', 'ac': 'detail'},
    ]);
  });

  test('取消搜索会取消正在执行的 HTTP 请求', () async {
    final started = Completer<RequestOptions>();
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => started.complete(options),
        ),
      );
    const site = SiteConfig(
      key: 'a',
      name: '站点',
      api: 'https://site.example/api',
      type: 1,
    );
    final cancellation = SearchCancellation();
    final result = expectLater(
      SiteApi(dio: dio).search(site, '名侦探', cancellation: cancellation),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    final options = await started.future;
    cancellation.cancel();
    expect(options.cancelToken?.isCancelled, isTrue);
    await result;
  });

  test('中文订阅跳转时保留 Box 请求头，以最终地址解析相对路径', () async {
    const input = 'https://例子.example:8443/饭太硬?x=%2F';
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options.uri.toString());
            expect(options.headers['User-Agent'], 'okhttp/3.15');
            expect(options.headers['Accept'], contains('image/webp'));
            expect(options.followRedirects, isFalse);
            if (requests.length == 1) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 301,
                  headers: Headers.fromMap({
                    'location': ['/config/'],
                  }),
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '{"sites":[{"key":"a","api":"./api"}]}',
              ),
            );
          },
        ),
      );
    final loaded = await ConfigService(dio: dio).loadFromUrl(input);
    expect(requests, [
      'https://xn--fsqu00a.example:8443/%E9%A5%AD%E5%A4%AA%E7%A1%AC?x=%2F',
      'https://xn--fsqu00a.example:8443/config/',
    ]);
    expect(loaded.sourceUrl, input);
    expect(
      loaded.config.sites.single.api,
      'https://xn--fsqu00a.example:8443/config/api',
    );
  });

  test('服务器返回网页时报告配置地址问题', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: '\uFEFF  <!DOCTYPE HTML><html>首页</html>',
            ),
          ),
        ),
      );
    await expectLater(
      ConfigService(dio: dio).loadFromUrl('https://box.example/config'),
      throwsA(
        isA<ConfigException>().having(
          (error) => error.message,
          'message',
          contains('返回的是网页'),
        ),
      ),
    );
  });

  test('type:4 使用专用首页、筛选、搜索、详情和播放参数', () async {
    final calls = <Map<String, dynamic>>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final query = options.uri.queryParameters;
            calls.add(query);
            final body = query.containsKey('play')
                ? {
                    'url': 'https://stream.example/video',
                    'parse': 0,
                    'header': '{"Referer":"https://site.example"}',
                  }
                : {
                    'class': [
                      {'type_id': 'movies', 'type_name': '电影'},
                    ],
                    'list': [
                      {'vod_id': 'a', 'vod_name': '影片'},
                    ],
                  };
            handler.resolve(
              Response(
                requestOptions: options,
                data: jsonEncode(body),
                statusCode: 200,
              ),
            );
          },
        ),
      );
    final api = SiteApi(dio: dio);
    const site = SiteConfig(
      key: 's',
      name: '站点',
      api: 'https://site.example/api',
      type: 4,
      ext: 'cfg',
    );
    expect((await api.home(site)).videos.single.id, 'a');
    await api.category(
      site,
      'movies',
      2,
      filters: {'area': '中国', 'year': '全部'},
    );
    await api.category(site, 'movies', 1);
    expect((await api.search(site, '影片')).single.id, 'a');
    expect((await api.detail(site, 'a')).name, '影片');
    final play = await api.spiderPlay(site, 'line', 'opaque-id', const []);
    expect(play.url, 'https://stream.example/video');
    expect(play.headers['Referer'], 'https://site.example');
    expect((play.parse, play.sniff), (false, false));
    expect(calls, [
      {'filter': 'true', 'extend': 'cfg'},
      {
        'ac': 'detail',
        'filter': 'true',
        't': 'movies',
        'pg': '2',
        'ext': base64Encode(utf8.encode('{"area":"中国"}')),
      },
      {'ac': 'detail', 'filter': 'true', 't': 'movies', 'pg': '1', 'ext': ''},
      {'wd': '影片', 'ac': 'detail', 'quick': 'false'},
      {'ac': 'detail', 'ids': 'a', 'extend': 'cfg'},
      {'play': 'opaque-id', 'flag': 'line', 'extend': 'cfg'},
    ]);
  });

  test('clan 配置用文件服务路径，保留相对资源基准和 JAR 解析器类名', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(
              options.uri.toString(),
              'http://box.example:9978/file/vod/config.json',
            );
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '''{
          "spider":"https://cdn.example/spider.jar",
          "sites":[{"key":"a","type":4,"api":"./api","ext":"../extra.json"}],
          "parses":[{"name":"内置","type":2,"url":"Demo"}],
          "lives":[{"url":"clan://box.example:9978/live.txt"}]
        }''',
              ),
            );
          },
        ),
      );
    final loaded = await ConfigService(dio: dio)
        .loadFromUrl('clan://box.example:9978/vod/config.json');
    expect(
      loaded.config.sites.single.api,
      'http://box.example:9978/file/vod/api',
    );
    expect(
      loaded.config.sites.single.ext,
      'http://box.example:9978/file/extra.json',
    );
    expect(loaded.config.parses.single.url, 'Demo');
    expect(loaded.config.parses.single.jar, 'https://cdn.example/spider.jar');
    expect(loaded.config.lives.single.url, 'clan://box.example:9978/live.txt');
  });

  test('站点 ext 的 JSON/base64 headers 交给现有模型解析', () {
    final jsonHeaders =
        '{"header":{"Referer":"https://site.example/",'
        '"Cookie":"session=1"}}';
    final encoded = base64Url.encode(utf8.encode(jsonHeaders));
    final config = ConfigService().parse(
      jsonEncode({
        'sites': [
          {
            'key': 'json',
            'name': 'JSON 头',
            'api': 'https://site.example/api',
            'ext': jsonHeaders,
          },
          {
            'key': 'base64',
            'name': 'Base64 头',
            'api': 'https://site.example/base64',
            'ext': encoded,
          },
        ],
      }),
    );
    expect(config.sites[0].headers, {
      'Referer': 'https://site.example/',
      'Cookie': 'session=1',
    });
    expect(config.sites[1].headers, config.sites[0].headers);
  });

  test('proxy 直播地址的 ext 只做一次 URI 解码，保留签名编码', () {
    const target = 'https://live.example/live.m3u8?sig=a%2Fb';
    final proxy = 'proxy://local?ext=${Uri.encodeQueryComponent(target)}';
    final config = ConfigService().parse(
      jsonEncode({
        'lives': [
          {'name': '代理直播', 'url': proxy},
        ],
      }),
    );
    expect(config.lives.single.url, target);
  });
}
