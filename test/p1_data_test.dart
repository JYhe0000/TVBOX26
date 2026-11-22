import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/backup_service.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/play_resolver.dart';
import 'package:tvbox_flutter/core/stream_proxy_server.dart';
import 'package:tvbox_flutter/data/network_policy.dart';
import 'package:tvbox_flutter/data/web_sniffer.dart';

class _Sniffer extends WebSniffer {
  String? page;
  @override
  Future<SniffedMedia?> sniff(
    String url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    page = url;
    return const SniffedMedia('https://video.test/sniff.m3u8', {
      'Cookie': 'session=1',
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('并发解析取首个有效响应并合并请求和视频头', () async {
    final dio = Dio();
    final slow = Completer<void>();
    var slowStarted = false;
    addTearDown(() {
      if (!slow.isCompleted) slow.complete();
    });
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.uri.path == '/slow') {
            slowStarted = true;
            await slow.future;
          }
          expect(options.headers['Referer'], 'https://site.test/');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: '{"url":"https://video.test/play.mp4","headers":{"Cookie":"token=1"}}',
            ),
          );
        },
      ),
    );
    final result = await PlayResolver(dio: dio).resolve(
      'https://page.test/watch',
      headers: {'Referer': 'https://site.test/'},
      parses: const [
        ParseConfig(name: '慢', url: 'https://parse.test/slow'),
        ParseConfig(
          name: '快',
          url: 'https://parse.test/fast',
          ext: '{"header":{"User-Agent":"custom"}}',
        ),
      ],
    );
    expect(slowStarted, isTrue);
    expect(result.parseName, '快');
    expect(result.headers['Cookie'], 'token=1');
    expect(result.headers['User-Agent'], 'custom');
  });
  test('解析总预算超时后取消未完成请求', () async {
    final dio = Dio();
    final cancelled = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.cancelToken!.whenCancel.then((_) {
            if (!cancelled.isCompleted) cancelled.complete();
          });
        },
      ),
    );
    final resolver = PlayResolver(
      dio: dio,
      timeout: const Duration(milliseconds: 40),
    );
    await expectLater(
      resolver.resolve(
        'https://page.test/watch',
        parses: const [ParseConfig(name: '慢', url: 'https://parse.test/')],
      ),
      throwsA(
        isA<PlayResolveException>().having(
          (error) => error.message,
          'message',
          contains('解析超时'),
        ),
      ),
    );
    await cancelled.future;
  });
  test('连接解析源失败时给出网络类错误提示', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          ),
        ),
      );
    await expectLater(
      PlayResolver(dio: dio).resolve(
        'https://page.test/watch',
        parses: const [ParseConfig(name: '失联解析', url: 'https://parse.test/')],
      ),
      throwsA(
        isA<PlayResolveException>().having(
          (error) => error.message,
          'message',
          contains('连接解析源失败'),
        ),
      ),
    );
  });
  test('HTML 解析调用嗅探并保留 Cookie', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: '<html><script>play()</script></html>',
          ),
        ),
      ),
    );
    final sniffer = _Sniffer();
    final result = await PlayResolver(dio: dio, sniffer: sniffer).resolve(
      'https://page.test/watch',
      parses: const [ParseConfig(name: '网页', url: 'https://parse.test/?url=')],
    );
    expect(sniffer.page, contains('https://parse.test/'));
    expect(result.url, endsWith('sniff.m3u8'));
    expect(result.headers['Cookie'], 'session=1');
  });
  test('解析 ext 的 JSON/base64 headers 透传到请求和播放结果', () async {
    final ext = base64Url.encode(
      utf8.encode(
        '{"headers":{"Referer":"https://site.test/","Cookie":"ext=1"}}',
      ),
    );
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.headers['Referer'], 'https://site.test/');
            expect(options.headers['Cookie'], 'ext=1');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data:
                    '{"url":"https://video.test/play.mp4",'
                    '"header":"{\\"Cookie\\":\\"result=1\\"}"}',
              ),
            );
          },
        ),
      );
    final result = await PlayResolver(dio: dio).resolve(
      'https://page.test/watch',
      parses: [
        ParseConfig(name: '带头解析', url: 'https://parse.test/p', ext: ext),
      ],
    );
    expect(result.headers['Referer'], 'https://site.test/');
    expect(result.headers['Cookie'], 'result=1');
  });
  test('HLS 资源包装只透传显式 Cookie，不把上游 Set-Cookie 当播放头', () async {
    NetworkPolicy.configure(doh: '', httpProxy: '127.0.0.1:1');
    addTearDown(() => NetworkPolicy.configure(doh: '', httpProxy: ''));
    final wrapped = await StreamProxyServer.urlFor(
      'https://media.example/playlist.m3u8',
      const {'Cookie': 'explicit=1'},
    );
    final uri = Uri.parse(wrapped);
    final headers = jsonDecode(
      utf8.decode(base64Url.decode(uri.queryParameters['h']!)),
    ) as Map<String, dynamic>;

    // HLS child URLs only receive the caller-provided base headers. The proxy
    // intentionally has no cookie-jar semantics for playlist Set-Cookie.
    expect(headers, {'Cookie': 'explicit=1'});
  });
  test('M3U 解析频道号、密码、EPG 标识和回看参数', () {
    final result = LiveParser.parse(
      '#EXTM3U\n#EXTINF:-1 tvg-id="cctv1" tvg-chno="101" password="1234" catchup-days="3" catchup-source="https://video.test/replay?start={utc}&duration={duration}",央视一套\nhttps://video.test/live.m3u8',
    );
    final channel = result.groups.single.channels.single;
    expect(channel.number, 101);
    expect(channel.password, '1234');
    expect(channel.epgId, 'cctv1');
    final now = DateTime(2026, 11, 17, 20);
    final url = channel.replayUrl(
      now.subtract(const Duration(hours: 2)),
      now.subtract(const Duration(hours: 1)),
      now: now,
    );
    expect(url, contains('duration=3600'));
    expect(
      channel.replayUrl(now.subtract(const Duration(days: 4)), now, now: now),
      isNull,
    );
  });
  test('备份恢复往返并拒绝畸形文件且不修改已有值', () async {
    SharedPreferences.setMockInitialValues({
      'auto_play': false,
      'playback_speed': 1.5,
      'favorites': '[]',
    });
    final storage = StorageService();
    await storage.init();
    final backup = BackupService(storage);
    final body = backup.export();
    await storage.setBool('auto_play', true);
    await backup.restore(body);
    expect(storage.getBool('auto_play'), isFalse);
    expect(storage.getDouble('playback_speed'), 1.5);
    await expectLater(
      backup.restore(
        '{"format":"tvbox26-backup","version":1,"settings":{"auto_play":true,"history":"invalid"}}',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(storage.getBool('auto_play'), isFalse);
  });
}
