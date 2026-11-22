import 'package:flutter/material.dart';

import '../../core/config_url_server.dart';
import '../../data/models.dart';
import '../../core/utils.dart';
import '../pages/player_page.dart';
import 'config_url_dialog.dart';

Future<void> showPushPlayDialog(BuildContext context) async {
  String? received;
  var open = false;
  final server = ConfigUrlServer(
    onUrl: (url) {
      received = url;
      if (context.mounted && open) {
        open = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    },
  );
  try {
    final address = await server.start();
    if (!context.mounted) return;
    open = true;
    await showConfigUrlDialog(context, address, '扫码投送视频地址');
    open = false;
    if (!context.mounted || received == null) return;
    final url = received!;
    final uri = Uri.tryParse(url);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) {
      showAppSnack(context, '请投送 HTTP 视频直链或可解析的网页地址');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          site: const SiteConfig(key: '@push', name: '手机投送', api: ''),
          vod: VodItem(
            id: url,
            name: '手机投送',
            sourceKey: '@push',
            lines: [
              PlayLine(
                name: '投送线路',
                episodes: [Episode(name: '播放', url: url)],
              ),
            ],
          ),
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) showAppSnack(context, '投送服务启动失败，请确认手机和电视连接同一局域网');
  } finally {
    await server.stop();
  }
}
