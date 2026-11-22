import 'dart:convert';

import 'storage.dart';

/// 影片 → 弹幕地址的记忆库。
///
/// 按「站点 key + 影片 id + 集号」记住已经匹配成功的弹幕地址，下次播放
/// 同一集时直接命中、免去模板试探的网络开销。持久化走 [StorageService]
/// 范式（JSON 字符串整体读写），未 init 时降级为内存 no-op。
class DanmakuStore {
  DanmakuStore(this._storage);

  final StorageService _storage;

  static const String _storageKey = 'danmaku_url_memory';

  /// 上限：超出时按插入顺序淘汰最旧的一半，避免无限增长。
  static const int _maxEntries = 500;

  /// 记忆键：站点 key + 影片 id + 集号（电影集号为 0）。
  static String entryKey(String siteKey, String vodId, int episode) =>
      '$siteKey|$vodId|$episode';

  /// 读取全部记忆（坏数据降级为空表）。
  Map<String, String> snapshot() {
    final raw = _storage.getString(_storageKey);
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
    } catch (_) {
      // 坏 JSON：按空表处理，不影响主流程。
    }
    return {};
  }

  /// 命中返回已记忆的弹幕地址，未命中返回 null。
  Future<String?> lookup(String siteKey, String vodId, int episode) async =>
      snapshot()[entryKey(siteKey, vodId, episode)];

  /// 记住某集命中的弹幕地址。
  Future<void> remember(
    String siteKey,
    String vodId,
    int episode,
    String url,
  ) async {
    final map = Map<String, String>.from(snapshot());
    map[entryKey(siteKey, vodId, episode)] = url;
    // 超容淘汰最旧条目（Map 保插入顺序）。
    while (map.length > _maxEntries) {
      map.remove(map.keys.first);
    }
    await _storage.setString(_storageKey, jsonEncode(map));
  }

  /// 清除全部记忆。
  Future<void> clear() => _storage.remove(_storageKey);

  /// 按站点 / 影片 / 集号定向清除（集号为 null 时清该影片所有集）。
  Future<void> clearFor(String siteKey, String vodId, {int? episode}) async {
    final map = snapshot();
    map.removeWhere((key, _) {
      final parts = key.split('|');
      if (parts.length != 3) return false;
      if (parts[0] != siteKey || parts[1] != vodId) return false;
      return episode == null || int.tryParse(parts[2]) == episode;
    });
    await _storage.setString(_storageKey, jsonEncode(map));
  }
}
