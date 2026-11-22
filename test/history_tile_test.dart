// 历史行卡片（`_HistoryTile`）有界高度回归测试 + 焦点体系重建投递表回归
// （docs/focus-system-spec.md §3/§4/§5）。
//
// 背景（有界高度）：`_HistoryTile` 位于 `ListView.separated`（滚动方向高度无界），
// 其 Row 内 Expanded 内 Column 里的 `Spacer`（Expanded flex）拿到的是无界高度，
// debug 下抛 `RenderFlex children have non-zero flex but incoming height constraints are
// unbounded`；release 下 Spacer 塌缩、进度条与时间行贴顶。
//
// 修复：把整行包进 `SizedBox(height: _posterHeight)`，用竖版海报高度约束 Column，
// Spacer 拿到有界高度后正常把进度条/时间行压到底部。
//
// 焦点（2026-11-19 重建）：单列行卡 + 行内删除钮 + 页头的方向键投递表——
// 行卡 UP/DOWN 逐行（页面显式投递 + ensureVisible，缓存区外的行先滚动
// 再补投）；行卡 RIGHT 直达本行删除钮；删除后焦点落相邻行；页面左缘 /
// 行尾 / 顶缘 / 页面底的边界吞键。
//
// 用法：flutter test test/history_tile_test.dart   （期望全绿）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/ui/pages/history_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

AppController buildController() {
  return AppController(storage: StorageService())..initialized = true;
}

/// 复刻 main.dart 的挂载方式（MultiProvider → Consumer → MaterialApp.forSkin），
/// 与 focus_fix_test.dart 的 harness 同构；[library] 覆盖默认空 store。
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

LibraryStore historyLibrary() {
  final library = LibraryStore();
  library.history.addAll(
    List.generate(
      2,
      (index) => HistoryEntry(
        vod: vod(index),
        sourceKey: 'test',
        sourceName: '测试站点',
        lineName: '线路一',
        lineIndex: 0,
        episodeName: '第${index + 1}集',
        episodeUrl: 'https://video.test/$index.m3u8',
        episodeIndex: index,
        positionMs: 60000,
        durationMs: 600000,
        updatedAt: DateTime(2026, 11, 14 - index),
      ),
    ),
  );
  return library;
}

/// 长历史（8 条）：行高 216+padding，视口只见 ~2 行，用于验证跨缓存区
/// 的显式投递与滚动揭示。
LibraryStore longHistoryLibrary() {
  final library = LibraryStore();
  library.history.addAll(
    List.generate(
      8,
      (index) => HistoryEntry(
        vod: vod(index),
        sourceKey: 'test',
        sourceName: '测试站点',
        lineName: '线路一',
        lineIndex: 0,
        episodeName: '第${index + 1}集',
        episodeUrl: 'https://video.test/$index.m3u8',
        episodeIndex: index,
        positionMs: 60000,
        durationMs: 600000,
        updatedAt: DateTime(2026, 11, 14 - index),
      ),
    ),
  );
  return library;
}

Finder _action(String label) => find.byWidgetPredicate(
  (widget) => widget is TvFocusable && widget.semanticLabel == label,
);

/// 行卡焦点节点（页面持有，挂在行卡的 TvFocusable 上）。
FocusNode _rowNode(WidgetTester tester, int index) =>
    tester.widget<TvFocusable>(_action('继续播放 测试影片 $index')).focusNode!;

/// 行内删除钮焦点节点。
FocusNode _deleteNode(WidgetTester tester, int index) =>
    tester.widget<TvFocusable>(_action('删除历史记录 测试影片 $index')).focusNode!;

Future<void> _send(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('历史行卡片有界高度：Spacer 不再抛无界约束异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const HistoryPage(), library: historyLibrary()),
    );
    await tester.pumpAndSettle();

    // 修复前：ListView 的无界高度传进 Column，Spacer 抛 unbounded 约束异常。
    expect(tester.takeException(), isNull);

    // 两张竖版海报行卡都渲染出来，片名可见。
    expect(find.text('测试影片 0'), findsOneWidget);
    expect(find.text('测试影片 1'), findsOneWidget);

    // 进度条可见（修复前 release 下会塌缩贴顶）。
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

    // 时间/操作行可见：进度条下方的「继续」操作按钮。
    expect(find.text('继续'), findsNWidgets(2));

    // 进度条有真实几何（高度 4、宽度 > 0），而非塌缩成零高幽灵。
    final rect = tester.getRect(find.byType(LinearProgressIndicator).first);
    expect(rect.height, greaterThan(0));
    expect(rect.width, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
  });

  // ===== 2026-11-19 焦点体系重建：历史页方向键投递表回归 =====

  testWidgets('入口焦点落第一行，UP 到页头返回键，返回键 DOWN 回记忆行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(
        buildController(),
        const HistoryPage(),
        library: historyLibrary(),
      ),
    );
    await tester.pumpAndSettle();

    final first = _rowNode(tester, 0);
    expect(first.hasFocus, isTrue, reason: '进页默认焦点应落第一行');

    // 首行 UP → 页头返回键（层级上升，落点稳定）。
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('返回')).focusNode),
      reason: '首行 UP 应落返回键',
    );

    // 返回键 DOWN → 网格记忆行（回到第一行）。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(first),
      reason: '页头 DOWN 应回记忆行',
    );

    // 页头左右：返回 RIGHT → 清空；清空 LEFT → 返回；清空 RIGHT 吞键。
    await _send(tester, LogicalKeyboardKey.arrowUp);
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('清空播放历史')).focusNode),
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('清空播放历史')).focusNode),
      reason: '页头行尾 RIGHT 应吞键',
    );
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('返回')).focusNode),
    );
    // 返回键 LEFT：页面左缘吞键（推入式路由，无侧栏可达）。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<TvFocusable>(_action('返回')).focusNode),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('行卡 RIGHT 直达本行删除钮，删除钮 LEFT 回行卡、RIGHT 吞键', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(
        buildController(),
        const HistoryPage(),
        library: historyLibrary(),
      ),
    );
    await tester.pumpAndSettle();

    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_deleteNode(tester, 0)),
      reason: '行卡 RIGHT 应直达本行删除钮',
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus,
      same(_deleteNode(tester, 0)),
      reason: '删除钮 RIGHT 应吞键（行尾）',
    );
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      FocusManager.instance.primaryFocus,
      same(_rowNode(tester, 0)),
      reason: '删除钮 LEFT 应回本行行卡',
    );

    // 行卡 LEFT：页面左缘吞键（单列行卡）。
    await _send(tester, LogicalKeyboardKey.arrowLeft);
    expect(FocusManager.instance.primaryFocus, same(_rowNode(tester, 0)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('删除钮 UP/DOWN 走相邻行卡；末行以下吞键', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(
        buildController(),
        const HistoryPage(),
        library: historyLibrary(),
      ),
    );
    await tester.pumpAndSettle();

    // 第 1 行删除钮 DOWN → 第 2 行行卡；再 DOWN（末行）吞键。
    _deleteNode(tester, 0).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_rowNode(tester, 1)),
      reason: '删除钮 DOWN 应落下一行行卡',
    );
    await _send(tester, LogicalKeyboardKey.arrowRight);
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_deleteNode(tester, 1)),
      reason: '末行删除钮 DOWN 应吞键（页面底）',
    );
    // 末行删除钮 UP → 上一行行卡。
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus, same(_rowNode(tester, 0)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('删除历史记录后焦点落到相邻行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = longHistoryLibrary();
    await tester.pumpWidget(
      harness(buildController(), const HistoryPage(), library: library),
    );
    await tester.pumpAndSettle();

    // 焦点在第 2 行（index 1）：RIGHT 进删除钮，OK 删除。
    _rowNode(tester, 1).requestFocus();
    await tester.pumpAndSettle();
    await _send(tester, LogicalKeyboardKey.arrowRight);
    expect(FocusManager.instance.primaryFocus, same(_deleteNode(tester, 1)));
    await _send(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(library.history.length, 7);
    expect(find.text('测试影片 1'), findsNothing);
    // min(_lastIndex=1, length-1=6) = 1：删完后下标 1 是原第 3 条。
    expect(
      FocusManager.instance.primaryFocus,
      same(_rowNode(tester, 2)),
      reason: '删除后焦点应落到相邻行（min(_lastIndex, length-1)）',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('长历史跨缓存区 UP/DOWN 显式投递，列表随焦点滚动', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(
        buildController(),
        const HistoryPage(),
        library: longHistoryLibrary(),
      ),
    );
    await tester.pumpAndSettle();

    // 逐行 DOWN 到第 8 行（index 7）：目标行多在缓存区外，走
    // 「先滚动再补投」路径；列表必须真的滚动过。
    for (var i = 0; i < 7; i++) {
      await _send(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(
      FocusManager.instance.primaryFocus,
      same(_rowNode(tester, 7)),
      reason: '连续 DOWN 应逐行到达最后一行',
    );
    final scrollable = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0), reason: '列表应随焦点滚动');

    // 末行以下 DOWN 吞键；UP 逐行回。
    await _send(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus,
      same(_rowNode(tester, 7)),
      reason: '末行以下 DOWN 应吞键（页面底）',
    );
    await _send(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus, same(_rowNode(tester, 6)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('入口焦点注入（entryFocus 挂到首行）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entry = FocusNode(debugLabel: 'history-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(
      harness(
        buildController(),
        HistoryPage(entryFocus: entry),
        library: historyLibrary(),
      ),
    );
    await tester.pumpAndSettle();
    expect(entry.hasFocus, isTrue, reason: 'entryFocus 应挂到首行行卡');
    await tester.pumpWidget(const SizedBox());
  });
}
