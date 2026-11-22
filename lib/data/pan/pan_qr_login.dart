/// 阿里云盘 / 夸克网盘 / 百度网盘 扫码登录（电视端展示二维码，手机扫码授权）。
///
/// 来源：`网盘参考/src/core/cloud-login.ts` 的 aliyun / quark / baidu 三个
/// handler（TVBox Source Aggregator，MIT）。本文件只搬「生成二维码 + 轮询
/// 状态 + 换取凭据」这三步，业务 API 仍走 `aliyun_pan.dart` /
/// `quark_pan.dart` / `baidu_pan.dart`。
///
/// 与参考实现的差异（都是实测修正，不是猜的）：
/// - 夸克生成接口实测返回 `status: 2000000`（参考代码判断 `!== 200` 会误判
///   失败），这里以 `members.token` 是否存在为准；
/// - 百度轮询 `channel/unicast` 是**长轮询**（实测 20s 无响应属正常），
///   Dio 收到超时一律按 `waiting` 继续，不弹错误；
/// - 百度生成时把 `gid` 一并存进会话，轮询复用同一个 `gid`（参考实现每次
///   重新生成，账号绑定偶发校验失败）。
///
/// 诚实边界（务必先读）：
/// - 三家扫码都是**网页端登录接口**，非厂商公开 OAuth；接口随时可能变更，
///   属「能用即用」能力，失败时 UI 仍保留手动粘贴凭据的退路；
/// - 本环境只能验证「生成二维码」与「等待态轮询」真实可达（见
///   `test/pan_qr_login_test.dart` 的 mock 契约）；`CONFIRMED` 分支依赖
///   手机实际扫码，未经真机验证；
/// - 百度扫码得到的是 `BDUSS` 登录态 Cookie，只能走网页版接口（见
///   `baidu_pan.dart` 的 Cookie 模式），与开放平台 access_token 是两条链路；
/// - 凭据只回传给调用方，本文件不落盘、不打日志。
library;

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../network_policy.dart';
import 'pan_account.dart';
import 'pan_provider.dart';

/// 三家登录接口的默认域名（测试可整体替换为本地 mock）。
final Map<PanProviderId, Uri> kPanQrDefaultBases = {
  PanProviderId.aliyun: _aliyunPassport,
  PanProviderId.quark: _quarkUop,
  PanProviderId.baidu: _baiduPassport,
};

final Uri _aliyunPassport = Uri.parse('https://passport.aliyundrive.com');
final Uri _quarkUop = Uri.parse('https://uop.quark.cn');
final Uri _quarkPan = Uri.parse('https://pan.quark.cn');
final Uri _baiduPassport = Uri.parse('https://passport.baidu.com');

/// 扫码登录专用 UA：这些 passport 接口按「网页端」形态发放二维码，用
/// 电视盒 UA 会被风控拒掉（参考实现同样用桌面 Chrome UA）。
const String kPanQrUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

/// 二维码轮询状态。
enum PanQrState {
  /// 等待手机扫码。
  waiting,

  /// 已扫码，等待手机确认。
  scanned,

  /// 已确认，[PanQrPoll.account] 可用。
  confirmed,

  /// 二维码过期，需重新生成。
  expired,

  /// 接口/解析失败，[PanQrPoll.message] 为中文可操作文案。
  error,
}

/// 一次扫码会话。[qrContent] 交给二维码渲染；[qrIsImage] 为 true 时
/// [qrContent] 是二维码**图片地址**（百度返回的是图片，不是待编码文本）。
class PanQrSession {
  const PanQrSession({
    required this.provider,
    required this.qrContent,
    required this.pollToken,
    this.qrIsImage = false,
  });

  final PanProviderId provider;
  final String qrContent;
  final bool qrIsImage;

  /// 轮询凭据（各厂私有格式，调用方只透传）。
  final String pollToken;
}

/// 轮询结果。[account] 仅在 [PanQrState.confirmed] 时非空。
class PanQrPoll {
  const PanQrPoll(this.state, {this.account, this.message});

  final PanQrState state;
  final PanAccount? account;
  final String? message;

  bool get done =>
      state == PanQrState.confirmed ||
      state == PanQrState.expired ||
      state == PanQrState.error;
}

/// 扫码登录客户端（单次会话无状态，可复用实例）。
class PanQrLogin {
  PanQrLogin({Dio? dio, Map<PanProviderId, Uri>? bases, Uri? quarkPanBase})
    : _dio = dio ?? NetworkPolicy.attach(Dio(_baseOptions())),
      _bases = {...kPanQrDefaultBases, ...?bases},
      _quarkPanBase = quarkPanBase ?? _quarkPan;

  final Dio _dio;
  final Map<PanProviderId, Uri> _bases;

  /// 夸克 Cookie 交换域（`pan.quark.cn`，与 `uop.quark.cn` 不同域）。
  final Uri _quarkPanBase;

  /// 百度长轮询需要比普通请求更长的接收超时；短超时按 waiting 处理。
  static BaseOptions _baseOptions() => BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    followRedirects: false,
    validateStatus: (_) => true,
    responseType: ResponseType.plain,
  );

  /// 生成二维码。[qrIsImage] 为 true 时需用图片控件显示 [qrContent]。
  Future<PanQrSession> create(PanProviderId provider) => switch (provider) {
    PanProviderId.aliyun => _createAliyun(),
    PanProviderId.quark => _createQuark(),
    PanProviderId.baidu => _createBaidu(),
  };

  /// 轮询扫码状态。网络异常统一收敛为 [PanQrState.waiting]（长轮询超时
  /// 属正常），只有接口明确返回错误才给 [PanQrState.error]。
  Future<PanQrPoll> poll(PanQrSession session) => switch (session.provider) {
    PanProviderId.aliyun => _pollAliyun(session),
    PanProviderId.quark => _pollQuark(session),
    PanProviderId.baidu => _pollBaidu(session),
  };

  // ── 阿里云盘 ────────────────────────────────────────────
  // GET  generate.do → content.data.{t, ck, codeContent}
  // POST query.do    → content.data.qrCodeStatus(NEW/SCANED/CONFIRMED/EXPIRED)
  // CONFIRMED 时 content.data.bizExt 是 base64(JSON)，取 pds_login_result。

  Future<PanQrSession> _createAliyun() async {
    final uri = _bases[PanProviderId.aliyun]!
        .resolve('/newlogin/qrcode/generate.do')
        .replace(
          queryParameters: {
            'appName': 'aliyun_drive',
            'fromSite': '52',
            'appEntrance': 'web',
            '_bx-v': '2.5.6',
          },
        );
    final json = await _readJson(
      uri,
      provider: PanProviderId.aliyun,
      action: '生成阿里云盘二维码',
    );
    final content = json['content'];
    final data = content is Map ? content['data'] : null;
    final qrContent = data is Map ? panStringOf(data, ['codeContent']) : null;
    final t = data is Map ? panIntOf(data, ['t']) : null;
    if (qrContent == null || t == null) {
      throw const PanException('生成阿里云盘二维码失败，请稍后重试或改用手动粘贴令牌');
    }
    final ck = data is Map ? (panStringOf(data, ['ck']) ?? '') : '';
    return PanQrSession(
      provider: PanProviderId.aliyun,
      qrContent: qrContent,
      pollToken: jsonEncode({'t': t, 'ck': ck}),
    );
  }

  Future<PanQrPoll> _pollAliyun(PanQrSession session) async {
    final token = _decodeToken(session.pollToken);
    if (token == null) {
      return const PanQrPoll(
        PanQrState.error,
        message: '阿里云盘扫码会话无效，请重新生成二维码',
      );
    }
    final uri = _bases[PanProviderId.aliyun]!.resolve(
      '/newlogin/qrcode/query.do',
    );
    final Response<String> response;
    try {
      response = await _dio.postUri<String>(
        uri,
        data: {
          't': '${token['t']}',
          'ck': '${token['ck'] ?? ''}',
          'appName': 'aliyun_drive',
          'appEntrance': 'web',
          'fromSite': '52',
          '_bx-v': '2.5.6',
        },
        options: _options(form: true),
      );
    } on DioException {
      return const PanQrPoll(PanQrState.waiting);
    }
    final json = _jsonOrNull(response);
    final content = json?['content'];
    final data = content is Map ? content['data'] : null;
    if (data is! Map) {
      return const PanQrPoll(
        PanQrState.error,
        message: '阿里云盘扫码状态查询失败，请重新生成二维码',
      );
    }
    final status = panStringOf(data, ['qrCodeStatus'])?.toUpperCase();
    switch (status) {
      case 'CONFIRMED':
        final account = _aliyunAccount(data);
        if (account == null) {
          return const PanQrPoll(
            PanQrState.error,
            message: '阿里云盘登录成功但未返回令牌，请重试或改用手动粘贴 refresh_token',
          );
        }
        return PanQrPoll(PanQrState.confirmed, account: account);
      case 'SCANED':
        return const PanQrPoll(PanQrState.scanned);
      case 'EXPIRED':
        return const PanQrPoll(PanQrState.expired);
      default:
        return const PanQrPoll(PanQrState.waiting);
    }
  }

  PanAccount? _aliyunAccount(Map data) {
    final bizExt = panStringOf(data, ['bizExt']);
    if (bizExt == null) return null;
    final decoded = _decodeBase64Json(bizExt);
    if (decoded == null) return null;
    final login = decoded['pds_login_result'];
    if (login is! Map) return null;
    final refreshToken = panStringOf(login, ['refreshToken', 'refresh_token']);
    if (refreshToken == null) return null;
    final accessToken =
        panStringOf(login, ['accessToken', 'access_token']) ?? '';
    return PanAccount(
      provider: PanProviderId.aliyun,
      refreshToken: refreshToken,
      accessToken: accessToken,
      userName: panStringOf(login, ['nickName', 'userName']) ?? '',
      userId: panStringOf(login, ['userId']) ?? '',
    );
  }

  // ── 夸克网盘 ────────────────────────────────────────────
  // GET getTokenForQrcodeLogin → data.members.token
  // GET getServiceTicketByQrcodeToken → data.members.{status, service_ticket}
  // CONFIRMED 后用 service_ticket 调 pan.quark.cn/account/info 换 Set-Cookie。

  Future<PanQrSession> _createQuark() async {
    final uri = _bases[PanProviderId.quark]!
        .resolve('/cas/ajax/getTokenForQrcodeLogin')
        .replace(
          queryParameters: {
            'client_id': '532',
            'v': '1.2',
            'request_id': _uuidV4(),
          },
        );
    final json = await _readJson(
      uri,
      provider: PanProviderId.quark,
      action: '生成夸克网盘二维码',
    );
    final data = json['data'];
    final members = data is Map ? data['members'] : null;
    final token = members is Map ? panStringOf(members, ['token']) : null;
    if (token == null) {
      throw const PanException('生成夸克网盘二维码失败，请稍后重试或改用手动粘贴 Cookie');
    }
    return PanQrSession(
      provider: PanProviderId.quark,
      qrContent:
          'https://su.quark.cn/4_eMHBJ?token=$token&client_id=532&ssb=weblogin',
      pollToken: token,
    );
  }

  Future<PanQrPoll> _pollQuark(PanQrSession session) async {
    final uri = _bases[PanProviderId.quark]!
        .resolve('/cas/ajax/getServiceTicketByQrcodeToken')
        .replace(
          queryParameters: {'client_id': '532', 'token': session.pollToken},
        );
    final Response<String> response;
    try {
      response = await _dio.getUri<String>(uri, options: _options());
    } on DioException {
      return const PanQrPoll(PanQrState.waiting);
    }
    final json = _jsonOrNull(response);
    if (json == null) {
      return const PanQrPoll(
        PanQrState.error,
        message: '夸克网盘扫码状态查询失败，请重新生成二维码',
      );
    }
    final data = json['data'];
    final members = data is Map ? data['members'] : null;
    final status = members is Map
        ? panStringOf(members, ['status'])?.toUpperCase()
        : null;
    // 实测未扫码时顶层 status=50004001 且无 members，直接按等待处理；
    // 成功态兼容「members.status == CONFIRMED」与「members.service_ticket 非空」。
    final ticket = members is Map
        ? panStringOf(members, ['service_ticket'])
        : null;
    if (status == 'CONFIRMED' || ticket != null) {
      final resolved = ticket ?? panStringOf(json, ['service_ticket']);
      if (resolved == null) {
        return const PanQrPoll(
          PanQrState.error,
          message: '夸克网盘登录成功但未返回票据，请重新扫码',
        );
      }
      final cookie = await _quarkCookie(resolved);
      return PanQrPoll(
        PanQrState.confirmed,
        account: PanAccount(
          provider: PanProviderId.quark,
          refreshToken: '',
          cookie: cookie,
        ),
      );
    }
    if (status == 'SCANED') return const PanQrPoll(PanQrState.scanned);
    if (status == 'EXPIRED') return const PanQrPoll(PanQrState.expired);
    return const PanQrPoll(PanQrState.waiting);
  }

  /// service_ticket → Cookie：优先取 302 的 Set-Cookie，拿不到时退回 `__st`。
  Future<String> _quarkCookie(String serviceTicket) async {
    final uri = _quarkPanBase
        .resolve('/account/info')
        .replace(queryParameters: {'st': serviceTicket, 'lw': 'scan'});
    try {
      final response = await _dio.getUri<String>(uri, options: _options());
      final cookie = _cookieHeader(response);
      if (cookie.isNotEmpty) return cookie;
    } on DioException {
      // 落到 __st 兜底（服务端未下发 Set-Cookie 时夸克也认这个字段）。
    }
    return '__st=$serviceTicket';
  }

  // ── 百度网盘 ────────────────────────────────────────────
  // GET v2/api/getqrcode → imgurl(二维码图片)、sign(轮询 channel_id)
  // GET channel/unicast  → 长轮询；channel_v JSON 里 status=0 时 v 即 BDUSS
  // GET v3/login/main/qrbdusslogin → 302 + Set-Cookie(BDUSS/STOKEN)

  Future<PanQrSession> _createBaidu() async {
    final gid = _uuidV4().toUpperCase();
    final uri = _bases[PanProviderId.baidu]!
        .resolve('/v2/api/getqrcode')
        .replace(
          queryParameters: {'lp': 'pc', 'qrloginfrom': 'pc', 'gid': gid},
        );
    final json = await _readJson(
      uri,
      provider: PanProviderId.baidu,
      action: '生成百度网盘二维码',
    );
    final imgurl = panStringOf(json, ['imgurl']);
    final sign = panStringOf(json, ['sign']);
    if (imgurl == null || sign == null) {
      throw const PanException('生成百度网盘二维码失败，请稍后重试或改用开放平台令牌');
    }
    return PanQrSession(
      provider: PanProviderId.baidu,
      // 百度返回的是二维码图片地址（PNG），不是待编码文本。
      qrContent: imgurl.startsWith('http') ? imgurl : 'https://$imgurl',
      qrIsImage: true,
      pollToken: jsonEncode({'sign': sign, 'gid': gid}),
    );
  }

  Future<PanQrPoll> _pollBaidu(PanQrSession session) async {
    final token = _decodeToken(session.pollToken);
    final sign = token == null ? null : panStringOf(token, ['sign']);
    if (sign == null) {
      return const PanQrPoll(PanQrState.error, message: '百度网盘扫码会话无效，请重新生成二维码');
    }
    final gid = panStringOf(token!, ['gid']) ?? '';
    final uri = _bases[PanProviderId.baidu]!
        .resolve('/channel/unicast')
        .replace(
          queryParameters: {
            'channel_id': sign,
            'tpl': 'netdisk',
            'gid': gid,
            'apiver': 'v3',
          },
        );
    final Response<String> response;
    try {
      response = await _dio.getUri<String>(uri, options: _options());
    } on DioException {
      // 长轮询超时 = 手机尚未扫码/确认，继续等。
      return const PanQrPoll(PanQrState.waiting);
    }
    final json = _jsonOrNull(response);
    if (json == null) return const PanQrPoll(PanQrState.waiting);
    final errno = panIntOf(json, ['errno']);
    if (errno == -1) return const PanQrPoll(PanQrState.expired);
    if (errno != 0) return const PanQrPoll(PanQrState.waiting);
    final channel = panStringOf(json, ['channel_v']);
    if (channel == null) return const PanQrPoll(PanQrState.waiting);
    final channelJson = _jsonOrNullText(channel);
    if (channelJson == null) return const PanQrPoll(PanQrState.waiting);
    final status = panIntOf(channelJson, ['status']);
    if (status == 1) return const PanQrPoll(PanQrState.scanned);
    if (status != 0) return const PanQrPoll(PanQrState.waiting);
    final bduss = panStringOf(channelJson, ['v']);
    if (bduss == null) {
      return const PanQrPoll(PanQrState.error, message: '百度网盘登录成功但未返回凭据，请重新扫码');
    }
    final cookie = await _baiduCookie(bduss);
    return PanQrPoll(
      PanQrState.confirmed,
      account: PanAccount(
        provider: PanProviderId.baidu,
        refreshToken: '',
        cookie: cookie,
      ),
    );
  }

  Future<String> _baiduCookie(String bduss) async {
    final uri = _bases[PanProviderId.baidu]!
        .resolve('/v3/login/main/qrbdusslogin')
        .replace(queryParameters: {'bduss': bduss, 'loginVersion': 'v5'});
    try {
      final response = await _dio.getUri<String>(uri, options: _options());
      final cookie = _cookieHeader(response, only: const ['BDUSS', 'STOKEN']);
      if (cookie.isNotEmpty) return cookie;
    } on DioException {
      // 落到 BDUSS 兜底。
    }
    return 'BDUSS=$bduss';
  }

  // ── 公共工具 ────────────────────────────────────────────

  Options _options({bool form = false}) => Options(
    headers: {
      'User-Agent': kPanQrUserAgent,
      'Accept': 'application/json, text/plain, */*',
      if (form) 'Content-Type': 'application/x-www-form-urlencoded',
    },
    responseType: ResponseType.plain,
    followRedirects: false,
    validateStatus: (_) => true,
  );

  Future<Map<String, dynamic>> _readJson(
    Uri uri, {
    required PanProviderId provider,
    required String action,
  }) async {
    final Response<String> response;
    try {
      response = await _dio.getUri<String>(uri, options: _options());
    } on DioException catch (error) {
      throw PanException('$action失败：网络错误（${error.type.name}），请检查网络后重试');
    }
    final json = _jsonOrNull(response);
    if (json == null) {
      throw PanException('$action失败：${provider.label}接口返回不是有效 JSON，请稍后重试');
    }
    return json;
  }

  Map<String, dynamic>? _jsonOrNull(Response<String> response) =>
      _jsonOrNullText(response.data ?? '');

  Map<String, dynamic>? _jsonOrNullText(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _decodeToken(String raw) => _jsonOrNullText(raw);

  /// `Set-Cookie` → `name=value; name2=value2`。[only] 非空时只保留指定
  /// 名字（百度只需 BDUSS/STOKEN，避免把无关 Cookie 带进播放请求）。
  String _cookieHeader(Response response, {List<String> only = const []}) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return '';
    final parts = <String>[];
    for (final line in raw) {
      final pair = line.split(';').first.trim();
      if (pair.isEmpty) continue;
      if (only.isNotEmpty) {
        final name = pair.split('=').first.trim();
        if (!only.contains(name)) continue;
      }
      parts.add(pair);
    }
    return parts.join('; ');
  }

  /// base64（含 URL-safe / 缺 padding）→ JSON Map。
  Map<String, dynamic>? _decodeBase64Json(String raw) {
    var text = raw.trim().replaceAll('-', '+').replaceAll('_', '/');
    final remainder = text.length % 4;
    if (remainder > 0) text = text.padRight(text.length + (4 - remainder), '=');
    try {
      final bytes = base64.decode(text);
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// v4 UUID（不引入 uuid 依赖，仅用于夸克 request_id 与百度 gid）。
  String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
