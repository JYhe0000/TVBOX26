/// 百度网盘开放平台（xpan）接口实现。
///
/// 差异与风险（诚实标注）：
/// - 这是三家之中**唯一有官方开放平台**的（xpan / union 文档），但网盘能力
///   需要应用审核 + `basic,netdisk` scope；access_token 30 天有效，
///   refresh_token 长期有效（用户解除授权即双双失效）。
/// - 已知限制：**非会员限速**（官方策略，接口层无解）；`dlink` 直链约 8 小时
///   有效、可能 302 跳转（播放器需允许跟随跳转）；超过 50MB 的文件不允许
///   浏览器直接下载，TV 端播放器以流式 Range 请求播放通常不受此限（以真机为准）。
/// - 错误码（官方 FAQ）：20016 access_token 已过期、20017 无效（重新授权）、
///   -6 身份验证失败（token 无效或 scope 缺 netdisk）、31045 验证未通过。
/// - 令牌走 `openapi.baidu.com` OAuth2，业务走 `pan.baidu.com`，两个域；
///   业务请求强制 `User-Agent: pan.baidu.com`（官方要求，dlink 下载也一样）。
/// - 需要的 scope：`basic,netdisk`（列举/元信息/下载直链）。
///
/// **双模式**（按 [PanAccount] 里哪份凭据有值自动选择）：
/// - **OAuth 模式**（有 `accessToken`）：走官方开放平台 xpan 接口，即
///   [BaiduPanEndpoints.listPath] / [BaiduPanEndpoints.filemetasPath]；
/// - **Cookie 模式**（有 `cookie`、无 `accessToken`）：扫码登录拿到的
///   `BDUSS`/`STOKEN`，走网页版 `/api/list` + `/api/filemetas`。网页版接口
///   属非官方、字段随前端版本变化，且**未真机验证**；失败时抛
///   [PanException]「登录态已失效，请重新扫码」并保留切回 OAuth 的退路。
///
/// 按官方开放平台文档 + 社区网页版实现整理；OAuth 链路未真机验证（本环境
/// 无法访问真实平台），验证只能靠 mock。账号数据只存本机
/// shared_preferences（见 pan_account.dart）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../network_policy.dart';
import 'pan_account.dart';
import 'pan_models.dart';
import 'pan_provider.dart';

/// 百度网盘 API 常量（官方开放平台文档）。
class BaiduPanEndpoints {
  BaiduPanEndpoints._();

  static const String auth = 'https://openapi.baidu.com';
  static const String api = 'https://pan.baidu.com';
  static const String tokenPath = '/oauth/2.0/token';
  static const String listPath = '/rest/2.0/xpan/file';
  static const String filemetasPath = '/rest/2.0/xpan/multimedia';

  /// 网页版（Cookie 模式）路径，非官方接口。
  static const String webListPath = '/api/list';
  static const String webFilemetasPath = '/api/filemetas';
  static const String webTemplatePath = '/api/gettemplatevariable';

  /// 官方要求的固定 UA（列举与 dlink 下载都要带）。
  static const String ua = 'pan.baidu.com';

  /// 网页版接口要求的桌面 UA（用 `pan.baidu.com` 会被当客户端拒绝）。
  static const String webUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

  /// 网页版接口的公共查询参数（缺一个就可能返回 errno 2）。
  static const Map<String, String> webCommon = {
    'channel': 'chunlei',
    'web': '1',
    'app_id': '250528',
    'clienttype': '0',
  };
}

class BaiduPan extends PanProvider {
  /// [dio] 可注入（测试用）；[base]/[authBase] 仅测试/自托管网关覆盖用，
  /// 生产不传，一律走官方常量域名。
  factory BaiduPan({Dio? dio, Uri? base, Uri? authBase}) {
    final shared = dio ?? NetworkPolicy.attach(Dio(PanHttp.defaultOptions));
    return BaiduPan._(
      PanHttp(label: '百度网盘', base: base ?? _kApiBase, dio: shared),
      PanHttp(label: '百度网盘', base: authBase ?? _kAuthBase, dio: shared),
    );
  }

  BaiduPan._(this._api, this._auth);

  final PanHttp _api;
  final PanHttp _auth;

  static final Uri _kApiBase = Uri.https('pan.baidu.com', '');
  static final Uri _kAuthBase = Uri.https('openapi.baidu.com', '');

  @override
  PanProviderId get providerId => PanProviderId.baidu;

  @override
  String get displayName => '百度网盘';

  @override
  Uri get base => _api.base;

  @override
  String get rootParentId => '/';

  @override
  String get description => '官方开放平台 xpan；需 basic,netdisk scope；非会员限速';

  @override
  Future<PanAccount> refresh(PanAccount account) async {
    if (_cookieMode(account)) return _refreshCookie(account);
    panRequireRefreshToken(account, displayName);
    if (account.clientId.isEmpty || account.clientSecret.isEmpty) {
      throw PanException(
        '百度网盘缺少 client_id / client_secret，请先在设置页填写开放平台应用密钥后绑定',
      );
    }
    final json = await _auth.get(
      BaiduPanEndpoints.tokenPath,
      query: {
        'grant_type': 'refresh_token',
        'refresh_token': account.refreshToken,
        'client_id': account.clientId,
        'client_secret': account.clientSecret,
      },
    );
    final accessToken = panStringOf(json, ['access_token']);
    if (accessToken == null || accessToken.isEmpty) {
      throw panErrorFromJson(json, provider: displayName, action: '刷新令牌');
    }
    final expiresIn = panIntOf(json, ['expires_in']);
    return account.copyWith(
      accessToken: accessToken,
      refreshToken:
          panStringOf(json, ['refresh_token']) ?? account.refreshToken,
      expiryUnixSec: expiresIn == null
          ? null
          : DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + expiresIn,
    );
  }

  @override
  Future<List<PanEntry>> list(PanAccount account, {String? parentId}) async {
    if (_cookieMode(account)) {
      return _listCookie(account, parentId ?? rootParentId);
    }
    panRequireAccessToken(account, displayName);
    final dir = parentId ?? rootParentId;
    final entries = <PanEntry>[];
    var start = 0;
    for (var page = 0; page < kPanMaxPages; page++) {
      final json = await _api.get(
        BaiduPanEndpoints.listPath,
        query: {
          'method': 'list',
          'dir': dir,
          'order': 'time',
          'desc': '1',
          'start': '$start',
          'limit': '$kPanPageSize',
          'access_token': account.accessToken,
        },
        headers: {
          'User-Agent': BaiduPanEndpoints.ua,
          'Referer': 'https://pan.baidu.com/',
        },
      );
      final errno = panIntOf(json, ['errno']);
      if (errno != null && errno != 0) {
        throw panErrorFromJson(json, provider: displayName, action: '列举目录');
      }
      final items = json['list'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        if (item is Map) {
          entries.add(panEntryOf(item, path: panStringOf(item, ['path'])));
        }
      }
      if (items.length < kPanPageSize) break;
      start += kPanPageSize;
    }
    return entries;
  }

  @override
  Future<PanFileUrl> fileUrl(PanAccount account, PanEntry entry) async {
    if (_cookieMode(account)) return _fileUrlCookie(account, entry);
    panRequireAccessToken(account, displayName);
    panRequireFileEntry(displayName, entry);
    if (entry.path == null || entry.path!.isEmpty) {
      throw PanException('百度网盘：该文件缺少路径信息，无法获取直链');
    }
    // 官方文档：dlink 需经 filemetas（dlink=1）查询；使用时拼接 access_token，
    // 请求头带 User-Agent: pan.baidu.com；有效期约 8 小时，可能 302 跳转。
    final fsId = int.tryParse(entry.id);
    final json = await _api.get(
      BaiduPanEndpoints.filemetasPath,
      query: {
        'method': 'filemetas',
        'fsids': jsonEncode([
          {'fs_id': fsId ?? entry.id},
        ]),
        'dlink': '1',
        'access_token': account.accessToken,
      },
      headers: {
        'User-Agent': BaiduPanEndpoints.ua,
        'Referer': 'https://pan.baidu.com/',
      },
    );
    final errno = panIntOf(json, ['errno']);
    if (errno != null && errno != 0) {
      throw panErrorFromJson(json, provider: displayName, action: '获取直链');
    }
    String? dlink;
    final list = json['list'];
    if (list is List && list.isNotEmpty && list.first is Map) {
      dlink = panStringOf(list.first as Map, ['dlink']);
    }
    dlink ??= panStringOf(json, ['dlink', 'url']);
    if (dlink == null || dlink.isEmpty) {
      throw PanException('获取播放地址失败：百度网盘未返回 dlink，请确认文件可下载后重试');
    }
    // 官方要求：dlink 后必须拼接 access_token（已带则覆盖）。
    final uri = Uri.parse(dlink);
    final withToken = uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'access_token': account.accessToken,
      },
    );
    return PanFileUrl(
      url: panPlayUrl(
        withToken.toString(),
        provider: displayName,
        action: '获取播放地址',
      ).toString(),
      headers: {
        'User-Agent': BaiduPanEndpoints.ua,
        'Referer': 'https://pan.baidu.com/',
      },
    );
  }

  // ── Cookie 模式（网页版非官方接口）────────────────────────
  //
  // 与 OAuth 模式的取舍：扫码拿到的是 BDUSS/STOKEN，官方开放平台不认；
  // 这里只能走 pan.baidu.com 网页前端同款接口。已知差异：
  // - 目录项字段 `server_filename` / `isdir` / `path`，与 xpan 的
  //   `server_filename` / `isdir` 基本一致（`panEntryOf` 已兼容）；
  // - `/api/list` 与 `/api/filemetas` 需要 `bdstoken`（先
  //   `/api/gettemplatevariable` 取），并随请求带 Cookie；
  // - dlink 不必再拼 access_token，播放请求带 Cookie + 桌面 UA。

  bool _cookieMode(PanAccount account) =>
      account.cookie.trim().isNotEmpty && account.accessToken.trim().isEmpty;

  Map<String, String> _webHeaders(PanAccount account) => {
    'User-Agent': BaiduPanEndpoints.webUA,
    'Referer': 'https://pan.baidu.com/disk/main',
    'Cookie': account.cookie,
  };

  Future<PanAccount> _refreshCookie(PanAccount account) async {
    final bdstoken = await _bdstoken(account);
    return account.copyWith(extra: {...account.extra, 'bdstoken': bdstoken});
  }

  /// `bdstoken` 是网页版接口的会话令牌；`refresh` 时取一次写回
  /// `extra`，[list] / [fileUrl] 直接复用，避免每页都多打一次请求。
  Future<String> _bdstoken(PanAccount account) async {
    final json = await _api.get(
      BaiduPanEndpoints.webTemplatePath,
      query: {
        'fields': jsonEncode(['bdstoken']),
        ...BaiduPanEndpoints.webCommon,
      },
      headers: _webHeaders(account),
    );
    final errno = panIntOf(json, ['errno']);
    if (errno != null && errno != 0) {
      throw PanException(
        '百度网盘登录态已失效（errno $errno），请重新扫码绑定',
        isAuthExpired: true,
      );
    }
    final result = json['result'];
    final token = result is Map ? panStringOf(result, ['bdstoken']) : null;
    if (token == null) {
      throw const PanException('百度网盘登录态已失效，请重新扫码绑定', isAuthExpired: true);
    }
    return token;
  }

  Future<List<PanEntry>> _listCookie(PanAccount account, String dir) async {
    final bdstoken =
        panStringOf(account.extra, ['bdstoken']) ?? await _bdstoken(account);
    final entries = <PanEntry>[];
    var start = 0;
    for (var page = 0; page < kPanMaxPages; page++) {
      final json = await _api.get(
        BaiduPanEndpoints.webListPath,
        query: {
          'dir': dir,
          'order': 'name',
          'desc': '0',
          'start': '$start',
          'limit': '$kPanPageSize',
          'bdstoken': bdstoken,
          ...BaiduPanEndpoints.webCommon,
        },
        headers: _webHeaders(account),
      );
      final errno = panIntOf(json, ['errno']);
      if (errno != null && errno != 0) {
        throw panErrorFromJson(json, provider: displayName, action: '列举目录');
      }
      final items = json['list'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        if (item is! Map) continue;
        entries.add(
          panEntryOf(
            item,
            nameKeys: const ['server_filename', 'name'],
            path: panStringOf(item, ['path']),
          ),
        );
      }
      if (items.length < kPanPageSize) break;
      start += kPanPageSize;
    }
    return entries;
  }

  Future<PanFileUrl> _fileUrlCookie(PanAccount account, PanEntry entry) async {
    panRequireFileEntry(displayName, entry);
    final bdstoken =
        panStringOf(account.extra, ['bdstoken']) ?? await _bdstoken(account);
    final fsId = int.tryParse(entry.id);
    if (fsId == null) {
      throw const PanException('百度网盘：文件 id 不是数字，无法获取直链');
    }
    final json = await _api.get(
      BaiduPanEndpoints.webFilemetasPath,
      query: {
        'target': jsonEncode([fsId]),
        'dlink': '1',
        'bdstoken': bdstoken,
        ...BaiduPanEndpoints.webCommon,
      },
      headers: _webHeaders(account),
    );
    final errno = panIntOf(json, ['errno']);
    if (errno != null && errno != 0) {
      throw panErrorFromJson(json, provider: displayName, action: '获取直链');
    }
    String? dlink;
    final info = json['info'];
    if (info is List && info.isNotEmpty && info.first is Map) {
      dlink = panStringOf(info.first as Map, ['dlink']);
    }
    dlink ??= panStringOf(json, ['dlink']);
    if (dlink == null || dlink.isEmpty) {
      throw const PanException('获取播放地址失败：百度网盘未返回 dlink，请确认文件可下载后重试');
    }
    return PanFileUrl(
      url: panPlayUrl(
        dlink,
        provider: displayName,
        action: '获取播放地址',
      ).toString(),
      headers: {
        'User-Agent': BaiduPanEndpoints.webUA,
        'Referer': 'https://pan.baidu.com/',
        'Cookie': account.cookie,
      },
    );
  }
}
