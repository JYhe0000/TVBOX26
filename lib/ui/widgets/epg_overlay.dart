import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../data/epg_service.dart';
import '../../theme/ui.dart';

class EpgOverlay extends StatefulWidget {
  const EpgOverlay({
    super.key,
    required this.url,
    required this.channel,
    this.service,
  });
  final String url;
  final String channel;
  final EpgService? service;

  @override
  State<EpgOverlay> createState() => _EpgOverlayState();
}

class _EpgOverlayState extends State<EpgOverlay> {
  late final EpgService _service = widget.service ?? EpgService();
  EpgSchedule? _schedule;
  String? _status;
  Timer? _timer;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void didUpdateWidget(EpgOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel || oldWidget.url != widget.url) {
      _schedule = null;
      _load();
    }
  }

  Future<void> _load() async {
    final token = ++_token;
    if (widget.url.isEmpty) return;
    try {
      final schedule = await _service.load(widget.url, widget.channel);
      if (!mounted || token != _token) return;
      setState(() {
        _schedule = schedule;
        _status = null;
      });
    } catch (_) {
      if (mounted && token == _token) setState(() => _status = '节目单暂不可用');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    return EpgSummary(
      current: _schedule?.current(now)?.title,
      next: _schedule?.next(now)?.title,
      status: _status ?? (_schedule == null ? '正在加载节目单…' : '暂无节目单'),
    );
  }
}

class EpgSummary extends StatelessWidget {
  const EpgSummary({super.key, this.current, this.next, this.status = '暂无节目单'});
  final String? current;
  final String? next;
  final String status;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    // 节目单压在直播画面上，前景固定白色，沿用播放器可读性约束。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          current == null ? status : '正在播  $current',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodyStrong.copyWith(color: Colors.white),
        ),
        if (next != null)
          Text(
            '下一档  $next',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.body.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
      ],
    );
  }
}

@Preview(name: '直播节目单', size: Size(560, 120))
Widget epgSummaryPreview() => MaterialApp(
  theme: AppTheme.forSkin(TvSkinId.netflix),
  home: const Scaffold(
    body: Center(
      child: EpgSummary(current: '新闻联播', next: '天气预报'),
    ),
  ),
);
