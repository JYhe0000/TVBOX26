import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/episode_selector.dart';

List<Episode> episodes(int count) => List.generate(
  count,
  (index) => Episode(name: '特别篇日期-$index', url: 'https://test/$index'),
);

void main() {
  for (final count in [0, 1, 30, 31, 70, 1000]) {
    test('区间边界 $count', () {
      final ranges = episodeRanges(count);
      expect(ranges.length, (count / 30).ceil());
      expect([
        for (final range in ranges)
          for (var i = range.start; i < range.end; i++) i,
      ], List.generate(count, (i) => i));
      if (count > 0) {
        expect(ranges.last.end, count);
        expect(ranges.last.end - ranges.last.start, inInclusiveRange(1, 30));
      }
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    TvSkinId skin = TvSkinId.smartisan,
    int count = 70,
    int selected = 65,
    bool video = false,
    ValueChanged<int>? onSelected,
    GlobalKey<EpisodeSelectorState>? selectorKey,
  }) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppController(),
        child: MaterialApp(
          theme: AppTheme.forSkin(skin),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: video ? 600 : 800,
                height: video ? 540 : 210,
                child: EpisodeSelector(
                  key: selectorKey,
                  episodes: episodes(count),
                  selectedIndex: selected,
                  columns: video ? 3 : 7,
                  rowHeight: video ? 48 : 34,
                  onVideo: video,
                  autofocus: true,
                  onSelected: onSelected ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final skin in TvSkinId.values) {
    for (final video in [false, true]) {
      testWidgets('$skin video=$video 当前集、区间切换与原始索引', (tester) async {
        final selected = <int>[];
        await mount(tester, skin: skin, video: video, onSelected: selected.add);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-65');
        expect(find.text('特别篇日期-65'), findsOneWidget);
        await tester.tap(find.text('31–60'));
        await tester.pumpAndSettle();
        expect(selected, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-30');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          video ? 'episode-33' : 'episode-37',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'episode-range-1',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(selected, [video ? 33 : 37]);
        expect(tester.takeException(), isNull);
        for (final element
            in find.byKey(const ValueKey('episode-cell-30')).evaluate()) {
          final box = element.renderObject! as RenderBox;
          expect(box.localToGlobal(Offset.zero).dx, greaterThanOrEqualTo(0));
          expect(
            box.localToGlobal(Offset(box.size.width, 0)).dx,
            lessThanOrEqualTo(1280),
          );
        }
      });
    }
  }

  testWidgets('千集定位末组，数据缩短后校验旧索引', (tester) async {
    final key = GlobalKey<EpisodeSelectorState>();
    await mount(tester, count: 1000, selected: 999, selectorKey: key);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-999');
    expect(find.text('991–1000'), findsOneWidget);
    await mount(tester, count: 1, selected: 999, selectorKey: key);
    expect(find.text('特别篇日期-0'), findsOneWidget);
    expect(find.text('1–1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空列表与单区间不显示左栏', (tester) async {
    await mount(tester, count: 0, selected: 0);
    expect(find.text('暂无可选集数'), findsOneWidget);
    await mount(tester, count: 30, selected: 29);
    expect(find.text('1–30'), findsNothing);
    expect(find.text('特别篇日期-29'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨行滚动后焦点仍位于选集固定区域内', (tester) async {
    await mount(tester, selected: 0, video: true);
    for (var row = 0; row < 9; row++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-27');
    final rect = tester.getRect(find.byKey(const ValueKey('episode-cell-27')));
    final selector = tester.getRect(find.byType(EpisodeSelector));
    expect(rect.top, greaterThanOrEqualTo(selector.top));
    expect(rect.bottom, lessThanOrEqualTo(selector.bottom));
    expect(tester.takeException(), isNull);
  });
}
