import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/storage.dart';

class LibraryStore extends ChangeNotifier {
  LibraryStore({StorageService? storage})
    : storage = storage ?? StorageService();

  final StorageService storage;
  final List<VodItem> favorites = [];
  final List<HistoryEntry> history = [];
  final List<String> searchHistory = [];
  bool initialized = false;
  Future<void>? _initializing;

  Set<String> get favoriteKeys => favorites.map(stableKey).toSet();

  Future<void> initialize() {
    final running = _initializing;
    if (running != null) return running;
    final future = _initialize();
    _initializing = future;
    return future.whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
    await storage.init();
    final loadedFavorites = <VodItem>[];
    for (final json in storage.getJsonList('favorites')) {
      try {
        final vod = VodItem.fromStoredJson(json);
        if (vod.id.trim().isNotEmpty) loadedFavorites.add(vod);
      } catch (_) {
        // 单条坏收藏不能阻断其它收藏的恢复。
      }
    }

    final loadedHistory = <HistoryEntry>[];
    for (final json in storage.getJsonList('history')) {
      try {
        final entry = HistoryEntry.fromJson(json);
        if (entry.vod.id.trim().isNotEmpty) loadedHistory.add(entry);
      } catch (_) {
        // 历史记录来自旧版本/外部备份，逐条隔离解析异常。
      }
    }

    final loadedSearchHistory = [
      for (final json in storage.getJsonList('search_history'))
        if (asString(json['q']).isNotEmpty) asString(json['q']),
    ];
    final changed =
        !_sameVodList(favorites, loadedFavorites) ||
        !_sameHistoryList(history, loadedHistory) ||
        !_sameStringList(searchHistory, loadedSearchHistory) ||
        !initialized;
    favorites
      ..clear()
      ..addAll(loadedFavorites);
    history
      ..clear()
      ..addAll(loadedHistory);
    searchHistory
      ..clear()
      ..addAll(loadedSearchHistory);
    initialized = true;
    if (changed) notifyListeners();
  }

  bool isFavorite(VodItem vod) =>
      favorites.any((e) => stableKey(e) == stableKey(vod));

  HistoryEntry? historyFor(VodItem vod) {
    for (final entry in history) {
      if (stableKey(entry.vod) == stableKey(vod)) return entry;
    }
    return null;
  }

  Future<bool> toggleFavorite(VodItem vod) async {
    if (vod.id.trim().isEmpty) return false;
    final index = favorites.indexWhere((e) => stableKey(e) == stableKey(vod));
    if (index >= 0) {
      favorites.removeAt(index);
      await _saveFavorites();
      notifyListeners();
      return false;
    }
    favorites.insert(0, vod.copyWith(lines: const []));
    await _saveFavorites();
    notifyListeners();
    return true;
  }

  Future<void> removeFavorite(VodItem vod) async {
    final before = favorites.length;
    favorites.removeWhere((e) => stableKey(e) == stableKey(vod));
    if (favorites.length == before) return;
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> clearFavorites() async {
    if (favorites.isEmpty) return;
    favorites.clear();
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> addHistory(HistoryEntry entry) async {
    if (entry.vod.id.trim().isEmpty) return;
    final key = stableKey(entry.vod);
    HistoryEntry? existing;
    var existingIndex = -1;
    for (var i = 0; i < history.length; i++) {
      final item = history[i];
      if (stableKey(item.vod) == key) {
        existing = item;
        existingIndex = i;
        break;
      }
    }
    if (existingIndex == 0 &&
        existing != null &&
        _sameHistoryContent(existing, entry)) {
      return;
    }
    history.removeWhere((e) => stableKey(e.vod) == stableKey(entry.vod));
    history.insert(0, entry.copyWith(updatedAt: DateTime.now()));
    while (history.length > 100) {
      history.removeLast();
    }
    await _saveHistory();
    notifyListeners();
  }

  static bool _sameHistoryContent(HistoryEntry a, HistoryEntry b) =>
      stableKey(a.vod) == stableKey(b.vod) &&
      _sameJson(a.vod.toJson(), b.vod.toJson()) &&
      a.sourceKey == b.sourceKey &&
      a.sourceName == b.sourceName &&
      a.lineName == b.lineName &&
      a.lineIndex == b.lineIndex &&
      a.episodeName == b.episodeName &&
      a.episodeUrl == b.episodeUrl &&
      a.episodeIndex == b.episodeIndex &&
      a.positionMs == b.positionMs &&
      a.durationMs == b.durationMs;

  Future<void> removeHistory(HistoryEntry entry) async {
    final before = history.length;
    history.removeWhere((e) => stableKey(e.vod) == stableKey(entry.vod));
    if (history.length == before) return;
    await _saveHistory();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    if (history.isEmpty) return;
    history.clear();
    await _saveHistory();
    notifyListeners();
  }

  Future<void> addSearchKeyword(String keyword) async {
    final value = keyword.trim();
    if (value.isEmpty) return;
    final before = List<String>.of(searchHistory);
    searchHistory.remove(value);
    searchHistory.insert(0, value);
    while (searchHistory.length > 12) {
      searchHistory.removeLast();
    }
    await storage.setJsonList(
      'search_history',
      searchHistory.map((e) => {'q': e}).toList(),
    );
    if (!_sameStringList(before, searchHistory)) notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    if (searchHistory.isEmpty) return;
    searchHistory.clear();
    await storage.setJsonList('search_history', const []);
    notifyListeners();
  }

  Future<void> _saveFavorites() async {
    await storage.setJsonList(
      'favorites',
      favorites.map((e) => e.toJson()).toList(),
    );
  }

  Future<void> _saveHistory() async {
    await storage.setJsonList(
      'history',
      history.map((e) => e.toJson()).toList(),
    );
  }

  static bool _sameVodList(List<VodItem> a, List<VodItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i].toJson(), b[i].toJson())) return false;
    }
    return true;
  }

  static bool _sameHistoryList(List<HistoryEntry> a, List<HistoryEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i].toJson(), b[i].toJson())) return false;
    }
    return true;
  }

  static bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameJson(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameValue(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }

  static bool _sameValue(Object? a, Object? b) {
    if (a is Map<String, dynamic> && b is Map<String, dynamic>) {
      return _sameJson(a, b);
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameValue(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
