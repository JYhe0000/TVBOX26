import '../data/storage.dart';

class SkipPreference {
  const SkipPreference({this.introMs = 0, this.outroMs = 0});
  final int introMs;
  final int outroMs;

  int startPosition(int resumeMs, int durationMs) {
    if (resumeMs > 0) return resumeMs.clamp(0, durationMs);
    return introMs < durationMs ? introMs : 0;
  }

  bool reachesOutro(int positionMs, int durationMs) =>
      outroMs > 0 &&
      durationMs > introMs + outroMs &&
      positionMs >= durationMs - outroMs;
}

class SkipPreferences {
  SkipPreferences(this.storage);
  final StorageService storage;
  static const storageKey = 'series_skip_points';

  SkipPreference read(String site, String vod) {
    final entry = storage
        .getJsonList(storageKey)
        .where((e) => e['site'] == site && e['vod'] == vod)
        .firstOrNull;
    int value(String key) =>
        entry?[key] is int ? (entry![key] as int).clamp(0, 600000) : 0;
    return SkipPreference(introMs: value('intro'), outroMs: value('outro'));
  }

  Future<void> save(String site, String vod, SkipPreference value) async {
    final entries = storage.getJsonList(storageKey)
      ..removeWhere((e) => e['site'] == site && e['vod'] == vod);
    if (value.introMs > 0 || value.outroMs > 0) {
      entries.add({
        'site': site,
        'vod': vod,
        'intro': value.introMs.clamp(0, 600000),
        'outro': value.outroMs.clamp(0, 600000),
      });
    }
    await storage.setJsonList(storageKey, entries);
  }
}
