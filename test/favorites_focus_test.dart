// 收藏页焦点体系重建投递表回归（docs/focus-system-spec.md §3/§4/§5）。
//
// 覆盖：入口焦点、网格显式投递（UP/DOWN 按 index ± 列数）、首行 UP 回
// 页头、页头 DOWN 回网格记忆格、最左列/行尾/顶缘/页面底的边界吞键、
// 编辑模式下「海报 ↔ 删除钮」焦点链、删除后焦点落相邻海报。
//
// 用法：flutter test test/favorites_focus_test.dart   （期望全绿）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/ui/pages/favorites_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/poster_card.dart';

AppController buildController() {
  return AppController(storage: StorageService())..initialized = true;
}

Widget harness(AppController controller, Widget home, {LibraryStore? library}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(
        create: (_) => library ?? LibraryStore(),
      ),
    ],
    child: Consumer<AppController>(
      builder: (context, c, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.forSkin(c.skinId),
        builder: (context, child) {
          if (child == null) return const SizedBox.shrink();
          return TvCanvas(child: child);
        },
        home: home,
      ),
    ),
  );
}

VodItem vod(int index) => VodItem(
  id: '$index',
  name: '测试影片 $index',
  sourceKey: 'test',
  sourceName: '测试站点',
);

LibraryStore favoritesLibrary({int count = 12}) {
  final library = LibraryStore();
  library.favorites.addAll(List.generate(count, vod));
  return library;
}

Finder _action(String label) => find.byWidgetPredicate(
  (widget) => widget is TvFocusable && widget.semanticLabel == label,
);

/// 第 [index] 张海报的焦点节点（页面持有；skipOffstage false 让缓存区
/// 外的海报也能取到节点）。
FocusNode _posterNode(WidgetTester tester, int index) => tester
    .widget<PosterCard>(
      find.byWidgetPredicate(
        (widget) =>
            widget is PosterCard && widget.vod.name == '测试影片 $index',
        skipOffstage: false,
      ),
    )
    .focusNode!;

/// 第 [index] 张海报的「取消收藏」删除钮节点（编辑模式）。
FocusNode _deleteNode(WidgetTester tester, int index) => tester
    .widget<TvFocusable>(_action('取消收藏 测试影片 $index'))
    .focusNode!;

Future<void> _send(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('入口焦点落第一张海报，DOWN 按列数下行、UP 回行首同列', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(),
          library: favoritesLibrary()),
    );
    await tester.pumpAndSettle();

    final first = _posterNode(tester, 0);
    expect(first.hasFocus, isTrue, reason: '进页默认焦点应落第一张海报');

    // smartisan 皮肤下网格 5 列（见 favorites_page `_posterColumns`）。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 5)),
      reason: 'DOWN 应落到下一行同列（index + 列数）',
    );
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(first),
      reason: 'UP 应回到上一行同列',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('首行 UP 回页头返回键，返回键 DOWN 回网格记忆格', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(),
          library: favoritesLibrary()),
    );
    await tester.pumpAndSettle();

    final first = _posterNode(tester, 0);
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('返回')).focusNode),
      reason: '首行 UP 应落页头返回键',
    );

    // 页头左右：返回 RIGHT → 编辑；编辑 LEFT → 返回。
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('编辑收藏')).focusNode),
    );
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('返回')).focusNode),
    );

    // 返回键 DOWN → 网格记忆格（回到第一张海报）。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(first),
      reason: '页头 DOWN 应回网格记忆格',
    );

    // 返回键 LEFT：页面左缘吞键（推入式路由，壳层侧栏不在按键链上）。
    await _send(tester, LogicalKeyboardKey.arrowUp);
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('返回')).focusNode),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('行内 LEFT/RIGHT 显式移动，最左列 LEFT 与行尾 RIGHT 吞键', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(),
          library: favoritesLibrary()),
    );
    await tester.pumpAndSettle();

    // 行内右移：0 → 1 → 2。
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 1)),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 2)),
    );
    // 行内左移：2 → 1。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 1)),
    );
    // 最左列 LEFT：吞键（页面左缘，焦点原地不动）。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 0)),
      reason: '最左列 LEFT 应吞键（页面左缘）',
    );
    // 行尾 RIGHT：吞键（第 5 格，index 4 是行尾）。
    await _send(tester, LogicalKeyboardKey.arrowRight);
    await _send(tester, LogicalKeyboardKey.arrowRight);
    await _send(tester, LogicalKeyboardKey.arrowRight);
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 4)),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 4)),
      reason: '行尾 RIGHT 应吞键',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('末行以下 DOWN 吞键（页面底）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(),
          library: favoritesLibrary()),
    );
    await tester.pumpAndSettle();

    // 12 张海报 / 5 列 = 3 行（5/5/2）：DOWN 到末行（index 10），再
    // DOWN 吞键。
    _posterNode(tester, 10).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 10)),
      reason: '末行以下 DOWN 应吞键（页面底）',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('编辑模式：海报 RIGHT 直达删除钮，删除钮 LEFT/RIGHT/DOWN 成链', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(),
          library: favoritesLibrary()),
    );
    await tester.pumpAndSettle();

    // 进编辑模式，焦点回第一张海报。
    await tester.tap(_action('编辑收藏'));
    await tester.pumpAndSettle();
    _posterNode(tester, 0).requestFocus();
    await tester.pumpAndSettle();

    // 海报 RIGHT → 本卡删除钮。
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_deleteNode(tester, 0)),
      reason: '编辑模式下海报 RIGHT 应直达本卡删除钮',
    );
    // 删除钮 LEFT → 本卡海报；RIGHT → 下一张海报。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 0)),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 1)),
      reason: '删除钮 RIGHT 应落下一张海报',
    );
    // 删除钮 DOWN → 下一行同列海报（0 + 5 = 5）。
    _deleteNode(tester, 0).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 5)),
      reason: '删除钮 DOWN 应落下一行同列海报',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('取消收藏后焦点落到相邻海报', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = favoritesLibrary();
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(), library: library),
    );
    await tester.pumpAndSettle();

    await tester.tap(_action('编辑收藏'));
    await tester.pumpAndSettle();
    _posterNode(tester, 2).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_deleteNode(tester, 2)),
    );

    // OK 删除第 3 张（index 2）：剩 11 张，min(2, 10) = 2 → 下标 2 是
    // 原第 4 张。
    await _send(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(library.favorites.length, 11);
    expect(find.text('测试影片 2'), findsNothing);
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 3)),
      reason: '删除后焦点应落到相邻海报（min(_lastIndex, length-1)）',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网格随焦点滚动（跨缓存区投递）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const FavoritesPage(),
          library: favoritesLibrary(count: 20)),
    );
    await tester.pumpAndSettle();

    // 20 张 / 5 列 = 4 行：逐行 DOWN 到最后一行（index 15），网格滚动。
    for (var i = 0; i < 3; i++) {
      await _send(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(
      FocusManager.instance.primaryFocus,
      same(_posterNode(tester, 15)),
      reason: '连续 DOWN 应逐行到达 index 15',
    );
    final scrollable = find
        .descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0), reason: '网格应随焦点滚动');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('入口焦点注入（entryFocus 挂到第一张海报）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entry = FocusNode(debugLabel: 'favorites-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      harness(
        buildController(),
        FavoritesPage(entryFocus: entry),
        library: favoritesLibrary(),
      ),
    );
    await tester.pumpAndSettle();
    expect(entry.hasFocus, isTrue, reason: 'entryFocus 应挂到第一张海报');
    await tester.pumpWidget(const SizedBox());
  });
}