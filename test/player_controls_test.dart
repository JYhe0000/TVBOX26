import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/skip_preferences.dart';
// 使用播放器插件公开的平台接口替身，不创建真实解码器。
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/player_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  int pauses = 0;
  int nextId = 0;
  double speed = 1;
  final seeks = <Duration>[];

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

  void failLatest() => events[nextId - 1]!.addError(
    PlatformException(
      code: 'VideoError',
      message: 'Decoder unsupported format',
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
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    this.speed = speed;
  }

  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {
    pauses++;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add(position);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}

const _vod = VodItem(
  id: 'player-test',
  name: '播放器测试',
  lines: [
    PlayLine(
      name: '测试线路',
      episodes: [
        Episode(name: '第一集', url: 'https://example.com/1.mp4'),
        Episode(name: '第二集', url: 'https://example.com/2.mp4'),
      ],
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester,
  TvSkinId skin, {
  bool autoPlay = true,
  int introMs = 0,
  int startMs = 0,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = AppController();
  controller.autoPlay = autoPlay;
  if (introMs > 0) {
    SharedPreferences.setMockInitialValues({});
    await controller.storage.init();
    await SkipPreferences(controller.storage)
        .save('test', _vod.id, SkipPreference(introMs: introMs));
  }
  final library = LibraryStore();
  addTearDown(controller.dispose);
  addTearDown(library.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        // 与应用同寿命：播放器 dispose 的异步历史保存完成后再释放 store。
        ChangeNotifierProvider<LibraryStore>.value(value: library),
      ],
      child: MaterialApp(
        theme: AppTheme.forSkin(skin),
        navigatorObservers: [kRouteObserver],
        home: PlayerPage(
          startPositionMs: startMs,
          vod: _vod,
          site: SiteConfig(key: 'test', name: '测试', api: ''),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _ready(WidgetTester tester, _VideoPlatform platform) async {
  platform.initializeLatest();
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

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

  for (final visible in [true, false]) {
    testWidgets('子路由返回：控制层 visible=$visible 恢复对应状态焦点', (tester) async {
      await _mount(tester, TvSkinId.smartisan);
      await _ready(tester, platform);
      if (!visible) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      }
      final navigator = Navigator.of(tester.element(find.byType(PlayerPage)));
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
        visible ? 'playerPlay' : 'playerRoot',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final opaque in [true, false]) {
    testWidgets('子路由覆盖 opaque=$opaque 期间自动隐藏到期不抢焦', (tester) async {
      await _mount(tester, TvSkinId.smartisan);
      await _ready(tester, platform);
      final navigator = Navigator.of(tester.element(find.byType(PlayerPage)));
      final cover = FocusNode(debugLabel: 'playerCover');
      addTearDown(cover.dispose);
      navigator.push<void>(
        PageRouteBuilder<void>(
          opaque: opaque,
          pageBuilder: (_, _, _) => Scaffold(
            body: Focus(
              focusNode: cover,
              autofocus: true,
              child: const Text('覆盖点播页'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(cover.hasPrimaryFocus, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerCover');
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('首播就绪立即获得可见焦点，确定键直接暂停', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    await _ready(tester, platform);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    final before = platform.pauses;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(platform.pauses, greaterThan(before));
    expect(find.text('播放'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('控制层可见但焦点掉在页面根时，方向键把焦点拉回播放键', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');

    // 模拟抢焦失败：焦点停在页面根，控制层仍然可见。
    final root = tester
        .widget<Focus>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Focus && widget.focusNode?.debugLabel == 'playerRoot',
          ),
        )
        .focusNode!;
    root.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('片头跳过点应用到后端，首次续播位置优先', (tester) async {
    await _mount(tester, TvSkinId.smartisan, introMs: 60000, startMs: 120000);
    await _ready(tester, platform);
    expect(platform.seeks, contains(const Duration(minutes: 2)));
    expect(platform.seeks, isNot(contains(const Duration(minutes: 1))));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('进度条长按方向键重复事件继续快进', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    final progress = find.byWidgetPredicate(
      (widget) =>
          widget is TvFocusable &&
          (widget.semanticLabel?.startsWith('播放进度，') ?? false),
    );
    final node = tester
        .widget<Focus>(
          find.descendant(of: progress, matching: find.byType(Focus)).first,
        )
        .focusNode!;
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final count = platform.seeks.length;
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(platform.seeks.length, greaterThan(count));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('关闭自动播放后首播保持暂停且确定键可开始', (tester) async {
    await _mount(tester, TvSkinId.smartisan, autoPlay: false);
    await _ready(tester, platform);
    expect(find.text('播放'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('暂停'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('倍速选择应用到后端，比例选择关闭后保留状态', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    await tester.tap(find.text('1.0×'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2.0×'));
    await tester.pumpAndSettle();
    expect(platform.speed, 2);
    expect(find.text('2.0×'), findsOneWidget);
    await tester.tap(find.text('原始比例'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4:3'));
    await tester.pumpAndSettle();
    expect(find.text('4:3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('运行中解码失败中文提示并默认聚焦重试，返回先关闭错误层', (tester) async {
    await _mount(tester, TvSkinId.netflix);
    await _ready(tester, platform);
    platform.failLatest();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('设备无法播放此视频格式'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRetry');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('重试'), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRetry');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('首播失败和再次失败都聚焦重试，丢焦后方向键找回', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    platform.failLatest();
    await tester.pumpAndSettle();
    final retry = FocusManager.instance.primaryFocus!;
    expect(retry.debugLabel, 'playerRetry');

    // 模拟焦点落在错误层的作用域而不是按钮上。
    final scope = retry.enclosingScope!;
    retry.unfocus();
    await tester.pump();
    expect(scope.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(retry.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(platform.nextId, 2);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    platform.failLatest();
    await tester.pumpAndSettle();
    expect(retry.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('自动隐藏和 ESC 隐藏均归还根焦点，方向键一次唤醒到播放按钮', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    expect(find.text('暂停'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('隐藏时媒体播放暂停键执行操作并恢复按钮焦点', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    final before = platform.pauses;
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    await tester.pump();
    expect(platform.pauses, greaterThan(before));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('选集面板隔离控制层，换集就绪后归还选集按钮焦点', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    final trigger = tester.widget<TvFocusable>(
      find
          .ancestor(
            of: find.text('选集 / 线路'),
            matching: find.byType(TvFocusable),
          )
          .first,
    );
    trigger.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(trigger.focusNode!.canRequestFocus, isFalse);
    await tester.tap(find.text('第二集').last);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    await _ready(tester, platform);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episodeTrigger');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放器被新路由盖住时硬件唤醒不截获方向键', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final nextFocus = FocusNode(debugLabel: 'cover');
    addTearDown(nextFocus.dispose);
    var downs = 0;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Focus(
            focusNode: nextFocus,
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent) downs++;
              return KeyEventResult.handled;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downs, 1);
    expect(nextFocus.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  for (final skin in TvSkinId.values) {
    testWidgets('${skin.name} 胶囊保留原生材质、白色前景与模糊预算', (tester) async {
      await _mount(tester, skin);
      await _ready(tester, platform);
      final surfaces = tester.widgetList<SkinSurface>(find.byType(SkinSurface));
      expect(surfaces.length, 8);
      expect(surfaces.every((surface) => surface.tint == null), isTrue);
      expect(surfaces.every((surface) => surface.floating), isTrue);
      expect(
        find.byType(BackdropFilter).evaluate().length,
        skinFor(skin).surfaceSkin.blurSigma > 0 ? 2 : 0,
      );
      final pause = tester.widget<Text>(find.text('暂停'));
      expect(pause.style?.color, Colors.white);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('控制层顶行 UP 回画面，任意方向键唤醒回播放键', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    // 顶行「返回」键 UP → 隐藏控制层回画面（控制层可见 → 隐藏的显式上行出口）。
    final backNode = tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byWidgetPredicate(
                  (widget) =>
                      widget is TvFocusable && widget.semanticLabel == '返回',
                ),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    backNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    expect(find.text('暂停'), findsNothing);
    // 方向键唤醒 → 播放键（状态机：隐藏 = 焦点在页面根）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('控制层顶行 DOWN 进播放胶囊，功能行 DOWN 回画面', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    // 顶行 DOWN → 中部播放胶囊（默认落播放/暂停键）。
    final backNode = tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byWidgetPredicate(
                  (widget) =>
                      widget is TvFocusable && widget.semanticLabel == '返回',
                ),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    backNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerPlay');
    // 功能行（页面最下沿）DOWN → 隐藏控制层回画面。
    final trigger = tester.widget<TvFocusable>(
      find
          .ancestor(
            of: find.text('选集 / 线路'),
            matching: find.byType(TvFocusable),
          )
          .first,
    );
    trigger.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'playerRoot');
    expect(find.text('选集 / 线路'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('选集面板工具行 DOWN 进网格，网格首行 UP 回工具行', (tester) async {
    await _mount(tester, TvSkinId.smartisan);
    await _ready(tester, platform);
    final trigger = tester.widget<TvFocusable>(
      find
          .ancestor(
            of: find.text('选集 / 线路'),
            matching: find.byType(TvFocusable),
          )
          .first,
    );
    trigger.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    // 工具行「画中画」DOWN → 网格当前集（面板主体入口）。
    final pipNode = tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byWidgetPredicate(
                  (widget) =>
                      widget is TvFocusable && widget.semanticLabel == '画中画',
                ),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    pipNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-0');
    // 网格首行 UP → 回工具行（面板内部投递链的返程）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'panelTool-0');
    await tester.pumpWidget(const SizedBox());
  });
}
