import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

void main() {
  for (final id in TvSkinId.values) {
    testWidgets('$id blur switch preserves floating surface and controls', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = AppController(storage: StorageService());
      addTearDown(controller.dispose);
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      var taps = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.forSkin(id),
            home: Scaffold(
              body: Center(
                child: ValueListenableBuilder<bool>(
                  valueListenable: enabled,
                  builder: (context, blur, _) => SkinSurface(
                    enableBlur: blur,
                    floating: true,
                    child: TvFocusable(
                      autofocus: true,
                      onTap: () => taps++,
                      child: const Text('播放'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(SkinSurface));
      final material = TvSkin.of(context).surfaceSkin;
      expect(
        find.byType(BackdropFilter),
        material.blurSigma > 0 ? findsOneWidget : findsNothing,
      );
      final decorations = find.descendant(
        of: find.byType(SkinSurface),
        matching: find.byType(DecoratedBox),
      );
      final before = tester.widget<DecoratedBox>(decorations.first).decoration;
      enabled.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.widget<DecoratedBox>(decorations.first).decoration, before);
      await tester.tap(find.text('播放'));
      expect(taps, 1);
      enabled.value = true;
      await tester.pumpAndSettle();
      expect(
        find.byType(BackdropFilter),
        material.blurSigma > 0 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
