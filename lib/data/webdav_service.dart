import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'network_policy.dart';

class CloudEntry {
  const CloudEntry(this.name, this.uri, this.folder);
  final String name;
  final Uri uri;
  final bool folder;
}

class WebDavService {
  WebDavService(String address, {Dio? dio})
    : root = Uri.parse(address),
      _dio =
          dio ??
          NetworkPolicy.attach(
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 20),
              ),
            ),
          );
  final Uri root;
  final Dio _dio;
  Uri get publicRoot => root.replace(userInfo: '');
  Map<String, String> get headers => root.userInfo.isEmpty
      ? {}
      : {
          'Authorization':
              'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(root.userInfo)))}',
        };

  Future<List<CloudEntry>> list(Uri uri) async {
    if (uri.origin != publicRoot.origin) {
      throw const FormatException('网盘地址超出当前服务器');
    }
    final response = await _dio.request<String>(
      uri.toString(),
      data: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>',
      options: Options(
        method: 'PROPFIND',
        responseType: ResponseType.plain,
        followRedirects: false,
        headers: {...headers, 'Depth': '1', 'Content-Type': 'application/xml'},
      ),
    );
    final document = XmlDocument.parse(response.data ?? '');
    final result = <CloudEntry>[];
    for (final node in document.descendants.whereType<XmlElement>().where(
      (node) => node.name.local == 'response',
    )) {
      final href = node.descendants
          .whereType<XmlElement>()
          .where((node) => node.name.local == 'href')
          .firstOrNull
          ?.innerText;
      if (href == null) continue;
      final target = uri.resolve(href).replace(userInfo: '');
      if (target.origin != publicRoot.origin ||
          target.path == uri.path ||
          target.path == '${uri.path}/') {
        continue;
      }
      final folder = node.descendants.whereType<XmlElement>().any(
        (node) => node.name.local == 'collection',
      );
      final name = node.descendants
          .whereType<XmlElement>()
          .where((node) => node.name.local == 'displayname')
          .firstOrNull
          ?.innerText;
      final segments = target.pathSegments.where(
        (segment) => segment.isNotEmpty,
      );
      result.add(
        CloudEntry(
          name?.isNotEmpty == true ? name! : segments.lastOrNull ?? '未命名',
          target,
          folder,
        ),
      );
    }
    result.sort(
      (a, b) =>
          a.folder != b.folder ? (a.folder ? -1 : 1) : a.name.compareTo(b.name),
    );
    return result;
  }
}
