import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/data/network_policy.dart';
import 'package:tvbox_flutter/data/pan/aliyun_pan.dart';
import 'package:tvbox_flutter/data/pan/baidu_pan.dart';
import 'package:tvbox_flutter/data/pan/pan_account.dart';
import 'package:tvbox_flutter/data/pan/pan_models.dart';
import 'package:tvbox_flutter/data/pan/pan_provider.dart';
import 'package:tvbox_flutter/data/pan/pan_registry.dart';
import 'package:tvbox_flutter/data/pan/quark_pan.dart';
import 'package:tvbox_flutter/data/storage.dart';

/// 网盘数据层契约测试：三家（阿里/百度/夸克）各覆盖
/// 令牌刷新 / 目录列举分页拼接 / 播放直链 / 401 错误路径，
/// 另有同源越界防护、账号 JSON 往返、代理生效（NetworkPolicy.attach）。
///
/// 注意：全部请求打本地 HttpServer mock，不起外网；默认构造的 provider
/// 走 NetworkPolicy.attach 的真实 dio（即代理/DoH 链路与生产一致）。
void main() {
  setUp(() {
    // 与生产一致：不配置 DoH/代理，直连本地 mock。
    NetworkPolicy.configure(doh: '', httpProxy: '');
  });

  tearDown(() => NetworkPolicy.configure(doh: '', httpProxy: ''));

  group('阿里云盘', () {
    test('refresh：用 refresh_token 换新令牌并轮换账号字段', () async {
      final seen = <_Req>[];
      final base = await mockServer((req) async {
        seen.add(await _capture(req));
        await writeJson(req, 200, {
          'access_token': 'new_at',
          'refresh_token': 'new_rt',
          'expire_time': 4102444800, // 2100-01-01（秒）
          'user_id': 'u1',
          'nick_name': '测试',
          'default_drive_id': 'drive1',
        });
      });
      final pan = AliyunPan(authBase: base);
      final account = await pan.refresh(
        const PanAccount(
          provider: PanProviderId.aliyun,
          refreshToken: 'old_rt',
        ),
      );
      expect(account.accessToken, 'new_at');
      expect(account.refreshToken, 'new_rt');
      expect(account.userId, 'u1');
      expect(account.userName, '测试');
      expect(account.driveId, 'drive1');
      expect(account.expiryUnixSec, 4102444800);
      final req = seen.single;
      expect(req.path, '/v2/account/token');
      expect(req.body['grant_type'], 'refresh_token');
      expect(req.body['refresh_token'], 'old_rt');
    });

    test('refresh：invalid_grant → 授权已过期（isAuthExpired）', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 400, {
          'error': 'invalid_grant',
          'error_description': 'refresh token expired',
        });
      });
      final pan = AliyunPan(authBase: base);
      await expectLater(
        pan.refresh(
          const PanAccount(provider: PanProviderId.aliyun, refreshToken: 'bad'),
        ),
        throwsA(
          isA<PanException>()
              .having((e) => e.isAuthExpired, 'isAuthExpired', isTrue)
              .having((e) => e.message, 'message', contains('授权已过期')),
        ),
      );
    });

    test('list：next_marker 跨页拼接 + Bearer 鉴权头 + 字段收敛', () async {
      final requests = <_Req>[];
      final base = await mockServer((req) async {
        final captured = await _capture(req);
        requests.add(captured);
        final body = captured.body;
        final marker = (body['marker'] as String?) ?? '';
        if (marker.isEmpty) {
          await writeJson(req, 200, {
            'items': [
              {
                'file_id': 'f1',
                'name': '片1.mp4',
                'type': 'file',
                'size': 1024,
                'updated_at': '2026-11-01T10:00:00Z',
                'category': 'video',
                'extension': 'mp4',
              },
              {
                'file_id': 'd1',
                'name': '剧集',
                'type': 'folder',
                'size': 0,
                'updated_at': '2026-11-02T10:00:00Z',
              },
            ],
            'next_marker': 'm2',
          });
        } else {
          await writeJson(req, 200, {
            'items': [
              {
                'file_id': 'f2',
                'name': '片2.mkv',
                'type': 'file',
                'size': 2048,
                'updated_at': '2026-11-03T10:00:00Z',
              },
            ],
            'next_marker': '',
          });
        }
      });
      final pan = AliyunPan(base: base);
      final entries = await pan.list(
        const PanAccount(
          provider: PanProviderId.aliyun,
          refreshToken: 'rt',
          accessToken: 'at',
        ),
      );
      expect(entries.length, 3);
      expect(entries[0].name, '片1.mp4');
      expect(entries[0].folder, isFalse);
      expect(entries[0].size, 1024);
      expect(entries[0].extension, 'mp4');
      expect(entries[0].modifiedAt, DateTime.utc(2026, 11, 1, 10));
      expect(entries[1].folder, isTrue);
      expect(entries[2].id, 'f2');
      expect(requests.length, 2);
      expect(requests[1].body['marker'], 'm2');
      expect(requests[0].body['parent_file_id'], 'root');
      expect(requests[0].headers['authorization'], 'Bearer at');
    });

    test('fileUrl：get_download_url 返回直链并带 Referer', () async {
      final bodies = <Map<String, dynamic>>[];
      final base = await mockServer((req) async {
        bodies.add(await _bodyJson(req));
        await writeJson(req, 200, {
          'url': 'https://cdn.example/video.mp4?sign=1',
        });
      });
      final pan = AliyunPan(base: base);
      final file = await pan.fileUrl(
        const PanAccount(
          provider: PanProviderId.aliyun,
          refreshToken: 'rt',
          accessToken: 'at',
          driveId: 'drive1',
        ),
        const PanEntry(id: 'f9', name: 'a.mp4', folder: false, size: 1),
      );
      expect(file.url, 'https://cdn.example/video.mp4?sign=1');
      expect(file.headers['Referer'], 'https://www.aliyundrive.com/');
      expect(bodies.single['file_id'], 'f9');
      expect(bodies.single['drive_id'], 'drive1');
      expect(bodies.single['expire_sec'], 14400);
    });

    test('list：HTTP 401 + AccessTokenInvalid → 授权已过期', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 401, {
          'code': 'AccessTokenInvalid',
          'message': 'access token expired',
        });
      });
      final pan = AliyunPan(base: base);
      await expectLater(
        pan.list(
          const PanAccount(
            provider: PanProviderId.aliyun,
            refreshToken: 'rt',
            accessToken: 'bad',
          ),
        ),
        throwsA(
          isA<PanException>()
              .having((e) => e.isAuthExpired, 'isAuthExpired', isTrue)
              .having((e) => e.message, 'message', contains('授权已过期')),
        ),
      );
    });

    test('refresh：未绑定凭据 → 提示先去绑定（不发请求）', () async {
      final pan = AliyunPan();
      await expectLater(
        pan.refresh(
          const PanAccount(provider: PanProviderId.aliyun, refreshToken: ''),
        ),
        throwsA(
          isA<PanException>().having(
            (e) => e.message,
            'message',
            contains('未绑定阿里云盘账号'),
          ),
        ),
      );
    });

    test('fileUrl：目录条目 → 提示无直链', () async {
      final pan = AliyunPan();
      await expectLater(
        pan.fileUrl(
          const PanAccount(
            provider: PanProviderId.aliyun,
            refreshToken: 'rt',
            accessToken: 'at',
            driveId: 'd1',
          ),
          const PanEntry(id: 'd1', name: '剧集', folder: true),
        ),
        throwsA(
          isA<PanException>().having(
            (e) => e.message,
            'message',
            contains('目录'),
          ),
        ),
      );
    });
  });

  group('百度网盘', () {
    test('refresh：走 openapi OAuth2，携带四参并按 expires_in 计算过期', () async {
      final queries = <Map<String, String>>[];
      final base = await mockServer((req) async {
        queries.add(req.uri.queryParameters);
        await writeJson(req, 200, {
          'access_token': 'baidu_at',
          'refresh_token': 'baidu_rt',
          'expires_in': 2592000,
          'scope': 'basic,netdisk',
        });
      });
      final pan = BaiduPan(authBase: base);
      final before = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final account = await pan.refresh(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: 'rt',
          clientId: 'ak',
          clientSecret: 'sk',
        ),
      );
      final after = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      expect(account.accessToken, 'baidu_at');
      expect(account.refreshToken, 'baidu_rt');
      expect(account.expiryUnixSec, greaterThanOrEqualTo(before + 2592000));
      expect(account.expiryUnixSec, lessThanOrEqualTo(after + 2592000));
      final q = queries.single;
      expect(q['grant_type'], 'refresh_token');
      expect(q['refresh_token'], 'rt');
      expect(q['client_id'], 'ak');
      expect(q['client_secret'], 'sk');
    });

    test('refresh：缺 client_id/client_secret → 可操作文案', () async {
      final pan = BaiduPan();
      await expectLater(
        pan.refresh(
          const PanAccount(provider: PanProviderId.baidu, refreshToken: 'rt'),
        ),
        throwsA(
          isA<PanException>().having(
            (e) => e.message,
            'message',
            contains('client_id'),
          ),
        ),
      );
    });

    test('list：start/limit 翻页拼接 100+0 两页，path/字段收敛', () async {
      final starts = <int>[];
      final base = await mockServer((req) async {
        final start = int.parse(req.uri.queryParameters['start'] ?? '0');
        starts.add(start);
        final items = <Map<String, dynamic>>[
          if (start == 0)
            for (var i = 0; i < 100; i++)
              {
                'fs_id': i,
                'path': '/视频/第$i集.mp4',
                'server_filename': '第$i集.mp4',
                'isdir': 0,
                'size': 1000 + i,
                'mtime': 1700000000 + i,
              },
        ];
        await writeJson(req, 200, {'errno': 0, 'list': items});
      });
      final pan = BaiduPan(base: base);
      final entries = await pan.list(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: 'rt',
          accessToken: 'at',
        ),
      );
      expect(entries.length, 100);
      expect(entries.first.id, '0');
      expect(entries.first.name, '第0集.mp4');
      expect(entries.first.path, '/视频/第0集.mp4');
      expect(entries.first.size, 1000);
      expect(
        entries.first.modifiedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
      expect(starts, [0, 100]);
    });

    test('fileUrl：filemetas+dlink，拼接 access_token 与强制 UA', () async {
      final queries = <Map<String, String>>[];
      final base = await mockServer((req) async {
        queries.add(req.uri.queryParameters);
        await writeJson(req, 200, {
          'errno': 0,
          'list': [
            {
              'fs_id': 123,
              'dlink': 'https://d.pcs.baidu.com/file/abc?fname=x.mp4',
            },
          ],
        });
      });
      final pan = BaiduPan(base: base);
      final file = await pan.fileUrl(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: 'rt',
          accessToken: 'at',
        ),
        const PanEntry(
          id: '123',
          name: 'x.mp4',
          folder: false,
          size: 1,
          path: '/x.mp4',
        ),
      );
      expect(file.url, contains('https://d.pcs.baidu.com/file/abc'));
      expect(file.url, contains('access_token=at'));
      expect(file.headers['User-Agent'], 'pan.baidu.com');
      expect(file.headers['Referer'], 'https://pan.baidu.com/');
      final q = queries.single;
      expect(q['method'], 'filemetas');
      expect(q['dlink'], '1');
      expect(q['fsids'], contains('"fs_id":123'));
    });

    test('list：errno=-6 → 授权已过期并提示 scope', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 200, {
          'errno': -6,
          'error_msg': 'invalid access token',
        });
      });
      final pan = BaiduPan(base: base);
      await expectLater(
        pan.list(
          const PanAccount(
            provider: PanProviderId.baidu,
            refreshToken: 'rt',
            accessToken: 'at',
          ),
        ),
        throwsA(
          isA<PanException>()
              .having((e) => e.isAuthExpired, 'isAuthExpired', isTrue)
              .having((e) => e.message, 'message', contains('basic,netdisk')),
        ),
      );
    });

    // ── Cookie 模式（扫码登录后的 BDUSS 链路）──────────────────
    test('cookie 模式 refresh：取 bdstoken 写回 extra，不碰 OAuth', () async {
      final base = await mockServer((req) async {
        expect(req.uri.path, '/api/gettemplatevariable');
        expect(req.uri.queryParameters['fields'], contains('bdstoken'));
        expect(req.headers.value('cookie'), 'BDUSS=bduss-value');
        await writeJson(req, 200, {
          'errno': 0,
          'result': {'bdstoken': 'token-1'},
        });
      });
      final pan = BaiduPan(base: base);
      final account = await pan.refresh(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: '',
          cookie: 'BDUSS=bduss-value',
        ),
      );
      expect(account.extra['bdstoken'], 'token-1');
      expect(account.accessToken, isEmpty);
    });

    test('cookie 模式 refresh：errno -6 → 授权过期提示重新扫码', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 200, {'errno': -6, 'error_msg': 'invalid'});
      });
      final pan = BaiduPan(base: base);
      await expectLater(
        pan.refresh(
          const PanAccount(
            provider: PanProviderId.baidu,
            refreshToken: '',
            cookie: 'BDUSS=expired',
          ),
        ),
        throwsA(
          isA<PanException>()
              .having((e) => e.isAuthExpired, 'isAuthExpired', isTrue)
              .having((e) => e.message, 'message', contains('重新扫码')),
        ),
      );
    });

    test('cookie 模式 list：走 /api/list，server_filename/isdir 收敛', () async {
      final base = await mockServer((req) async {
        expect(req.uri.path, '/api/list');
        expect(req.uri.queryParameters['dir'], '/');
        expect(req.uri.queryParameters['bdstoken'], 'token-1');
        expect(req.uri.queryParameters['app_id'], '250528');
        expect(req.headers.value('cookie'), 'BDUSS=bduss-value');
        await writeJson(req, 200, {
          'errno': 0,
          'list': [
            {
              'fs_id': 1,
              'path': '/',
              'server_filename': '电影',
              'isdir': 1,
              'size': 0,
            },
            {
              'fs_id': 2,
              'path': '/电影/正片.mp4',
              'server_filename': '正片.mp4',
              'isdir': 0,
              'size': 1024,
            },
          ],
        });
      });
      final pan = BaiduPan(base: base);
      final entries = await pan.list(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: '',
          cookie: 'BDUSS=bduss-value',
          extra: {'bdstoken': 'token-1'},
        ),
      );
      expect(entries, hasLength(2));
      expect(entries[0].folder, isTrue);
      expect(entries[0].name, '电影');
      expect(entries[1].folder, isFalse);
      expect(entries[1].extension, 'mp4');
      expect(entries[1].path, '/电影/正片.mp4');
    });

    test('cookie 模式 fileUrl：/api/filemetas 取 dlink，播放头带 Cookie', () async {
      final base = await mockServer((req) async {
        expect(req.uri.path, '/api/filemetas');
        expect(req.uri.queryParameters['dlink'], '1');
        expect(req.uri.queryParameters['target'], contains('2'));
        await writeJson(req, 200, {
          'errno': 0,
          'info': [
            {
              'fs_id': 2,
              'dlink':
                  'https://d.pcs.baidu.com/file/abc?fid=2&sign=xyz&expires=8',
            },
          ],
        });
      });
      final pan = BaiduPan(base: base);
      final file = await pan.fileUrl(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: '',
          cookie: 'BDUSS=bduss-value',
          extra: {'bdstoken': 'token-1'},
        ),
        const PanEntry(id: '2', name: '正片.mp4', folder: false),
      );
      expect(file.url, contains('d.pcs.baidu.com/file/abc'));
      // Cookie 模式不需要拼接 access_token。
      expect(file.url, isNot(contains('access_token')));
      expect(file.headers['Cookie'], 'BDUSS=bduss-value');
      expect(file.headers['User-Agent'], BaiduPanEndpoints.webUA);
    });
  });

  group('夸克网盘', () {
    test('list：_page 翻页拼接 + Cookie 透传 + 字段收敛', () async {
      final pages = <String>[];
      final cookies = <String?>[];
      final base = await mockServer((req) async {
        pages.add(req.uri.queryParameters['_page'] ?? '');
        cookies.add(req.headers.value('cookie'));
        final page = req.uri.queryParameters['_page'] ?? '1';
        if (page == '1') {
          await writeJson(req, 200, {
            'status': 200,
            'data': {
              'list': [
                for (var i = 0; i < 100; i++)
                  {
                    'fid': 'f$i',
                    'file_name': '夸克片$i.mp4',
                    'dir': false,
                    'size': 2048,
                    'updated_at': 1770000000000,
                    'pdir_fid': '0',
                  },
              ],
              'metadata': {'_total': 150, '_count': 100, '_size': 100},
            },
            'message': '',
          });
        } else {
          await writeJson(req, 200, {
            'status': 200,
            'data': {
              'list': [
                for (var i = 100; i < 150; i++)
                  {
                    'fid': 'f$i',
                    'file_name': '夸克片$i.mp4',
                    'dir': false,
                    'size': 2048,
                    'updated_at': 1770000000000,
                    'pdir_fid': '0',
                  },
              ],
              'metadata': {'_total': 150, '_count': 50, '_size': 100},
            },
            'message': '',
          });
        }
      });
      final pan = QuarkPan(driveBase: base);
      final entries = await pan.list(
        const PanAccount(
          provider: PanProviderId.quark,
          refreshToken: '',
          accessToken: '',
          cookie: 'k=1',
        ),
      );
      expect(entries.length, 150);
      expect(entries.first.id, 'f0');
      expect(entries.first.name, '夸克片0.mp4');
      expect(entries.first.folder, isFalse);
      expect(entries.first.size, 2048);
      expect(
        entries.first.modifiedAt,
        DateTime.fromMillisecondsSinceEpoch(1770000000000, isUtc: true),
      );
      expect(pages, ['1', '2']);
      expect(cookies, ['k=1', 'k=1']);
    });

    test('fileUrl：download 返回直链并带 Referer/Cookie；23018 换 UA 重试', () async {
      final uas = <String?>[];
      final base = await mockServer((req) async {
        uas.add(req.headers.value('user-agent'));
        if (uas.length == 1) {
          await writeJson(req, 200, {'code': 23018, 'message': '操作频繁'});
        } else {
          await writeJson(req, 200, {
            'status': 200,
            'data': [
              {
                'fid': 'a1',
                'file_name': 'a.mp4',
                'download_url': 'https://oss.example/x.mp4',
              },
            ],
            'message': '',
          });
        }
      });
      final pan = QuarkPan(driveBase: base);
      final file = await pan.fileUrl(
        const PanAccount(
          provider: PanProviderId.quark,
          refreshToken: '',
          accessToken: '',
          cookie: 'k=1',
        ),
        const PanEntry(id: 'a1', name: 'a.mp4', folder: false, size: 1),
      );
      expect(file.url, 'https://oss.example/x.mp4');
      expect(file.headers['Referer'], 'https://pan.quark.cn/');
      expect(file.headers['Cookie'], 'k=1');
      expect(uas.length, 2);
      expect(uas.first, isNot(kQuarkElectronUA));
      expect(uas.last, kQuarkElectronUA);
    });

    test('list：HTTP 401 require login → 授权已过期', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 401, {'status': 401, 'message': 'require login'});
      });
      final pan = QuarkPan(driveBase: base);
      await expectLater(
        pan.list(
          const PanAccount(
            provider: PanProviderId.quark,
            refreshToken: '',
            accessToken: '',
            cookie: 'bad',
          ),
        ),
        throwsA(
          isA<PanException>()
              .having((e) => e.isAuthExpired, 'isAuthExpired', isTrue)
              .having((e) => e.message, 'message', contains('授权已过期')),
        ),
      );
    });

    test('refresh：Cookie 模式校验登录态并回填昵称/UID', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 200, {
          'status': 200,
          'data': {'nickname': '夸克用户', 'user_id': 'u9'},
          'message': '',
        });
      });
      final pan = QuarkPan(panBase: base);
      final account = await pan.refresh(
        const PanAccount(
          provider: PanProviderId.quark,
          refreshToken: '',
          cookie: 'c=1',
        ),
      );
      expect(account.userName, '夸克用户');
      expect(account.userId, 'u9');
      expect(account.cookie, 'c=1');
    });

    test('refresh：OAuth 模式走 account/v1/token 换令牌', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 200, {
          'data': {
            'access_token': 'qk_at',
            'refresh_token': 'qk_rt',
            'expires_in': 2592000,
          },
        });
      });
      final pan = QuarkPan(authBase: base);
      final account = await pan.refresh(
        const PanAccount(provider: PanProviderId.quark, refreshToken: 'qk_rt'),
      );
      expect(account.accessToken, 'qk_at');
      expect(account.refreshToken, 'qk_rt');
    });

    test('refresh：Cookie 失效（401）→ 授权已过期', () async {
      final base = await mockServer((req) async {
        await writeJson(req, 401, {'status': 401, 'message': 'require login'});
      });
      final pan = QuarkPan(panBase: base);
      await expectLater(
        pan.refresh(
          const PanAccount(
            provider: PanProviderId.quark,
            refreshToken: '',
            cookie: 'bad',
          ),
        ),
        throwsA(
          isA<PanException>().having((e) => e.isAuthExpired, 'auth', isTrue),
        ),
      );
    });

    test('list：未登录（无 Cookie 无 token）→ 提示粘贴凭据', () async {
      final pan = QuarkPan();
      await expectLater(
        pan.list(
          const PanAccount(provider: PanProviderId.quark, refreshToken: ''),
        ),
        throwsA(
          isA<PanException>().having(
            (e) => e.message,
            'message',
            contains('未登录'),
          ),
        ),
      );
    });
  });

  group('同源/越界防护', () {
    test('panSameOriginUrl：同源放行，跨域绝对路径直接拒绝', () {
      final base = Uri.parse('http://127.0.0.1:1234');
      expect(
        panSameOriginUrl(base, '/adrive/v3/file/list').origin,
        'http://127.0.0.1:1234',
      );
      expect(
        () => panSameOriginUrl(
          base,
          'https://evil.example.com/adrive/v3/file/list',
        ),
        throwsA(
          isA<PanException>().having(
            (e) => e.message,
            'message',
            contains('网盘地址超出当前服务器'),
          ),
        ),
      );
    });

    test('panPlayUrl：只允许 http/https + host 非空', () {
      expect(
        panPlayUrl(
          'https://cdn.example/a.mp4',
          provider: 'X',
          action: 'Y',
        ).toString(),
        'https://cdn.example/a.mp4',
      );
      expect(
        () => panPlayUrl('file:///etc/passwd', provider: 'X', action: 'Y'),
        throwsA(isA<PanException>()),
      );
      expect(
        () => panPlayUrl('javascript:alert(1)', provider: 'X', action: 'Y'),
        throwsA(isA<PanException>()),
      );
      expect(
        () => panPlayUrl('https://', provider: 'X', action: 'Y'),
        throwsA(isA<PanException>()),
      );
    });
  });

  group('账号模型与持久化', () {
    test('PanAccount JSON 序列化往返', () {
      const account = PanAccount(
        provider: PanProviderId.baidu,
        refreshToken: 'rt',
        accessToken: 'at',
        expiryUnixSec: 1600000000, // 2020 年，已过期
        userId: 'u1',
        userName: '名',
        clientId: 'ak',
        clientSecret: 'sk',
        driveId: 'd1',
        cookie: 'c=1',
        extra: {'k': 'v'},
      );
      final restored = PanAccount.fromJson(account.toJson());
      expect(restored.toJson(), equals(account.toJson()));
      expect(restored.provider, PanProviderId.baidu);
      expect(restored.expiryUnixSec, 1600000000);
      expect(restored.extra['k'], 'v');
      expect(restored.isTokenExpired(), isTrue);
    });

    test('PanAccount.fromJson 容忍脏字段（缺失/类型错位不崩）', () {
      final account = PanAccount.fromJson({
        'provider': 'quark',
        'refreshToken': 123,
        'expiryUnixSec': '1893456000',
      });
      expect(account.provider, PanProviderId.quark);
      expect(account.refreshToken, '123');
      expect(account.expiryUnixSec, 1893456000);
    });

    test(
      'PanAccountStore：save/load/remove 往返（本机 shared_preferences）',
      () async {
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        final store = PanAccountStore(storage);
        const account = PanAccount(
          provider: PanProviderId.aliyun,
          refreshToken: 'rt',
          accessToken: 'at',
          expiryUnixSec: 2000000000,
          userName: '阿',
        );
        await store.save(account);
        expect(
          store.load(PanProviderId.aliyun)!.toJson(),
          equals(account.toJson()),
        );
        expect(store.loadAll().length, 1);
        await store.remove(PanProviderId.aliyun);
        expect(store.load(PanProviderId.aliyun), isNull);
        expect(store.loadAll(), isEmpty);
      },
    );

    test('PanAccountStore：损坏 JSON 降级为空不崩', () async {
      SharedPreferences.setMockInitialValues({'pan_account_aliyun': '{broken'});
      final storage = StorageService();
      await storage.init();
      final store = PanAccountStore(storage);
      expect(store.load(PanProviderId.aliyun), isNull);
    });

    test('panTokenNeedsRefresh：无过期时间不刷新；缺失/临期令牌需刷新', () {
      const forever = PanAccount(
        provider: PanProviderId.quark,
        refreshToken: 'rt',
        accessToken: 'at',
      );
      expect(panTokenNeedsRefresh(forever), isFalse);
      const expired = PanAccount(
        provider: PanProviderId.aliyun,
        refreshToken: 'rt',
        accessToken: 'at',
        expiryUnixSec: 1,
      );
      expect(panTokenNeedsRefresh(expired), isTrue);
      final soon = PanAccount(
        provider: PanProviderId.aliyun,
        refreshToken: 'rt',
        accessToken: 'at',
        expiryUnixSec:
            DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 10,
      );
      expect(panTokenNeedsRefresh(soon, leadSeconds: 120), isTrue);
      expect(panTokenNeedsRefresh(soon, leadSeconds: 5), isFalse);
      const noAccess = PanAccount(
        provider: PanProviderId.baidu,
        refreshToken: 'rt',
      );
      expect(panTokenNeedsRefresh(noAccess), isTrue);
    });
  });

  group('注册表与网络策略', () {
    test('kPanProviders：三家齐全，根目录标识与描述齐备', () {
      expect(kPanProviders.keys, containsAll(PanProviderId.values));
      expect(panProviderFor(PanProviderId.aliyun), isA<AliyunPan>());
      expect(panProviderFor(PanProviderId.baidu), isA<BaiduPan>());
      expect(panProviderFor(PanProviderId.quark), isA<QuarkPan>());
      expect(panProviderFor(PanProviderId.aliyun).rootParentId, 'root');
      expect(panProviderFor(PanProviderId.baidu).rootParentId, '/');
      expect(panProviderFor(PanProviderId.quark).rootParentId, '0');
      for (final provider in kPanProviders.values) {
        expect(provider.displayName, isNotEmpty);
        expect(provider.description, isNotEmpty);
        expect(provider.base.scheme, 'https'); // 生产基址一律官方 https
      }
    });

    test('NetworkPolicy：HTTP 代理对网盘请求生效（请求经代理转发）', () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      var proxied = 0;
      proxy.listen((request) async {
        proxied++;
        request.response.statusCode = 200;
        request.response.write('{"errno": 0, "list": []}');
        await request.response.close();
      });
      NetworkPolicy.configure(
        doh: '',
        httpProxy: 'http://127.0.0.1:${proxy.port}',
      );
      // 非局域网域名由本地代理直接应答，不依赖真实 DNS 或外部服务。
      final target = Uri.parse('http://pan.test.invalid');
      final pan = BaiduPan(base: target);
      final entries = await pan.list(
        const PanAccount(
          provider: PanProviderId.baidu,
          refreshToken: 'rt',
          accessToken: 'at',
        ),
      );
      expect(entries, isEmpty);
      expect(proxied, greaterThanOrEqualTo(1));
    });
  });
}

/// 一次请求的录制（方法/路径/查询/体/头）。
class _Req {
  const _Req(this.method, this.path, this.query, this.body, this.headers);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

/// 读取请求体（HttpRequest 是 `Stream<Uint8List>`，先收字节再 UTF-8 解码）。
Future<String> _readBody(HttpRequest req) async {
  final chunks = await req.toList();
  final bytes = <int>[for (final chunk in chunks) ...chunk];
  return utf8.decode(bytes);
}

/// 启动本地 mock server；返回基址（provider 的 base/authBase 注入它）。
Future<Uri> mockServer(Future<void> Function(HttpRequest req) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    try {
      await handler(request);
    } catch (_) {
      // 单个用例的 handler 异常不能让整个 server 挂掉。
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  });
  return Uri.parse('http://127.0.0.1:${server.port}');
}

/// 写 JSON 响应并关闭。
Future<void> writeJson(HttpRequest req, int status, Map body) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

/// 录制请求（POST 读体）。
Future<_Req> _capture(HttpRequest req) async {
  final text = await _readBody(req);
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    decoded = null;
  }
  final headers = <String, String>{};
  req.headers.forEach((name, values) => headers[name] = values.join(','));
  return _Req(
    req.method,
    req.uri.path,
    Map<String, String>.from(req.uri.queryParameters),
    decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{},
    headers,
  );
}

Future<Map<String, dynamic>> _bodyJson(HttpRequest req) async {
  final text = await _readBody(req);
  if (text.trim().isEmpty) return {};
  final decoded = jsonDecode(text);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}
