import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/pan/pan_account.dart';
import 'package:tvbox_flutter/data/pan/pan_provider.dart';
import 'package:tvbox_flutter/data/pan/pan_qr_login.dart';

/// 网盘扫码登录契约测试：三家「生成二维码 → 轮询状态 → 换凭据」全链路，
/// 全部打本地 HttpServer mock，不起外网。
///
/// 覆盖要点：
/// - 阿里 `qrCodeStatus` 四态 + `bizExt`(base64 JSON) → refresh_token；
/// - 夸克实测形态（顶层 `status: 2000000`）不被误判失败，service_ticket
///   → Set-Cookie，无 Cookie 时回落 `__st`；
/// - 百度二维码是图片地址，长轮询 errno 分支，channel_v 内层
///   `status: 0/1` → BDUSS → Set-Cookie，回落裸 `BDUSS=`。
void main() {
  group('阿里云盘扫码', () {
    test('生成二维码解析 t/ck/codeContent', () async {
      final mock = await startMock((req) async {
        expect(req.uri.path, '/newlogin/qrcode/generate.do');
        expect(req.uri.queryParameters['appName'], 'aliyun_drive');
        writeJson(req, {
          'content': {
            'data': {
              't': 1794957845986,
              'codeContent': 'https://passport.aliyundrive.com/qrcodeCheck.htm?lgToken=abc',
              'ck': 'ck-value',
              'resultCode': 100,
            },
            'status': 0,
            'success': true,
          },
          'hasError': false,
        });
      });
      addTearDown(mock.close);
      final session = await api(mock).create(PanProviderId.aliyun);
      expect(session.qrIsImage, isFalse);
      expect(session.qrContent, contains('qrcodeCheck.htm'));
      final token = jsonDecode(session.pollToken) as Map;
      expect(token['t'], 1794957845986);
      expect(token['ck'], 'ck-value');
    });

    test('生成失败抛中文可操作异常', () async {
      final mock = await startMock((req) async {
        writeJson(req, {
          'content': {'data': <String, dynamic>{}},
        });
      });
      addTearDown(mock.close);
      await expectLater(
        api(mock).create(PanProviderId.aliyun),
        throwsA(
          isA<PanException>().having(
            (e) => e.message,
            'message',
            contains('阿里云盘二维码'),
          ),
        ),
      );
    });

    test('NEW → waiting，SCANED → scanned，EXPIRED → expired', () async {
      var status = 'NEW';
      final mock = await startMock((req) async {
        if (req.uri.path.endsWith('generate.do')) {
          writeJson(req, {
            'content': {
              'data': {'t': 1, 'ck': 'c', 'codeContent': 'https://qr'},
            },
          });
          return;
        }
        writeJson(req, {
          'content': {
            'data': {'qrCodeStatus': status},
          },
        });
      });
      addTearDown(mock.close);
      final login = api(mock);
      final session = await login.create(PanProviderId.aliyun);

      expect((await login.poll(session)).state, PanQrState.waiting);
      status = 'SCANED';
      expect((await login.poll(session)).state, PanQrState.scanned);
      status = 'EXPIRED';
      expect((await login.poll(session)).state, PanQrState.expired);
    });

    test('CONFIRMED 的 bizExt 解出 refresh_token/access_token', () async {
      final biz = base64.encode(
        utf8.encode(
          jsonEncode({
            'pds_login_result': {
              'refreshToken': 'rt-from-qr',
              'accessToken': 'at-from-qr',
              'nickName': '电视用户',
              'userId': 'u-1',
            },
          }),
        ),
      );
      final mock = await startMock((req) async {
        if (req.uri.path.endsWith('generate.do')) {
          writeJson(req, {
            'content': {
              'data': {'t': 1, 'ck': 'c', 'codeContent': 'https://qr'},
            },
          });
          return;
        }
        writeJson(req, {
          'content': {
            'data': {'qrCodeStatus': 'CONFIRMED', 'bizExt': biz},
          },
        });
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.aliyun));
      expect(result.state, PanQrState.confirmed);
      expect(result.account?.refreshToken, 'rt-from-qr');
      expect(result.account?.accessToken, 'at-from-qr');
      expect(result.account?.userName, '电视用户');
    });

    test('bizExt 不是合法 JSON → error（不回传半截凭据）', () async {
      final mock = await startMock((req) async {
        if (req.uri.path.endsWith('generate.do')) {
          writeJson(req, {
            'content': {
              'data': {'t': 1, 'ck': 'c', 'codeContent': 'https://qr'},
            },
          });
          return;
        }
        writeJson(req, {
          'content': {
            'data': {
              'qrCodeStatus': 'CONFIRMED',
              'bizExt': base64.encode(utf8.encode('not-json')),
            },
          },
        });
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.aliyun));
      expect(result.state, PanQrState.error);
      expect(result.message, contains('refresh_token'));
    });
  });

  group('夸克网盘扫码', () {
    test('实测形态 status=2000000 + members.token 视为成功', () async {
      final mock = await startMock((req) async {
        writeJson(req, {
          'status': 2000000,
          'message': 'ok',
          'data': {
            'members': {'token': 'sta-token'},
          },
        });
      });
      addTearDown(mock.close);
      final session = await api(mock).create(PanProviderId.quark);
      expect(session.qrContent, contains('token=sta-token'));
      expect(session.qrContent, contains('client_id=532'));
      expect(session.pollToken, 'sta-token');
    });

    test('无 members.token → 抛异常', () async {
      final mock = await startMock((req) async {
        writeJson(req, {'status': 2000000, 'data': <String, dynamic>{}});
      });
      addTearDown(mock.close);
      await expectLater(
        api(mock).create(PanProviderId.quark),
        throwsA(isA<PanException>()),
      );
    });

    test('未扫码 status=50004001 → waiting', () async {
      final mock = await startMock((req) async {
        if (req.uri.path.contains('getTokenForQrcodeLogin')) {
          writeJson(req, {
            'status': 2000000,
            'data': {
              'members': {'token': 't'},
            },
          });
          return;
        }
        writeJson(req, {
          'status': 50004001,
          'message': 'Query result is empty',
        });
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.quark));
      expect(result.state, PanQrState.waiting);
    });

    test('SCANED / EXPIRED 状态映射', () async {
      var status = 'SCANED';
      final mock = await startMock((req) async {
        if (req.uri.path.contains('getTokenForQrcodeLogin')) {
          writeJson(req, {
            'status': 2000000,
            'data': {
              'members': {'token': 't'},
            },
          });
          return;
        }
        writeJson(req, {
          'status': 2000000,
          'data': {
            'members': {'status': status},
          },
        });
      });
      addTearDown(mock.close);
      final login = api(mock);
      final session = await login.create(PanProviderId.quark);
      expect((await login.poll(session)).state, PanQrState.scanned);
      status = 'EXPIRED';
      expect((await login.poll(session)).state, PanQrState.expired);
    });

    test('CONFIRMED → service_ticket 换 Set-Cookie', () async {
      final mock = await startMock((req) async {
        if (req.uri.path.contains('getTokenForQrcodeLogin')) {
          writeJson(req, {
            'status': 2000000,
            'data': {
              'members': {'token': 't'},
            },
          });
          return;
        }
        if (req.uri.path.contains('getServiceTicketByQrcodeToken')) {
          writeJson(req, {
            'status': 2000000,
            'data': {
              'members': {'status': 'CONFIRMED', 'service_ticket': 'st-1'},
            },
          });
          return;
        }
        expect(req.uri.path, '/account/info');
        expect(req.uri.queryParameters['st'], 'st-1');
        writeStatus(
          req,
          302,
          setCookies: ['__puus=abc; Path=/', '__pus=def; Path=/'],
        );
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.quark));
      expect(result.state, PanQrState.confirmed);
      expect(result.account?.cookie, '__puus=abc; __pus=def');
      expect(result.account?.provider, PanProviderId.quark);
    });

    test('换 Cookie 失败时回落 __st=<ticket>', () async {
      final mock = await startMock((req) async {
        if (req.uri.path.contains('getTokenForQrcodeLogin')) {
          writeJson(req, {
            'status': 2000000,
            'data': {
              'members': {'token': 't'},
            },
          });
          return;
        }
        if (req.uri.path.contains('getServiceTicketByQrcodeToken')) {
          writeJson(req, {
            'status': 2000000,
            'data': {
              'members': {'service_ticket': 'st-2'},
            },
          });
          return;
        }
        writeStatus(req, 302);
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.quark));
      expect(result.state, PanQrState.confirmed);
      expect(result.account?.cookie, '__st=st-2');
    });
  });

  group('百度网盘扫码', () {
    test('生成二维码返回图片地址（qrIsImage）', () async {
      final mock = await startMock((req) async {
        expect(req.uri.path, '/v2/api/getqrcode');
        expect(req.uri.queryParameters['gid'], isNotEmpty);
        writeJson(req, {
          'imgurl':
              'passport.baidu.com/v2/api/qrcode?sign=abc&lp=pc&qrloginfrom=pc',
          'errno': 0,
          'sign': 'abc',
        });
      });
      addTearDown(mock.close);
      final session = await api(mock).create(PanProviderId.baidu);
      expect(session.qrIsImage, isTrue);
      expect(session.qrContent, startsWith('https://passport.baidu.com'));
      final token = jsonDecode(session.pollToken) as Map;
      expect(token['sign'], 'abc');
      expect(token['gid'], isNotEmpty);
    });

    test('缺 sign → 抛异常', () async {
      final mock = await startMock((req) async {
        writeJson(req, {'errno': 0, 'imgurl': 'x'});
      });
      addTearDown(mock.close);
      await expectLater(
        api(mock).create(PanProviderId.baidu),
        throwsA(isA<PanException>()),
      );
    });

    test('errno 1 → waiting，errno -1 → expired', () async {
      var errno = 1;
      final mock = await startMock((req) async {
        if (req.uri.path == '/v2/api/getqrcode') {
          writeJson(req, {
            'errno': 0,
            'imgurl': 'passport.baidu.com/qr',
            'sign': 's',
          });
          return;
        }
        writeJson(req, {'errno': errno});
      });
      addTearDown(mock.close);
      final login = api(mock);
      final session = await login.create(PanProviderId.baidu);
      expect((await login.poll(session)).state, PanQrState.waiting);
      errno = -1;
      expect((await login.poll(session)).state, PanQrState.expired);
    });

    test('channel_v status=1 → scanned', () async {
      final mock = await startMock((req) async {
        if (req.uri.path == '/v2/api/getqrcode') {
          writeJson(req, {
            'errno': 0,
            'imgurl': 'passport.baidu.com/qr',
            'sign': 's',
          });
          return;
        }
        writeJson(req, {
          'errno': 0,
          'channel_v': jsonEncode({'status': 1}),
        });
      });
      addTearDown(mock.close);
      final login = api(mock);
      expect(
        (await login.poll(await login.create(PanProviderId.baidu))).state,
        PanQrState.scanned,
      );
    });

    test('status=0 → BDUSS 换 BDUSS/STOKEN Cookie', () async {
      final mock = await startMock((req) async {
        if (req.uri.path == '/v2/api/getqrcode') {
          writeJson(req, {
            'errno': 0,
            'imgurl': 'passport.baidu.com/qr',
            'sign': 's',
          });
          return;
        }
        if (req.uri.path == '/channel/unicast') {
          writeJson(req, {
            'errno': 0,
            'channel_v': jsonEncode({'status': 0, 'v': 'bduss-value'}),
          });
          return;
        }
        expect(req.uri.path, '/v3/login/main/qrbdusslogin');
        expect(req.uri.queryParameters['bduss'], 'bduss-value');
        writeStatus(
          req,
          302,
          setCookies: [
            'BDUSS=bduss-value; Path=/; Domain=.baidu.com',
            'STOKEN=stoken-value; Path=/; Domain=.baidu.com',
            'BAIDUID=ignored; Path=/',
          ],
        );
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.baidu));
      expect(result.state, PanQrState.confirmed);
      // 只保留 BDUSS/STOKEN，避免把无关 Cookie 带进播放请求。
      expect(result.account?.cookie, 'BDUSS=bduss-value; STOKEN=stoken-value');
      expect(result.account?.provider, PanProviderId.baidu);
    });

    test('换 Cookie 失败时回落裸 BDUSS', () async {
      final mock = await startMock((req) async {
        if (req.uri.path == '/v2/api/getqrcode') {
          writeJson(req, {
            'errno': 0,
            'imgurl': 'passport.baidu.com/qr',
            'sign': 's',
          });
          return;
        }
        if (req.uri.path == '/channel/unicast') {
          writeJson(req, {
            'errno': 0,
            'channel_v': jsonEncode({'status': 0, 'v': 'bduss-value'}),
          });
          return;
        }
        writeStatus(req, 302);
      });
      addTearDown(mock.close);
      final login = api(mock);
      final result = await login.poll(await login.create(PanProviderId.baidu));
      expect(result.account?.cookie, 'BDUSS=bduss-value');
    });
  });

  test('轮询网络异常按 waiting 处理（长轮询超时不弹错）', () async {
    final mock = await startMock((req) async {
      if (req.uri.path == '/v2/api/getqrcode') {
        writeJson(req, {
          'errno': 0,
          'imgurl': 'passport.baidu.com/qr',
          'sign': 's',
        });
        return;
      }
      // 模拟长轮询挂起：直接断开连接。
      await req.response.detachSocket().then((socket) => socket.destroy());
    });
    addTearDown(mock.close);
    final login = api(mock);
    final result = await login.poll(await login.create(PanProviderId.baidu));
    expect(result.state, PanQrState.waiting);
  });
}

// ── mock 工具 ──────────────────────────────────────────────

PanQrLogin api(MockApi mock) => PanQrLogin(
  dio: Dio(),
  bases: {
    PanProviderId.aliyun: mock.base,
    PanProviderId.quark: mock.base,
    PanProviderId.baidu: mock.base,
  },
  quarkPanBase: mock.base,
);

class MockApi {
  MockApi(this._server);

  final HttpServer _server;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);
}

Future<MockApi> startMock(
  Future<void> Function(HttpRequest req) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    handler(req).catchError((_) {
      try {
        req.response.close();
      } catch (_) {}
    });
  });
  return MockApi(server);
}

void writeJson(HttpRequest req, Object body) {
  req.response.statusCode = 200;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  req.response.close();
}

void writeStatus(
  HttpRequest req,
  int status, {
  List<String> setCookies = const [],
}) {
  req.response.statusCode = status;
  for (final cookie in setCookies) {
    req.response.headers.add('set-cookie', cookie);
  }
  req.response.close();
}
