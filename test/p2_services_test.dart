import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/danmaku_service.dart';
import 'package:tvbox_flutter/data/recommendation_service.dart';
import 'package:tvbox_flutter/data/webdav_service.dart';

void main() {
  test('XML 与 JSON 弹幕排序、过滤非法时间、限制文本长度', () {
    final xml = DanmakuService.parse(
      '<i><d p="2,1,25">后</d><d p="1,1,25">先</d><d p="-1">忽略</d></i>',
    );
    expect(xml.map((comment) => comment.text), ['先', '后']);
    expect(xml.first.timeMs, 1000);
    final json = DanmakuService.parse(
      '{"comments":[{"p":"3,1,25","m":"弹幕"},{"time":0.5,"text":"开头"}]}',
    );
    expect(json.first.timeMs, 500);
    expect(json.last.text, '弹幕');
  });
  test('推荐数据映射与站点内容隔离', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'subjects': [
                    {
                      'id': '1',
                      'title': '影片',
                      'cover': 'https://pic.test/1.jpg',
                      'rate': '8.0',
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
    final entries = await RecommendationService(dio: dio).load();
    expect(entries.single.sourceKey, '@douban');
    expect(entries.single.name, '影片');
    expect(entries.single.lines, isEmpty);
  });
  test('WebDAV 授权、目录解析、同源保护', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.method, 'PROPFIND');
            expect(options.headers['Depth'], '1');
            expect(options.headers['Authorization'], 'Basic dXNlcjpwYXNz');
            expect(options.uri.userInfo, isEmpty);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 207,
                data: '''
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/dav/</d:href></d:response>
<d:response><d:href>/dav/video.mp4</d:href><d:propstat><d:prop><d:displayname>影片</d:displayname></d:prop></d:propstat></d:response>
<d:response><d:href>/dav/folder/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>https://other.test/secret</d:href></d:response>
</d:multistatus>''',
              ),
            );
          },
        ),
      );
    final service = WebDavService(
      'https://user:pass@cloud.test/dav/',
      dio: dio,
    );
    final entries = await service.list(service.publicRoot);
    expect(entries.length, 2);
    expect(entries.first.folder, isTrue);
    expect(entries.last.name, '影片');
    await expectLater(
      service.list(Uri.parse('https://other.test/')),
      throwsFormatException,
    );
  });
}
