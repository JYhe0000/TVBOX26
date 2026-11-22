import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/config_service.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/theme/theme_controller.dart';
import 'package:tvbox_flutter/ui/pages/settings_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

class _EmptyConfigService extends ConfigService {
  @override
  Future<LoadedConfig> loadBuiltIn() async =>
      LoadedConfig(config: AppConfig.empty, raw: '{}');
}

AppController _controller() =>
    AppController(configService: _EmptyConfigService())..initialized = true;

Widget _settingsHarness(AppController controller) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(create: (_) => LibraryStore()),
    ],
    child: Consumer<AppController>(
      builder: (context, app, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.forSkin(app.skinId, accentColor: app.accentColor),
        builder: (context, child) => TvCanvas(
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
}

FocusNode _accentFocusNode(WidgetTester tester, String semanticLabel) {
  final option = find.byWidgetPredicate(
    (widget) =>
        widget is TvFocusable && widget.semanticLabel == semanticLabel,
  );
  final focus = find.descendant(of: option, matching: find.byType(Focus));
  return tester.widget<Focus>(focus.first).focusNode!;
}

Color _expectedAccent(TvSkin skin, TvAccentColor selection) {
  final color = selection.color!;
  if (skin.brightness == Brightness.light) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withLightness((hsl.lightness + 0.12).clamp(0.0, 1.0).toDouble())
      .toColor();
}

void _expectAccentDoesNotChangeSkinSemantics(TvSkin original, TvSkin themed) {
  expect(themed.id, original.id);
  expect(themed.brightness, original.brightness);
  expect(themed.bg, original.bg);
  expect(themed.bgGradient, same(original.bgGradient));
  expect(themed.bgStripes, same(original.bgStripes));
  expect(themed.wallpaperOpacity, original.wallpaperOpacity);
  expect(themed.glowBlobs, same(original.glowBlobs));
  expect(themed.surface, original.surface);
  expect(themed.surfaceAlt, original.surfaceAlt);
  expect(themed.surfaceSubtle, original.surfaceSubtle);
  expect(themed.textPrimary, original.textPrimary);
  expect(themed.textSecondary, original.textSecondary);
  expect(themed.textMuted, original.textMuted);
  expect(themed.textOnAccent, original.textOnAccent);
  expect(themed.border, original.border);
  expect(themed.borderSoft, original.borderSoft);
  expect(themed.accentGlow, original.accentGlow);
  expect(themed.success, original.success);
  expect(themed.warning, original.warning);
  expect(themed.danger, original.danger);
  expect(themed.radiusSm, original.radiusSm);
  expect(themed.radiusMd, original.radiusMd);
  expect(themed.radiusLg, original.radiusLg);
  expect(themed.radiusPill, original.radiusPill);
  expect(themed.spaceXs, original.spaceXs);
  expect(themed.spaceSm, original.spaceSm);
  expect(themed.spaceMd, original.spaceMd);
  expect(themed.spaceLg, original.spaceLg);
  expect(themed.spaceXl, original.spaceXl);
  expect(themed.fontFamily, original.fontFamily);
  expect(themed.titleWeight, original.titleWeight);
  expect(themed.surfaceSkin, same(original.surfaceSkin));
  expect(themed.motionFast, original.motionFast);
  expect(themed.motionPanel, original.motionPanel);
  expect(themed.motionPage, original.motionPage);
  expect(themed.topBarStyle, original.topBarStyle);
  expect(themed.posterOverlay, same(original.posterOverlay));
  expect(themed.heroScrim, same(original.heroScrim));
  expect(themed.controlScrim, same(original.controlScrim));

  final before = original.focus;
  final after = themed.focus;
  expect(after.grow, before.grow);
  expect(after.cardGrow, before.cardGrow);
  expect(after.duration, before.duration);
  expect(after.cardDuration, before.cardDuration);
  expect(after.curve, same(before.curve));
  expect(after.showFill, before.showFill);
  if (!before.showFill) expect(after.fillColor, before.fillColor);
  expect(after.showGlow, before.showGlow);
  expect(after.glowColor, before.glowColor);
  expect(after.tintContent, before.tintContent);
  expect(after.borderWidth, before.borderWidth);
  expect(after.glowBlur, before.glowBlur);
  expect(after.glowSpread, before.glowSpread);
  expect(after.liftShadow, before.liftShadow);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('主题强调色基础与持久化', () {
    test('默认值、枚举名称与现有皮肤持久化名称保持兼容', () async {
      final fresh = _controller();
      expect(fresh.skinId, TvSkinId.netflix);
      expect(fresh.accentColor, TvAccentColor.skinDefault);
      expect(TvSkinId.netflix.label, '默认');

      for (final id in TvSkinId.values) {
        expect(TvSkinId.fromName(id.name), id);
      }
      expect(TvSkinId.fromName(null), TvSkinId.netflix);
      expect(TvSkinId.fromName(''), TvSkinId.netflix);
      expect(TvSkinId.fromName('ios26'), TvSkinId.netflix);
      expect(TvSkinId.fromName('removed_or_unknown_skin'), TvSkinId.netflix);

      for (final accent in TvAccentColor.values) {
        expect(TvAccentColor.fromName(accent.name), accent);
      }
      expect(TvAccentColor.fromName(null), TvAccentColor.skinDefault);
      expect(TvAccentColor.fromName(''), TvAccentColor.skinDefault);
      expect(
        TvAccentColor.fromName('unknown_accent'),
        TvAccentColor.skinDefault,
      );

      // 已发布版本持久化过的皮肤 id 仍应被启动逻辑识别。
      for (final legacyName in ['smartisan', 'smartisanDark', 'netflix']) {
        SharedPreferences.setMockInitialValues({
          AppController.skinStorageKey: legacyName,
        });
        final restored = AppController(configService: _EmptyConfigService());
        await restored.initialize(notify: false);
        expect(restored.skinId.name, legacyName);
        expect(restored.accentColor, TvAccentColor.skinDefault);
        restored.dispose();
      }
      SharedPreferences.setMockInitialValues({
        AppController.skinStorageKey: 'ios26',
      });
      final retired = AppController(configService: _EmptyConfigService());
      await retired.initialize(notify: false);
      expect(retired.skinId, TvSkinId.netflix);
      retired.dispose();
      fresh.dispose();
    });

    test('设置主题色持久化并请求冷重启，同值不重复触发', () async {
      final controller = _controller();
      await controller.storage.init();
      var restarts = 0;
      var notifications = 0;
      controller.onRestartRequested = () => restarts++;
      controller.addListener(() => notifications++);

      await controller.setAccentColor(TvAccentColor.orange);
      expect(controller.accentColor, TvAccentColor.orange);
      expect(
        controller.storage.getString(AppController.accentColorStorageKey),
        TvAccentColor.orange.name,
      );
      expect(restarts, 1);
      expect(notifications, 0, reason: '主题色切换应保持冷切换语义');

      await controller.setAccentColor(TvAccentColor.orange);
      expect(restarts, 1, reason: '设置当前主题色应为无操作');
      expect(notifications, 0);
      controller.dispose();
    });

    test('冷启动回读保存的主题色；坏值与缺省值回落到跟随皮肤', () async {
      final first = _controller();
      await first.storage.init();
      await first.setAccentColor(TvAccentColor.purple);

      final restored = AppController(configService: _EmptyConfigService());
      await restored.initialize(notify: false);
      expect(restored.accentColor, TvAccentColor.purple);
      expect(restored.skinId, TvSkinId.netflix);
      restored.dispose();

      SharedPreferences.setMockInitialValues({
        AppController.accentColorStorageKey: 'not_a_color',
      });
      final invalid = AppController(configService: _EmptyConfigService());
      await invalid.initialize(notify: false);
      expect(invalid.accentColor, TvAccentColor.skinDefault);
      invalid.dispose();
      first.dispose();
    });
  });

  group('强调色主题不变量', () {
    test('所有预设适用于各皮肤而不改变状态色、布局或焦点行为', () {
      for (final id in TvSkinId.values) {
        final original = skinFor(id);
        for (final selection in TvAccentColor.values.where(
          (value) => value != TvAccentColor.skinDefault,
        )) {
          final themed = skinFor(id, accentColor: selection);
          final expected = _expectedAccent(original, selection);
          expect(
            themed.accent,
            expected,
            reason: '${id.name}/${selection.name}',
          );
          expect(themed.accentGradient, isA<LinearGradient>());
          final gradient = themed.accentGradient as LinearGradient;
          expect(gradient.colors.first, expected);
          expect(gradient.colors.last, themed.accentPressed);
          expect(
            themed.accentPressed,
            HSLColor.fromColor(expected)
                .withLightness(
                  (HSLColor.fromColor(expected).lightness - 0.12)
                      .clamp(0.0, 1.0)
                      .toDouble(),
                )
                .toColor(),
          );
          if (original.focus.showFill) {
            expect(themed.focus.fillColor, expected);
          }
          if (original.focus.showFill || original.focus.tintContent) {
            final accentHsl = HSLColor.fromColor(expected);
            expect(
              themed.focus.borderColor,
              accentHsl
                  .withLightness(
                    (accentHsl.lightness - 0.18).clamp(0.0, 1.0).toDouble(),
                  )
                  .toColor(),
            );
          }
          _expectAccentDoesNotChangeSkinSemantics(original, themed);

          if (!original.focus.showFill && !original.focus.tintContent) {
            expect(themed.focus.borderColor, original.focus.borderColor);
          }
        }

        expect(
          identical(
            skinFor(id, accentColor: TvAccentColor.skinDefault),
            original,
          ),
          isTrue,
          reason: '${id.name} 的默认主题色应还原皮肤原色',
        );
      }
    });

    test('ThemeData 注入强调色并可通过跟随皮肤恢复默认', () {
      for (final id in TvSkinId.values) {
        final base = skinFor(id);
        final themed = AppTheme.forSkin(id, accentColor: TvAccentColor.green);
        final themedSkin = themed.extension<TvSkinTokens>()!.skin;
        expect(
          themedSkin.accent,
          skinFor(id, accentColor: TvAccentColor.green).accent,
        );
        expect(themed.colorScheme.primary, themedSkin.accent);
        expect(themed.colorScheme.error, themedSkin.danger);
        expect(themed.progressIndicatorTheme.color, themedSkin.accent);
        expect(themed.sliderTheme.activeTrackColor, themedSkin.accent);
        _expectAccentDoesNotChangeSkinSemantics(base, themedSkin);

        final reset = AppTheme.forSkin(
          id,
          accentColor: TvAccentColor.skinDefault,
        ).extension<TvSkinTokens>()!.skin;
        expect(reset.accent, base.accent);
        expect(reset.focus.borderColor, base.focus.borderColor);
        expect(reset.focus.fillColor, base.focus.fillColor);
      }
    });
  });

  testWidgets('设置页可用遥控器确认键选择主题色', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _controller();
    await controller.storage.init();
    addTearDown(controller.dispose);
    var restarts = 0;
    var notifications = 0;
    controller.onRestartRequested = () => restarts++;
    controller.addListener(() => notifications++);

    await tester.pumpWidget(_settingsHarness(controller));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    await tester.pumpAndSettle();

    const optionLabel = '主题色 暖阳橙，按确认切换';
    final option = find.byWidgetPredicate(
      (widget) => widget is TvFocusable && widget.semanticLabel == optionLabel,
    );
    expect(option, findsOneWidget);
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();

    final focus = _accentFocusNode(tester, optionLabel);
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(controller.accentColor, TvAccentColor.orange);
    expect(
      controller.storage.getString(AppController.accentColorStorageKey),
      TvAccentColor.orange.name,
    );
    expect(restarts, 1);
    expect(notifications, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
