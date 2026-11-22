// 设置页行内按钮焦点回归测试。
//
// 背景：settings_page.dart 的 `_RowButtons` 曾用裸 `FilledButton` /
// `OutlinedButton` 渲染「上传背景图」「恢复默认」等按钮，这些 Material 按钮
// 在 TV 上没有遥控器焦点态、也点不到（违反 AGENTS.md §3 硬性规则 1）。
//
// 修复：改由统一的 `TvFocusable` 承载焦点视觉 + OK 键 onTap。本测试锁死：
// 两个按钮各是一个可获焦的 `TvFocusable`，焦点能落到它们，OK 键能触发 onTap。
//
// 用法：flutter test test/settings_buttons_test.dart   （期望全绿）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/ui/pages/settings_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

AppController buildController() {
  return AppController(storage: StorageService())..initialized = true;
}

/// 复刻 main.dart 的挂载方式（MultiProvider → Consumer → MaterialApp.forSkin），
/// 与 settings_back_test.dart 的 harness 同构。
Widget harness(AppController controller, Widget home) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(create: (_) => LibraryStore()),
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

/// 把一个页面 push 到根导航器上（复刻真实进入路径）。
NavigatorState pushPage(WidgetTester tester, Widget page) {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.push(MaterialPageRoute<void>(builder: (_) => page));
  return navigator;
}

/// 找到指定 semanticLabel 的 [TvFocusable] 内部 [Focus] 节点。
FocusNode focusNodeOf(WidgetTester tester, String label) {
  final focusFinder = find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is TvFocusable && w.semanticLabel == label,
    ),
    matching: find.byType(Focus),
  );
  return tester.widget<Focus>(focusFinder.first).focusNode!;
}

void main() {
  testWidgets('遥控器打开点播聚合并看到运行状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = buildController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    final navigator = pushPage(tester, const SettingsPage());
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置接口'));
    await tester.pumpAndSettle();
    final trigger = focusNodeOf(tester, '点播聚合');
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('聚合状态：未启用'), findsOneWidget);
    expect(find.text('应用聚合'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(trigger.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('「上传背景图」「恢复默认」是可获焦的 TvFocusable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    pushPage(tester, const SettingsPage());
    await tester.pumpAndSettle();

    final upload = find.byWidgetPredicate(
      (w) => w is TvFocusable && w.semanticLabel == '上传背景图',
    );
    final restore = find.byWidgetPredicate(
      (w) => w is TvFocusable && w.semanticLabel == '恢复默认',
    );
    expect(upload, findsOneWidget);
    expect(restore, findsOneWidget);

    // 两个按钮都能获焦。
    final uploadNode = focusNodeOf(tester, '上传背景图');
    uploadNode.requestFocus();
    await tester.pump();
    expect(uploadNode.hasFocus, isTrue);

    final restoreNode = focusNodeOf(tester, '恢复默认');
    restoreNode.requestFocus();
    await tester.pump();
    expect(restoreNode.hasFocus, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('OK 键触发「恢复默认」按钮 onTap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    pushPage(tester, const SettingsPage());
    await tester.pumpAndSettle();

    final restoreNode = focusNodeOf(tester, '恢复默认');
    restoreNode.requestFocus();
    await tester.pump();
    expect(restoreNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump();

    // onTap 触发的 `_clearWallpaper` 会弹「已恢复默认背景」提示。
    expect(find.text('已恢复默认背景'), findsOneWidget);

    // 清掉 TvNotice 的 3 秒定时器，避免测试收尾报 pending timer。
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(const SizedBox());
  });
}
