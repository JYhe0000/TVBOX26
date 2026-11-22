import 'package:flutter/material.dart';

import '../../core/config_url_server.dart';
import '../../core/utils.dart';
import '../../data/models.dart';
import '../../data/webdav_service.dart';
import '../pages/player_page.dart';
import 'config_url_dialog.dart';
import 'tv_sheet.dart';

Future<void> showCloudBrowser(BuildContext context) async {
  String? address;
  var open = false;
  final server = ConfigUrlServer(
    onUrl: (url) {
      address = url;
      if (context.mounted && open) {
        open = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    },
  );
  try {
    final endpoint = await server.start();
    if (!context.mounted) return;
    open = true;
    await showConfigUrlDialog(context, endpoint, 'WebDAV 网盘地址（可含用户名密码）');
    open = false;
    if (!context.mounted || address == null) return;
    final uri = Uri.tryParse(address!);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      showAppSnack(context, '请输入有效的 HTTP / HTTPS WebDAV 地址');
      return;
    }
    final service = WebDavService(address!);
    var current = service.publicRoot;
    final parents = <Uri>[];
    final memory = <Uri, int>{};
    while (context.mounted) {
      final entries = await service.list(current);
      if (!context.mounted) return;
      final selected = await showTvSheet<int>(
        context,
        title: 'WebDAV 网盘',
        subtitle: current.path,
        autofocusClose: false,
        builder: (sheetContext) => TvSheetList(
          initialIndex: memory[current] ?? 0,
          labels: [
            parents.isEmpty ? '关闭网盘' : '上一级',
            for (final entry in entries)
              '${entry.folder ? '目录' : '文件'} · ${entry.name}',
          ],
          onSelected: (index) => Navigator.pop(sheetContext, index - 1),
        ),
      );
      if (!context.mounted || selected == null) return;
      if (selected < 0) {
        if (parents.isEmpty) return;
        current = parents.removeLast();
        continue;
      }
      memory[current] = selected + 1;
      final entry = entries[selected];
      if (entry.folder) {
        parents.add(current);
        current = entry.uri;
        continue;
      }
      final videos = entries
          .where(
            (entry) =>
                !entry.folder &&
                RegExp(
                  r'\.(mp4|mkv|m3u8|avi|mov|m4v|ts|flv|webm)$',
                  caseSensitive: false,
                ).hasMatch(entry.uri.path),
          )
          .toList();
      final episodeIndex = videos.indexOf(entry);
      if (episodeIndex < 0) {
        showAppSnack(context, '请选择视频文件');
        continue;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            site: SiteConfig(
              key: '@webdav',
              name: 'WebDAV 网盘',
              api: '',
              headers: service.headers,
            ),
            vod: VodItem(
              id: current.toString(),
              name: entry.name,
              sourceKey: '@webdav',
              lines: [
                PlayLine(
                  name: '网盘目录',
                  episodes: videos
                      .map(
                        (entry) => Episode(
                          name: entry.name,
                          url: entry.uri.toString(),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
            episodeIndex: episodeIndex,
          ),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      showAppSnack(context, '网盘访问失败，请检查 WebDAV 地址、账号与权限', error: true);
    }
  } finally {
    await server.stop();
  }
}
