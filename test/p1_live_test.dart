import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// 使用播放器公开平台替身，测试不创建真实解码器。
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:tvbox_flutter/core/live_preferences.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/live_player_page.dart';
import 'package:tvbox_flutter/ui/widgets/channel_password_dialog.dart';

class _Platform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final urls = <String>[];
  int nextId = 0;
  @override
  Future<void> init() async {}
  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    final id = nextId++;
    urls.add(options.dataSource.uri!);
    events[id] = StreamController<VideoEvent>();
    return id;
  }

  void ready() => events[nextId - 1]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(hours: 1),
      size: const Size(1280, 720),
    ),
  );
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async => events[playerId]!.close();
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}

void main() {
  late _Platform platform;
  late VideoPlayerPlatform previous;
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() => VideoPlayerPlatform.instance = previous);

  testWidgets('数字选台与频道键跨组换台保持可见播放焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = LiveGroup(
      name: '一组',
      channels: [
        LiveChannel(
          name: '一台',
          urls: ['https://v.test/1.m3u8'],
          sourceNames: ['源'],
          number: 1,
        ),
      ],
    );
    final second = LiveGroup(
      name: '二组',
      channels: [
        LiveChannel(
          name: '二台',
          urls: ['https://v.test/2.m3u8'],
          sourceNames: ['源'],
          number: 2,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: LivePlayerPage(
          group: first,
          groups: [first, second],
          preferences: const LivePreferences(crossGroup: true),
        ),
      ),
    );
    await tester.pump();
    platform.ready();
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(platform.urls.last, 'https://v.test/2.m3u8');
    platform.ready();
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.channelUp);
    await tester.pump();
    expect(platform.urls.last, 'https://v.test/1.m3u8');
    platform.ready();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('密码错误不解锁，数字键盘输入正确密码后返回成功', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool? unlocked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                unlocked = await unlockChannel(context, '12');
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解锁'));
    await tester.pump();
    expect(find.text('密码错误，请重新输入'), findsOneWidget);
    expect(unlocked, isNull);
    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(unlocked, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
