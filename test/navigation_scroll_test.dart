// 收藏、历史与直播长列表的焦点预滚动回归。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/favorites_page.dart';
import 'package:tvbox_flutter/ui/pages/history_page.dart';
import 'package:tvbox_flutter/ui/pages/live_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/poster_card.dart';

class _LongLiveService extends LiveService {
  @override
  Future<LiveParseResult> load(LiveSource source) async {
    return LiveParseResult(
      title: source.name,
      groups: [
        LiveGroup(
          name: '滚动测试分组',
          channels: List.generate(
            60,
            (index) => LiveChannel(
              name: '滚动测试频道 ${index + 1}',
              urls: ['https://live.test/$index.m3u8'],
              sourceNames: const ['测试线路'],
              group: '滚动测试分组',
            ),
          ),
        ),
      ],
    );
  }
}

VodItem _vod(int index) => VodItem(
  id: '$index',
  name: '滚动测试影片 $index',
  sourceKey: 'test',
  sourceName: '测试站点',
);

HistoryEntry _historyEntry(int index) => HistoryEntry(
  vod: _vod(index),
  sourceKey: 'test',
  sourceName: '测试站点',
  lineName: '测试线路',
  lineIndex: 0,
  episodeName: '第${index + 1}集',
  episodeUrl: 'https://video.test/$index.m3u8',
  episodeIndex: index,
  positionMs: 1000,
  durationMs: 10000,
  updatedAt: DateTime(2026, 11, 20),
);

AppController _controller({bool withLiveSource = false}) =>
    AppController(storage: StorageService(), liveService: _LongLiveService())
      ..initialized = true
      ..config = AppConfig(
        sites: const [],
        parses: const [],
        lives: withLiveSource
            ? const [
                LiveSource(name: '测试直播源', url: 'https://live.test/list.m3u'),
              ]
            : const [],
      );

Widget _harness({
  required Widget page,
  required AppController controller,
  required LibraryStore library,
  bool disableAnimations = false,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<AppController>.value(value: controller),
    ChangeNotifierProvider<LibraryStore>.value(value: library),
  ],
  child: MaterialApp(
    theme: AppTheme.forSkin(TvSkinId.smartisan),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: Scaffold(body: page),
      ),
    ),
  ),
);

FocusNode _favoriteNode(WidgetTester tester, int index) => tester
    .widget<PosterCard>(
      find.byWidgetPredicate(
        (widget) => widget is PosterCard && widget.vod.name == '滚动测试影片 $index',
        skipOffstage: false,
      ),
    )
    .focusNode!;

FocusNode _historyNode(WidgetTester tester, int index) => tester
    .widget<TvFocusable>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TvFocusable &&
            widget.semanticLabel == '继续播放 滚动测试影片 $index',
        skipOffstage: false,
      ),
    )
    .focusNode!;

FocusNode _channelNode(WidgetTester tester, int index) => tester
    .widget<TvFocusable>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TvFocusable &&
            (widget.semanticLabel?.startsWith('滚动测试频道 ${index + 1}，') ?? false),
        skipOffstage: false,
      ),
    )
    .focusNode!;

ScrollPosition _scrollPosition(WidgetTester tester, Type viewType) {
  final view = find.byType(viewType).first;
  final scrollable = find.descendant(
    of: view,
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

Future<void> _sendQuickly(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('收藏网格快速连续 DOWN 按键沿最新目标索引继续', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = LibraryStore()..favorites.addAll(List.generate(60, _vod));
    await tester.pumpWidget(
      _harness(
        page: const FavoritesPage(),
        controller: _controller(),
        library: library,
      ),
    );
    await tester.pumpAndSettle();

    final position = _scrollPosition(tester, GridView);
    _favoriteNode(tester, 0).requestFocus();
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await _sendQuickly(tester, LogicalKeyboardKey.arrowDown);
    }
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(_favoriteNode(tester, 25)));
    expect(position.pixels, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('历史列表快速连续 DOWN 按键沿最新目标索引继续', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = LibraryStore()
      ..history.addAll(List.generate(40, _historyEntry));
    await tester.pumpWidget(
      _harness(
        page: const HistoryPage(),
        controller: _controller(),
        library: library,
      ),
    );
    await tester.pumpAndSettle();

    final position = _scrollPosition(tester, ListView);
    _historyNode(tester, 0).requestFocus();
    await tester.pump();
    for (var i = 0; i < 7; i++) {
      await _sendQuickly(tester, LogicalKeyboardKey.arrowDown);
    }
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(_historyNode(tester, 7)));
    expect(position.pixels, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('直播网格连续按键在预滚动期间按目标格续投', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller(withLiveSource: true);
    await tester.pumpWidget(
      _harness(
        page: const LivePage(),
        controller: controller,
        library: LibraryStore(),
      ),
    );
    await tester.pumpAndSettle();

    final position = _scrollPosition(tester, GridView);
    _channelNode(tester, 0).requestFocus();
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await _sendQuickly(tester, LogicalKeyboardKey.arrowDown);
    }
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(_channelNode(tester, 36)));
    expect(position.pixels, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('减弱动态时收藏网格预滚动立即 jumpTo', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = LibraryStore()..favorites.addAll(List.generate(30, _vod));
    await tester.pumpWidget(
      _harness(
        page: const FavoritesPage(),
        controller: _controller(),
        library: library,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    final position = _scrollPosition(tester, GridView);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(position.pixels, greaterThan(0));
    expect(FocusManager.instance.primaryFocus, same(_favoriteNode(tester, 5)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收藏网格预滚动使用 ease-out 曲线而非瞬时跳转', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = LibraryStore()..favorites.addAll(List.generate(30, _vod));
    await tester.pumpWidget(
      _harness(
        page: const FavoritesPage(),
        controller: _controller(),
        library: library,
      ),
    );
    await tester.pumpAndSettle();

    final position = _scrollPosition(tester, GridView);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(position.pixels, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final halfway = position.pixels;
    await tester.pumpAndSettle();
    expect(halfway, greaterThan(position.pixels * 0.7));
    expect(halfway, lessThan(position.pixels));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('离开收藏网格后旧预滚动不会延迟抢焦', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = LibraryStore()..favorites.addAll(List.generate(40, _vod));
    await tester.pumpWidget(
      _harness(
        page: const FavoritesPage(),
        controller: _controller(),
        library: library,
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    final back = tester.widget<TvFocusable>(
      find.byWidgetPredicate(
        (widget) => widget is TvFocusable && widget.semanticLabel == '返回',
      ),
    );
    expect(FocusManager.instance.primaryFocus, same(back.focusNode));
    await tester.pumpWidget(const SizedBox());
  });
}
