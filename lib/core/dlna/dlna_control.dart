import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'dlna_discovery.dart';

/// AVTransport 指令失败。message 是中文可操作文案，直接展示给用户。
class DlnaControlException implements Exception {
  const DlnaControlException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `GetPositionInfo` 的结果（已换算毫秒；解析失败的字段为 0）。
class DlnaPositionInfo {
  const DlnaPositionInfo({required this.positionMs, required this.durationMs});

  final int positionMs;
  final int durationMs;
}

/// XML 文本转义（DIDL-Lite 嵌入 SOAP 与 dc:title 都要走它）。
String escapeXmlText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 最小 DIDL-Lite 元数据（item + dc:title + upnp:class=videoItem + res）。
///
/// 标题与地址都经 [escapeXmlText] 转义；整段字符串之后会作为
/// `CurrentURIMetaData` 的**元素文本**再整体转义一次进 SOAP 报文。
String buildDidlLite({required String title, required String url}) {
  return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${escapeXmlText(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      // 固定兜底 protocolInfo：部分严格渲染器据此放行；按扩展名猜 MIME 反而不稳。
      '<res protocolInfo="http-get:*:*:*">${escapeXmlText(url)}</res>'
      '</item>'
      '</DIDL-Lite>';
}

/// 构造 AVTransport SOAP 报文体。
String buildSoapEnvelope(
  String serviceType,
  String action,
  Map<String, String> args,
) {
  final arguments = args.entries
      .map(
        (entry) => '<${entry.key}>${escapeXmlText(entry.value)}</${entry.key}>',
      )
      .join();
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body>'
      '<u:$action xmlns:u="$serviceType">$arguments</u:$action>'
      '</s:Body>'
      '</s:Envelope>';
}

/// 毫秒 → `H:MM:SS`（AVTransport Seek 的 REL_TIME Target 格式）。
String formatRelTime(int positionMs) {
  final clamped = positionMs < 0 ? 0 : positionMs;
  final hours = clamped ~/ Duration.millisecondsPerHour;
  final minutes =
      (clamped % Duration.millisecondsPerHour) ~/
      Duration.millisecondsPerMinute;
  final seconds =
      (clamped % Duration.millisecondsPerMinute) ~/
      Duration.millisecondsPerSecond;
  return '$hours:${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

/// `H:MM:SS`（可带 `.fraction`、可前导补零）→ 毫秒。
///
/// 分数秒（如 `0:00:01.500`）按毫秒解析，最多取 3 位，超长截断；
/// `NOT_IMPLEMENTED`、空串、非法格式返回 null。
int? parseRelTime(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split(':');
  if (parts.length != 3) return null;
  final secondsParts = parts[2].split('.');
  if (secondsParts.length > 2) return null;
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  final seconds = int.tryParse(secondsParts[0]);
  if (hours == null || minutes == null || seconds == null) return null;
  var ms = (hours * 3600 + minutes * 60 + seconds) * 1000;
  if (secondsParts.length == 2) {
    final fraction = secondsParts[1];
    // 分数秒必须是非空纯数字（`.5` / `.500` 都合法，空或杂字符非法）。
    if (fraction.isEmpty || !_digitsOnly.hasMatch(fraction)) return null;
    // 右补零到 3 位再截断：`.5`→500ms，`.50`→500ms，`.1234`→123ms。
    ms += int.parse(fraction.padRight(3, '0').substring(0, 3));
  }
  return ms;
}

final _digitsOnly = RegExp(r'^\d+$');

/// AVTransport SOAP 控制（SetAVTransportURI / Play / Pause / Stop /
/// Seek / GetPositionInfo / GetTransportInfo）。
class DlnaControl {
  // 保留公开命名参数 dio，内部客户端字段保持私有。
  // ignore: prefer_initializing_formals
  DlnaControl({Dio? dio}) : _dio = dio;

  Dio? _dio;

  /// 局域网 AVTransport SOAP 控制必须**直连**，不能接 [NetworkPolicy]：
  /// 用户配置的 HTTP 代理 / DoH 指向公网出口，私网 192.168.x.x 的
  /// 控制请求一旦被送出国代理必然失败，投屏指令到不了渲染器。
  /// 局域网流量永不绕代理，故此处用普通 Dio（超时仍为 5 秒级）。
  Dio get _client => _dio ??= Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      responseType: ResponseType.plain,
    ),
  );

  static const String _serviceType =
      'urn:schemas-upnp-org:service:AVTransport:1';

  /// 设置播放地址（CurrentURIMetaData 携带最小 DIDL-Lite）。
  Future<void> setUri(DlnaDevice device, String url, String title) async {
    await _post(device, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': url,
      'CurrentURIMetaData': buildDidlLite(title: title, url: url),
    });
  }

  Future<void> play(DlnaDevice device) async {
    await _post(device, 'Play', {'InstanceID': '0', 'Speed': '1'});
  }

  Future<void> pause(DlnaDevice device) async {
    await _post(device, 'Pause', {'InstanceID': '0'});
  }

  Future<void> stop(DlnaDevice device) async {
    await _post(device, 'Stop', {'InstanceID': '0'});
  }

  /// Seek（Unit=REL_TIME，Target `H:MM:SS`）。
  Future<void> seek(DlnaDevice device, int positionMs) async {
    await _post(device, 'Seek', {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': formatRelTime(positionMs),
    });
  }

  /// GetPositionInfo → RelTime / TrackDuration（毫秒）。
  Future<DlnaPositionInfo> positionInfo(DlnaDevice device) async {
    final doc = await _post(device, 'GetPositionInfo', {'InstanceID': '0'});
    final relTime = _firstText(doc, 'RelTime');
    final duration = _firstText(doc, 'TrackDuration');
    return DlnaPositionInfo(
      positionMs: parseRelTime(relTime) ?? 0,
      durationMs: parseRelTime(duration) ?? 0,
    );
  }

  /// GetTransportInfo → PLAYING / PAUSED_PLAYBACK / STOPPED / …。
  Future<String> transportInfo(DlnaDevice device) async {
    final doc = await _post(device, 'GetTransportInfo', {'InstanceID': '0'});
    return _firstText(doc, 'CurrentTransportState') ?? 'STOPPED';
  }

  Future<XmlDocument> _post(
    DlnaDevice device,
    String action,
    Map<String, String> args,
  ) async {
    final body = buildSoapEnvelope(_serviceType, action, args);
    Response<String> response;
    try {
      response = await _client.post<String>(
        device.avTransportControlUrl.toString(),
        data: body,
        options: Options(
          contentType: 'text/xml; charset="utf-8"',
          headers: {'SOAPACTION': '"$_serviceType#$action"'},
          // SOAP Fault 走 HTTP 500 + body：状态码不抛异常，统一在下面解析。
          validateStatus: (status) => true,
        ),
      );
    } catch (_) {
      throw DlnaControlException('投屏指令发送失败（$action），请确认设备仍在线');
    }
    final text = response.data ?? '';
    XmlDocument? doc;
    try {
      doc = text.isEmpty ? null : XmlDocument.parse(text);
    } catch (_) {
      doc = null;
    }
    final fault = doc == null ? null : _faultMessage(doc);
    if (fault != null) {
      throw DlnaControlException('设备拒绝了播放指令（$fault），请尝试其它设备或本机播放');
    }
    if (response.statusCode != 200) {
      throw DlnaControlException(
        '设备返回了异常状态（HTTP ${response.statusCode}），请尝试其它设备或本机播放',
      );
    }
    if (doc == null) {
      throw DlnaControlException('设备返回了无法解析的响应，请尝试其它设备或本机播放');
    }
    return doc;
  }

  /// SOAP Fault → UPnPError 的 errorCode / errorDescription 摘要。
  /// 无 Fault 时返回 null。
  static String? _faultMessage(XmlDocument doc) {
    var hasFault = false;
    for (final node in doc.descendants) {
      if (node is XmlElement && node.name.local == 'Fault') {
        hasFault = true;
        break;
      }
    }
    if (!hasFault) return null;
    final code = _firstText(doc, 'errorCode');
    final description = _firstText(doc, 'errorDescription');
    if (code != null && code.isNotEmpty) {
      return description != null && description.isNotEmpty
          ? '错误码 $code（$description）'
          : '错误码 $code';
    }
    return description;
  }

  /// 按 local name 找第一个元素的文本（SOAP 响应无固定命名空间前缀，
  /// 直接扫 descendants 最稳）。
  static String? _firstText(XmlDocument doc, String name) {
    for (final node in doc.descendants) {
      if (node is XmlElement && node.name.local == name) {
        return node.innerText.trim();
      }
    }
    return null;
  }
}
