import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/remote_search_server.dart';
import '../../core/utils.dart';
import '../../data/models.dart';
import '../../data/pan/pan_account.dart';
import '../../data/pan/pan_provider.dart';
import '../../data/pan/pan_registry.dart';
import '../pages/player_page.dart';
import 'pan_qr_dialog.dart';
import 'remote_search_dialog.dart';
import 't9_search_dialog.dart';
import 'tv_sheet.dart';

Future<int?> _choosePanItem(
  BuildContext context,
  String title,
  List<String> labels, {
  int initialIndex = 0,
}) => showTvSheet<int>(
  context,
  title: title,
  autofocusClose: false,
  builder: (sheetContext) => TvSheetList(
    labels: labels,
    initialIndex: initialIndex,
    onSelected: (index) => Navigator.pop(sheetContext, index),
  ),
);

Future<String> _panCredential(BuildContext context, String title) async {
  var value = '';
  final trigger = FocusManager.instance.primaryFocus;
  await showT9SearchDialog(
    context,
    title: title,
    hint: '凭据仅保存在本机；留空取消绑定',
    returnFocus: trigger,
    onChanged: (text) => value = text,
    onScan: () async {
      var open = false;
      final server = RemoteSearchServer(
        onQuery: (text) {
          value = text;
          if (context.mounted && open) {
            open = false;
            Navigator.of(context, rootNavigator: true).pop();
            Navigator.of(context, rootNavigator: true).pop();
          }
        },
      );
      try {
        final address = await server.start();
        if (!context.mounted) return;
        open = true;
        await showRemoteSearchDialog(context, address);
      } finally {
        open = false;
        await server.stop();
      }
    },
  );
  return value.trim();
}

/// 原生网盘目录入口：使用用户已有凭据，不冒充厂商扫码 OAuth。
Future<void> showNativePanBrowser(BuildContext context) async {
  final trigger = FocusManager.instance.primaryFocus;
  final store = PanAccountStore(context.read<AppController>().storage);
  try {
    final choice = await _choosePanItem(context, '原生网盘 · 凭据绑定', [
      for (final id in PanProviderId.values)
        '${id.label} · ${store.load(id) == null ? '未绑定' : '已绑定'}',
    ]);
    if (!context.mounted || choice == null) return;
    final id = PanProviderId.values[choice];
    final provider = panProviderFor(id);
    var account = store.load(id);
    final action = await _choosePanItem(context, id.label, [
      if (account != null) '浏览目录',
      '绑定或更换凭据（本机明文保存）',
      if (account != null) '解除绑定',
    ]);
    if (!context.mounted || action == null) return;
    if (account != null && action == 2) {
      await store.remove(id);
      return;
    }
    if (account == null || action == 1) {
      final method = await _choosePanItem(context, '${id.label} · 绑定方式', [
        '手机扫码登录（推荐）',
        '手动粘贴凭据',
      ]);
      if (!context.mounted || method == null) return;
      if (method == 0) {
        account = await showPanQrLogin(context, id);
        if (!context.mounted || account == null) return;
      } else {
        final credential = await _panCredential(
          context,
          id == PanProviderId.quark
              ? '夸克网盘登录 Cookie'
              : '${id.label} refresh_token',
        );
        if (!context.mounted || credential.isEmpty) return;
        var clientId = '';
        var clientSecret = '';
        if (id == PanProviderId.baidu) {
          clientId = await _panCredential(context, '百度开放平台 client_id');
          if (!context.mounted || clientId.isEmpty) return;
          clientSecret = await _panCredential(context, '百度开放平台 client_secret');
          if (!context.mounted || clientSecret.isEmpty) return;
        }
        account = PanAccount(
          provider: id,
          refreshToken: id == PanProviderId.quark ? '' : credential,
          cookie: id == PanProviderId.quark ? credential : '',
          clientId: clientId,
          clientSecret: clientSecret,
        );
      }
    }
    var activeAccount = await provider.refresh(account);
    await store.save(activeAccount);
    if (!context.mounted) return;
    var parent = provider.rootParentId;
    final parents = <String>[];
    final memory = <String, int>{};
    while (context.mounted) {
      // 只有令牌模式需要按过期时间续期；Cookie 模式（夸克/百度扫码）
      // 没有可续期的 access_token，重复 refresh 只会多打一次校验请求。
      if (activeAccount.hasAccessToken && panTokenNeedsRefresh(activeAccount)) {
        activeAccount = await provider.refresh(activeAccount);
        await store.save(activeAccount);
      }
      final entries = await provider.list(activeAccount, parentId: parent);
      if (!context.mounted) return;
      final selected = await _choosePanItem(context, '${id.label} · 目录', [
        parents.isEmpty ? '关闭网盘' : '上一级',
        for (final entry in entries)
          '${entry.folder ? '目录' : '文件'} · ${entry.name}',
      ], initialIndex: memory[parent] ?? 0);
      if (!context.mounted || selected == null) return;
      if (selected == 0) {
        if (parents.isEmpty) return;
        parent = parents.removeLast();
        continue;
      }
      memory[parent] = selected;
      final entry = entries[selected - 1];
      if (entry.folder) {
        parents.add(parent);
        parent = entry.path ?? entry.id;
        continue;
      }
      if (!_videoExtensions.contains(entry.extension)) {
        showAppSnack(context, '请选择视频文件');
        continue;
      }
      final media = await provider.fileUrl(activeAccount, entry);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            site: SiteConfig(
              key: '@pan_${id.name}',
              name: id.label,
              api: '',
              headers: media.headers,
            ),
            vod: VodItem(
              id: entry.id,
              name: entry.name,
              sourceKey: '@pan_${id.name}',
              lines: [
                PlayLine(
                  name: id.label,
                  episodes: [Episode(name: entry.name, url: media.url)],
                ),
              ],
            ),
          ),
        ),
      );
    }
  } on PanException catch (error) {
    if (context.mounted) showAppSnack(context, error.message, error: true);
  } catch (_) {
    if (context.mounted) {
      showAppSnack(context, '网盘访问失败，请检查凭据、网络与授权范围', error: true);
    }
  } finally {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (trigger?.context != null) trigger!.requestFocus();
    });
  }
}

const _videoExtensions = {
  'mp4',
  'mkv',
  'm3u8',
  'avi',
  'mov',
  'm4v',
  'ts',
  'flv',
  'webm',
};
