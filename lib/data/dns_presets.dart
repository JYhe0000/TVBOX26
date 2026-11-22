import 'dart:convert';
import 'dart:typed_data';

const dnsPresets = {
  '关闭': '',
  '腾讯': 'https://doh.pub/dns-query',
  '阿里': 'https://dns.alidns.com/dns-query',
  '360': 'https://doh.360.cn/dns-query',
  'Google': 'https://dns.google/dns-query',
  'AdGuard': 'https://dns.adguard.com/dns-query',
  'Quad9': 'https://dns.quad9.net/dns-query',
};

List<int> dnsQuestion(String host) {
  final labels = host.replaceFirst(RegExp(r'\.$'), '').split('.');
  final bytes = <int>[0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final label in labels) {
    final data = ascii.encode(label);
    if (data.isEmpty || data.length > 63) throw const FormatException();
    bytes.addAll([data.length, ...data]);
  }
  if (bytes.length > 266) throw const FormatException();
  return bytes..addAll([0, 0, 1, 0, 1]);
}

(String, int)? dnsAnswer(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12 || data.getUint16(0) != 0 ||
      data.getUint16(2) & 0x820f != 0x8000 || data.getUint16(4) != 1) {
    return null;
  }
  var pos = 12;
  void skipName() {
    while (true) {
      final size = bytes[pos++];
      if (size == 0) return;
      if (size & 0xc0 == 0xc0) {
        pos++;
        return;
      }
      if (size > 63) throw const FormatException();
      pos += size;
    }
  }
  skipName();
  pos += 4;
  for (var i = 0; i < data.getUint16(6); i++) {
    skipName();
    final type = data.getUint16(pos);
    final cls = data.getUint16(pos + 2);
    final ttl = data.getUint32(pos + 4);
    final size = data.getUint16(pos + 8);
    pos += 10;
    if (type == 1 && cls == 1 && size == 4) {
      // 与 JSON DoH 路径统一：TTL=0 视为最小缓存 1 秒，避免每条请求都重新解析。
      return (bytes.sublist(pos, pos + 4).join('.'), ttl.clamp(1, 300));
    }
    pos += size;
  }
  return null;
}
