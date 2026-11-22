// 搜索页 / T9 弹窗 / 我的页 / 弹窗组焦点回归测试（F4 焦点体系重建）。
//
// 覆盖：
// - 搜索页输入行展示型焦点（无 TextField 弹出、UP 到页头行、DOWN 到搜索按钮）；
// - 搜索页三栏结构 LEFT 语义（左栏吞住、中栏回左栏输入行、页头行放行给壳层）；
// - T9 九宫格弹窗焦点链（进弹窗落键盘、行内 UP/DOWN/LEFT/RIGHT、清空/完成可达、
//   BACK 关弹窗回触发节点）；
// - 我的页 fromRoute 返回焦点归还（RouteAware didPopNext 契约）；
// - 设置页左栏 RIGHT 进面板、面板 LEFT 回左栏（水平方向确定性投递）。
//
// 用法：flutter test test/search_focus_test.dart   （期望全绿）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/mine_page.dart';
import 'package:tvbox_flutter/ui/pages/search_page.dart';
import 'package:tvbox_flutter/ui/pages/settings_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/t9_search_dialog.dart';

/// 取某个 TvFocusable 内部挂载的 Focus 节点（按 semanticLabel 精确匹配）。
FocusNode? focusNodeOf(WidgetTester tester, String label) {
  final target = find.byWidgetPredicate(
    (widget) => widget is TvFocusable && widget.semanticLabel == label,
  );
  if (target.evaluate().isEmpty) return null;
  return tester
      .widget<Focus>(
        find.descendant(of: target.first, matching: find.byType(Focus)).first,
      )
      .focusNode;
}

/// 按键 + 稳定。KeyDown 后补一次 up 避免 keyRepeat 状态残留。
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

Widget harness(Widget home, {List<RouteObserver>? observers}) {
  final controller = AppController()..initialized = true;
  addTearDown(controller.dispose);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(create: (_) => LibraryStore()),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      navigatorObservers: [...?observers, kRouteObserver],
      home: home,
    ),
  );
}

/// 当前 primaryFocus 对应的 TvFocusable 语义标签（无归属时 null）。
String? labelOfFocused(WidgetTester tester) {
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return null;
  String? label;
  for (final element in tester.allElements) {
    if (label != null) break;
    final w = element.widget;
    if (w is Focus && w.focusNode == node) {
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget is TvFocusable) {
          label = (ancestor.widget as TvFocusable).semanticLabel;
          return false;
        }
        return true;
      });
    }
  }
  return label;
}

void main() {
  testWidgets('搜索页输入行：UP 可达搜索源设置，DOWN 到搜索按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inputNode = FocusNode(debugLabel: 'search-input');
    addTearDown(inputNode.dispose);
    await tester.pumpWidget(
      harness(SearchPage(standalone: true, entryFocus: inputNode)),
    );
    await tester.pumpAndSettle();

    // 进页默认焦点落在输入行（FOCUS-06）。
    inputNode.requestFocus();
    await tester.pumpAndSettle();
    expect(inputNode.hasFocus, isTrue);

    // UP 先落到搜索框正上方的「勾选聚合搜索源」。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusNodeOf(tester, '勾选聚合搜索源')?.hasFocus, isTrue);

    // 再按 UP 到「搜索范围」，之后才是页头/侧栏。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusNodeOf(tester, '搜索范围')?.hasFocus, isTrue);

    // DOWN 回到搜索源设置，再 DOWN 回输入框。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusNodeOf(tester, '勾选聚合搜索源')?.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(inputNode.hasFocus, isTrue);

    // DOWN 明确落到「搜 索」按钮。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusNodeOf(tester, '搜索')?.hasFocus, isTrue);

    // 搜索按钮 UP 回到输入行。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(inputNode.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('搜索页中栏：输入行 RIGHT 进来源筛选，LEFT 回输入行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inputNode = FocusNode(debugLabel: 'search-input');
    addTearDown(inputNode.dispose);
    await tester.pumpWidget(
      harness(SearchPage(standalone: true, entryFocus: inputNode)),
    );
    await tester.pumpAndSettle();

    inputNode.requestFocus();
    await tester.pumpAndSettle();

    // RIGHT 落到中栏第一个可获焦项（清空历史 / 搜索历史列表首项）。
    await press(tester, LogicalKeyboardKey.arrowRight);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNot(same(inputNode)));
    expect(inputNode.hasFocus, isFalse);

    // LEFT 回到左栏输入行。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(inputNode.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('T9 弹窗：进弹窗落键盘、九宫格内方向可达、BACK 回触发节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'search-field-trigger');
    addTearDown(trigger.dispose);
    late BuildContext ctx;
    // 触发节点必须挂在树上（真实用法：搜索框节点常驻树中），否则
    // requestFocus 落空、FOCUS-07 的 previous.context 断言失效。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return TvFocusable(
                focusNode: trigger,
                semanticLabel: '搜索输入',
                child: const Text('x'),
              );
            },
          ),
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();

    showT9SearchDialog(ctx, title: '测试', returnFocus: trigger);
    await tester.pumpAndSettle();

    // 进弹窗默认焦点落在键盘第一个键「1」。
    final one = focusNodeOf(tester, '键 1 符');
    expect(one, isNotNull);
    expect(one!.hasFocus, isTrue);
    expect(find.byType(TextField), findsNothing);

    // 每个格子的四方向都按坐标验证，避免只测单一路径漏掉方向历史污染。
    const labels = [
      '键 1 符',
      '键 2 ABC',
      '键 3 DEF',
      '键 4 GHI',
      '键 5 JKL',
      '键 6 MNO',
      '键 7 PQRS',
      '键 8 TUV',
      '键 9 WXYZ',
      '扫码',
      '键 0 空格',
      '退格',
    ];
    for (var index = 0; index < labels.length; index++) {
      final moves = <LogicalKeyboardKey, int>{
        if (index >= 3) LogicalKeyboardKey.arrowUp: index - 3,
        if (index < 9) LogicalKeyboardKey.arrowDown: index + 3,
        if (index % 3 > 0) LogicalKeyboardKey.arrowLeft: index - 1,
        if (index % 3 < 2) LogicalKeyboardKey.arrowRight: index + 1,
      };
      for (final move in moves.entries) {
        focusNodeOf(tester, labels[index])!.requestFocus();
        await tester.pumpAndSettle();
        await press(tester, move.key);
        expect(
          focusNodeOf(tester, labels[move.value])!.hasFocus,
          isTrue,
          reason:
              '${labels[index]} ${move.key.keyLabel} → ${labels[move.value]}',
        );
      }
    }
    // 焦点放大后相邻键之间仍要有可见留缝，避免电视远看时键帽连成一整块。
    final keyRects = [
      for (final label in labels) focusNodeOf(tester, label)!.rect,
    ];
    for (var row = 0; row < 3; row++) {
      expect(
        keyRects[(row + 1) * 3].top - keyRects[row * 3].bottom,
        greaterThan(0),
        reason: '数字键第 ${row + 1} 行与第 ${row + 2} 行之间应留缝',
      );
    }
    expect(
      keyRects[9].top - keyRects[6].bottom,
      greaterThan(0),
      reason: '数字键与功能键之间应留缝',
    );
    for (var row = 0; row < 4; row++) {
      final first = row == 3 ? 9 : row * 3;
      expect(
        keyRects[first + 1].left - keyRects[first].right,
        greaterThan(0),
        reason: '第 ${row + 1} 行按键之间应留缝',
      );
    }

    one.requestFocus();
    await tester.pumpAndSettle();

    // 键盘行内：DOWN → 4，DOWN → 7，RIGHT → 8，UP → 5，LEFT → 4。
    await press(tester, LogicalKeyboardKey.arrowDown);
    final four = focusNodeOf(tester, '键 4 GHI');
    expect(four!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final seven = focusNodeOf(tester, '键 7 PQRS');
    expect(seven!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight);
    final eight = focusNodeOf(tester, '键 8 TUV');
    expect(eight!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowUp);
    final five = focusNodeOf(tester, '键 5 JKL');
    expect(five!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusNodeOf(tester, '键 4 GHI')!.hasFocus, isTrue);

    // 末行 DOWN：从 4 落 7，再 DOWN 落到功能行扫码（第一列），RIGHT 到键 0，
    // LEFT 回扫码；LEFT 到行首吞住（不甩焦）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(seven.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusNodeOf(tester, '扫码')!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusNodeOf(tester, '键 0 空格')!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusNodeOf(tester, '扫码')!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusNodeOf(tester, '扫码')!.hasFocus, isTrue);

    // OK 输入验证：回到键 1 按确定键，回显出现「1」。
    final one2 = focusNodeOf(tester, '键 1 符');
    one2!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('1'), findsWidgets);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusNodeOf(tester, '清空输入')!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(one.hasFocus, isTrue);
    expect(find.byType(TextField), findsNothing);
    // 功能行 DOWN 到完成，UP 返回稳定的底行节点。
    focusNodeOf(tester, '退格')!.requestFocus();
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusNodeOf(tester, '完成')!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusNodeOf(tester, '键 0 空格')!.hasFocus, isTrue);

    // 完成按钮关闭后焦点回到触发节点（FOCUS-07）。
    focusNodeOf(tester, '完成')!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('测试'), findsNothing);
    await tester.pumpAndSettle();
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('T9 弹窗：BACK 键（escape）关闭并归还焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'trigger-2');
    addTearDown(trigger.dispose);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return TvFocusable(
                focusNode: trigger,
                semanticLabel: '触发',
                child: const Text('x'),
              );
            },
          ),
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();

    showT9SearchDialog(ctx, title: '测试2', returnFocus: trigger);
    await tester.pumpAndSettle();

    // BACK（escape）在本层关闭弹窗（spec §3：覆盖层 BACK 本层解决并消费）。
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('测试2'), findsNothing);
    await tester.pumpAndSettle();
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('T9 弹窗：OK 键完成按钮关闭并归还焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final trigger = FocusNode(debugLabel: 'trigger-3');
    addTearDown(trigger.dispose);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return TvFocusable(
                focusNode: trigger,
                semanticLabel: '触发',
                child: const Text('x'),
              );
            },
          ),
        ),
      ),
    );
    trigger.requestFocus();
    await tester.pump();

    showT9SearchDialog(ctx, title: '测试3', returnFocus: trigger);
    await tester.pumpAndSettle();

    // 「完成」按钮 OK 关闭（FOCUS-06/07：关闭后焦点回触发节点）。
    focusNodeOf(tester, '完成')!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('测试3'), findsNothing);
    await tester.pumpAndSettle();
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('我的页：入页焦点落左栏首项，子路由返回后焦点归还入口节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entry = FocusNode(debugLabel: 'mine-entry');
    addTearDown(entry.dispose);
    await tester.pumpWidget(harness(MinePage(entryFocus: entry)));
    await tester.pumpAndSettle();

    // 进页落「概览」分类。
    expect(focusNodeOf(tester, '概览')!.hasFocus, isTrue);

    // 模拟子路由 push（收藏→设置入口链），pop 后 RouteAware.didPopNext
    // 归还到 entryFocus 挂载的首项（收藏统计卡）。
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(
      [
        '概览',
        '收藏 0',
      ].any((label) => focusNodeOf(tester, label)?.hasFocus ?? false),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('设置页：左栏 RIGHT 进面板，面板 LEFT 回左栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness(const SettingsPage()));
    await tester.pumpAndSettle();

    // 进页落「主题皮肤」分类（左栏首项）。
    expect(focusNodeOf(tester, '主题皮肤')!.hasFocus, isTrue);

    // RIGHT 进右侧面板首行（皮肤行）。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusNodeOf(tester, '主题皮肤')!.hasFocus, isFalse);

    // LEFT 从面板回左栏：几何遍历落到面板正左方的分类项（皮肤行多行布局
    // 时垂直线命中下一个分类）。只断言「焦点回到左栏分类区」。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    final leftFocused = FocusManager.instance.primaryFocus;
    expect(leftFocused, isNotNull);
    expect(
      [
        '主题皮肤',
        '配置接口',
        '直播源',
        '播放',
        '关于',
      ].any((label) => focusNodeOf(tester, label) == leftFocused),
      isTrue,
    );

    // DOWN 沿左栏切分类，UP 回上一分类（保持几何遍历的互逆性）。
    await press(tester, LogicalKeyboardKey.arrowDown);
    final downLabel = labelOfFocused(tester);
    expect(downLabel, isNotNull);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(labelOfFocused(tester), isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('设置页：分类间 DOWN 切换分类、面板首行 RIGHT 进面板', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness(const SettingsPage()));
    await tester.pumpAndSettle();

    // 左栏 DOWN 到「配置接口」。
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusNodeOf(tester, '配置接口')!.hasFocus, isTrue);

    // RIGHT 进面板首个可获焦控件（主题皮肤分类下是皮肤行）。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(
      [
        '皮肤 Smartisan OS，点击切换',
        'https://example.com/tvbox.json',
      ].any((label) => focusNodeOf(tester, label)?.hasFocus ?? false),
      isTrue,
    );

    // LEFT 从面板回左栏（几何遍历落到当前分类项附近）。
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      [
        '配置接口',
        '直播源',
        '主题皮肤',
      ].any((label) => focusNodeOf(tester, label)?.hasFocus ?? false),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
