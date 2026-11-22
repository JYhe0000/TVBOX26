import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/core/dlna/dlna_control.dart';
import 'package:tvbox_flutter/core/dlna/dlna_discovery.dart';
import 'package:tvbox_flutter/data/network_policy.dart';
import 'package:xml/xml.dart';

/// 标准 DLNA/UPnP 投屏回归：
/// - 纯函数范式（参照 p2_services_test）：SSDP 报文、描述 XML 解析、
///   DIDL-Lite/SOAP 构造、REL_TIME 互逆与分数秒。
/// - 本地 HttpServer mock 范式（参照 stream_proxy_test）：起本地
///   AVTransport 端点，断言 SOAPACTION 头、参数、Fault / HTTP 500 /
///   网络错误路径，以及「NetworkPolicy 配置代理后 SOAP 仍直连达 mock」。
void main() {
  group('SSDP 报文构造与响应解析', () {
    test('buildMsearch：请求行与 HOST/MAN/MX/ST 头齐全', () {
      final msg = buildMsearch(
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        mx: 2,
      );
      final lines = msg.split('\r\n');
      expect(lines[0], 'M-SEARCH * HTTP/1.1');
      expect(lines[1], 'HOST: 239.255.255.250:1900');
      expect(lines[2], 'MAN: "ssdp:discover"');
      expect(lines[3], 'MX: 2');
      expect(lines[4], 'ST: urn:schemas-upnp-org:device:MediaRenderer:1');
      expect(lines[5], '');
      // 报文以空行收尾（SSDP 请求头结束符）。
      expect(msg.endsWith('\r\n\r\n'), isTrue);
    });

    test('parseSsdpLocation：提取 HTTP/1.1 应答的 LOCATION', () {
      const response = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: http://192.168.1.10:49152/desc.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          '\r\n';
      expect(
        parseSsdpLocation(response),
        Uri.parse('http://192.168.1.10:49152/desc.xml'),
      );
    });

    test('parseSsdpLocation：头名大小写不敏感', () {
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\r\nlocation: http://x/d\r\n\r\n')
            ?.host,
        'x',
      );
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\r\nLoCaTiOn: http://y/d\r\n\r\n')
            ?.host,
        'y',
      );
    });

    test('parseSsdpLocation：NOTIFY / 缺头 / 空值 / 非 http 协议 → null', () {
      expect(
        parseSsdpLocation('NOTIFY * HTTP/1.1\r\nLOCATION: http://x\r\n\r\n'),
        isNull,
      );
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\r\nSERVER: x\r\n\r\n'),
        isNull,
      );
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: \r\n\r\n'),
        isNull,
      );
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: upnp:uuid:x\r\n\r\n'),
        isNull,
      );
    });

    test('parseSsdpLocation：兼容裸 LF 换行的设备栈', () {
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\nLOCATION: http://z/d\n\n')?.host,
        'z',
      );
    });
  });

  group('isMediaRenderer / dedupeDevices', () {
    test('isMediaRenderer：版本号与厂商命名空间接受，其余拒绝', () {
      expect(
        isMediaRenderer('urn:schemas-upnp-org:device:MediaRenderer:1'),
        isTrue,
      );
      expect(
        isMediaRenderer('urn:schemas-upnp-org:device:MediaRenderer:2'),
        isTrue,
      );
      expect(
        isMediaRenderer('urn:vendor:device:MediaRenderer:1'),
        isTrue,
      );
      expect(
        isMediaRenderer('urn:schemas-upnp-org:device:MediaServer:1'),
        isFalse,
      );
      expect(
        isMediaRenderer('urn:schemas-upnp-org:service:AVTransport:1'),
        isFalse,
      );
      // 无版本后缀（4 段）不算合法 deviceType。
      expect(isMediaRenderer('urn:schemas-upnp-org:device:MediaRenderer'), isFalse);
      expect(isMediaRenderer('MediaRenderer'), isFalse);
    });

    test('dedupeDevices：同 UDN 去重、保留先出现者', () {
      final a = _deviceOf('uuid:1', 'A');
      final aDup = _deviceOf('uuid:1', 'A-dup');
      final b = _deviceOf('uuid:2', 'B');
      final out = dedupeDevices([a, aDup, b]);
      expect(out.length, 2);
      expect(out[0].friendlyName, 'A');
      expect(out.map((d) => d.udn).toSet().length, 2);
    });
  });

  group('parseDeviceDescription：描述 XML 解析边界', () {
    const rendererDesc = '<?xml version="1.0"?>'
        '<root xmlns="urn:schemas-upnp-org:device-1-0">'
        '<URLBase>http://192.168.1.10:8080</URLBase>'
        '<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1'
        '</deviceType>'
        '<friendlyName>客厅电视</friendlyName><UDN>uuid:renderer-1</UDN>'
        '<modelName>MockTV/1.0</modelName>'
        '<serviceList><service>'
        '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
        '<controlURL>/upnp/control/avt</controlURL>'
        '</service></serviceList></device></root>';

    test('URLBase + 相对 controlURL → resolve 成绝对地址', () {
      final d = parseDeviceDescription(
        rendererDesc,
        location: Uri.parse('http://192.168.1.5/desc.xml'),
      )!;
      expect(d.friendlyName, '客厅电视');
      expect(d.udn, 'uuid:renderer-1');
      expect(d.productName, 'MockTV/1.0');
      expect(d.descriptionUrl.toString(), 'http://192.168.1.5/desc.xml');
      expect(
        d.avTransportControlUrl.toString(),
        'http://192.168.1.10:8080/upnp/control/avt',
      );
    });

    test('无 URLBase 时按 LOCATION 基址 resolve 相对 controlURL', () {
      final xml = rendererDesc.replaceFirst(
        '<URLBase>http://192.168.1.10:8080</URLBase>',
        '',
      );
      final d = parseDeviceDescription(
        xml,
        location: Uri.parse('http://192.168.1.5:49152/desc.xml'),
      )!;
      expect(
        d.avTransportControlUrl.toString(),
        'http://192.168.1.5:49152/upnp/control/avt',
      );
    });

    test('绝对 controlURL 原样保留', () {
      final xml = rendererDesc.replaceFirst(
        '/upnp/control/avt',
        'http://other:9999/ctl',
      );
      final d = parseDeviceDescription(
        xml,
        location: Uri.parse('http://192.168.1.5/desc.xml'),
      )!;
      expect(d.avTransportControlUrl.toString(), 'http://other:9999/ctl');
    });

    test('嵌套 deviceList 里的渲染器可发现（挂在 MediaServer 下）', () {
      const nested = '<?xml version="1.0"?>'
          '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>'
          '<friendlyName>服务器</friendlyName><UDN>uuid:server-1</UDN>'
          '<deviceList><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1'
          '</deviceType>'
          '<friendlyName>嵌套渲染器</friendlyName><UDN>uuid:renderer-2</UDN>'
          '<serviceList><service>'
          '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
          '<controlURL>/avt</controlURL>'
          '</service></serviceList></device></deviceList>'
          '</device></root>';
      final d = parseDeviceDescription(
        nested,
        location: Uri.parse('http://10.0.0.2/desc.xml'),
      )!;
      expect(d.udn, 'uuid:renderer-2');
      expect(d.friendlyName, '嵌套渲染器');
      expect(d.avTransportControlUrl.toString(), 'http://10.0.0.2/avt');
    });

    test('非 MediaRenderer / XML 损坏 / 缺关键字段 → null', () {
      const serverOnly = '<?xml version="1.0"?>'
          '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>'
          '<friendlyName>服务器</friendlyName><UDN>uuid:server-1</UDN>'
          '</device></root>';
      expect(
        parseDeviceDescription(serverOnly, location: Uri.parse('http://x/')),
        isNull,
      );
      expect(
        parseDeviceDescription('<root><broken', location: Uri.parse('http://x/')),
        isNull,
      );
      expect(
        parseDeviceDescription(
          rendererDesc.replaceFirst('<UDN>uuid:renderer-1</UDN>', ''),
          location: Uri.parse('http://x/'),
        ),
        isNull,
      );
      expect(
        parseDeviceDescription(
          rendererDesc.replaceFirst('<friendlyName>客厅电视</friendlyName>', ''),
          location: Uri.parse('http://x/'),
        ),
        isNull,
      );
      expect(
        parseDeviceDescription(
          rendererDesc.replaceFirst('<controlURL>/upnp/control/avt</controlURL>', ''),
          location: Uri.parse('http://x/'),
        ),
        isNull,
      );
    });
  });

  group('DIDL-Lite / SOAP 构造与转义', () {
    test('escapeXmlText：& < > " \' 全转义', () {
      expect(escapeXmlText('a&b<c>d"e\'f'), 'a&amp;b&lt;c&gt;d&quot;e&apos;f');
    });

    test('buildDidlLite：结构完整且标题/地址被转义、整体可解析', () {
      final didl = buildDidlLite(
        title: 'A & B <c>"d"\'e',
        url: 'http://x/y.mp4?a=1&b=2',
      );
      expect(
        didl,
        contains('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'),
      );
      expect(didl, contains('xmlns:dc="http://purl.org/dc/elements/1.1/"'));
      expect(didl, contains('xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"'));
      expect(didl, contains('<item id="0" parentID="-1" restricted="1">'));
      expect(
        didl,
        contains('<dc:title>A &amp; B &lt;c&gt;&quot;d&quot;&apos;e</dc:title>'),
      );
      expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(
        didl,
        contains(
          '<res protocolInfo="http-get:*:*:*">'
          'http://x/y.mp4?a=1&amp;b=2</res>',
        ),
      );
      expect(() => XmlDocument.parse(didl), returnsNormally);
    });

    test('buildSoapEnvelope：信封结构与参数转义', () {
      final env = buildSoapEnvelope(
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Seek',
        {'InstanceID': '0', 'Unit': 'REL_TIME', 'Target': '0:00:10'},
      );
      expect(env, startsWith('<?xml version="1.0" encoding="utf-8"?>'));
      expect(
        env,
        contains(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"',
        ),
      );
      expect(
        env,
        contains(
          '<u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">',
        ),
      );
      expect(
        env,
        contains('<InstanceID>0</InstanceID><Unit>REL_TIME</Unit>'
            '<Target>0:00:10</Target>'),
      );
      expect(env, contains('</u:Seek></s:Body></s:Envelope>'));
      expect(() => XmlDocument.parse(env), returnsNormally);
    });

    test('buildSoapEnvelope：参数值含特殊字符时仍为合法 XML', () {
      final env = buildSoapEnvelope(
        'urn:schemas-upnp-org:service:AVTransport:1',
        'SetAVTransportURI',
        {'CurrentURI': 'http://x/a.mp4?a=1&b=2'},
      );
      final doc = XmlDocument.parse(env);
      final uri = doc.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'CurrentURI')
          .innerText;
      expect(uri, 'http://x/a.mp4?a=1&b=2');
    });
  });

  group('formatRelTime / parseRelTime', () {
    test('整数秒互逆', () {
      for (final ms in [0, 1000, 59000, 3723000, 3600000]) {
        expect(parseRelTime(formatRelTime(ms)), ms);
      }
    });

    test('formatRelTime：H 不补零、MM/SS 补零、负数 clamp 到 0', () {
      expect(formatRelTime(0), '0:00:00');
      expect(formatRelTime(3723000), '1:02:03');
      expect(formatRelTime(-5), '0:00:00');
    });

    test('parseRelTime：分数秒解析（含 1/2/3 位与超长截断）', () {
      expect(parseRelTime('0:00:01.500'), 1500);
      expect(parseRelTime('0:00:01.5'), 1500);
      expect(parseRelTime('0:00:01.50'), 1500);
      expect(parseRelTime('0:00:01.1234'), 1123);
      expect(parseRelTime('1:02:03.500'), 3723500);
    });

    test('parseRelTime：NOT_IMPLEMENTED / 前导零 / 非法格式', () {
      expect(parseRelTime('NOT_IMPLEMENTED'), isNull);
      expect(parseRelTime(null), isNull);
      expect(parseRelTime(''), isNull);
      expect(parseRelTime('   '), isNull);
      expect(parseRelTime('00:01:02'), 62000);
      expect(parseRelTime('0:00:00.000'), 0);
      expect(parseRelTime('0:00:01.'), isNull);
      expect(parseRelTime('0:00:01.5a'), isNull);
      expect(parseRelTime('0:00'), isNull);
      expect(parseRelTime('0:00:01:02'), isNull);
    });
  });

  group('DlnaControl 对本地 mock AVTransport 端点', () {
    late HttpServer server;

    // 请求记录（大小写不敏感捕获 SOAPACTION）。
    String? lastSoapAction;
    String? lastBody;
    String? lastContentType;
    String lastMethod = '';
    String lastPath = '';
    var requestCount = 0;

    DlnaDevice deviceAt(String path) => DlnaDevice(
          udn: 'uuid:dlna-cast-test',
          friendlyName: 'Mock Renderer',
          descriptionUrl: Uri.parse('http://127.0.0.1:${server.port}/desc.xml'),
          avTransportControlUrl:
              Uri.parse('http://127.0.0.1:${server.port}$path'),
          productName: 'MockRenderer/1.0',
        );

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requestCount++;
        lastMethod = request.method;
        lastPath = request.uri.path;
        lastContentType = request.headers.contentType?.mimeType;
        lastSoapAction = null;
        request.headers.forEach((name, values) {
          if (name.toLowerCase() == 'soapaction') {
            lastSoapAction = values.join(',');
          }
        });
        lastBody = await utf8.decoder.bind(request).join();
        final response = request.response;
        switch (request.uri.path) {
          case '/position':
            response.write(_positionResponse('0:00:07.500', '0:00:59.000'));
          case '/badtime':
            response.write(_positionResponse('NOT_IMPLEMENTED', 'NOT_IMPLEMENTED'));
          case '/state':
            response.write(_soapResponse('GetTransportInfo',
                '<CurrentTransportState>PLAYING</CurrentTransportState>'));
          case '/fault':
            response.statusCode = 500;
            response.write(_faultResponse('601', 'Argument value invalid'));
          case '/http500':
            response.statusCode = 500;
            response.headers.contentType = ContentType.text;
            response.write('Internal Server Error');
          case '/garbage':
            response.write('this is not xml <');
          default:
            response.write(_soapResponse(_actionFromBody(lastBody ?? '')));
        }
        await response.close();
      });
    });

    setUp(() {
      lastSoapAction = null;
      lastBody = null;
      lastContentType = null;
      lastMethod = '';
      lastPath = '';
      requestCount = 0;
    });

    tearDown(() {
      // 旁路测试会改 NetworkPolicy 全局配置，统一复位避免污染其它测试。
      NetworkPolicy.configure(doh: '', httpProxy: '');
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('setUri：SOAPACTION 带引号、参数齐全、DIDL 双重转义', () async {
      final title = '片名 & <测试> "引号"';
      final url = 'http://example.com/movie.mp4?a=1&b=2';
      await DlnaControl().setUri(deviceAt('/ctl'), url, title);

      expect(lastMethod, 'POST');
      expect(lastPath, '/ctl');
      expect(lastContentType, startsWith('text/xml'));
      expect(
        lastSoapAction,
        '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
      );
      expect(
        lastBody,
        contains(
          '<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">',
        ),
      );
      expect(lastBody, contains('<InstanceID>0</InstanceID>'));
      // CurrentURI 作为元素文本只转义一次（& → &amp;）。
      expect(lastBody, contains('<CurrentURI>${url.replaceAll('&', '&amp;')}</CurrentURI>'));
      expect(lastBody, contains('<CurrentURIMetaData>'));
      // DIDL 作为元素文本被整体再转义一次：内层标签变为 &lt;。
      expect(lastBody, contains('&lt;DIDL-Lite'));
      expect(lastBody, contains('&amp;'));
      // 强断言：SOAP 解析器反转义后还原出原始 DIDL 串。
      final doc = XmlDocument.parse(lastBody!);
      final metadata = doc.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'CurrentURIMetaData')
          .innerText;
      expect(metadata, buildDidlLite(title: title, url: url));
    });

    test('play / pause / stop / seek：SOAPACTION 与参数正确', () async {
      final control = DlnaControl();
      final device = deviceAt('/ctl');

      await control.play(device);
      expect(lastSoapAction,
          '"urn:schemas-upnp-org:service:AVTransport:1#Play"');
      expect(lastBody, contains('<Speed>1</Speed>'));

      await control.pause(device);
      expect(lastSoapAction,
          '"urn:schemas-upnp-org:service:AVTransport:1#Pause"');

      await control.stop(device);
      expect(lastSoapAction,
          '"urn:schemas-upnp-org:service:AVTransport:1#Stop"');

      await control.seek(device, 10000);
      expect(lastSoapAction,
          '"urn:schemas-upnp-org:service:AVTransport:1#Seek"');
      expect(lastBody, contains('<Unit>REL_TIME</Unit>'));
      expect(lastBody, contains('<Target>0:00:10</Target>'));
    });

    test('positionInfo：分数秒 RelTime/TrackDuration 换算毫秒', () async {
      final info = await DlnaControl().positionInfo(deviceAt('/position'));
      expect(info.positionMs, 7500);
      expect(info.durationMs, 59000);
    });

    test('positionInfo：NOT_IMPLEMENTED 等异常格式回落 0 且不抛错', () async {
      final info = await DlnaControl().positionInfo(deviceAt('/badtime'));
      expect(info.positionMs, 0);
      expect(info.durationMs, 0);
    });

    test('transportInfo：读取 CurrentTransportState', () async {
      expect(await DlnaControl().transportInfo(deviceAt('/state')), 'PLAYING');
    });

    test('SOAP Fault：errorCode/errorDescription 映射为中文文案', () async {
      await expectLater(
        DlnaControl().play(deviceAt('/fault')),
        throwsA(
          isA<DlnaControlException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('设备拒绝'),
              contains('601'),
              contains('Argument value invalid'),
            ),
          ),
        ),
      );
    });

    test('HTTP 500 且无 Fault 体：状态码路径中文文案', () async {
      await expectLater(
        DlnaControl().play(deviceAt('/http500')),
        throwsA(
          isA<DlnaControlException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 500'),
          ),
        ),
      );
    });

    test('HTTP 200 但非 XML：无法解析路径中文文案', () async {
      await expectLater(
        DlnaControl().play(deviceAt('/garbage')),
        throwsA(
          isA<DlnaControlException>().having(
            (e) => e.message,
            'message',
            contains('无法解析'),
          ),
        ),
      );
    });

    test('网络错误（端口无监听）：中文可操作文案', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close(force: true);
      final deadDevice = DlnaDevice(
        udn: 'uuid:dead',
        friendlyName: 'Dead',
        descriptionUrl: Uri.parse('http://127.0.0.1/desc.xml'),
        avTransportControlUrl: Uri.parse('http://127.0.0.1:$port/ctl'),
      );
      await expectLater(
        DlnaControl().play(deadDevice),
        throwsA(
          isA<DlnaControlException>().having(
            (e) => e.message,
            'message',
            allOf(contains('投屏指令发送失败'), contains('Play')),
          ),
        ),
      );
    });

    test('局域网直连旁路：NetworkPolicy 配代理/DoH 后 SOAP 仍达本地 mock',
        () async {
      // 若 DLNA 的 Dio 接了 NetworkPolicy，请求会被送进 127.0.0.1:1 的
      // 死代理 / 死 DoH 而失败；直连旁路则应正常到达 mock。
      NetworkPolicy.configure(
        doh: 'http://127.0.0.1:1/doh',
        httpProxy: 'http://127.0.0.1:1/proxy',
      );
      await DlnaControl().play(deviceAt('/ctl'));
      expect(lastPath, '/ctl');
      expect(lastSoapAction,
          '"urn:schemas-upnp-org:service:AVTransport:1#Play"');
      expect(lastBody, contains('<Speed>1</Speed>'));
      expect(requestCount, 1);
    });
  });
}

/// GetPositionInfo 响应（RelTime / TrackDuration 可注入异常格式）。
String _positionResponse(String relTime, String duration) => _soapResponse(
      'GetPositionInfo',
      '<Track>1</Track><TrackDuration>$duration</TrackDuration>'
      '<RelTime>$relTime</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime>'
      '<AbsCount>2147483647</AbsCount><RelCount>2147483647</RelCount>',
    );

/// 标准 AVTransport SOAP 响应外壳（action 名按请求回显）。
String _soapResponse(String action, [String inner = '']) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body><u:${action}Response '
    'xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
    '$inner</u:${action}Response></s:Body></s:Envelope>';

/// SOAP Fault（UPnPError：errorCode + errorDescription，HTTP 500 上行）。
String _faultResponse(String code, String description) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
    '<s:Body><s:Fault><faultcode>s:Client</faultcode>'
    '<faultstring>UPnPError</faultstring><detail><UPnPError>'
    '<errorCode>$code</errorCode>'
    '<errorDescription>$description</errorDescription>'
    '</UPnPError></detail></s:Fault></s:Body></s:Envelope>';

/// 从 SOAP 请求体提取动作名（`<u:Action …>`）。
String _actionFromBody(String body) {
  final match = RegExp(r'<u:([A-Za-z]+) ').firstMatch(body) ??
      RegExp(r'<u:([A-Za-z]+)>').firstMatch(body);
  return match?.group(1) ?? 'Action';
}

DlnaDevice _deviceOf(String udn, String friendlyName) => DlnaDevice(
      udn: udn,
      friendlyName: friendlyName,
      descriptionUrl: Uri.parse('http://192.168.1.1/desc.xml'),
      avTransportControlUrl: Uri.parse('http://192.168.1.1/ctl'),
    );
