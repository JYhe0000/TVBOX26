// 检查更新的纯函数回归：版本比较 / GitHub Release 解析 / APK 资产选择。
// 网络拉取与 APK 下载不在此覆盖（真机验收），这里锁定可离线判定的契约。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/core/app_updater.dart';

void main() {
  group('isNewerVersion', () {
    test('远端更高 → true（逐段比较）', () {
      expect(isNewerVersion('1.0.0', '1.0.1'), isTrue);
      expect(isNewerVersion('1.0.9', '1.1.0'), isTrue);
      expect(isNewerVersion('1.9.9', '2.0.0'), isTrue);
    });

    test('远端更低或相同 → false', () {
      expect(isNewerVersion('1.0.1', '1.0.0'), isFalse);
      expect(isNewerVersion('2.0.0', '1.9.9'), isFalse);
      expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    });

    test('v 前缀与 +build 后缀', () {
      expect(isNewerVersion('1.0.0', 'v1.1.0'), isTrue);
      expect(isNewerVersion('1.0.0', 'v1.0.0+2'), isTrue);
      expect(isNewerVersion('1.0.0+3', 'v1.0.0+2'), isFalse);
      expect(isNewerVersion('1.0.0+3', 'v1.0.0+3'), isFalse);
    });

    test('段数不同按 0 补齐（1.0 == 1.0.0）', () {
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0.0', '1.1'), isTrue);
    });

    test('脏 tag 解析失败的段按 0 处理，不抛异常', () {
      expect(isNewerVersion('1.0.0', 'abc'), isFalse);
      expect(isNewerVersion('1.0.0', 'v1.x.0'), isFalse);
    });
  });

  group('parseLatestRelease', () {
    const assets = [
      {
        'name': 'tvbox26-v1.2.3-arm64-v8a.apk',
        'size': 24117248,
        'browser_download_url':
            'https://github.com/JYhe0000/TVBOX26/releases/download/v1.2.3/tvbox26-v1.2.3-arm64-v8a.apk',
        'content_type': 'application/vnd.android.package-archive',
      },
      {
        'name': 'tvbox26-v1.2.3-universal.apk',
        'size': 31457280,
        'browser_download_url':
            'https://github.com/JYhe0000/TVBOX26/releases/download/v1.2.3/tvbox26-v1.2.3-universal.apk',
        'content_type': 'application/vnd.android.package-archive',
      },
    ];

    test('解析 tag / 说明 / 资产并剥 v 前缀', () {
      final info = parseLatestRelease(const {
        'tag_name': 'v1.2.3',
        'body': '修复若干问题\n优化体验',
        'published_at': '2026-11-22T08:00:00Z',
        'assets': assets,
      });
      expect(info.tagName, 'v1.2.3');
      expect(info.versionName, '1.2.3');
      expect(info.releaseNotes, '修复若干问题\n优化体验');
      expect(info.assetName, 'tvbox26-v1.2.3-arm64-v8a.apk');
      expect(info.assetUrl, contains('releases/download/v1.2.3'));
      expect(info.assetSize, 24117248);
      expect(info.publishedAt, isNotNull);
    });

    test('arm64 资产优先于 universal', () {
      final info = parseLatestRelease(
        const {'tag_name': 'v1.2.3', 'assets': assets},
      );
      expect(info.assetName, 'tvbox26-v1.2.3-arm64-v8a.apk');
    });

    test('没有 arm64 时回退第一个 .apk（非 apk 资产被跳过）', () {
      final info = parseLatestRelease(const {
        'tag_name': 'v1.0.0',
        'assets': [
          {
            'name': 'tvbox26-universal.apk',
            'size': 1,
            'browser_download_url': 'u1',
          },
          {
            'name': 'tvbox26-arm64-v8a.zip',
            'size': 2,
            'browser_download_url': 'z',
          },
        ],
      });
      expect(info.assetName, 'tvbox26-universal.apk');
    });

    test('没有 APK 资产 → UpdateCheckException(noApk)', () {
      expect(
        () => parseLatestRelease(const {
          'tag_name': 'v1.0.0',
          'assets': [
            {
              'name': 'source.zip',
              'size': 1,
              'browser_download_url': 'z',
            },
          ],
        }),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.type,
            'type',
            AppUpdateError.noApk,
          ),
        ),
      );
    });
  });

  group('pickApkAsset', () {
    test('混入非 Map / 缺名资产不崩溃，能挑出合法 .apk', () {
      final picked = pickApkAsset(<Object?>[
        null,
        'not-a-map',
        const {'no-name': true},
        const {'name': 'a.apk', 'browser_download_url': 'u'},
      ]);
      expect(picked, isNotNull);
      expect(picked!['name'], 'a.apk');
    });

    test('没有任何 .apk → null', () {
      final picked = pickApkAsset(<Object?>[
        const {'name': 'source.zip'},
      ]);
      expect(picked, isNull);
    });
  });

  test('jsonDecode 产物（真实响应路径）也能解析', () {
    final json = jsonDecode(
      '{"tag_name":"v2.0.0","body":"","published_at":null,'
      '"assets":[{"name":"x.apk","size":10,"browser_download_url":"u"}]}',
    );
    final info = parseLatestRelease(json as Map);
    expect(info.versionName, '2.0.0');
    expect(info.releaseNotes, isEmpty);
    expect(info.publishedAt, isNull);
  });
}
