/// 夸克网盘非官方接口实现（Cookie 登录态为主，TV/OAuth 模式为辅）。
///
/// 差异与风险（诚实标注）：
/// - 个人网盘**没有公开 refresh_token 接口**；社区/OpenList 的夸克TV 驱动走
///   `api.quark.cn/account/v1/token` 的 OAuth 刷新（需 refresh_token + 设备号），
///   本层按公开资料实现该路径，但**未真机验证**；更稳的路线是 Cookie 模式。
/// - Cookie 模式：`drive-pc.quark.cn` 的接口需要完整登录态 Cookie（含 `__puus`
///   等），UI 集成时须提示用户粘贴 pan.quark.cn 的完整 Cookie；Cookie 失效时
///   接口返回 `require login`，本层映射为「授权已过期，请重新绑定」。
/// - 已知限制：非会员下载限速（接口层无解）；`/file/download` 返回的直链指向
///   阿里云 OSS，**播放时不得带 Content-Type**（签名校验会失败），只带
///   Referer/Origin/Cookie/UA；`code=23018` 为获取频率限制（换 Electron UA
///   重试一次，社区原逻辑）。
/// - 列表接口 `_sort` 固定 `file_type:asc,updated_at:desc`（目录优先）。
/// - 需要的授权：网盘文件读取（Cookie 模式即账号本身；TV/OAuth 模式需
///   refresh_token 由夸克TV 驱动授权页发放）。
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

/// 夸克 PC 网页 UA（drive-pc.quark.cn 接口按 web 端校验）。
const String kQuarkWebUA =
    'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/94.0.4606.71 Safari/537.36 Core/1.94.225.400 QQBrowser/12.2.5544.400';

/// 夸克 Electron 客户端 UA：`/file/download` 返回 code=23018（频率限制）时
/// 切换该 UA 重试一次（社区项目 QuarkPanTool / quark-hub 的原逻辑）。
const String kQuarkElectronUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'quark-cloud-drive/2.5.56 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 '
    'Safari/537.36 Channel/pckk_other_ch';

/// 夸克网盘 API 常量（公开非官方资料整理，未真机验证）。
class QuarkPanEndpoints {
  QuarkPanEndpoints._();

  static const String drive = 'https://drive-pc.quark.cn';
  static const String pan = 'https://pan.quark.cn';
  static const String auth = 'https://api.quark.cn';
  static const String listPath = '/1/clouddrive/file/sort';
  static const String downloadPath = '/1/clouddrive/file/download';
  static const String accountInfoPath = '/account/info';
  static const String tokenPath = '/account/v1/token';
}

class QuarkPan extends PanProvider {
  /// [dio] 可注入（测试用）；[driveBase]/[panBase]/[authBase] 仅测试/自托管
  /// 网关覆盖用，生产不传，一律走官方常量域名。
  factory QuarkPan({Dio? dio, Uri? driveBase, Uri? panBase, Uri? authBase}) {
    final shared = dio ?? NetworkPolicy.attach(Dio(PanHttp.defaultOptions));
    return QuarkPan._(
      PanHttp(label: '夸克网盘', base: driveBase ?? _kDriveBase, dio: shared),
      PanHttp(label: '夸克网盘', base: panBase ?? _kPanBase, dio: shared),
      PanHttp(label: '夸克网盘', base: authBase ?? _kAuthBase, dio: shared),
    );
  }

  QuarkPan._(this._drive, this._pan, this._auth);

  final PanHttp _drive;
  final PanHttp _pan;
  final PanHttp _auth;

  static final Uri _kDriveBase = Uri.https('drive-pc.quark.cn', '');
  static final Uri _kPanBase = Uri.https('pan.quark.cn', '');
  static final Uri _kAuthBase = Uri.https('api.quark.cn', '');

  @override
  PanProviderId get providerId => PanProviderId.quark;

  @override
  String get displayName => '夸克网盘';

  @override
  Uri get base => _drive.base;

  @override
  String get rootParentId => '0';

  @override
  String get description => '非官方接口；需粘贴登录态 Cookie（或夸克TV refresh_token）；非会员限速';

  @override
  Future<PanAccount> refresh(PanAccount account) async {
    if (!account.hasRefreshToken && !account.hasCookie) {
      throw PanException('未绑定夸克网盘账号，请粘贴 Cookie 或 refresh_token 后重试');
    }
    if (account.hasRefreshToken) {
      // TV/OAuth 模式：refresh_token 换 access_token（夸克TV 驱动同款路径）。
      final json = await _auth.post(
        QuarkPanEndpoints.tokenPath,
        body: {
          'refresh_token': account.refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      final data = json['data'];
      final payload = data is Map ? data : json;
      final accessToken = panStringOf(payload, ['access_token', 'token']);
      if (accessToken == null || accessToken.isEmpty) {
        throw panErrorFromJson(json, provider: displayName, action: '刷新令牌');
      }
      return account.copyWith(
        accessToken: accessToken,
        refreshToken:
            panStringOf(payload, ['refresh_token']) ?? account.refreshToken,
        expiryUnixSec: panUnixSecOf(panIntOf(payload, ['expires_in'])),
        userId: panStringOf(payload, ['user_id']) ?? account.userId,
        userName:
            panStringOf(payload, ['nickname', 'nick_name']) ?? account.userName,
      );
    }
    // Cookie 模式：无刷新流程，只校验登录态并回填昵称/UID。
    final json = await _pan.get(
      QuarkPanEndpoints.accountInfoPath,
      query: {'fr': 'pc', 'platform': 'pc'},
      headers: _headers(account),
    );
    _checkStatus(json, '校验登录态');
    final data = json['data'];
    if (data is! Map) {
      throw PanException('校验登录态失败：夸克网盘未返回账号信息，请重新粘贴 Cookie');
    }
    return account.copyWith(
      userName:
          panStringOf(data, ['nickname', 'nick_name']) ?? account.userName,
      userId: panStringOf(data, ['user_id', 'uid']) ?? account.userId,
    );
  }

  @override
  Future<List<PanEntry>> list(PanAccount account, {String? parentId}) async {
    _requireLogin(account);
    final entries = <PanEntry>[];
    var page = 1;
    for (var i = 0; i < kPanMaxPages; i++) {
      final json = await _drive.get(
        QuarkPanEndpoints.listPath,
        query: {
          'pr': 'ucpro',
          'fr': 'pc',
          'uc_param_str': '',
          'pdir_fid': parentId ?? rootParentId,
          '_page': '$page',
          '_size': '$kPanPageSize',
          '_fetch_total': '1',
          '_fetch_sub_dirs': '1',
          '_sort': 'file_type:asc,updated_at:desc',
        },
        headers: _headers(account),
      );
      _checkStatus(json, '列举目录');
      final data = json['data'];
      if (data is! Map) break;
      final items = data['list'];
      if (items is! List) break;
      for (final item in items) {
        if (item is Map) entries.add(panEntryOf(item));
      }
      final meta = data['metadata'];
      final total = meta is Map ? (panIntOf(meta, ['_total']) ?? 0) : 0;
      if (items.length < kPanPageSize) break;
      if (total > 0 && entries.length >= total) break;
      page++;
    }
    return entries;
  }

  @override
  Future<PanFileUrl> fileUrl(PanAccount account, PanEntry entry) async {
    _requireLogin(account);
    panRequireFileEntry(displayName, entry);
    // 社区原逻辑：code=23018（频率限制）时换 Electron UA 重试一次。
    for (final ua in [kQuarkWebUA, kQuarkElectronUA]) {
      final json = await _drive.post(
        QuarkPanEndpoints.downloadPath,
        body: {
          'fids': [entry.id],
        },
        query: {'pr': 'ucpro', 'fr': 'pc', 'uc_param_str': ''},
        headers: _headers(account, ua: ua),
      );
      if (panStringOf(json, ['code']) == '23018') continue;
      _checkStatus(json, '获取直链');
      final data = json['data'];
      String? url;
      if (data is List && data.isNotEmpty && data.first is Map) {
        url = panStringOf(data.first as Map, [
          'download_url',
          'video_url',
          'url',
        ]);
      } else if (data is Map) {
        url = panStringOf(data, ['download_url', 'video_url', 'url']);
      }
      url ??= panStringOf(json, ['download_url', 'video_url', 'url']);
      if (url == null || url.isEmpty) {
        throw PanException('获取播放地址失败：夸克网盘未返回直链，请确认文件为自有文件后重试');
      }
      return PanFileUrl(
        url: panPlayUrl(
          url,
          provider: displayName,
          action: '获取播放地址',
        ).toString(),
        headers: _playHeaders(account),
      );
    }
    throw const PanException('获取直链过于频繁，请稍后再试');
  }

  /// 夸克成功约定：顶层 `status == 200`（其余为错误，message 带原因）。
  void _checkStatus(Map<String, dynamic> json, String action) {
    final status = panIntOf(json, ['status']);
    if (status != null && status != 200) {
      throw panErrorFromJson(json, provider: displayName, action: action);
    }
  }

  void _requireLogin(PanAccount account) {
    if (account.cookie.trim().isEmpty && account.accessToken.trim().isEmpty) {
      throw PanException(
        '夸克网盘未登录：请粘贴 pan.quark.cn 的 Cookie 或绑定 refresh_token 后重试',
      );
    }
  }

  Map<String, String> _headers(PanAccount account, {String? ua}) {
    final headers = <String, String>{
      'Referer': 'https://pan.quark.cn/',
      'Origin': 'https://pan.quark.cn',
      'User-Agent': ua ?? kQuarkWebUA,
      'Accept': 'application/json, text/plain, */*',
    };
    if (account.cookie.isNotEmpty) {
      headers['Cookie'] = account.cookie;
    } else if (account.accessToken.isNotEmpty) {
      // TV/OAuth 模式下以 Bearer 头发送（夸克TV 驱动做法；未真机验证）。
      headers['Authorization'] = 'Bearer ${account.accessToken}';
    }
    return headers;
  }

  /// 播放直链请求头：OSS 直链带签名，Referer/Origin/Cookie/UA 缺一不可。
  Map<String, String> _playHeaders(PanAccount account) {
    final headers = <String, String>{
      'Referer': 'https://pan.quark.cn/',
      'Origin': 'https://pan.quark.cn',
      'User-Agent': kQuarkWebUA,
    };
    if (account.cookie.isNotEmpty) headers['Cookie'] = account.cookie;
    return headers;
  }
}
