import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/background_playback.dart';
import 'package:tvbox_flutter/data/storage.dart';

/// 长驻后台播放 Dart 状态层测试：
/// - mock 'tvbox/playback' MethodChannel（本仓库无既有 mock 范式，按 flutter_test
///   标准 TestDefaultBinaryMessengerBinding 写法）；
/// - 覆盖 start/update/stop 的通道参数、storage.dart 持久化往返、
///   restore 的空态/有态/原生兜底分支、重复 start 幂等、原生动作回放。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tvbox/playback');
  final calls = <MethodCall>[];
  /// 原生侧兜底快照（模拟 ForegroundMediaService 的 SharedPreferences）。
  final nativeSnapshot = <String, dynamic>{};
  final actions = <String>[];

  setUp(() {
    calls.clear();
    nativeSnapshot.clear();
    actions.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'backgroundRestore') {
        return nativeSnapshot.isEmpty
            ? null
            : Map<String, dynamic>.from(nativeSnapshot);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    BackgroundPlayback.onAction = null;
  });

  StorageService newStorage() => StorageService();

  test('start 下发 backgroundStart（url/title/positionMs/playing）并持久化',
      () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);

    await playback.start(
      url: 'https://x/1.mp4',
      title: '测试片',
      positionMs: 12345,
      playing: true,
    );

    final start = calls.singleWhere((c) => c.method == 'backgroundStart');
    expect(start.arguments, <String, dynamic>{
      'url': 'https://x/1.mp4',
      'title': '测试片',
      'positionMs': 12345,
      'playing': true,
    });
    // 持久化往返
    final raw = storage.getString('bg_playback_state');
    expect(raw.isNotEmpty, isTrue);
    final restored = BackgroundPlaybackState.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
    expect(restored.url, 'https://x/1.mp4');
    expect(restored.title, '测试片');
    expect(restored.positionMs, 12345);
    expect(restored.playing, isTrue);
    expect(playback.isActive, isTrue);
  });

  test('update 下发 backgroundUpdateState 并刷新持久化', () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);
    await playback.start(url: 'https://x/1.mp4', title: '测试片');
    calls.clear();

    await playback.update(playing: false, positionMs: 60000);

    final update = calls.singleWhere((c) => c.method == 'backgroundUpdateState');
    expect(update.arguments, <String, dynamic>{
      'playing': false,
      'positionMs': 60000,
    });
    final state = BackgroundPlaybackState.fromJson(
      Map<String, dynamic>.from(jsonDecode(storage.getString('bg_playback_state')) as Map),
    );
    expect(state.playing, isFalse);
    expect(state.positionMs, 60000);
  });

  test('stop 下发 backgroundStop 并清空持久化', () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);
    await playback.start(url: 'https://x/1.mp4', title: '测试片');
    calls.clear();

    await playback.stop();

    expect(calls.single.method, 'backgroundStop');
    expect(storage.getString('bg_playback_state'), '');
    expect(playback.isActive, isFalse);
    expect(playback.state, isNull);
  });

  test('restore 空态：storage 与原生兜底均无会话 → null', () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);

    expect(await playback.restore(), isNull);
  });

  test('restore 有态：优先读 storage.dart（进程被杀后数据仍在）', () async {
    final storage = newStorage();
    await storage.init();
    await BackgroundPlayback(storage: storage).start(
      url: 'https://x/2.mp4',
      title: '另一部',
      positionMs: 9999,
      playing: false,
    );
    // 模拟进程被杀后新实例：storage 里的 JSON 还在。
    calls.clear();
    final restored = BackgroundPlayback(storage: storage);

    final state = await restored.restore();

    expect(state?.url, 'https://x/2.mp4');
    expect(state?.title, '另一部');
    expect(state?.positionMs, 9999);
    expect(state?.playing, isFalse);
    // storage 命中时不消耗通道调用
    expect(calls, isEmpty);
  });

  test('restore 兜底：storage 坏数据时回读原生 backgroundRestore', () async {
    final storage = newStorage();
    await storage.init();
    await storage.setString('bg_playback_state', '{坏JSON');
    nativeSnapshot
      ['url'] = 'https://x/native.mp4';
    nativeSnapshot['title'] = '原生兜底';
    nativeSnapshot['positionMs'] = 5000;
    nativeSnapshot['playing'] = true;

    final state = await BackgroundPlayback(storage: storage).restore();

    expect(state?.url, 'https://x/native.mp4');
    expect(state?.positionMs, 5000);
    expect(state?.playing, isTrue);
    expect(calls.any((c) => c.method == 'backgroundRestore'), isTrue);
  });

  test('重复 start 同一 url 幂等：不再发 backgroundStart，只 update', () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);
    await playback.start(url: 'https://x/1.mp4', title: '测试片');
    calls.clear();

    await playback.start(url: 'https://x/1.mp4', title: '测试片', positionMs: 5);

    expect(calls.where((c) => c.method == 'backgroundStart'), isEmpty);
    expect(calls.single.method, 'backgroundUpdateState');
  });

  test('换 url 的 start 不幂等：重新下发 backgroundStart', () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);
    await playback.start(url: 'https://x/1.mp4', title: '测试片');
    calls.clear();

    await playback.start(url: 'https://x/2.mp4', title: '新集');

    expect(calls.singleWhere((c) => c.method == 'backgroundStart').arguments,
        <String, dynamic>{
          'url': 'https://x/2.mp4',
          'title': '新集',
          'positionMs': 0,
          'playing': true,
        });
  });

  test('原生 backgroundAction 回放进 onAction（通知按钮 → Dart）', () async {
    final storage = newStorage();
    await storage.init();
    final playback = BackgroundPlayback(storage: storage);
    BackgroundPlayback.onAction = actions.add;
    await playback.start(url: 'https://x/1.mp4', title: '测试片');

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      StandardMethodCodec().encodeMethodCall(
        const MethodCall('backgroundAction', {'action': 'play'}),
      ),
      (_) {},
    );

    expect(actions, ['play']);
  });
}
