Future<void> runSearchBatch<T>(
  List<T> sites, {
  required bool Function() isCurrent,
  required Future<void> Function(T) search,
  int Function(T)? laneFor,
}) async {
  final pending = [
    for (final site in sites) (site: site, lane: laneFor?.call(site) ?? -1),
  ];
  final activeLanes = <int>{};
  Future<void> worker() async {
    while (isCurrent()) {
      final index = pending.indexWhere(
        (entry) => entry.lane < 0 || !activeLanes.contains(entry.lane),
      );
      if (index < 0) return;
      final entry = pending.removeAt(index);
      final lane = entry.lane;
      if (lane >= 0) activeLanes.add(lane);
      try {
        await search(entry.site);
      } finally {
        if (lane >= 0) activeLanes.remove(lane);
      }
    }
  }

  // 与参考 Box 的搜索并发上限一致，单站完成后立即启动下一站。
  await Future.wait(List.generate(sites.length.clamp(0, 5), (_) => worker()));
}
