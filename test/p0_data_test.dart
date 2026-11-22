import 'package:flutter_test/flutter_test.dart';

import 'package:dio/dio.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/playback_preferences.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/data/play_resolver.dart';
import 'package:tvbox_flutter/data/epg_service.dart';
import 'package:tvbox_flutter/data/playback_error.dart';
import 'package:tvbox_flutter/data/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('手动解析直链时只调用所选接口，自动模式仍直连', () async {
    final paths = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          paths.add(options.uri.path);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: '{"url":"https://example.com/resolved.mp4"}',
            ),
          );
        },
      ),
    );
    final resolver = PlayResolver(dio: dio);
    final parse = ParseConfig(name: '指定解析', url: 'https://parse.test/selected');
    final result = await resolver.resolve(
      'https://example.com/direct.mp4',
      parses: [ParseConfig(name: '不应调用', url: 'https://parse.test/other')],
      selectedParse: parse,
    );
    expect(result.parseName, '指定解析');
    expect(result.url, 'https://example.com/resolved.mp4');
    expect(paths, ['/selected']);
    final direct = await resolver.resolve(
      'https://example.com/direct.mp4',
      parses: [parse],
    );
    expect(direct.viaParse, isFalse);
    final forced = await resolver.resolve(
      'https://example.com/direct.mp4',
      parses: [parse],
      forceParse: true,
    );
    expect(forced.viaParse, isTrue);
  });
  test('查询参数里的扩展名不误判直链，签名只解码一次', () async {
    final paths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            paths.add(options.uri.path);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '{"url":"https://video.test/resolved.mp4"}',
              ),
            );
          },
        ),
      );
    final resolver = PlayResolver(dio: dio);
    final parsed = await resolver.resolve(
      'https://page.test/watch?format=mp4',
      parses: const [ParseConfig(name: '解析', url: 'https://parse.test/p')],
    );
    expect(parsed.viaParse, isTrue);
    expect(paths, ['/p']);

    final signed = await resolver.resolve(
      'https://resolver.test/play?url=https%3A%2F%2Fvideo.test%2Fplay.m3u8%3Fsig%3Da%252Fb',
    );
    expect(signed.url, 'https://video.test/play.m3u8?sig=a%2Fb');
    expect(signed.viaParse, isFalse);
  });
  test('播放设置持久化并在新控制器初始化时回读', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final controller = AppController(storage: storage);
    await controller.setPlaybackSpeed(1.5);
    await controller.setPlaybackScale(PlaybackScale.classic);
    await controller.setAutoPlay(false);
    final restored = AppController(storage: storage);
    await restored.initialize();
    expect(restored.playbackSpeed, 1.5);
    expect(restored.playbackScale, PlaybackScale.classic);
    expect(restored.autoPlay, isFalse);
    controller.dispose();
    restored.dispose();
  });
  test('JSON 节目单排序、当前下一档与跨午夜', () {
    final data = EpgService.parse(
      '{"date":"2026-11-17","epg_data":[{"start":"23:30","end":"00:30","title":"夜间"},{"start":"22:00","end":"23:30","title":"晚间"}]}',
      'CCTV1',
      DateTime(2026, 11, 17),
    );
    final now = DateTime(2026, 11, 17, 23);
    expect(data.current(now)?.title, '晚间');
    expect(data.next(now)?.title, '夜间');
    expect(data.current(DateTime(2026, 11, 18, 0))?.title, '夜间');
    expect(data.current(DateTime(2026, 11, 18, 0, 30)), isNull);
  });
  test('XMLTV 按频道匹配并处理时区', () {
    final data = EpgService.parse(
      '<tv><channel id="one"><display-name>CCTV1</display-name></channel><programme channel="one" start="20261117190000 +0800" stop="20261117193000 +0800"><title>新闻</title></programme><programme channel="two" start="20261117190000 +0800" stop="20261117193000 +0800"><title>其他频道</title></programme></tv>',
      'CCTV1',
      DateTime(2026),
    );
    expect(data.programmes.length, 1);
    expect(data.current(DateTime.utc(2026, 11, 17, 11, 15))?.title, '新闻');
  });
  test('播放器异常归因且不泄漏原始平台错误', () {
    expect(friendlyPlaybackError('HTTP 403'), contains('拒绝访问'));
    expect(friendlyPlaybackError('HTTP 404'), contains('已失效'));
    expect(friendlyPlaybackError('SocketException'), contains('检查网络'));
    expect(friendlyPlaybackError('TimeoutException'), contains('超时'));
    expect(
      friendlyPlaybackError('android.media3.ExoPlaybackException'),
      isNot(contains('ExoPlayback')),
    );
  });
  test('分类筛选保留空值与协议键，忽略畸形条目', () {
    final data = CategoryFilter.parse({
      'movie': [
        {
          'key': 'year',
          'name': '年份',
          'value': [
            {'n': '全部', 'v': ''},
            {'n': '2026', 'v': '2026'},
          ],
        },
        {'name': '坏数据'},
      ],
    });
    expect(data['movie']!.single.values['2026'], '2026');
    expect(data['movie']!.single.values[''], '全部');
  });
}
