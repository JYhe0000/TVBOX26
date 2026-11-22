import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/storage.dart';

VodItem _vod(String id) =>
    VodItem(id: id, name: '影片 $id', sourceKey: 'test', sourceName: '测试站点');

HistoryEntry _entry({
  required VodItem vod,
  required int episodeIndex,
  required int positionMs,
}) => HistoryEntry(
  vod: vod,
  sourceKey: 'test',
  sourceName: '测试站点',
  lineName: '线路一',
  lineIndex: 0,
  episodeName: '第${episodeIndex + 1}集',
  episodeUrl: 'https://video.test/$episodeIndex.m3u8',
  episodeIndex: episodeIndex,
  positionMs: positionMs,
  durationMs: 600000,
  updatedAt: DateTime(2026, 11, 20),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('收藏与历史写入、从存储恢复时保留业务字段', () async {
    final storage = StorageService();
    final store = LibraryStore(storage: storage);
    await store.initialize();
    final vod = _vod('movie-1');
    final entry = _entry(vod: vod, episodeIndex: 2, positionMs: 123456);

    await store.toggleFavorite(vod);
    await store.addHistory(entry);

    final restored = LibraryStore(storage: StorageService());
    await restored.initialize();
    expect(restored.isFavorite(vod), isTrue);
    expect(restored.favoriteKeys, {'test__movie-1'});
    final history = restored.historyFor(vod)!;
    expect(history.vod.name, vod.name);
    expect(history.sourceKey, 'test');
    expect(history.sourceName, '测试站点');
    expect(history.lineName, '线路一');
    expect(history.lineIndex, 0);
    expect(history.episodeName, '第3集');
    expect(history.episodeUrl, 'https://video.test/2.m3u8');
    expect(history.episodeIndex, 2);
    expect(history.positionMs, 123456);
    expect(history.durationMs, 600000);
  });

  test('单条损坏历史隔离，其它合法历史仍能初始化', () async {
    SharedPreferences.setMockInitialValues({
      'history': jsonEncode([
        {'vod': 'broken'},
        _entry(vod: _vod('ok'), episodeIndex: 1, positionMs: 5000).toJson(),
      ]),
    });
    final store = LibraryStore(storage: StorageService());
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.initialize();

    expect(store.initialized, isTrue);
    expect(store.history, hasLength(1));
    expect(store.history.single.vod.id, 'ok');
    expect(store.history.single.positionMs, 5000);
    expect(notifications, 1);
    await store.initialize();
    expect(notifications, 1, reason: '无状态变化时不重复通知');
  });

  test('重复搜索词不引起无意义通知，真实状态变化仍通知', () async {
    final store = LibraryStore(storage: StorageService());
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.addSearchKeyword(' 测试 ');
    expect(notifications, 1);
    await store.addSearchKeyword('测试');
    expect(notifications, 1);
    await store.addSearchKeyword('新查询');
    expect(notifications, 2);
  });

  test('重复写入未变化的最新历史不更新时间或通知', () async {
    final store = LibraryStore(storage: StorageService());
    final entry = _entry(vod: _vod('same'), episodeIndex: 0, positionMs: 1000);
    await store.addHistory(entry);
    final updatedAt = store.history.single.updatedAt;
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.addHistory(entry);

    expect(store.history, hasLength(1));
    expect(store.history.single.updatedAt, updatedAt);
    expect(notifications, 0);
  });
}
