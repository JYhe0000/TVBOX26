// 设置页返回键死循环回归测试。
//
// 背景：settings_page.dart 曾用 `PopScope(canPop: false)` + `_handleBack` 在
// `_index == 0` 时调 `Navigator.maybePop`。因为 `maybePop` 内部有
// `await route.willPop()` 的微任务边界，`canPop:false` 会命中 `doNotPop` 分支
// 再次回调 `onPopInvokedWithResult` → `_handleBack` → `maybePop` → …，形成
// **无限微任务循环**，主 isolate 饿死 → 真机 ANR（「切换主题后按返回卡死」）。
//
// 修复：`canPop: _index == 0`（首分类才允许真正 pop）+ `Navigator.pop`（明确
// 退页）。本测试锁死该语义，防止回退成反模式后再次卡死。
//
// 用法：flutter test test/settings_back_test.dart   （期望全绿）

import 'package:flutter/material.dart';
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
/// 与 skin_switch_test.dart 的 harness 同构，去掉构建计数等无关部分。
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

/// 把一个页面 push 到根导航器上（复刻真实进入路径），返回 base 导航器。
NavigatorState pushPage(WidgetTester tester, Widget page) {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.push(MaterialPageRoute<void>(builder: (_) => page));
  return navigator;
}

void main() {
  testWidgets('设置页首个分类按返回键：退页而非死循环', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    pushPage(tester, const SettingsPage());
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    // 系统返回键（真机 ANR 的触发路径）。修复前这里会无限微任务循环卡死；
    // 修复后应正常弹出。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('设置页非首个分类按返回键：退回首个分类而非退页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    pushPage(tester, const SettingsPage());
    await tester.pumpAndSettle();

    // 切到第二个分类（配置接口），_index 变为 1。
    await tester.tap(find.text('配置接口'));
    await tester.pumpAndSettle();

    // 返回键应只退回首个分类（主题皮肤），页面不退出。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    // 首个分类（主题皮肤）重新成为当前面板：皮肤行可见。
    expect(find.text('Smartisan OS'), findsOneWidget);
    final category = tester.widget<TvFocusable>(
      find.byWidgetPredicate(
        (widget) => widget is TvFocusable && widget.semanticLabel == '主题皮肤',
      ),
    );
    expect(category.focusNode!.hasFocus, isTrue);
    // 真实 push 路由在首分类再 BACK 必须退页；根路由不可 pop 不属于设置页缺陷。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
