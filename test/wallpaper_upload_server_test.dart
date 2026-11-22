import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/core/wallpaper_upload_server.dart';

/// 背景图上传服务的端到端契约。
///
/// 核心回归：手机端 `FileReader.readAsDataURL` 返回的 DataURL 按 MIME 规范
/// （RFC 2045）允许每 76 字符插入换行，部分移动浏览器/WebView 也确实会插；
/// Dart 的 `base64Decode` 是严格解码器，遇空白直接抛 `FormatException`，导致
/// 真实手机上传大图时报「上传失败，请重试」。服务器端必须在解码前剥掉空白。
void main() {
  test('serves the upload page with Chinese text', () async {
    final server = WallpaperUploadServer(onImageReceived: (b, n) {});
    final base = await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.getUrl(Uri.parse('$base/'));
    final response = await request.close();
    expect(response.statusCode, 200);
    final html = utf8.decode(
      await response.fold<List<int>>(<int>[], (b, c) => b..addAll(c)),
    );
    expect(html, contains('上传背景图'));
    expect(html, contains('上传到电视'));
    // 文件选择结构回归：必须用「透明 input 覆盖」方案（label 包裹 + hidden +
    // 手动 click 会在 iOS Safari / 部分 WebView 上打不开选择器或双击触发，
    // 导致「选择后无提示、按钮无反应」）。
    expect(html, contains('class="fileInput"'));
    expect(html, isNot(contains('<label class="pick"')));
    expect(html, isNot(contains('pick.addEventListener(\'click\'')));
  });

  test('uploads a small base64 image', () async {
    final received = <Uint8List>[];
    final receivedNames = <String>[];
    final server = WallpaperUploadServer(
      onImageReceived: (bytes, filename) {
        received.add(bytes);
        receivedNames.add(filename);
      },
    );
    final base = await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final imageBytes = Uint8List.fromList(
      List<int>.generate(2048, (i) => i % 256),
    );
    final body = await _post(client, base, '小图.jpg', base64Encode(imageBytes));
    expect(body['ok'], isTrue, reason: '$body');
    expect(receivedNames, ['小图.jpg']);
    expect(received.single, imageBytes);
  });

  test('tolerates newline-wrapped base64 (MIME 76-char wrap)', () async {
    final received = <Uint8List>[];
    final server = WallpaperUploadServer(
      onImageReceived: (bytes, filename) => received.add(bytes),
    );
    final base = await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final rng = Random(7);
    final imageBytes = Uint8List.fromList(
      List<int>.generate(5 * 1024 * 1024, (_) => rng.nextInt(256)),
    );
    // 每 76 字符换行，模拟 MIME DataURL 的换行包装。
    final wrapped = base64Encode(imageBytes).replaceAllMapped(
      RegExp('.{1,76}'),
      (m) => '${m[0]}\n',
    );

    final body = await _post(client, base, 'big.jpg', wrapped);
    expect(body['ok'], isTrue, reason: '$body');
    expect(received.single, imageBytes);
  });

  test('rejects image larger than 8MB', () async {
    final received = <Uint8List>[];
    final server = WallpaperUploadServer(
      onImageReceived: (bytes, filename) => received.add(bytes),
    );
    final base = await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final huge = Uint8List(9 * 1024 * 1024); // 9MB，超过 8MB 上限
    final body = await _post(client, base, 'huge.jpg', base64Encode(huge));
    expect(body['ok'], isFalse);
    expect(received, isEmpty);
  });

  test('rejects missing image data', () async {
    final server = WallpaperUploadServer(onImageReceived: (b, n) {});
    final base = await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.postUrl(Uri.parse('$base/api/upload'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'name': 'x.jpg'}));
    final response = await request.close();
    final body = jsonDecode(
      utf8.decode(await response.fold<List<int>>(<int>[], (b, c) => b..addAll(c))),
    ) as Map<String, dynamic>;
    expect(body['ok'], isFalse);
  });
}

Future<Map<String, dynamic>> _post(
  HttpClient client,
  String base,
  String name,
  String data,
) async {
  final request = await client.postUrl(Uri.parse('$base/api/upload'));
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode({'name': name, 'data': data}));
  final response = await request.close();
  expect(response.statusCode, 200);
  return jsonDecode(
    utf8.decode(await response.fold<List<int>>(<int>[], (b, c) => b..addAll(c))),
  ) as Map<String, dynamic>;
}
