import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/home_hero_carousel.dart';

const _longTitle = '仙逆剧场版：跨越群山与星海的漫长旅程';
const _title = ValueKey('home-hero-title');
const _viewport = ValueKey('home-hero-title-viewport');

Future<void> _setSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Widget _hero(
  FocusNode focus, {
  TvSkinId skin = TvSkinId.netflix,
  String title = _longTitle,
  int index = 0,
  bool expanded = true,
  bool reducedMotion = false,
  double textScale = 1,
}) => MaterialApp(
  theme: AppTheme.forSkin(skin),
  builder: (context, child) => TvCanvas(
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reducedMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: HomeHeroCarousel(
        item: VodItem(id: '$index', name: title, remarks: '高清'),
        itemCount: 2,
        index: index,
        expanded: expanded,
        ctaFocus: focus,
        onTapItem: () {},
      ),
    ),
  ),
);

void main() {
  for (final skin in TvSkinId.values) {
    testWidgets('${skin.name} 长标题停顿后横滚并停在末尾', (tester) async {
      await _setSurface(tester);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_hero(focus, skin: skin));
      final title = find.byKey(_title);
      final viewport = tester.getRect(find.byKey(_viewport));
      final start = tester.getRect(title);
      expect(viewport.width, greaterThan(360));
      expect(start.left, closeTo(viewport.left, 0.01));
      expect(start.right, greaterThan(viewport.right));

      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(title), start);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getRect(title).left, lessThan(start.left));
      await tester.pumpAndSettle();
      final end = tester.getRect(title);
      expect(end.right, closeTo(viewport.right, 1));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getRect(title), end);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('同名换片重置横滚，收起后长标题回到静态两行', (tester) async {
    await _setSurface(tester);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_hero(focus));
    focus.requestFocus();
    await tester.pump();
    final title = find.byKey(_title);
    final start = tester.getTopLeft(title);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.getTopLeft(title).dx, lessThan(start.dx));

    await tester.pumpWidget(_hero(focus, index: 1));
    expect(tester.getTopLeft(title), start);
    expect(focus.hasPrimaryFocus, isTrue);

    await tester.pumpWidget(_hero(focus, index: 1, expanded: false));
    expect(find.byKey(_viewport), findsNothing);
    expect(tester.widget<Text>(title).maxLines, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('不抢焦弹窗覆盖时停滚，关闭后从标题开头开始', (tester) async {
    await _setSurface(tester);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_hero(focus));
    focus.requestFocus();
    await tester.pump();
    final title = find.byKey(_title);
    final start = tester.getTopLeft(title);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.getTopLeft(title).dx, lessThan(start.dx));

    final navigator = Navigator.of(focus.context!);
    navigator.push<void>(
      DialogRoute<void>(
        context: focus.context!,
        requestFocus: false,
        builder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();
    expect(focus.hasPrimaryFocus, isTrue);
    expect(find.byKey(_viewport), findsNothing);

    navigator.pop();
    await tester.pump();
    expect(tester.getTopLeft(title), start);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('短标题静止，减弱动态与放大字体保留两行长标题', (tester) async {
    await _setSurface(tester);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final title = find.byKey(_title);
    await tester.pumpWidget(_hero(focus, title: '仙逆'));
    expect(find.byKey(_viewport), findsNothing);
    expect(tester.widget<Text>(title).maxLines, 1);

    await tester.pumpWidget(_hero(focus, reducedMotion: true, textScale: 2));
    expect(find.byKey(_viewport), findsNothing);
    expect(tester.widget<Text>(title).maxLines, 2);
    final cta = tester.getRect(find.byKey(const ValueKey('home-hero-cta')));
    final hero = tester.getRect(find.byType(HomeHeroCarousel));
    expect(cta.bottom, lessThan(hero.bottom));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
