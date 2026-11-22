import 'dart:convert';

import '../data/storage.dart';
import '../data/models.dart';

class BackupService {
  BackupService(this.storage);
  final StorageService storage;

  static const stringKeys = [
    'series_skip_points',
    'search_excluded_sites',
    'disabled_sites',
    'site_order',
    'config_url_history',
    'live_last_channel',
    'epg_url_override',
    'epg_url_history',
    'network_doh',
    'network_proxy',
    'danmaku_base_url',
    'config_url',
    'config_cache',
    'config_cache_url',
    'config_cache_base',
    'vod_aggregate_urls',
    'live_url_override',
    'home_site_key',
    'ui_skin_id',
    'playback_scale',
    'live_preferences',
    'favorites',
    'history',
    'search_history',
  ];
  static const boolKeys = [
    'show_source_badges',
    'home_rows',
    'live_media_kit',
    'background_playback',
    'danmaku_auto_match',
    'auto_next',
    'auto_play',
    'player_media_kit',
    'ui_background_blur',
  ];
  static const doubleKeys = [
    'seek_step_seconds',
    'playback_speed',
    'ui_glass_opacity',
    'ui_glass_refraction',
  ];

  String export() => jsonEncode({
    'format': 'tvbox26-backup',
    'version': 1,
    'settings': {
      for (final key in stringKeys) key: storage.getString(key),
      for (final key in boolKeys)
        key: storage.getBool(
          key,
          ['auto_next', 'auto_play', 'show_source_badges', 'danmaku_auto_match'].contains(key),
        ),
      for (final key in doubleKeys)
        key: storage.getDouble(key, key == 'seek_step_seconds' ? 10 : 1),
    },
  });

  Map<String, dynamic> validate(String body) {
    if (utf8.encode(body).length > 4 * 1024 * 1024) {
      throw const FormatException('备份文件超过 4MB');
    }
    final root = jsonDecode(body);
    if (root is! Map ||
        root['format'] != 'tvbox26-backup' ||
        root['version'] != 1 ||
        root['settings'] is! Map) {
      throw const FormatException('不是支持的 TVBOX26 备份文件');
    }
    final values = Map<String, dynamic>.from(root['settings'] as Map);
    for (final entry in values.entries) {
      final key = entry.key;
      if (stringKeys.contains(key)) {
        if (entry.value is! String) throw FormatException('$key 格式错误');
        if ([
              'favorites',
              'history',
              'search_history',
              'series_skip_points',
              'search_excluded_sites',
              'disabled_sites',
              'site_order',
              'config_url_history',
              'vod_aggregate_urls',
              'live_last_channel',
              'epg_url_history',
            ].contains(key) &&
            entry.value != '') {
          final list = jsonDecode(entry.value as String);
          if (list is! List || list.any((value) => value is! Map)) {
            throw FormatException('$key 内容错误');
          }
          for (final node in list) {
            final map = Map<String, dynamic>.from(node as Map);
            if (key == 'history') HistoryEntry.fromJson(map);
            if (key == 'favorites') VodItem.fromStoredJson(map);
          }
        }
        if (key == 'live_preferences' &&
            entry.value != '' &&
            jsonDecode(entry.value as String) is! Map) {
          throw const FormatException('直播设置格式错误');
        }
      } else if (boolKeys.contains(key)) {
        if (entry.value is! bool) throw FormatException('$key 格式错误');
      } else if (doubleKeys.contains(key)) {
        if (entry.value is! num || !(entry.value as num).isFinite) {
          throw FormatException('$key 格式错误');
        }
      } else {
        throw FormatException('备份包含未知设置：$key');
      }
    }
    return values;
  }

  Future<void> restore(String body) async {
    final values = validate(body);
    // 整份验证通过后再写入，避免畸形文件造成半份恢复。
    for (final entry in values.entries) {
      if (entry.value is String) {
        await storage.setString(entry.key, entry.value as String);
      } else if (entry.value is bool) {
        await storage.setBool(entry.key, entry.value as bool);
      } else {
        await storage.setDouble(entry.key, (entry.value as num).toDouble());
      }
    }
  }
}
