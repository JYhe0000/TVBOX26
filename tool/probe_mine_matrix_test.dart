// 临时探针 2：我的页各落点矩阵（跑完即删）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/ui/pages/mine_page.dart';

AppController buildController() {
  const site = SiteConfig(
    key: 'test',
    name: '测试站点',
    api: 'https://api.test/',
    type: 1,
  );
  return AppController(storage: StorageService())
    ..config = const AppConfig(sites: [site], parses: [], lives: [])
    ..selectedSiteKey = 'test'
    ..initialized = true;
}

LibraryStore buildLibrary({int count = 4}) {
  return LibraryStore()
    ..history.addAll(
      List.generate(
        count,
        (index) => HistoryEntry(
          vod: VodItem(
            id: '$index',
            name: '测试影片 $index',
            pic: '',
            remarks: '',
            typeId: '1',
            typeName: '电影',
            year: '2026',
            area: '中国大陆',
            sourceKey: 'test',
            sourceName: '测试站点',
          ),
          sourceKey: 'test',
          sourceName: '测试站点',
          lineName: '线路一',
          lineIndex: 0,
          episodeName: '第${index + 1}集',
          episodeUrl: 'https://video.test/$index.m3u8',
          episodeIndex: index,
          positionMs: 60000,
          durationMs: 600000,
          updatedAt: DateTime(2026, 11, 14 - index),
        ),
      ),
    );
}

Widget harness(AppController controller, Widget child, LibraryStore library) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>.value(value: library),
    ],
    child: MaterialApp(
      theme: AppTheme.forSkin(TvSkinId.smartisan),
      home: Scaffold(body: child),
    ),
  );
}

String describe() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null) return '<null>';
  final ctx = focus.context;
  String text = '';
  if (ctx != null) {
    final widgets = <String>[];
    ctx.visitAncestorElements((element) {
      final w = element.widget;
      final name = w.runtimeType.toString();
      if (name.contains('TvFocusable') ||
          name.contains('StatCard') ||
          name.contains('CategoryItem') ||
          name.contains('PanelAction') ||
          name.contains('ContinueCard') ||
          name.contains('SectionHeader')) {
        widgets.add(name);
      }
      return widgets.length < 2;
    });
    // ignore: avoid_print
    text = widgets.isEmpty ? '?' : widgets.first;
  }
  final r = focus.rect;
  return '${focus.debugLabel} $text '
      'x${r.left.toStringAsFixed(0)}-${r.right.toStringAsFixed(0)} '
      'y${r.top.toStringAsFixed(0)}-${r.bottom.toStringAsFixed(0)}';
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey k, String tag) async {
  await tester.sendKeyEvent(k);
  await tester.pumpAndSettle();
  // ignore: avoid_print
  print('[$tag] ${describe()}');
}

void main() {
  testWidgets('probe mine matrix', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entry = FocusNode(debugLabel: 'mine-entry');
    await tester.pumpWidget(
      harness(buildController(), MinePage(entryFocus: entry), buildLibrary()),
    );
    await tester.pumpAndSettle();

    // 统计卡 1 / 2 / 3 的 DOWN。
    entry.requestFocus();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('[stat-1] ${describe()}');
    await key(tester, LogicalKeyboardKey.arrowDown, 'stat-1 DOWN');
    await key(tester, LogicalKeyboardKey.arrowUp, 'stat-1 DOWN UP');
    await key(tester, LogicalKeyboardKey.arrowRight, 'stat-1 RIGHT');
    // ignore: avoid_print
    print('[stat-2] ${describe()}');
    await key(tester, LogicalKeyboardKey.arrowDown, 'stat-2 DOWN');
    await key(tester, LogicalKeyboardKey.arrowUp, 'stat-2 DOWN UP');
    await key(tester, LogicalKeyboardKey.arrowRight, 'stat-2 RIGHT');
    // ignore: avoid_print
    print('[stat-3] ${describe()}');
    await key(tester, LogicalKeyboardKey.arrowDown, 'stat-3 DOWN');
    await key(tester, LogicalKeyboardKey.arrowDown, 'stat-3 DOWN DOWN');
    await key(tester, LogicalKeyboardKey.arrowUp, 'stat-3 DOWN UP');
    await key(tester, LogicalKeyboardKey.arrowUp, 'stat-3 DOWN UP UP');
    await key(tester, LogicalKeyboardKey.arrowUp, 'stat-3 DOWN UP UP UP');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('probe mine rail right into panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(buildController(), const MinePage(), buildLibrary()),
    );
    await tester.pumpAndSettle();
    // 左栏第 3 项（播放历史）RIGHT → 面板落点？
    for (var i = 0; i < 2; i++) {
      await key(tester, LogicalKeyboardKey.arrowDown, 'rail down $i');
    }
    // ignore: avoid_print
    print('[rail-3] ${describe()}');
    await key(tester, LogicalKeyboardKey.arrowRight, 'rail-3 RIGHT');
    await key(tester, LogicalKeyboardKey.arrowDown, 'rail-3 RIGHT DOWN');
    await tester.pumpWidget(const SizedBox());
  });
}
