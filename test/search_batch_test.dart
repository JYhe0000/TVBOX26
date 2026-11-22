import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/search_batch.dart';

void main() {
  test('同一队列逐站派发，其他队列可以先返回', () async {
    final slow = Completer<void>();
    final otherLaneStarted = Completer<void>();
    final started = <int>[];
    final batch = runSearchBatch(
      [0, 1, 2, 3, 4],
      isCurrent: () => true,
      laneFor: (site) => site < 3 ? 0 : 1,
      search: (site) async {
        started.add(site);
        if (site == 3) otherLaneStarted.complete();
        if (site == 0) await slow.future;
      },
    );
    await otherLaneStarted.future;
    // 队列 0 被站点 0 阻挡，队列 1 的站点 3 可以先启动。
    expect(started, containsAll([0, 3]));
    slow.complete();
    await batch;
    // 所有站点最终都被启动。
    expect(started, containsAll([0, 1, 2, 3, 4]));
  });

  test('慢站不阻止其他站点继续搜索，超过 12 个站点也会被搜索', () async {
    final slow = Completer<void>();
    final othersFinished = Completer<void>();
    final completed = <int>[];
    var active = 0;
    var peak = 0;
    final batch = runSearchBatch(
      List.generate(35, (index) => index),
      isCurrent: () => true,
      search: (index) async {
        active++;
        if (active > peak) peak = active;
        await (index == 0 ? slow.future : Future<void>.value());
        completed.add(index);
        active--;
        if (completed.length == 34) othersFinished.complete();
      },
    );
    await othersFinished.future;
    expect(completed, isNot(contains(0)));
    expect(completed, contains(34));
    expect(peak, 5);
    slow.complete();
    await batch;
    expect(completed.last, 0);
  });

  test('更换搜索词后停止派发旧一批搜索任务', () async {
    var current = true;
    final inFlight = Completer<void>();
    final started = <int>[];
    final batch = runSearchBatch(
      List.generate(12, (index) => index),
      isCurrent: () => current,
      search: (index) async {
        started.add(index);
        await inFlight.future;
      },
    );
    current = false;
    inFlight.complete();
    await batch;
    expect(started, [0, 1, 2, 3, 4]);
  });
}
