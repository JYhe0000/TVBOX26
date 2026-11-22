import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/core/stream_proxy_server.dart';
import 'package:tvbox_flutter/data/network_policy.dart';

/// 本地流代理回归：上游与 DoH 均为本地 HttpServer 伪造（不起外网）。
/// 上游 host 用 video.invalid，DNS 只能来自 DoH mock 返回的 127.0.0.1，
/// 从而同时验证「回源确实吃到 NetworkPolicy 的 DoH」。
void main() {
  late HttpServer dns;
  late HttpServer upstream;
  final upstreamPaths = <String>[];
  final upstreamHeaders = <Map<String, String>>[];

  const media = 'http://media.invalid';
  // upstream 实际地址，bind 后拼接。
  String upstreamBase = '';

  setUpAll(() async {
    dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    dns.listen((request) async {
      request.response.write(
        '{"Answer":[{"type":1,"TTL":60,"data":"127.0.0.1"}]}',
      );
      await request.response.close();
    });

    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = 'http://media.invalid:${upstream.port}';
    upstream.listen((request) async {
      upstreamPaths.add(request.uri.path);
      final captured = <String, String>{};
      request.headers.forEach((name, values) {
        captured[name] = values.join(',');
      });
      upstreamHeaders.add(captured);
      final path = request.uri.path;
      final response = request.response;
      switch (path) {
        case '/range.mp4':
          response.statusCode = 206;
          response.headers
            ..set('content-type', 'video/mp4')
            ..set('content-range', 'bytes 0-99/1000')
            ..set('accept-ranges', 'bytes')
            ..contentLength = 100;
          response.add(List.filled(100, 0x42));
          await response.close();
        case '/media.m3u8':
          response.headers
            ..set('content-type', 'application/vnd.apple.mpegurl')
            ..contentLength = _mediaPlaylist().length;
          response.write(_mediaPlaylist());
          await response.close();
        case '/master.m3u8':
          response.headers
            ..set('content-type', 'application/vnd.apple.mpegurl')
            ..contentLength = _masterPlaylist().length;
          response.write(_masterPlaylist());
          await response.close();
        case '/plain.bin':
          response.headers
            ..set('content-type', 'application/octet-stream')
            ..contentLength = 16;
          response.add(List.filled(16, 0x11));
          await response.close();
        case '/h.ts':
          response.headers
            ..set('content-type', 'video/mp2t')
            ..contentLength = 8;
          response.add(List.filled(8, 0x22));
          await response.close();
        case '/not-found.bin':
          response.statusCode = 404;
          response.headers.contentLength = 9;
          response.write('not found');
          await response.close();
        case '/forbidden.bin':
          response.statusCode = 403;
          response.headers.contentLength = 9;
          response.write('forbidden');
          await response.close();
        case '/server-error.bin':
          response.statusCode = 500;
          response.headers.contentLength = 4;
          response.write('boom');
          await response.close();
        case '/play.m3u8':
          // 302 到 /dir/real.m3u8：验证分片改写基准是重定向后的
          // effectiveUri 而非原始请求路径。
          response.statusCode = HttpStatus.movedTemporarily;
          response.headers.set(HttpHeaders.locationHeader, '/dir/real.m3u8');
          await response.close();
        case '/dir/real.m3u8':
          response.headers
            ..set('content-type', 'application/vnd.apple.mpegurl')
            ..contentLength = _redirectedPlaylist().length;
          response.write(_redirectedPlaylist());
          await response.close();
        case '/huge.m3u8':
          // 超长播放列表（> _maxPlaylistBytes）：放弃改写回退透传。
          final body = _hugePlaylist();
          response.headers
            ..set('content-type', 'application/vnd.apple.mpegurl')
            ..contentLength = body.length;
          response.write(body);
          await response.close();
        default:
          // 分片 / 变体 / key 一律回小 payload，验证改写后的 URL 能打回
          // 上游且路径正确。
          response.headers
            ..set('content-type', 'application/octet-stream')
            ..contentLength = 4;
          response.add(List.filled(4, 0x33));
          await response.close();
      }
    });
  });

  setUp(() {
    upstreamPaths.clear();
    upstreamHeaders.clear();
    NetworkPolicy.configure(
      doh: 'http://127.0.0.1:${dns.port}/resolve',
      httpProxy: '',
    );
  });

  tearDown(() {
    NetworkPolicy.configure(doh: '', httpProxy: '');
  });

  tearDownAll(() async {
    await dns.close(force: true);
    await upstream.close(force: true);
  });

  HttpClient freshClient() {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    return client;
  }

  Future<(HttpClientResponse, String)> get(
    HttpClient client,
    String url, {
    Map<String, String>? headers,
  }) async {
    final request = await client.getUrl(Uri.parse(url));
    headers?.forEach(request.headers.set);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (response, body);
  }

  group('urlFor', () {
    test('改写为本地代理地址且 u/h 参数可解码往返', () async {
      final wrapped = await StreamProxyServer.urlFor(
        '$media/a.m3u8?sign=x',
        {'Referer': 'https://site.example/', 'User-Agent': 'okhttp/3.15'},
      );
      expect(wrapped.startsWith('http://127.0.0.1:'), isTrue);
      final uri = Uri.parse(wrapped);
      expect(uri.path, '/m');
      final upstreamUrl =
          utf8.decode(base64Url.decode(uri.queryParameters['u']!));
      expect(upstreamUrl, '$media/a.m3u8?sign=x');
      final headersJson =
          jsonDecode(utf8.decode(base64Url.decode(uri.queryParameters['h']!)))
              as Map<String, dynamic>;
      expect(headersJson['Referer'], 'https://site.example/');
      expect(headersJson['User-Agent'], 'okhttp/3.15');
    });

    test('非 http 上游与本机地址原样返回', () async {
      expect(
        await StreamProxyServer.urlFor('file:///sdcard/a.mp4', const {}),
        'file:///sdcard/a.mp4',
      );
      expect(
        await StreamProxyServer.urlFor('http://127.0.0.1:9999/a', const {}),
        'http://127.0.0.1:9999/a',
      );
      expect(
        await StreamProxyServer.urlFor('http://localhost:9/a', const {}),
        'http://localhost:9/a',
      );
    });

    test('网络策略未配置时不改写', () async {
      NetworkPolicy.configure(doh: '', httpProxy: '');
      expect(StreamProxyServer.enabled, isFalse);
      expect(
        await StreamProxyServer.urlFor('$media/a.mp4', const {}),
        '$media/a.mp4',
      );
    });
  });

  test('mp4 Range 请求 206 透传（Content-Range / Accept-Ranges）', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/range.mp4',
      const {},
    );
    final client = freshClient();
    final (response, body) = await get(
      client,
      wrapped,
      headers: {'Range': 'bytes=0-99'},
    );
    expect(response.statusCode, 206);
    expect(response.headers.value('content-range'), 'bytes 0-99/1000');
    expect(response.headers.value('accept-ranges'), 'bytes');
    expect(body.length, 100);
    // 客户端 Range 透传到上游。
    expect(upstreamHeaders.last['range'], 'bytes=0-99');
    expect(upstreamPaths.last, '/range.mp4');
  });

  test('m3u8 media playlist 相对分片改写且分片请求打回上游', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/media.m3u8',
      const {'Referer': 'https://site.example/'},
    );
    final client = freshClient();
    final (response, body) = await get(client, wrapped);
    expect(response.statusCode, 200);
    expect(
      response.headers.value('content-type'),
      'application/vnd.apple.mpegurl',
    );

    final lines = const LineSplitter().convert(body);
    expect(lines.first, '#EXTM3U');
    final segmentLine =
        lines.firstWhere((line) => line.startsWith('http://127.0.0.1:'));
    expect(segmentLine, contains('/m?u='));
    // 原始相对分片名保留在改写 URL 的 u 参数里。
    final segmentUri = Uri.parse(segmentLine);
    final upstreamSegment =
        utf8.decode(base64Url.decode(segmentUri.queryParameters['u']!));
    expect(upstreamSegment, '$upstreamBase/seg001.ts');
    // h 参数携带原 headers（_route 把头键规范化为小写，HTTP 头本就不
    // 区分大小写，与「站点请求头透传」用例断小写的惯例一致）。
    expect(
      jsonDecode(
        utf8.decode(base64Url.decode(segmentUri.queryParameters['h']!)),
      )['referer'],
      'https://site.example/',
    );

    // 分片请求经改写 URL 打回上游正确路径。
    final (segmentResponse, segmentBody) = await get(client, segmentLine);
    expect(segmentResponse.statusCode, 200);
    expect(segmentBody.length, 4);
    expect(upstreamPaths, contains('/seg001.ts'));
  });

  test('master playlist 变体与 EXT-X-KEY URI 改写', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/master.m3u8',
      const {},
    );
    final client = freshClient();
    final (_, body) = await get(client, wrapped);
    final lines = const LineSplitter().convert(body);

    // 变体行（非注释行）改写。
    final variantLines =
        lines.where((line) => line.startsWith('http://127.0.0.1:')).toList();
    expect(variantLines.length, 1);
    final variantUri = Uri.parse(variantLines.single);
    expect(
      utf8.decode(base64Url.decode(variantUri.queryParameters['u']!)),
      '$upstreamBase/variant_720.m3u8',
    );

    // EXT-X-KEY 的 URI="..." 属性改写。
    final keyLine = lines.firstWhere(
      (line) => line.startsWith('#EXT-X-KEY:'),
    );
    expect(keyLine, contains('URI="http://127.0.0.1:'));
    final keyUri = Uri.parse(
      keyLine.substring(keyLine.indexOf('URI="') + 5, keyLine.length - 1),
    );
    expect(
      utf8.decode(base64Url.decode(keyUri.queryParameters['u']!)),
      '$upstreamBase/key.bin',
    );

    // 变体与 key 的改写 URL 都能打回上游。
    await get(client, variantLines.single);
    await get(client, keyUri.toString());
    expect(upstreamPaths, containsAll(['/variant_720.m3u8', '/key.bin']));
  });

  test('站点请求头透传到上游（Referer / User-Agent）', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/h.ts',
      {'Referer': 'https://site.example/', 'User-Agent': 'okhttp/3.15'},
    );
    final client = freshClient();
    // 客户端自带默认 UA，站点头应优先。
    final (response, _) = await get(client, wrapped);
    expect(response.statusCode, 200);
    expect(upstreamHeaders.last['referer'], 'https://site.example/');
    expect(upstreamHeaders.last['user-agent'], 'okhttp/3.15');
    // 不给上游送压缩，保证 Content-Length 可透传。
    expect(upstreamHeaders.last['accept-encoding'], 'identity');
  });

  test('上游 404 原样透传', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/not-found.bin',
      const {},
    );
    final client = freshClient();
    final (response, _) = await get(client, wrapped);
    expect(response.statusCode, 404);
  });

  test('上游连接失败返回 502 中文错误', () async {
    // 找一个确定无人监听的端口：bind 后立刻关闭。
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    final wrapped = await StreamProxyServer.urlFor(
      'http://media.invalid:$port/x.mp4',
      const {},
    );
    final client = freshClient();
    final (response, body) = await get(client, wrapped);
    expect(response.statusCode, 502);
    expect(body, contains('上游视频源访问失败'));
  });

  test('stats：转发字节累计且窗口速率大于零', () async {
    final before = StreamProxyServer.stats.totalServedBytes;
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/range.mp4',
      const {},
    );
    final client = freshClient();
    final (response, _) = await get(
      client,
      wrapped,
      headers: {'Range': 'bytes=0-99'},
    );
    expect(response.statusCode, 206);
    expect(
      StreamProxyServer.stats.totalServedBytes,
      greaterThan(before + 99),
    );
    expect(StreamProxyServer.stats.currentBytesPerSecond, greaterThan(0));
    // 收尾后会话计数回落。
    await Future<void>.delayed(Duration.zero);
    expect(StreamProxyServer.stats.activeSessions, 0);
  });

  test('非 m3u8 的普通字节流按 chunk 透传不改写', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/plain.bin',
      const {},
    );
    final client = freshClient();
    final (response, body) = await get(client, wrapped);
    expect(response.statusCode, 200);
    expect(response.headers.value('content-type'), 'application/octet-stream');
    expect(response.headers.value('content-length'), '16');
    expect(body.length, 16);
    // 普通流不改写：上游不会收到再次回环的请求。
    expect(upstreamPaths.where((p) => p == '/plain.bin').length, 1);
  });

  test('上游 403 / 500 原样透传（状态码与响应体）', () async {
    for (final (path, code, body) in [
      ('/forbidden.bin', 403, 'forbidden'),
      ('/server-error.bin', 500, 'boom'),
    ]) {
      final wrapped = await StreamProxyServer.urlFor(
        '$upstreamBase$path',
        const {},
      );
      final client = freshClient();
      final (response, respBody) = await get(client, wrapped);
      expect(response.statusCode, code, reason: path);
      expect(respBody, body, reason: path);
    }
  });

  test('重定向后以 effectiveUri 作分片改写基准', () async {
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/play.m3u8',
      const {'Referer': 'https://site.example/'},
    );
    final client = freshClient();
    final (response, body) = await get(client, wrapped);
    expect(response.statusCode, 200);
    final lines = const LineSplitter().convert(body);
    // 分片基准是重定向后的 /dir/real.m3u8（而非原始 /play.m3u8）。
    final segmentLine =
        lines.firstWhere((line) => line.startsWith('http://127.0.0.1:'));
    final segmentUri = Uri.parse(segmentLine);
    expect(
      utf8.decode(base64Url.decode(segmentUri.queryParameters['u']!)),
      '$upstreamBase/dir/seg.ts',
    );
    // EXT-X-KEY 的 URI 属性同样以 effectiveUri 为基准。
    final keyLine = lines.firstWhere(
      (line) => line.contains('URI="http://127.0.0.1:'),
    );
    final keyUri = Uri.parse(
      keyLine.substring(keyLine.indexOf('URI="') + 5, keyLine.length - 1),
    );
    expect(
      utf8.decode(base64Url.decode(keyUri.queryParameters['u']!)),
      '$upstreamBase/dir/key.bin',
    );
    // 改写后的分片打回上游正确路径；上游确实经历了 302 → real.m3u8。
    final (segResp, _) = await get(client, segmentLine);
    expect(segResp.statusCode, 200);
    expect(
      upstreamPaths,
      containsAll(['/play.m3u8', '/dir/real.m3u8', '/dir/seg.ts']),
    );
  });

  test('超长播放列表放弃改写，原始字节完整透传', () async {
    final playlist = _hugePlaylist();
    final wrapped = await StreamProxyServer.urlFor(
      '$upstreamBase/huge.m3u8',
      const {},
    );
    final client = freshClient();
    final (response, body) = await get(client, wrapped);
    expect(response.statusCode, 200);
    // 放弃改写：没有任何 /m?u= 包裹地址，且内容与上游逐字节一致
    // （开头块不丢失、HTTP 分帧完整）。
    expect(body.contains('/m?u='), isFalse);
    expect(body.startsWith('#EXTM3U'), isTrue);
    expect(body, playlist);
  });
}

String _mediaPlaylist() => '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-VERSION:3
#EXTINF:9.009,
seg001.ts
#EXT-X-ENDLIST
''';

String _masterPlaylist() => '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720
variant_720.m3u8
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-ENDLIST
''';

String _redirectedPlaylist() => '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-VERSION:3
#EXTINF:9.009,
seg.ts
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-ENDLIST
''';

/// 超过 StreamProxyServer._maxPlaylistBytes（8MiB）的播放列表，
/// 用于验证「超长放弃改写回退透传」。
String _hugePlaylist() {
  const target = 8 << 20;
  final buf = StringBuffer('#EXTM3U\n');
  var i = 0;
  while (buf.length <= target + 1024) {
    buf.writeln('#EXTINF:10.0,');
    buf.writeln('seg$i.ts');
    i++;
  }
  buf.writeln('#EXT-X-ENDLIST');
  return buf.toString();
}
