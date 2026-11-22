import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/theme/app_theme.dart';
import 'package:tvbox_flutter/theme/skin.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/shelf_row.dart';

void main() {
  testWidgets('ShelfRow renders horizontal geometry and clamped scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const height = 180.0;
    const itemExtent = 120.0;
    const separator = 12.0;
    const padding = EdgeInsets.symmetric(horizontal: 20);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: const Scaffold(
          body: SizedBox(
            width: 600,
            height: height,
            child: ShelfRow(
              itemCount: 4,
              itemExtent: itemExtent,
              separator: separator,
              padding: padding,
              itemBuilder: _itemBuilder,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollDirection, Axis.horizontal);
    expect(list.physics, isA<ClampingScrollPhysics>());

    expect(tester.getSize(find.byType(ShelfRow)).height, height);
    expect(
      tester.getSize(find.byKey(const ValueKey('item-0'))).width,
      itemExtent,
    );
    expect(tester.getSize(find.byKey(const ValueKey('item-0'))).height, height);

    final item0 = tester.getTopLeft(find.byKey(const ValueKey('item-0')));
    final item1 = tester.getTopLeft(find.byKey(const ValueKey('item-1')));
    expect(item1.dx - item0.dx, itemExtent + separator);
  });

  testWidgets('ShelfRow restores the last focused index after re-entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outside = FocusNode(debugLabel: 'outside');
    addTearDown(outside.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 600,
                height: 160,
                child: ShelfRow(
                  itemCount: 5,
                  itemExtent: 120,
                  itemBuilder: _itemBuilder,
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

    final item0 = _focusNodeFor(tester, 0);
    final item3 = _focusNodeFor(tester, 3);
    item0.requestFocus();
    await tester.pumpAndSettle();
    item3.requestFocus();
    await tester.pumpAndSettle();
    expect(item3.hasFocus, isTrue);

    outside.requestFocus();
    await tester.pumpAndSettle();
    expect(outside.hasFocus, isTrue);

    item3.requestFocus();
    await tester.pumpAndSettle();
    expect(item3.hasFocus, isTrue);
  });

  testWidgets('ShelfRow shrinks without crashing and reports focus order', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outside = FocusNode(debugLabel: 'shrink-outside');
    final focusLog = <int>[];
    var count = 4;
    addTearDown(outside.dispose);

    late StateSetter setCount;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setCount = setState;
              return Column(
                children: [
                  SizedBox(
                    width: 600,
                    height: 160,
                    child: ShelfRow(
                      itemCount: count,
                      itemExtent: 120,
                      onFocusIndex: focusLog.add,
                      itemBuilder: (context, index, node) => _item(index),
                    ),
                  ),
                  Focus(
                    focusNode: outside,
                    child: const SizedBox(width: 20, height: 20),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    _focusNodeFor(tester, 0).requestFocus();
    await tester.pumpAndSettle();
    _focusNodeFor(tester, 1).requestFocus();
    await tester.pumpAndSettle();
    _focusNodeFor(tester, 2).requestFocus();
    await tester.pumpAndSettle();

    expect(focusLog, <int>[1, 2]);

    setCount(() => count = 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ShelfRow), findsOneWidget);
  });

  testWidgets('ShelfRow vertical geometry with self-sized items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const rowHeight = 44.0;
    const separator = 4.0;
    const hPad = 10.0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 400,
              child: ShelfRow(
                scrollDirection: Axis.vertical,
                itemCount: 5,
                separator: separator,
                padding: EdgeInsets.symmetric(horizontal: hPad),
                itemBuilder: _verticalItemBuilder,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollDirection, Axis.vertical);
    expect(list.physics, isA<ClampingScrollPhysics>());

    // 垂直模式忽略 height：高度来自外部约束（这里 SizedBox 400）。
    expect(tester.getSize(find.byType(ShelfRow)).height, 400);

    // 每项自决高度；padding 只吃掉 cross axis（左右各 hPad）。
    expect(
      tester.getSize(find.byKey(const ValueKey('v-item-0'))).height,
      rowHeight,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('v-item-0'))).width,
      300 - hPad * 2,
    );

    // separator 是纵向间距。
    final top0 = tester.getTopLeft(find.byKey(const ValueKey('v-item-0')));
    final top1 = tester.getTopLeft(find.byKey(const ValueKey('v-item-1')));
    expect(top1.dy - top0.dy, rowHeight + separator);

    // 首末项获焦：渲染无异常（光晕/放大被 viewport 轻裁不算 overflow）。
    _focusNodeFor(tester, 0, prefix: 'v-item-').requestFocus();
    await tester.pumpAndSettle();
    expect(_focusNodeFor(tester, 0, prefix: 'v-item-').hasFocus, isTrue);
    expect(tester.takeException(), isNull);

    _focusNodeFor(tester, 4, prefix: 'v-item-').requestFocus();
    await tester.pumpAndSettle();
    expect(_focusNodeFor(tester, 4, prefix: 'v-item-').hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ShelfRow vertical restores the last focused index after '
      're-entry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outside = FocusNode(debugLabel: 'outside');
    addTearDown(outside.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Column(
            children: [
              Focus(
                focusNode: outside,
                child: const SizedBox(width: 20, height: 20),
              ),
              Expanded(
                child: ShelfRow(
                  scrollDirection: Axis.vertical,
                  itemCount: 5,
                  itemBuilder: _verticalItemBuilder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final item0 = _focusNodeFor(tester, 0, prefix: 'v-item-');
    final item3 = _focusNodeFor(tester, 3, prefix: 'v-item-');
    item0.requestFocus();
    await tester.pumpAndSettle();
    item3.requestFocus();
    await tester.pumpAndSettle();
    expect(item3.hasFocus, isTrue);

    outside.requestFocus();
    await tester.pumpAndSettle();
    expect(outside.hasFocus, isTrue);

    // 再进入行：落回上次聚焦的 index 3（逐行记忆）。
    item3.requestFocus();
    await tester.pumpAndSettle();
    expect(item3.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ShelfRow smoothly restores a recycled item and cancels stale '
      'focus after leaving', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outside = FocusNode(debugLabel: 'restore-outside');
    final controller = ScrollController();
    addTearDown(outside.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: SizedBox(
                  width: 360,
                  child: ShelfRow(
                    scrollDirection: Axis.vertical,
                    controller: controller,
                    itemCount: 40,
                    itemExtent: 60,
                    itemBuilder: _verticalItemBuilder,
                  ),
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

    // 记住第 20 项，然后把它滚出懒列表挂载区。
    controller.jumpTo(20 * 60);
    await tester.pumpAndSettle();
    final remembered = _focusNodeFor(tester, 20, prefix: 'v-item-');
    remembered.requestFocus();
    await tester.pumpAndSettle();
    outside.requestFocus();
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pump();
    expect(remembered.context?.mounted, isNot(true));

    final rowFocus = tester
        .widget<Focus>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Focus && widget.focusNode?.debugLabel == 'shelf-row',
          ),
        )
        .focusNode!;
    rowFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(20 * 60));

    await tester.pumpAndSettle();
    expect(remembered.hasFocus, isTrue);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('v-item-20')))
          .overlaps(tester.getRect(find.byType(ShelfRow))),
      isTrue,
    );

    // 新恢复尚未结束就离开行，旧完成回调不能再把焦点拉回来。
    outside.requestFocus();
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pump();
    rowFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    outside.requestFocus();
    await tester.pumpAndSettle();
    expect(outside.hasFocus, isTrue);
    expect(remembered.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ShelfRow controlled memory node mounts on the remembered row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final memory = FocusNode(debugLabel: 'memory');
    final memoryIndex = ValueNotifier<int>(0);
    final outside = FocusNode(debugLabel: 'outside');
    addTearDown(memory.dispose);
    addTearDown(memoryIndex.dispose);
    addTearDown(outside.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Column(
            children: [
              Focus(
                focusNode: outside,
                child: const SizedBox(width: 20, height: 20),
              ),
              Expanded(
                child: ShelfRow(
                  scrollDirection: Axis.vertical,
                  memoryFocus: memory,
                  memoryIndex: memoryIndex,
                  itemCount: 4,
                  itemBuilder: _verticalItemBuilder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始：外部节点挂到 memoryIndex 指向的行（0），其余行用内部节点。
    expect(_focusNodeFor(tester, 0, prefix: 'v-item-'), memory);
    expect(_focusNodeFor(tester, 1, prefix: 'v-item-'), isNot(memory));

    // 页面侧投递：requestFocus 落在记忆行。
    memory.requestFocus();
    await tester.pumpAndSettle();
    expect(memory.hasFocus, isTrue);

    // 模拟行内移动 + 页面同步索引：换位后焦点不中断、不丢。
    _focusNodeFor(tester, 2, prefix: 'v-item-').requestFocus();
    await tester.pumpAndSettle();
    memoryIndex.value = 2;
    await tester.pumpAndSettle();
    expect(_focusNodeFor(tester, 2, prefix: 'v-item-'), memory);
    expect(_focusNodeFor(tester, 0, prefix: 'v-item-'), isNot(memory));
    expect(memory.hasFocus, isTrue);

    // memoryIndex 变化不抢焦：焦点在行外时只换挂载项。
    outside.requestFocus();
    await tester.pumpAndSettle();
    memoryIndex.value = 1;
    await tester.pumpAndSettle();
    expect(outside.hasFocus, isTrue);
    expect(_focusNodeFor(tester, 1, prefix: 'v-item-'), memory);
    expect(_focusNodeFor(tester, 2, prefix: 'v-item-'), isNot(memory));
  });

  testWidgets(
    'horizontal ShelfRow defers memory-node reparent while navigating',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final memory = FocusNode(debugLabel: 'horizontal-memory');
      final memoryIndex = ValueNotifier<int>(0);
      final outside = FocusNode(debugLabel: 'horizontal-outside');
      addTearDown(memory.dispose);
      addTearDown(memoryIndex.dispose);
      addTearDown(outside.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.forSkin(TvSkinId.smartisan),
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: outside,
                  child: const SizedBox(width: 20, height: 20),
                ),
                ShelfRow(
                  height: 120,
                  itemExtent: 120,
                  memoryFocus: memory,
                  memoryIndex: memoryIndex,
                  itemCount: 4,
                  itemBuilder: _verticalItemBuilder,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      memory.requestFocus();
      await tester.pumpAndSettle();
      final thirdItem = _focusNodeFor(tester, 2, prefix: 'v-item-');
      thirdItem.requestFocus();
      await tester.pumpAndSettle();
      memoryIndex.value = 2;
      await tester.pumpAndSettle();

      expect(_focusNodeFor(tester, 2, prefix: 'v-item-'), isNot(memory));
      expect(FocusManager.instance.primaryFocus, same(thirdItem));

      outside.requestFocus();
      await tester.pumpAndSettle();
      expect(_focusNodeFor(tester, 2, prefix: 'v-item-'), memory);
      expect(outside.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('ShelfRow external delivery wins over restore and becomes the '
      'new memory', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outside = FocusNode(debugLabel: 'outside');
    final focusLog = <int>[];
    addTearDown(outside.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(
          body: Column(
            children: [
              Focus(
                focusNode: outside,
                child: const SizedBox(width: 20, height: 20),
              ),
              Expanded(
                child: ShelfRow(
                  scrollDirection: Axis.vertical,
                  itemCount: 4,
                  onFocusIndex: focusLog.add,
                  itemBuilder: _verticalItemBuilder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 记忆在 index 2，然后焦点离开行。
    _focusNodeFor(tester, 2, prefix: 'v-item-').requestFocus();
    await tester.pumpAndSettle();
    expect(focusLog, <int>[2]);
    outside.requestFocus();
    await tester.pumpAndSettle();

    // 外部显式投递到 index 0：落点必须是 0（行根恢复让位），记忆
    // 同步变成 0（新落点成为新记忆）。
    _focusNodeFor(tester, 0, prefix: 'v-item-').requestFocus();
    await tester.pumpAndSettle();
    expect(_focusNodeFor(tester, 0, prefix: 'v-item-').hasFocus, isTrue);
    expect(focusLog, <int>[2, 0]);

    // 隔一段异步时间焦点不漂移（post-frame 补投不回旧记忆）。
    await tester.pump(const Duration(milliseconds: 400));
    expect(_focusNodeFor(tester, 0, prefix: 'v-item-').hasFocus, isTrue);
    expect(
      FocusManager.instance.primaryFocus,
      _focusNodeFor(tester, 0, prefix: 'v-item-'),
    );
  });
}

Widget _itemBuilder(BuildContext context, int index, FocusNode node) {
  return _item(index);
}

/// 纵向测试项：node 透传给 TvFocusable（挂载权归调用方的标准用法），
/// 每项自决高度 44。
Widget _verticalItemBuilder(BuildContext context, int index, FocusNode node) {
  return TvFocusable(
    focusNode: node,
    onTap: () {},
    child: SizedBox(
      key: ValueKey('v-item-$index'),
      height: 44,
      child: Center(child: Text('item $index')),
    ),
  );
}

/// 项内容的最近祖先 Focus 节点：TvFocusable 用法下即 ShelfRow 交给
/// itemBuilder 的节点（哨兵 Focus 是更外层的记账节点，不参与）。
FocusNode _focusNodeFor(
  WidgetTester tester,
  int index, {
  String prefix = 'item-',
}) {
  final element = tester.element(find.byKey(ValueKey('$prefix$index')));
  return Focus.of(element);
}

Widget _item(int index) {
  return Container(
    key: ValueKey('item-$index'),
    alignment: Alignment.center,
    color: const Color(0xFF202020),
    child: Text('item $index'),
  );
}
