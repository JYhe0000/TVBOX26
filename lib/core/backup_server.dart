import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'backup_service.dart';

class BackupServer {
  BackupServer(this.service, {required this.onRestore});
  final BackupService service;
  final Future<void> Function(String body) onRestore;
  HttpServer? _server;
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_handle);
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = interfaces.expand((i) => i.addresses);
    final host = addresses.firstOrNull?.address ?? '127.0.0.1';
    return 'http://$host:${server.port}/$_token/';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (!request.uri.path.startsWith('/$_token/')) {
        request.response.statusCode = 404;
        return;
      }
      request.response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'GET' && request.uri.path.endsWith('/download')) {
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(
          'Content-Disposition',
          'attachment; filename="tvbox26-backup.json"',
        );
        request.response.write(service.export());
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/restore')) {
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          if (bytes.length > 4 * 1024 * 1024) {
            throw const FormatException('备份文件超过 4MB');
          }
        }
        final body = utf8.decode(bytes);
        service.validate(body);
        await onRestore(body);
        request.response.write('备份已提交，请在电视上确认恢复。');
      } else if (request.method == 'GET') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '''<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TVBOX26 备份恢复</title><body><h1>备份与恢复</h1><p><a href="download">下载备份 JSON</a></p><p>包含配置、播放设置、收藏与历史。</p><input id="file" type="file" accept="application/json"><button id="restore">提交恢复</button><p id="status"></p><script>document.getElementById('restore').onclick=async()=>{const f=document.getElementById('file').files[0];if(!f)return;const r=await fetch('restore',{method:'POST',body:await f.text()});document.getElementById('status').textContent=await r.text();};</script></body></html>''',
        );
      } else {
        request.response.statusCode = 405;
      }
    } catch (_) {
      request.response.statusCode = 400;
      request.response.write('备份文件无效，请选择 TVBOX26 导出的 JSON。');
    } finally {
      await request.response.close();
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
