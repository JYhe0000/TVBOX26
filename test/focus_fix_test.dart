// 收藏 / 历史子页面空态默认焦点回归测试。
//
// 背景：FavoritesPage / HistoryPage 在数据为空时走 EmptyState，页头返回键与
// EmptyState 的「返回」按钮都没有 autofocus，导致进页后焦点落到不可见的
// 路由 FocusScope 根（`_ModalScopeState Focus Scope`），遥控器第一次按方向键
// 才有可见焦点（AGENTS.md §3 硬性规则 1 / FOCUS-06：进页有默认落点）。
//
// 修复：空态时把页头返回键设为 autofocus，进页默认焦点落在可见的返回键上；
// 非空态仍由首张海报 / 首行卡片的 autofocus 接管，返回键不抢焦点。
//
// 用法：flutter test test/focus_fix_test.dart   （期望全绿）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/storage.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/ui/pages/favorites_page.dart';
import 'package:tvbox_flutter/ui/pages/history_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';

AppController buildController() {
  return AppController(storage: StorageService())..initialized = true;
}

/// 复刻 main.dart 的挂载方式（MultiProvider → Consumer → MaterialApp.forSkin），
/// 与 settings_back_test.dart 的 harness 同构；[library] 覆盖默认空 store。
Widget harness(AppController controller, Widget home, {LibraryStore? library}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      ChangeNotifierProvider<LibraryStore>(
        create: (_) => library ?? LibraryStore(),
      ),
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

/// 把一个页面 push 到根导航器上（复刻真实进入路径）。
void pushPage(WidgetTester tester, Widget page) {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.push(MaterialPageRoute<void>(builder: (_) => page));
}

VodItem vod(int index) =>
    VodItem(id: '$index', name: '测试影片 $index', remarks: '更新至 ${index + 1} 集');

LibraryStore favoritesLibrary() {
  final library = LibraryStore();
  library.favorites.addAll([vod(0), vod(1)]);
  return library;
}

void main() {
  testWidgets('收藏为空时进页焦点落在返回键，而非不可见的 FocusScope 根', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    pushPage(tester, const FavoritesPage());
    await tester.pumpAndSettle();

    expect(find.byType(FavoritesPage), findsOneWidget);
    // 空态无海报网格，默认焦点应落在可见的页头返回键上。
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'favorites-back');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('历史为空时进页焦点落在返回键，而非不可见的 FocusScope 根', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(controller, const Scaffold(body: SizedBox.expand())),
    );
    pushPage(tester, const HistoryPage());
    await tester.pumpAndSettle();

    expect(find.byType(HistoryPage), findsOneWidget);
    // 空态无行列表，默认焦点应落在可见的页头返回键上。
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'history-back');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收藏非空时进页焦点仍落在第一张海报，返回键不抢焦点', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = buildController();
    await tester.pumpWidget(
      harness(
        controller,
        const Scaffold(body: SizedBox.expand()),
        library: favoritesLibrary(),
      ),
    );
    pushPage(tester, const FavoritesPage());
    await tester.pumpAndSettle();

    expect(find.byType(FavoritesPage), findsOneWidget);
    // 非空态进页焦点落第一张海报（spec §4.1：未注入 entryFocus 时第 0 格
    // 用页面兜底入口节点，debugLabel 命名 '<page>-entry'，即 'favorites-entry'，
    // 与 history_page 的 'history-entry' 同惯例）。它就是首张海报的焦点节点；
    // 返回键 autofocus 仅在空态打开，非空态不抢焦点。
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'favorites-entry',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
