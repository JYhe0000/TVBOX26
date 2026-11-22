/// 阿里云盘（个人网盘）非官方接口实现。
///
/// 差异与风险（诚实标注）：
/// - 全部接口均为**非官方**（阿里云盘未对个人开放网盘 API；官方 PDS 是另一套
///   面向开发者的 API），路径/字段随时可能变更，接口变更风险高。
/// - 令牌：`POST https://auth.aliyundrive.com/v2/account/token`
///   body `{"refresh_token": ..., "grant_type": "refresh_token"}`；
///   2024-08 起社区反馈 `api.alipan.com` 与 `api.aliyundrive.com` 等价可用。
/// - refresh_token **必须是移动端抓取的**（桌面 web 的 token 无法下载/播放）。
/// - 2023 年后官方加了 `x-device-id` / `x-signature` 设备签名校验，纯 Bearer
///   可能被 401 拒绝；本层不伪造签名，真机接入遇 401 时需补设备签名或改走
///   OpenList/社区网关（不在本层范围）。
/// - 播放：`get_download_url` 返回下载直链（视频可直接播），需带
///   `Referer: https://www.aliyundrive.com/`。
/// - scope：抓包所得 refresh_token 不需要任何 client 凭据；自建应用走官方
///   OAuth 时 client_id/secret 由用户粘贴（本层不内建）。
/// - 需要的授权范围：网盘文件读取（个人版无显式 scope 概念）。
///
/// 以上端点均未真机验证（本环境无法访问真实平台），验证只能靠 mock；
/// 接入时请先真机抓包核对路径与字段。账号数据只存本机 shared_preferences
/// （见 pan_account.dart）。
library;

import 'package:dio/dio.dart';

import '../network_policy.dart';
import 'pan_account.dart';
import 'pan_models.dart';
import 'pan_provider.dart';

/// 阿里云盘 API 常量（公开非官方资料整理，未真机验证）。
class AliyunPanEndpoints {
  AliyunPanEndpoints._();

  static const String auth = 'https://auth.aliyundrive.com';
  static const String api = 'https://api.aliyundrive.com';
  static const String refreshPath = '/v2/account/token';
  static const String listPath = '/adrive/v3/file/list';
  static const String downloadPath = '/v2/file/get_download_url';

  /// 官方播放信息接口（视频在线转码）；本层用下载直链播放，不调它。
  static const String playInfoPath = '/v2/file/get_video_preview_play_info';
}

class AliyunPan extends PanProvider {
  /// [dio] 可注入（测试用）；[base]/[authBase] 仅测试/自托管网关覆盖用，
  /// 生产不传，一律走官方常量域名。
  factory AliyunPan({Dio? dio, Uri? base, Uri? authBase}) {
    final shared = dio ?? NetworkPolicy.attach(Dio(PanHttp.defaultOptions));
    return AliyunPan._(
      PanHttp(label: '阿里云盘', base: base ?? _kApiBase, dio: shared),
      PanHttp(label: '阿里云盘', base: authBase ?? _kAuthBase, dio: shared),
    );
  }

  AliyunPan._(this._api, this._auth);

  final PanHttp _api;
  final PanHttp _auth;

  static final Uri _kApiBase = Uri.https('api.aliyundrive.com', '');
  static final Uri _kAuthBase = Uri.https('auth.aliyundrive.com', '');

  @override
  PanProviderId get providerId => PanProviderId.aliyun;

  @override
  String get displayName => '阿里云盘';

  @override
  Uri get base => _api.base;

  @override
  String get rootParentId => 'root';

  @override
  String get description => '非官方接口；refresh_token 需移动端抓取，access_token 约 2 小时有效';

  @override
  Future<PanAccount> refresh(PanAccount account) async {
    panRequireRefreshToken(account, displayName);
    final json = await _auth.post(
      AliyunPanEndpoints.refreshPath,
      body: {
        'refresh_token': account.refreshToken,
        'grant_type': 'refresh_token',
      },
    );
    if (panStringOf(json, ['code', 'error']) != null) {
      throw panErrorFromJson(json, provider: displayName, action: '刷新令牌');
    }
    final accessToken = panStringOf(json, ['access_token']);
    if (accessToken == null || accessToken.isEmpty) {
      throw PanException('刷新失败：阿里云盘未返回 access_token，请检查 refresh_token 是否有效');
    }
    return account.copyWith(
      accessToken: accessToken,
      refreshToken:
          panStringOf(json, ['refresh_token']) ?? account.refreshToken,
      expiryUnixSec: panUnixSecOf(json['expire_time'] ?? json['expires_in']),
      userId: panStringOf(json, ['user_id']) ?? account.userId,
      userName: panStringOf(json, ['nick_name']) ?? account.userName,
      driveId: panStringOf(json, ['default_drive_id']) ?? account.driveId,
    );
  }

  @override
  Future<List<PanEntry>> list(PanAccount account, {String? parentId}) async {
    panRequireAccessToken(account, displayName);
    final entries = <PanEntry>[];
    var marker = '';
    for (var page = 0; page < kPanMaxPages; page++) {
      final json = await _api.post(
        AliyunPanEndpoints.listPath,
        body: <String, dynamic>{
          'parent_file_id': parentId ?? rootParentId,
          'limit': kPanPageSize,
          'fields': '*',
          'order_by': 'updated_at',
          'order_direction': 'DESC',
          if (marker.isNotEmpty) 'marker': marker,
        },
        headers: {'Authorization': 'Bearer ${account.accessToken}'},
      );
      if (panStringOf(json, ['code', 'error']) != null) {
        throw panErrorFromJson(json, provider: displayName, action: '列举目录');
      }
      final items = json['items'];
      if (items is! List) break;
      for (final item in items) {
        if (item is Map) entries.add(panEntryOf(item));
      }
      marker = panStringOf(json, ['next_marker']) ?? '';
      if (marker.isEmpty) break;
    }
    return entries;
  }

  @override
  Future<PanFileUrl> fileUrl(PanAccount account, PanEntry entry) async {
    panRequireAccessToken(account, displayName);
    panRequireFileEntry(displayName, entry);
    if (account.driveId.isEmpty) {
      throw PanException('阿里云盘缺少 drive_id，请解绑后重新绑定账号');
    }
    final json = await _api.post(
      AliyunPanEndpoints.downloadPath,
      body: {
        'drive_id': account.driveId,
        'file_id': entry.id,
        'expire_sec': 14400,
      },
      headers: {'Authorization': 'Bearer ${account.accessToken}'},
    );
    final url = panStringOf(json, ['url', 'download_url']);
    if (url == null || url.isEmpty) {
      throw PanException('获取播放地址失败：阿里云盘未返回直链，请稍后重试');
    }
    return PanFileUrl(
      url: panPlayUrl(url, provider: displayName, action: '获取播放地址').toString(),
      headers: {
        'Referer': 'https://www.aliyundrive.com/',
        'User-Agent': kPanDefaultUA,
      },
    );
  }
}
