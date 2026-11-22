// Re-exported so existing `import 'core/utils.dart'` call sites keep working;
// the implementation lives with the TV overlay widgets.
export '../ui/widgets/tv_notice.dart' show showAppSnack;

String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String formatMilliseconds(int ms) => formatDuration(Duration(milliseconds: ms));

String formatRelativeTime(DateTime time) {
  final delta = DateTime.now().difference(time);
  if (delta.inMinutes < 1) return '刚刚';
  if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
  if (delta.inDays < 1) return '${delta.inHours} 小时前';
  if (delta.inDays < 7) return '${delta.inDays} 天前';
  return '${time.month}月${time.day}日';
}

String formatClock(DateTime time) {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  return '${time.month}月${time.day}日  星期${weekdays[time.weekday - 1]}  '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

String formatCount(int value) {
  if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
  return value.toString();
}

String safeText(String input, {String fallback = '—'}) {
  final text = input.trim();
  return text.isEmpty ? fallback : text;
}

String initials(String name) {
  final value = name.trim();
  if (value.isEmpty) return '?';
  return value.substring(0, value.length >= 2 ? 2 : 1);
}
