import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/network_policy.dart';
import 'package:tvbox_flutter/data/dns_presets.dart';

void main() {
  test('标准 DoH 跳过 CNAME 并读取压缩域名的 A 记录', () {
    final query = dnsQuestion('video.example');
    final response = Uint8List.fromList([...query,
      192,12,0,5,0,1,0,0,0,60,0,2,192,12,
      192,12,0,1,0,1,0,0,0,60,0,4,192,0,2,8,
    ])..[2] = 129..[7] = 2;
    expect(dnsAnswer(response), ('192.0.2.8', 60));
    response[3] = 3;
    expect(dnsAnswer(response), isNull);
  });
  tearDown(() => NetworkPolicy.configure(doh: '', httpProxy: ''));
  test('DoH 回源 HTTPS 先发送带原域名的 TLS 握手', () async {
    final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => dns.close(force: true));
    dns.listen((request) {
      request.response.write('{"Answer":[{"type":1,"data":"127.0.0.1"}]}');
      request.response.close();
    });
    final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(origin.close);
    final firstRecord = Completer<List<int>>();
    origin.listen((socket) async {
      final bytes = <int>[];
      await for (final chunk in socket) {
        bytes.addAll(chunk);
        if (bytes.length < 5) continue;
        if (bytes.first == 22 && bytes.length < 5 + bytes[3] * 256 + bytes[4]) continue;
        firstRecord.complete(bytes);
        socket.destroy();
        break;
      }
    });
    NetworkPolicy.configure(doh: 'http://127.0.0.1:${dns.port}/resolve', httpProxy: '');
    final client = NetworkPolicy.createClient();
    addTearDown(() => client.close(force: true));
    final failed = expectLater(client.getUrl(Uri.parse('https://media.invalid:${origin.port}/video'))
        .then((request) => request.close()), throwsA(anything));
    final bytes = await firstRecord.future.timeout(const Duration(seconds: 5));
    expect(bytes.first, 22);
    expect(String.fromCharCodes(bytes), contains('media.invalid'));
    await failed;
  });
  test('HTTP 代理实际接收原目标请求', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    Uri? requested;
    proxy.listen((request) async {
      requested = request.uri;
      request.response.write('proxied');
      await request.response.close();
    });
    NetworkPolicy.configure(
      doh: '',
      httpProxy: 'http://127.0.0.1:${proxy.port}',
    );
    final client = NetworkPolicy.createClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://unresolvable.invalid/video'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(requested?.host, 'unresolvable.invalid');
  });
  test('JSON DoH 解析后连接目标并保留 Host', () async {
    final video = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => video.close(force: true));
    addTearDown(() => dns.close(force: true));
    String? host;
    video.listen((request) async {
      host = request.headers.value('host');
      request.response.write('video');
      await request.response.close();
    });
    dns.listen((request) async {
      expect(request.uri.queryParameters['name'], 'video.invalid');
      request.response.write(
        '{"Answer":[{"type":1,"TTL":60,"data":"127.0.0.1"}]}',
      );
      await request.response.close();
    });
    NetworkPolicy.configure(
      doh: 'http://127.0.0.1:${dns.port}/resolve',
      httpProxy: '',
    );
    final client = NetworkPolicy.createClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://video.invalid:${video.port}/video'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(host, 'video.invalid:${video.port}');
  });

  group('isDirectHost', () {
    test('环回 / 链路本地 / RFC1918 / ULA / localhost 命中', () {
      const hosts = [
        '127.0.0.1',
        '127.1.2.3', // 127/8 整段环回
        'localhost',
        'LOCALHOST',
        ' localhost ', // 容忍空白与大小写
        '169.254.169.254', // 链路本地（云元数据地址）
        '169.254.1.1',
        '10.0.0.1',
        '10.255.255.255',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.0.1',
        '192.168.99.255',
        '::1',
        '[::1]', // 带方括号的 IPv6 字面量
        'fe80::1', // fe80::/10 链路本地
        'fc00::1', // fc00::/7 唯一本地地址
        'fd12:3456:789a::1',
        '192.168.1.1:8080', // 容忍带端口写法
        '::ffff:192.168.1.1', // IPv4-mapped 按其 IPv4 段判定
      ];
      for (final host in hosts) {
        expect(NetworkPolicy.isDirectHost(host), isTrue, reason: host);
      }
    });
    test('公有地址与域名不命中', () {
      const hosts = [
        '8.8.8.8',
        '1.1.1.1',
        '11.0.0.1',
        '172.15.0.1', // 172.16/12 之外
        '172.32.0.1',
        '192.169.0.1', // 192.168/16 之外
        'example.com',
        'video.invalid',
        '2001:db8::1',
        '2001:4860:4860::8888',
        '::ffff:8.8.8.8', // mapped 公有地址同样不命中
      ];
      for (final host in hosts) {
        expect(NetworkPolicy.isDirectHost(host), isFalse, reason: host);
      }
    });
    test('空串与非法输入不命中', () {
      expect(NetworkPolicy.isDirectHost(''), isFalse);
      expect(NetworkPolicy.isDirectHost('   '), isFalse);
      expect(NetworkPolicy.isDirectHost('['), isFalse);
      expect(NetworkPolicy.isDirectHost('not a host'), isFalse);
    });
  });

  group('代理规则输出', () {
    test('host:port 与 http:// 前缀两种输入都生效（行为级验证）', () async {
      // findProxy 是只写 setter 读不回来，这里用「不可解析域名能否
      // 被代理收到」证明两种写法都归一化为 PROXY 规则：若归一化
      // 失败会走 DIRECT，请求直接抛 SocketException。
      for (final form in ['plain', 'uri']) {
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        Uri? requested;
        proxy.listen((request) async {
          requested = request.uri;
          request.response.write('proxied');
          await request.response.close();
        });
        addTearDown(() => proxy.close(force: true));
        NetworkPolicy.configure(
          doh: '',
          httpProxy:
              form == 'plain'
                  ? '127.0.0.1:${proxy.port}'
                  : 'http://127.0.0.1:${proxy.port}',
        );
        final client = NetworkPolicy.createClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(
          Uri.parse('http://unresolvable.invalid/video'),
        );
        final response = await request.close();
        expect(response.statusCode, 200, reason: form);
        await response.drain<void>();
        expect(requested?.host, 'unresolvable.invalid', reason: form);
      }
    });
  });

  test('配置了代理时局域网 host 直连（代理服务器零命中）', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var proxyHits = 0;
    proxy.listen((request) {
      proxyHits++;
      request.response.close();
    });
    addTearDown(() => proxy.close(force: true));
    final video = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var videoHits = 0;
    video.listen((request) async {
      videoHits++;
      request.response.write('direct');
      await request.response.close();
    });
    addTearDown(() => video.close(force: true));
    NetworkPolicy.configure(
      doh: '',
      httpProxy: 'http://127.0.0.1:${proxy.port}',
    );
    final client = NetworkPolicy.createClient();
    addTearDown(() => client.close(force: true));
    // 127.0.0.1 是环回地址：应直连视频服务器，代理一条都收不到。
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${video.port}/video'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(videoHits, 1);
    expect(proxyHits, 0);
  });

  test('配置了 DoH 时本机 host 直连（DNS 服务器零命中）', () async {
    final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var dnsHits = 0;
    dns.listen((request) async {
      dnsHits++;
      request.response.write(
        '{"Answer":[{"type":1,"TTL":60,"data":"127.0.0.1"}]}',
      );
      await request.response.close();
    });
    addTearDown(() => dns.close(force: true));
    final video = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    video.listen((request) async {
      request.response.write('video');
      await request.response.close();
    });
    addTearDown(() => video.close(force: true));
    NetworkPolicy.configure(
      doh: 'http://127.0.0.1:${dns.port}/resolve',
      httpProxy: '',
    );
    final client = NetworkPolicy.createClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${video.port}/video'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(dnsHits, 0);
  });

  group('DoH 多端点', () {
    test('首个端点失败自动试下一个', () async {
      final video = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      addTearDown(() => video.close(force: true));
      addTearDown(() => dns.close(force: true));
      var dnsHits = 0;
      video.listen((request) async {
        request.response.write('video');
        await request.response.close();
      });
      dns.listen((request) async {
        dnsHits++;
        request.response.write(
          '{"Answer":[{"type":1,"TTL":60,"data":"127.0.0.1"}]}',
        );
        await request.response.close();
      });
      NetworkPolicy.configure(
        doh:
            'http://127.0.0.1:$deadPort/resolve '
            'http://127.0.0.1:${dns.port}/resolve',
        httpProxy: '',
      );
      // 端点列表按空白切分，多端点配置生效。
      expect(NetworkPolicy.dohEndpoints.length, 2);
      final client = NetworkPolicy.createClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://video.invalid:${video.port}/video'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect(dnsHits, 1);
    });

    test('全部端点失败回退系统 DNS（不抛自有错误阻断）', () async {
      final dead1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dead2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final p1 = dead1.port;
      final p2 = dead2.port;
      await dead1.close(force: true);
      await dead2.close(force: true);
      NetworkPolicy.configure(
        doh: 'http://127.0.0.1:$p1/resolve http://127.0.0.1:$p2/resolve',
        httpProxy: '',
      );
      final client = NetworkPolicy.createClient();
      addTearDown(() => client.close(force: true));
      // connectionFactory 在 getUrl 阶段就被调用：DoH 全失败 → 回退
      // 系统 DNS → .invalid 不可解析 → SocketException；错误来自系统
      // 解析器而非 DoH 逻辑，证明没有抛错阻断。
      await expectLater(
        () => client.getUrl(Uri.parse('http://video.invalid:8080/video')),
        throwsA(isA<SocketException>()),
      );
    });

    test('缓存命中不重复请求', () async {
      final video = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => video.close(force: true));
      addTearDown(() => dns.close(force: true));
      var dnsHits = 0;
      video.listen((request) async {
        request.response.write('video');
        await request.response.close();
      });
      dns.listen((request) async {
        dnsHits++;
        request.response.write(
          '{"Answer":[{"type":1,"TTL":60,"data":"127.0.0.1"}]}',
        );
        await request.response.close();
      });
      NetworkPolicy.configure(
        doh: 'http://127.0.0.1:${dns.port}/resolve',
        httpProxy: '',
      );
      // 每次新建 client：强制走 connectionFactory，区分缓存与连接复用。
      for (var i = 0; i < 2; i++) {
        final client = NetworkPolicy.createClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(
          Uri.parse('http://video.invalid:${video.port}/video'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      }
      expect(dnsHits, 1);
    });

    test('TTL 过期后重新查询', () async {
      final video = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => video.close(force: true));
      addTearDown(() => dns.close(force: true));
      var dnsHits = 0;
      video.listen((request) async {
        request.response.write('video');
        await request.response.close();
      });
      dns.listen((request) async {
        dnsHits++;
        // TTL=1（clamp 下限）：1 秒后缓存应过期。
        request.response.write(
          '{"Answer":[{"type":1,"TTL":1,"data":"127.0.0.1"}]}',
        );
        await request.response.close();
      });
      NetworkPolicy.configure(
        doh: 'http://127.0.0.1:${dns.port}/resolve',
        httpProxy: '',
      );
      Future<void> requestVideo() async {
        final client = NetworkPolicy.createClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(
          Uri.parse('http://video.invalid:${video.port}/video'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      }

      await requestVideo();
      expect(dnsHits, 1);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await requestVideo();
      expect(dnsHits, 2);
    });
  });
}
