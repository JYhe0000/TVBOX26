import 'play_resolver.dart';
import 'site_api.dart';

/// 把播放链路的异常翻成用户能看懂、且可操作的提示。
///
/// 注意：不要用裸 `contains('404')` / `contains('host')` 这类子串判断——
/// URL 里的端口（`:4045`）、路径（`/4045/`）或域名（`ghost.example`）都会误命中。
/// 状态码只认 `Response code: 403`、`HTTP 403` 这类显式形态。
String friendlyPlaybackError(Object error) {
  if (error is PlayResolveException) return error.message;
  // ApiException 已经带可读文案（接口超时、HTTP 状态、Spider 阶段失败等）。
  if (error is ApiException) return error.message;
  final message = error.toString();
  final lower = message.toLowerCase();
  if (lower.contains('unknownhostexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('nodename nor servname')) {
    return '域名解析失败，可在设置中更换 DNS 后重试。';
  }
  final code = _statusCode(message);
  if (code != null) {
    if (code == 400) return '视频请求被拒绝（HTTP 400），请重试或切换线路。';
    if (code == 401 || code == 403) {
      return '视频服务器拒绝访问（$code），请切换线路或解析源后重试。';
    }
    if (code == 404 || code == 410) {
      return '视频地址已失效（$code），请切换线路或解析源。';
    }
    if (code >= 500) {
      return '视频服务器暂时不可用（$code），请稍后重试或切换线路。';
    }
    return '视频服务器返回 HTTP $code，请切换线路或解析源。';
  }
  if (lower.contains('failed to open')) {
    return '无法连接视频服务器，请检查网络后重试，或切换线路。';
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return '视频连接超时，请检查网络后重试，或切换线路。';
  }
  if (lower.contains('decoder') ||
      lower.contains('format') ||
      lower.contains('unsupported') ||
      lower.contains('codec')) {
    return '设备无法播放此视频格式，请切换线路或解析源。';
  }
  if (lower.contains('socket') ||
      lower.contains('connection') ||
      lower.contains('network')) {
    return '无法连接视频服务器，请检查网络后重试，或切换线路。';
  }
  return '视频加载失败，请重试，或切换线路与解析源。';
}

/// 只从显式形态里取状态码，避免 URL 端口/路径/文件名误判。
int? _statusCode(String message) {
  final match = RegExp(
    r'(?:response\s*code|status\s*code|http(?:/[\d.]+)?|code)\s*[:=]?\s*(\d{3})\b',
    caseSensitive: false,
  ).firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}