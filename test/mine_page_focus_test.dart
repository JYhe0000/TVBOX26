import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/mine_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

FocusNode nodeFor(WidgetTester tester, String label) {
  final target = find.byWidgetPredicate(
    (widget) => widget is TvFocusable && widget.semanticLabel == label,
  );
  return tester
      .widget<Focus>(
        find.descendant(of: target, matching: find.byType(Focus)).first,
      )
      .focusNode!;
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> mount(
  WidgetTester tester,
  TvSkinId skin, {
  bool withHistory = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = AppController()..initialized = true;
  final library = LibraryStore();
  if (withHistory) {
    library.history.add(
      HistoryEntry(
        vod: const VodItem(id: 'focus-test', name: '焦点测试影片'),
        sourceKey: 'test',
        sourceName: '测试源',
        lineName: '线路一',
        lineIndex: 0,
        episodeName: '第一集',
        episodeUrl: '',
        episodeIndex: 0,
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: DateTime(2026),
      ),
    );
  }
  addTearDown(controller.dispose);
  addTearDown(library.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<LibraryStore>.value(value: library),
      ],
      child: MaterialApp(
        theme: AppTheme.forSkin(skin),
        // 顶部保留真实 shell 的导航栏高度，页面仍独立挂载。
        home: const Scaffold(
          body: Padding(padding: EdgeInsets.only(top: 64), child: MinePage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final skin in TvSkinId.values) {
    testWidgets('${skin.name} 无历史时统计卡 DOWN 保持焦点，LEFT 可回左栏', (tester) async {
      await mount(tester, skin);
      final stats = ['收藏 0', '历史 0', '站点 0'];
      for (final label in stats) {
        final node = nodeFor(tester, label);
        node.requestFocus();
        await tester.pumpAndSettle();
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(FocusManager.instance.primaryFocus, same(node), reason: label);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus, same(node), reason: label);
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(FocusManager.instance.primaryFocus, same(node), reason: label);
      }
      nodeFor(tester, stats.first).requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(nodeFor(tester, '概览').hasPrimaryFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('${skin.name} 继续观看 DOWN 不跳左栏，UP 与内部 DOWN 保留', (tester) async {
      await mount(tester, skin, withHistory: true);
      final card = find.ancestor(
        of: find.text('焦点测试影片'),
        matching: find.byType(TvFocusable),
      );
      final node = tester
          .widget<Focus>(
            find.descendant(of: card, matching: find.byType(Focus)).first,
          )
          .focusNode!;
      node.requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, same(node));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, same(node));
      await press(tester, LogicalKeyboardKey.arrowUp);
      final above = FocusManager.instance.primaryFocus;
      expect(above, isNot(same(node)));
      expect(
        [
          '收藏 0',
          '历史 1',
          '站点 0',
          '查看全部播放历史',
        ].any((label) => nodeFor(tester, label).hasPrimaryFocus),
        isTrue,
      );
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, same(node));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(node.hasPrimaryFocus, isFalse);
      expect(
        [
          '概览',
          '我的收藏',
          '播放历史',
          '视频站点',
          '主题皮肤',
          '设置',
        ].any((label) => nodeFor(tester, label).hasPrimaryFocus),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('${skin.name} 视频站点内部 DOWN 与 UP 正常，末项 DOWN 留在右栏', (
      tester,
    ) async {
      await mount(tester, skin);
      nodeFor(tester, '视频站点').requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.select);
      final first = nodeFor(tester, '切换视频站点，未选择');
      final last = nodeFor(tester, '刷新配置，内置演示配置');
      first.requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, same(last));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, same(last));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(FocusManager.instance.primaryFocus, same(first));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(first.hasPrimaryFocus, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
