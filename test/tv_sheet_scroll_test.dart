import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/ui/widgets/tv_sheet.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

void main() {
  testWidgets('TvSheetList smoothly scrolls to uncached focus and honors the '
      'latest repeated direction intent', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: TvSheetList(
            labels: List.generate(40, (index) => '目录项 $index'),
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNotNull);

    // 快速连续输入越过缓存区：最新方向意图应胜过旧滚动动画完成回调。
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, greaterThan(0));
    expect(scrollable.position.pixels, lessThan(20 * 60));

    await tester.pumpAndSettle();
    final focusedItem = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TvFocusable>();
    expect(focusedItem?.semanticLabel, '目录项 20');
    expect(find.text('目录项 20'), findsOneWidget);
    expect(
      tester
          .getRect(find.text('目录项 20'))
          .overlaps(tester.getRect(find.byType(ListView))),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TvSheetList stops an old focus intent when focus leaves the '
      'list', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outside = FocusNode(debugLabel: 'outside-list');
    addTearDown(outside.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: TvSheetList(
                  labels: List.generate(40, (index) => '目录项 $index'),
                  onSelected: (_) {},
                ),
              ),
              Focus(
                focusNode: outside,
                child: const SizedBox(width: 20, height: 20),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    outside.requestFocus();
    await tester.pumpAndSettle();

    expect(outside.hasFocus, isTrue);
    expect(FocusManager.instance.primaryFocus, outside);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TvSheetList uses immediate positioning when animations are '
      'disabled', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1280, 720),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: TvSheetList(
              labels: List.generate(40, (index) => '目录项 $index'),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, greaterThanOrEqualTo(20 * 60));
    expect(
      FocusManager.instance.primaryFocus,
      Focus.of(tester.element(find.text('目录项 20'))),
    );
    expect(tester.takeException(), isNull);
  });
}
