import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/data/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('JSON 列表存储往返保持现有对象格式', () async {
    final storage = StorageService();
    await storage.init();
    final records = [
      {'id': 'movie-1', 'name': '测试影片'},
      {'id': 'movie-2', 'name': '另一部影片'},
    ];

    await storage.setJsonList('records', records);

    expect(storage.getJsonList('records'), records);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('records')!), records);
  });

  test('初始化前的写入先在内存可读，初始化后补写入持久化', () async {
    final storage = StorageService();
    final write = storage.setJsonList('history', [
      {'id': 'movie-1'},
    ]);

    expect(storage.getJsonList('history'), [
      {'id': 'movie-1'},
    ]);
    await storage.init();
    await write;

    final restored = StorageService();
    await restored.init();
    expect(restored.getJsonList('history'), [
      {'id': 'movie-1'},
    ]);
  });

  test('坏数组条目不会影响同数组中的有效对象', () async {
    SharedPreferences.setMockInitialValues({
      'records': '[{"id":"good"},null,3,"bad",{"name":"also good"}]',
    });
    final storage = StorageService();
    await storage.init();

    expect(storage.getJsonList('records'), [
      {'id': 'good'},
      {'name': 'also good'},
    ]);
  });

  test('JSON 编码失败时不覆盖此前可读值', () async {
    final storage = StorageService();
    await storage.init();
    await storage.setJsonList('records', [
      {'id': 'keep'},
    ]);

    await storage.setJsonList('records', [
      {'invalid': Object()},
    ]);

    expect(storage.getJsonList('records'), [
      {'id': 'keep'},
    ]);
  });
}
