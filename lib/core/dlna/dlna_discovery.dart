import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// 局域网里一台可投屏的 DLNA/UPnP 媒体渲染器（MediaRenderer）。
class DlnaDevice {
  const DlnaDevice({
    required this.udn,
    required this.friendlyName,
    required this.descriptionUrl,
    required this.avTransportControlUrl,
    this.productName,
  });

  /// 设备唯一标识（`uuid:…`），来自设备描述 XML 的 `UDN` 元素。
  final String udn;

  /// 用户可见名称（`friendlyName`），设备选择列表展示用。
  final String friendlyName;

  /// 设备描述 XML 的地址（SSDP 响应里的 `LOCATION`）。
  final Uri descriptionUrl;

  /// AVTransport 服务的 SOAP 控制地址（已按 URLBase/LOCATION 基址 resolve）。
  final Uri avTransportControlUrl;

  /// 设备型号名（`modelName`），列表副行展示用，可为空。
  final String? productName;

  /// 同一 UDN 视为同一台设备（SSDP 双 ST 搜索会重复应答）。
  @override
  bool operator ==(Object other) => other is DlnaDevice && other.udn == udn;

  @override
  int get hashCode => udn.hashCode;
}

/// 按 UDN 去重，保留先出现的设备。
///
/// M-SEARCH 双 ST（MediaRenderer:1 + ssdp:all）会让同一设备应答两次，
/// 描述拉取也会因此并发两路，这里保证最终列表里 UDN 唯一。
List<DlnaDevice> dedupeDevices(Iterable<DlnaDevice> devices) {
  final seen = <String>{};
  final result = <DlnaDevice>[];
  for (final device in devices) {
    if (seen.add(device.udn)) result.add(device);
  }
  return result;
}

/// 构造 M-SEARCH 报文（SSDP 发现请求）。
String buildMsearch(String st, {int mx = 3}) {
  return 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $_ssdpAddress:$_ssdpPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: $mx\r\n'
      'ST: $st\r\n'
      '\r\n';
}

const _ssdpAddress = '239.255.255.250';
const _ssdpPort = 1900;

/// M-SEARCH 的两种搜索目标：精确 MediaRenderer 与全量（兜底发现
/// deviceList 嵌套渲染器、厂商私有命名的设备）。
const _searchTargets = [
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'ssdp:all',
];

/// 从 SSDP 响应（HTTP 200 文本）里提取 `LOCATION` 头。
///
/// 返回 null 表示这不是可用的 M-SEARCH 应答（NOTIFY 通知、缺头等）。
Uri? parseSsdpLocation(String raw) {
  if (!raw.startsWith('HTTP/1.')) return null;
  // 行分隔兼容 CRLF 与裸 LF（个别嵌入式设备栈只发 LF）。
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final index = line.indexOf(':');
    if (index <= 0) continue;
    final name = line.substring(0, index).trim().toUpperCase();
    if (name != 'LOCATION') continue;
    final value = line.substring(index + 1).trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }
  return null;
}

/// `deviceType` 是否为 MediaRenderer（接受 1/2/3 版本与厂商命名空间）。
bool isMediaRenderer(String deviceType) {
  final parts = deviceType.split(':');
  return parts.length >= 5 &&
      parts[2] == 'device' &&
      parts[3] == 'MediaRenderer';
}

/// 解析设备描述 XML，返回带 AVTransport 控制地址的 MediaRenderer。
///
/// - 非法 XML / 非 MediaRenderer / 缺 UDN、friendlyName、AVTransport
///   service 一律返回 null（调用方静默跳过该设备）。
/// - 相对 `controlURL` 按 `URLBase`（若为绝对地址）或 `LOCATION` 基址
///   resolve 成绝对地址；绝对 `controlURL` 原样保留。
/// - 支持 `deviceList` 里嵌套的子设备（部分电视把渲染器挂在服务器下）。
DlnaDevice? parseDeviceDescription(String xml, {required Uri location}) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (_) {
    return null;
  }
  final root = doc.rootElement;

  Uri base = location;
  final urlBaseText = root.getElement('URLBase')?.innerText.trim() ?? '';
  if (urlBaseText.isNotEmpty) {
    final parsed = Uri.tryParse(urlBaseText);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      base = parsed;
    }
  }

  DlnaDevice? found;
  void walk(XmlElement deviceNode) {
    if (found != null) return;
    final deviceType =
        deviceNode.getElement('deviceType')?.innerText.trim() ?? '';
    if (isMediaRenderer(deviceType)) {
      final friendlyName = deviceNode
          .getElement('friendlyName')
          ?.innerText
          .trim();
      final udn = deviceNode.getElement('UDN')?.innerText.trim();
      final controlUrl = _findAvTransportControlUrl(deviceNode, base);
      if (friendlyName != null &&
          friendlyName.isNotEmpty &&
          udn != null &&
          udn.isNotEmpty &&
          controlUrl != null) {
        found = DlnaDevice(
          udn: udn,
          friendlyName: friendlyName,
          descriptionUrl: location,
          avTransportControlUrl: controlUrl,
          productName: deviceNode.getElement('modelName')?.innerText.trim(),
        );
        return;
      }
    }
    for (final list in deviceNode.findElements('deviceList')) {
      for (final sub in list.findElements('device')) {
        walk(sub);
        if (found != null) return;
      }
    }
  }

  for (final deviceNode in root.findElements('device')) {
    walk(deviceNode);
    if (found != null) break;
  }
  return found;
}

Uri? _findAvTransportControlUrl(XmlElement deviceNode, Uri base) {
  for (final serviceList in deviceNode.findElements('serviceList')) {
    for (final service in serviceList.findElements('service')) {
      final serviceType =
          service.getElement('serviceType')?.innerText.trim() ?? '';
      if (!serviceType.contains(':service:AVTransport:')) continue;
      final controlUrl =
          service.getElement('controlURL')?.innerText.trim() ?? '';
      if (controlUrl.isEmpty) continue;
      final absolute = Uri.tryParse(controlUrl);
      if (absolute != null && absolute.hasScheme) return absolute;
      return base.resolve(controlUrl);
    }
  }
  return null;
}

/// SSDP 设备发现 + 设备描述拉取。
///
/// M-SEARCH 的响应是**单播**回包：绑定随机端口直接向组播地址发送即可，
/// 不需要加入组播组，也不需要 AndroidManifest 权限 / MulticastLock。
///
/// 时序：每台设备描述拉取完成即通过 [onDevices] 推送当前全量列表
/// （首屏不等满 8 秒），[total] 到点后收尾返回最终列表；单设备失败
/// 静默跳过。默认发两种 ST（`MediaRenderer:1` 精确 + `ssdp:all` 兜底），
/// 按 LOCATION 去重请求、按 UDN 去重结果。
class DlnaDiscovery {
  // 保留公开命名参数 dio，内部客户端字段保持私有。
  // ignore: prefer_initializing_formals
  DlnaDiscovery({Dio? dio}) : _dio = dio;

  Dio? _dio;

  /// 局域网 SSDP 描述拉取必须**直连**，不能接 [NetworkPolicy]：
  /// 用户配置的 HTTP 代理 / DoH 指向公网出口，组播发现与私网
  /// 192.168.x.x 的描述请求一旦被送出国代理必然超时，投屏直接失败。
  /// 局域网流量永不绕代理，故此处用普通 Dio（超时仍为 5 秒级）。
  Dio get _client => _dio ??= Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      responseType: ResponseType.plain,
    ),
  );

  /// 扫描局域网。总时长默认 8 秒；[onDevices] 在每台设备就绪时回调。
  Future<List<DlnaDevice>> scan({
    Duration total = const Duration(seconds: 8),
    void Function(List<DlnaDevice>)? onDevices,
  }) async {
    final devices = <DlnaDevice>[];
    final udnSeen = <String>{};
    final locationsSeen = <String>{};
    final fetches = <Future<void>>[];

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
    } catch (_) {
      // 网络栈不可用（无 Wi-Fi 等）：按「没发现设备」处理，不阻断 UI。
      return devices;
    }

    StreamSubscription<RawSocketEvent>? subscription;
    try {
      for (final st in _searchTargets) {
        socket.send(
          utf8.encode(buildMsearch(st)),
          InternetAddress(_ssdpAddress),
          _ssdpPort,
        );
      }
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final raw = utf8.decode(datagram.data, allowMalformed: true);
        final location = parseSsdpLocation(raw);
        if (location == null) return;
        if (!locationsSeen.add(location.toString())) return;
        fetches.add(
          _fetchDevice(location).then((device) {
            if (device == null) return;
            if (!udnSeen.add(device.udn)) return;
            devices.add(device);
            if (onDevices != null) {
              // 快照 + 去重防御：调用方拿到的永远是稳定列表。
              onDevices(dedupeDevices(devices));
            }
          }),
        );
      });

      final deadline = DateTime.now().add(total);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      // 描述拉取自带 5s 超时；这里再兜底 3s，避免个别慢设备拖垮收尾。
      try {
        await Future.wait(fetches).timeout(const Duration(seconds: 3));
      } catch (_) {}
    } finally {
      await subscription?.cancel();
      socket.close();
    }
    return dedupeDevices(devices);
  }

  Future<DlnaDevice?> _fetchDevice(Uri location) async {
    try {
      final response = await _client.get<String>(location.toString());
      final body = response.data;
      if (body == null || body.isEmpty) return null;
      return parseDeviceDescription(body, location: location);
    } catch (_) {
      // 单设备失败（离线、超时、XML 损坏）静默跳过。
      return null;
    }
  }
}
