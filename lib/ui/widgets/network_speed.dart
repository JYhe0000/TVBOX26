import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/android_playback.dart';
import '../../core/stream_proxy_server.dart';
import '../../theme/ui.dart';

/// 网速显示的统计来源。
enum NetworkSpeedMode {
  /// 应用整体接收流量（默认，保持原有行为）。
  appStream,

  /// 当前视频流单独统计（走本地流代理 [StreamProxyStats]）。
  video,
}

class NetworkSpeed extends StatefulWidget {
  /// [mode] 选统计来源；[activeSessions]/[currentBytesPerSecond]/
  /// [totalServedBytes] 仅在 [NetworkSpeedMode.video] 下使用，默认读
  /// [StreamProxyServer.stats]，测试时可注入假数据。
  const NetworkSpeed({
    super.key,
    this.mode = NetworkSpeedMode.appStream,
    this.activeSessions,
    this.currentBytesPerSecond,
    this.totalServedBytes,
  });

  final NetworkSpeedMode mode;

  // 视频模式统计注入点（null 时读 StreamProxyServer.stats）。
  final int Function()? activeSessions;
  final int Function()? currentBytesPerSecond;
  final int Function()? totalServedBytes;

  @override
  State<NetworkSpeed> createState() => _NetworkSpeedState();
}

class _NetworkSpeedState extends State<NetworkSpeed> {
  Timer? _timer;
  int? _bytes;
  DateTime? _sampleAt;
  double? _rate;
  bool _busy = false;

  // 视频模式最近一次采样结果。
  int _sessions = 0;
  int _videoRate = 0;
  int _videoTotal = 0;

  int _readSessions() =>
      widget.activeSessions?.call() ?? StreamProxyServer.stats.activeSessions;

  int _readRate() =>
      widget.currentBytesPerSecond?.call() ??
      StreamProxyServer.stats.currentBytesPerSecond;

  int _readTotal() =>
      widget.totalServedBytes?.call() ??
      StreamProxyServer.stats.totalServedBytes;

  @override
  void initState() {
    super.initState();
    if (widget.mode == NetworkSpeedMode.video) {
      // 视频模式采样是同步 setState，须避开 initState，首帧后再取。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sample();
      });
    } else {
      _sample();
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sample());
  }

  Future<void> _sample() async {
    if (widget.mode == NetworkSpeedMode.video) {
      // 视频流统计是只读快照（3 秒滑动窗口），无需差分。
      if (!mounted) return;
      setState(() {
        _sessions = _readSessions();
        _videoRate = _readRate();
        _videoTotal = _readTotal();
      });
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      final bytes = await AndroidPlayback.receivedBytes();
      final now = DateTime.now();
      if (!mounted || bytes < 0) return;
      final previous = _bytes;
      final at = _sampleAt;
      if (previous != null && at != null && bytes >= previous) {
        final elapsed = now.difference(at).inMilliseconds;
        if (elapsed > 0) {
          setState(() => _rate = (bytes - previous) * 1000 / elapsed);
        }
      }
      _bytes = bytes;
      _sampleAt = now;
    } catch (_) {
      // 非 Android 或系统不支持时不显示估算值。
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    if (widget.mode == NetworkSpeedMode.video) {
      if (_sessions <= 0) {
        // 无转发会话时显示占位而非速率，避免误导。
        return Text(
          '视频流空闲',
          style: t.meta.copyWith(color: Colors.white.withValues(alpha: 0.55)),
        );
      }
      return Text(
        '视频流 ${(_videoRate / 1024).toStringAsFixed(0)} KB/s · '
        '累计 ${_formatBytes(_videoTotal)}',
        // 压在视频画面上，前景恒为白色（AGENTS.md §8.3）。
        style: t.label.copyWith(color: Colors.white),
      );
    }
    return _rate == null
        ? const SizedBox.shrink()
        : Text(
            '应用接收 ${(_rate! / 1024).toStringAsFixed(0)} KB/s',
            style: AppText.of(context).label.copyWith(color: Colors.white),
          );
  }

  /// 累计流量人性化换算（B → KB/MB/GB）。
  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 KB';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / kb).toStringAsFixed(1)} KB';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
