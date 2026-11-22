import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/poster_card.dart';

void main() {
  for (final skinId in TvSkinId.values) {
    testWidgets('$skinId 焦点按皮肤曲线过渡，减弱动态保留焦点态', (tester) async {
      final focusNode = FocusNode(debugLabel: 'transition-test');
      addTearDown(focusNode.dispose);
      var reduceMotion = false;
      late StateSetter setHarnessState;
      final focusSkin = skinFor(skinId).focus;
      final midpoint = Duration(
        microseconds: focusSkin.duration.inMicroseconds ~/ 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.forSkin(skinId),
          home: StatefulBuilder(
            builder: (context, setState) {
              setHarnessState = setState;
              return MediaQuery(
                data: MediaQueryData(disableAnimations: reduceMotion),
                child: Scaffold(
                  body: TvFocusable(
                    focusNode: focusNode,
                    child: const Text('焦点项'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      final focusAnimations = tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(TvFocusable),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(focusAnimations, hasLength(2));
      expect(
        focusAnimations.every(
          (animation) =>
              animation.duration == focusSkin.duration &&
              animation.curve == focusSkin.curve,
        ),
        isTrue,
      );
      expect(
        tester
            .widget<AnimatedTheme>(
              find.descendant(
                of: find.byType(TvFocusable),
                matching: find.byType(AnimatedTheme),
              ),
            )
            .duration,
        focusSkin.duration,
      );
      expect(
        tester
            .widget<AnimatedDefaultTextStyle>(
              find.descendant(
                of: find.byType(TvFocusable),
                matching: find.byType(AnimatedDefaultTextStyle),
              ),
            )
            .duration,
        focusSkin.duration,
      );

      focusNode.requestFocus();
      await tester.pump();
      await tester.pump(midpoint);
      final scaleFinder = find.descendant(
        of: find.byType(TvFocusable),
        matching: find.byType(ScaleTransition),
      );
      var scale = tester.widget<ScaleTransition>(scaleFinder.first);
      expect(
        scale.scale.value,
        closeTo(
          1 + (focusSkin.grow - 1) * focusSkin.curve.transform(0.5),
          0.0001,
        ),
      );

      await tester.pump(midpoint);
      scale = tester.widget<ScaleTransition>(scaleFinder.first);
      expect(scale.scale.value, closeTo(focusSkin.grow, 0.0001));

      setHarnessState(() => reduceMotion = true);
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
        Duration.zero,
      );
      scale = tester.widget<ScaleTransition>(scaleFinder.first);
      expect(scale.scale.value, 1);
      expect(
        tester.widget<TvFocusTint>(find.byType(TvFocusTint)).active,
        focusSkin.tintContent,
      );
    });

    testWidgets('$skinId 海报焦点放大与过渡更易辨认', (tester) async {
      final focusNode = FocusNode(debugLabel: 'poster-transition-test');
      addTearDown(focusNode.dispose);
      final focus = skinFor(skinId).focus;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.forSkin(skinId),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 300,
                child: PosterCard(
                  vod: const VodItem(
                    id: 'poster',
                    name: '测试封面',
                    pic: 'https://images.test/poster.jpg',
                  ),
                  onTap: () {},
                  focusNode: focusNode,
                ),
              ),
            ),
          ),
        ),
      );

      final imageBeforeFocus = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      final animation = tester.widget<AnimatedScale>(
        find.descendant(
          of: find.byType(TvFocusable),
          matching: find.byType(AnimatedScale),
        ),
      );
      expect(animation.duration, focus.cardDuration);
      focusNode.requestFocus();
      await tester.pump();
      await tester.pump(
        Duration(microseconds: focus.cardDuration.inMicroseconds ~/ 2),
      );
      final scale = tester.widget<ScaleTransition>(
        find.descendant(
          of: find.byType(TvFocusable),
          matching: find.byType(ScaleTransition),
        ),
      );
      expect(scale.scale.value, greaterThan(1.02));
      final imageDuringFocus = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(imageDuringFocus.memCacheWidth, imageBeforeFocus.memCacheWidth);
      expect(imageDuringFocus.memCacheHeight, imageBeforeFocus.memCacheHeight);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
