// 对话框/浮层按钮遥控器焦点回归测试。
//
// 背景：二维码弹窗（上传背景图 / 手机远程搜索）底部唯一的「返回」按钮原本是
// 裸 `TextButton`，且整张卡片被一个 `autofocus` 的 `TvFocusable` 包住，导致
// 弹窗打开后默认焦点落到整张卡片、按钮无法获得皮肤焦点视觉（AGENTS.md §3
// 硬性规则 1 / FOCUS-06：每个可交互元素必须有唯一、可见的焦点）。
//
// 修复：去掉卡片的 `TvFocusable` 包装，把「返回」按钮改成带 `autofocus` 的
// `TvFocusable`，弹窗打开默认焦点落在按钮上，OK 键关闭弹窗。
//
// 用法：flutter test test/dialog_buttons_test.dart   （期望全绿）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/remote_search_dialog.dart';
import 'package:tvbox_flutter/ui/widgets/wallpaper_upload_dialog.dart';

/// 取按钮文案对应 TvFocusable 内部的 Focus 节点（最内层 Focus 祖先）。
FocusNode? buttonFocusNode(WidgetTester tester, String label) {
  final focus = tester.widget<Focus>(
    find.ancestor(of: find.text(label), matching: find.byType(Focus)).first,
  );
  return focus.focusNode;
}

/// 1280×720 表面 + ios26 皮肤，挂一个能拿到 BuildContext 的空壳。
Widget buildShell(void Function(BuildContext) onReady) {
  return MaterialApp(
    theme: AppTheme.forSkin(TvSkinId.smartisan),
    home: Builder(
      builder: (context) {
        onReady(context);
        return const Scaffold(body: SizedBox.expand());
      },
    ),
  );
}

void main() {
  testWidgets('上传背景图弹窗的返回按钮可获焦，且是默认焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late BuildContext dialogCtx;
    await tester.pumpWidget(buildShell((context) => dialogCtx = context));
    await tester.pump();

    showWallpaperUploadDialog(dialogCtx, 'http://192.168.1.2:8080/upload');
    await tester.pumpAndSettle();

    expect(find.text('返回'), findsOneWidget);
    // 按钮由 TvFocusable 包裹（而非裸 TextButton）。
    expect(
      find.ancestor(of: find.text('返回'), matching: find.byType(TvFocusable)),
      findsOneWidget,
    );
    // 弹窗默认焦点落在「返回」按钮上（FOCUS-06）。
    final node = buttonFocusNode(tester, '返回');
    expect(node, isNotNull);
    expect(FocusManager.instance.primaryFocus, node);
    // OK 键关闭弹窗。
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('返回'), findsNothing);
  });

  testWidgets('手机远程搜索弹窗的返回搜索按钮可获焦，且是默认焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late BuildContext dialogCtx;
    await tester.pumpWidget(buildShell((context) => dialogCtx = context));
    await tester.pump();

    showRemoteSearchDialog(dialogCtx, 'http://192.168.1.2:8080/search');
    await tester.pumpAndSettle();

    expect(find.text('返回搜索'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('返回搜索'),
        matching: find.byType(TvFocusable),
      ),
      findsOneWidget,
    );
    final node = buttonFocusNode(tester, '返回搜索');
    expect(node, isNotNull);
    expect(FocusManager.instance.primaryFocus, node);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('返回搜索'), findsNothing);
  });
}
