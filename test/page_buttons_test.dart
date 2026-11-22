import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/detail_page.dart';
import 'package:tvbox_flutter/ui/splash_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

/// 页面上「可交互但缺 TV 焦点」的元素回归测试。
///
/// 覆盖本代理负责的两个页面：启动页（配置地址/错误恢复按钮）与详情页
/// （错误横幅上的重试按钮）。修复前这些是裸 `FilledButton`/`OutlinedButton`/
/// `TextButton`，电视遥控器无法获焦也没有焦点视觉；修复后统一包 [TvFocusable]。
Widget harness(
  AppController controller,
  Widget child, {
  LibraryStore? library,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(
        create: (_) => library ?? LibraryStore(),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(body: child),
    ),
  );
}

/// 找到某个按钮文字包着的那一个 [TvFocusable]，并断言它内部的可获焦节点。
FocusNode focusNodeOf(WidgetTester tester, String label) {
  final focusable = find
      .ancestor(of: find.text(label), matching: find.byType(TvFocusable))
      .first;
  final focus = tester.widget<Focus>(
    find.descendant(of: focusable, matching: find.byType(Focus)).first,
  );
  return focus.focusNode!;
}

void main() {
  testWidgets('splash error buttons are all TV-focusable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController();
    await tester.pumpWidget(
      harness(
        controller,
        const SplashPage(loading: false, error: '配置加载失败，请检查地址后重试'),
      ),
    );
    await tester.pumpAndSettle();

    // 错误恢复区三个动作都在：内置源 / 重试 / 输入配置接口。
    expect(find.text('内置源'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('输入配置接口'), findsOneWidget);

    // 每个动作都包在 TvFocusable 里（而不是裸 Material 按钮），可获焦。
    for (final label in ['内置源', '重试', '输入配置接口']) {
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(TvFocusable),
        ),
        findsOneWidget,
      );
    }

    // FOCUS-06：进页焦点落在 autofocus 的「重试」按钮上。
    final retryNode = focusNodeOf(tester, '重试');
    expect(retryNode.hasFocus, isTrue);
    expect(retryNode.canRequestFocus, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('detail error retry button is TV-focusable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController();
    // 空 id 让 `_loadDetail` 直接进入错误分支，渲染错误横幅上的「重试」。
    await tester.pumpWidget(
      harness(
        controller,
        const DetailPage(vod: VodItem(id: '', name: '测试影片')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    // 重试按钮包在 TvFocusable 里，电视遥控器可获焦。
    expect(
      find.ancestor(
        of: find.text('重试'),
        matching: find.byType(TvFocusable),
      ),
      findsOneWidget,
    );
    final retryNode = focusNodeOf(tester, '重试');
    expect(retryNode.canRequestFocus, isTrue);
    // 页面里已有明确焦点落点（操作区「立即播放」，FOCUS-06）。
    expect(FocusManager.instance.primaryFocus, isNotNull);

    await tester.pumpWidget(const SizedBox());
  });
}
