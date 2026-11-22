// player_focus_test.dart — 播放器焦点体系公共件（player_focus.dart）与
// 直播播放器焦点状态机的回归（focus-system-spec §5；点播侧由
// player_controls_test 覆盖）。覆盖：
// 1. 控制层顶行 UP 回画面、LEFT 唤醒回中央播放键（可见 × 隐藏两态）；
// 2. 中央播放键 DOWN 回画面、UP 到顶行返回键（控制层与画面的显式切换）；
// 3. 隐藏态 UP = 换台（直播现有机制：HardwareKeyboard 兜底先于焦点分发
//    拦截方向键），换台就绪回中央播放键；
// 4. 频道面板打开聚焦当前频道、行内 UP/DOWN 显式投递到面板关闭键；
// 5. 面板换台关闭后焦点回频道列表触发键（覆盖层还焦链）；
// 6. 30 频道下 DOWN 跨出视口仍逐行移动（cacheExtent 死键回归）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
// 使用播放器插件公开的平台接口替身，不创建真实解码器。
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/live_player_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  int nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    final id = nextId++;
    events[id] = StreamController<VideoEvent>();
    return id;
  }

  void initializeLatest() => events[nextId - 1]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 5),
      size: const Size(1920, 1080),
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

LiveGroup _group({int channels = 6, int sources = 1}) => LiveGroup(
  name: '测试组',
  channels: List.generate(
    channels,
    (i) => LiveChannel(
      name: '频道 ${i + 1}',
      urls: [
        'https://test/$i.m3u8',
        for (var source = 1; source < sources; source++)
          'https://test/$i/$source.m3u8',
      ],
      sourceNames: List.generate(sources, (source) => '线路 ${source + 1}'),
    ),
  ),
);

Future<void> _mountLive(
  WidgetTester tester, {
  int channels = 6,
  int sources = 1,
  TvSkinId skin = TvSkinId.smartisan,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = AppController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
      ],
      child: MaterialApp(
        theme: AppTheme.forSkin(skin),
        navigatorObservers: [kRouteObserver],
        home: LivePlayerPage(
          group: _group(channels: channels, sources: sources),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _readyLive(WidgetTester tester, _VideoPlatform platform) async {
  platform.initializeLatest();
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 取 semanticLabel 匹配的 TvFocusable 背后真正的 Focus 节点。
FocusNode _nodeOf(WidgetTester tester, String label) => tester
    .widget<Focus>(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is TvFocusable && widget.semanticLabel == label,
            ),
            matching: find.byType(Focus),
          )
          .first,
    )
    .focusNode!;

void main() {
  late _VideoPlatform platform;
  late VideoPlayerPlatform previous;
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = previous;
  });

  testWidgets('直播超时后默认聚焦重试，左右选择线路并按 OK 切换', (tester) async {
    await _mountLive(tester, sources: 2);
    platform.events[platform.nextId - 1]!.addError(
      PlatformException(code: 'VideoError', message: 'Connection timed out'),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(_nodeOf(tester, '重试').hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_nodeOf(tester, '切换线路').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_nodeOf(tester, '下一个频道').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_nodeOf(tester, '切换线路').hasPrimaryFocus, isTrue);

    final count = platform.nextId;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(platform.nextId, count + 1);
    await _readyLive(tester, platform);
    await tester.pumpWidget(const SizedBox());
  });

  for (final visible in [true, false]) {
    testWidgets('直播子路由返回：控制层 visible=$visible 恢复对应状态焦点', (tester) async {
      await _mountLive(tester);
      await _readyLive(tester, platform);
      if (!visible) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      }
      final navigator = Navigator.of(
        tester.element(find.byType(LivePlayerPage)),
      );
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: Focus(autofocus: true, child: Text('子路由'))),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        visible ? 'livePlay' : 'liveRoot',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final opaque in [true, false]) {
    testWidgets('直播子路由覆盖 opaque=$opaque 期间自动隐藏到期不抢焦', (tester) async {
      await _mountLive(tester);
      await _readyLive(tester, platform);
      final navigator = Navigator.of(
        tester.element(find.byType(LivePlayerPage)),
      );
      final cover = FocusNode(debugLabel: 'liveCover');
      addTearDown(cover.dispose);
      navigator.push<void>(
        PageRouteBuilder<void>(
          opaque: opaque,
          pageBuilder: (_, _, _) => Scaffold(
            body: Focus(
              focusNode: cover,
              autofocus: true,
              child: const Text('覆盖直播页'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(cover.hasPrimaryFocus, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveCover');
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('直播前后台恢复明确落到 livePlay', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveRoot');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('直播切台加载期间焦点留在 liveRoot，完成后回频道列表触发键', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    _nodeOf(tester, '频道列表').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveRoot');
    expect(find.textContaining('正在连接 频道 2'), findsOneWidget);
    await _readyLive(tester, platform);
    // 面板换台沿用既有还焦语义：完成后回「频道列表」触发键，不能留在
    // 已卸载的频道行，也不能误投到播放键。
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channelTrigger');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('直播控制层：顶行 UP 回画面，LEFT 唤醒回中央播放键', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    // 顶行「返回」键 UP → 隐藏控制层回画面（可见 → 隐藏的显式上行出口）。
    _nodeOf(tester, '返回').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveRoot');
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    // LEFT 唤醒 → 中央播放键（隐藏态 UP/DOWN 是换台语义，见换台用例；
    // 状态机：隐藏 = 焦点在页面根，LEFT/RIGHT/OK 负责唤醒）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('直播中央播放键：DOWN 回画面，UP 到顶行返回键', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    // 中央键 DOWN → 隐藏控制层（控制层内最下沿的交互控件）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveRoot');
    // LEFT 唤醒 → 顶行 DOWN → 中央键；中央键 UP → 顶行返回键。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    _nodeOf(tester, '返回').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveBack');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('直播隐藏态 UP = 换台（现有机制），换台就绪回中央播放键', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    // ESC 隐藏控制层回画面。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'liveRoot');
    // 隐藏态 UP → 下一频道（_handleChannelKey 的换台语义，HardwareKeyboard
    // 兜底先于焦点分发拦截）；换台成功后控制层自动可见并落焦中央键。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await _readyLive(tester, platform);
    expect(find.text('频道 2'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'livePlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('频道面板：打开聚焦当前频道，UP/DOWN 显式投递', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    // 打开频道面板 → 焦点直达当前频道行（覆盖层的内容主项）。
    _nodeOf(tester, '频道列表').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-0');
    // 行内 DOWN/UP 按 index 显式投递（单列纵向列表）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-0');
    // 首行 UP → 面板头「关闭」按钮（面板顶唯一可获焦控件）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channelPanelClose');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('频道面板：换台关闭后焦点回频道列表触发键', (tester) async {
    await _mountLive(tester);
    await _readyLive(tester, platform);
    _nodeOf(tester, '频道列表').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // DOWN 到第二个频道，OK 换台：面板关闭、新流就绪。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await _readyLive(tester, platform);
    // 换台完成 → 焦点回开面板前的触发键（覆盖层还焦链）。
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channelTrigger');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('频道列表 30 频道：DOWN 跨出视口仍逐行移动（显式投递）', (tester) async {
    await _mountLive(tester, channels: 30);
    await _readyLive(tester, platform);
    _nodeOf(tester, '频道列表').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-0');
    // 视口约 13 行 + 缓存 480px（约 9 行）：15 次 DOWN 后焦点在第 20 行，
    // 已跨出首屏——显式投递 + cacheExtent 双保险（AGENTS.md §3 规则 7）。
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-20');
    // 末行 DOWN 显式吞（面板底）：焦点停在最后一行。
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-29');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'channel-29');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
