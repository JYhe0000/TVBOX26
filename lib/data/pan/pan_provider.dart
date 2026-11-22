/// 网盘统一抽象与三家共用的 HTTP 底座 / 错误映射 / 同源防护。
///
/// 设计约定（三家一致）：
/// - 所有请求经 [NetworkPolicy.attach]（代理 / DoH 与站内其它网络请求一致）；
/// - 任何 API 路径先过 [panSameOriginUrl] 同源校验（沿用 WebDAV 的 origin
///   检查思路，[WebDavService.list] 会拒绝跨源 href）；
/// - 任何平台返回的直链过 [panPlayUrl] 校验（只允许 http/https + host 非空）；
/// - 错误统一映射为 [PanException]，token 类错误 `isAuthExpired=true`，
///   UI 据此提示「授权已过期，请重新绑定」。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../network_policy.dart';
import 'pan_account.dart';
import 'pan_models.dart';

/// 单家目录列举最多拉多少页（防 mock/异常端点死循环；真实目录翻不到这个量级）。
const int kPanMaxPages = 50;

/// 目录列举的每页大小（三家接口上限各异，取保守公共值）。
const int kPanPageSize = 100;

/// 三家共用的默认 UA（电视盒 Chromium 风格；百度 dlink 强制要求
/// `pan.baidu.com`，该厂单独覆盖）。
const String kPanDefaultUA =
    'Mozilla/5.0 (Linux; Android 11; TVBOX26) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

/// 网盘层统一异常：[message] 为中文可操作文案，[isAuthExpired] 为 true 时
/// UI 应提示「授权已过期，请重新绑定」并清掉本地账号。
class PanException implements Exception {
  const PanException(this.message, {this.isAuthExpired = false});

  final String message;
  final bool isAuthExpired;

  @override
  String toString() => 'PanException: $message';
}

/// 网盘能力抽象；差异（端点/字段/分页游标）由三个子类实现。
abstract class PanProvider {
  /// 厂商标识。
  PanProviderId get providerId;

  /// 中文展示名（设置页 / 错误文案用）。
  String get displayName;

  /// API 基址（生产为官方常量域名；测试可注入 mock 基址）。
  Uri get base;

  /// 一句话说明该厂接入方式与已知限制（设置页 subtitle 用）。
  String get description;

  /// 根目录标识（阿里 `root` / 百度 `/` / 夸克 `0`）。
  String get rootParentId;

  /// 用 refresh_token 换 access_token；返回更新后的账号副本（原对象不变）。
  /// 失败抛 [PanException]（已映射为中文可操作文案）。
  Future<PanAccount> refresh(PanAccount account);

  /// 列举 [parentId] 目录下全部条目（自动翻页拼接）；为空表示根目录。
  Future<List<PanEntry>> list(PanAccount account, {String? parentId});

  /// 取文件直链/播放地址（含播放所需 header，如 Referer / User-Agent / Cookie）。
  Future<PanFileUrl> fileUrl(PanAccount account, PanEntry entry);
}

/// 三家共用的 HTTP 底座：统一超时、同源校验、JSON 解码与错误映射。
///
/// 默认 dio 走 [NetworkPolicy.attach]（代理 / DoH 生效）；测试可注入 dio
/// 或 [base] 指向本地 mock server。
class PanHttp {
  PanHttp({required this.label, required this.base, Dio? dio})
    : _dio = dio ?? NetworkPolicy.attach(Dio(defaultOptions));

  final String label;
  final Uri base;
  final Dio _dio;

  /// 与 [WebDavService] 同款超时（连接 12s / 接收 20s）。
  static final BaseOptions defaultOptions = BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
  );

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
  }) async {
    try {
      final response = await _dio.get(
        panSameOriginUrl(base, path).toString(),
        queryParameters: query,
        options: Options(headers: headers, responseType: ResponseType.plain),
      );
      return panJsonBody(response, provider: label, action: 'GET $path');
    } on DioException catch (e) {
      throw panErrorFromDio(e, provider: label, action: 'GET $path');
    }
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
  }) async {
    try {
      final response = await _dio.post(
        panSameOriginUrl(base, path).toString(),
        data: body,
        queryParameters: query,
        options: Options(headers: headers, responseType: ResponseType.plain),
      );
      return panJsonBody(response, provider: label, action: 'POST $path');
    } on DioException catch (e) {
      throw panErrorFromDio(e, provider: label, action: 'POST $path');
    }
  }
}

/// 把相对路径 [path] 拼到 [base] 并做同源校验（沿用 WebDAV 的 origin 检查思路：
/// [WebDavService.list] 会拒绝跨源 href，文案也保持一致）。
///
/// 生产代码里所有路径都是常量，正常不会触发；此校验是防御层——未来若允许
/// 账号携带自建网关 endpoint（OpenList 模式），响应里夹带的跳转/分页链接
/// 把请求带离授权域时直接拒绝。越界抛 [PanException]「网盘地址超出当前服务器」。
Uri panSameOriginUrl(Uri base, String path) {
  final resolved = base.resolve(path);
  if (resolved.origin != base.origin) {
    throw PanException('网盘地址超出当前服务器（${resolved.origin}）');
  }
  return resolved;
}

/// 校验平台返回的播放/下载直链：只允许 http/https、host 非空；拒绝
/// file:// / javascript: 等危险 scheme 与空 host（防止异常响应把播放器
/// 指到本地或恶意地址）。跨域 CDN 属正常，不做同源限制。
Uri panPlayUrl(String url, {required String provider, required String action}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    throw PanException('$action 失败：$provider 返回的直链不是有效 URL');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw PanException('$action 失败：$provider 返回的直链协议不受支持（${uri.scheme}）');
  }
  if (uri.host.isEmpty) {
    throw PanException('$action 失败：$provider 返回的直链缺少域名');
  }
  return uri;
}

/// 把 dio 响应体解码为 JSON Map；非 JSON/空体映射为可操作异常。
Map<String, dynamic> panJsonBody(
  Response response, {
  required String provider,
  required String action,
}) {
  final data = response.data;
  if (data is Map) return Map<String, dynamic>.from(data);
  final text = data?.toString() ?? '';
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  throw PanException('$action 失败：$provider 接口返回不是有效 JSON，请稍后重试');
}

/// 平台错误体 → [PanException]（中文可操作文案）。
///
/// 三家错误载体不一致：阿里 `{code, message}`、百度 OAuth
/// `{error, error_description}` 与 xpan `{errno, error_msg}`、夸克
/// `{status, code, message}`。统一收敛规则：
/// - token 类错误（invalid_grant / invalid_token / AccessTokenInvalid /
///   RefreshTokenExpired / 百度 errno -6·20016·20017·31045 / 夸克 require login）
///   → isAuthExpired=true，文案「授权已过期，请重新绑定」；
/// - 百度 -6 额外提示 scope 需为 basic,netdisk；
/// - 夸克 23018（获取频率过快）→ 「获取直链过于频繁，请稍后再试」；
/// - 其余 → 保留平台原始 code/message，拼上 action 前缀便于定位。
PanException panErrorFromJson(
  Map<String, dynamic>? json, {
  required String provider,
  required String action,
}) {
  if (json == null) {
    return PanException('$action 失败：$provider 接口返回异常，请稍后重试');
  }
  final code = panStringOf(json, ['code', 'error', 'error_code', 'errno']);
  final codeNum = panIntOf(json, ['code', 'error_code', 'errno', 'status']);
  final msg = panStringOf(json, [
    'message',
    'error_msg',
    'error_description',
    'msg',
  ]);
  if (_isTokenError(code, codeNum) || _isTokenMessage(msg)) {
    if (codeNum == -6 || code == '-6') {
      return const PanException(
        '授权已过期，请重新绑定（百度网盘需 basic,netdisk 授权范围）',
        isAuthExpired: true,
      );
    }
    return const PanException('授权已过期，请重新绑定', isAuthExpired: true);
  }
  if (codeNum == 23018 || code == '23018') {
    return const PanException('获取直链过于频繁，请稍后再试');
  }
  final detail = <String>[
    if (code != null && code.isNotEmpty) code,
    if (msg != null && msg.isNotEmpty) msg,
  ].join(' ');
  return PanException(
    detail.isEmpty
        ? '$action 失败：$provider 接口返回异常，请稍后重试'
        : '$action 失败：$provider $detail',
  );
}

/// dio 异常 → [PanException]；HTTP 4xx 优先解析响应体里的平台错误码。
PanException panErrorFromDio(
  DioException e, {
  required String provider,
  required String action,
}) {
  final response = e.response;
  final status = response?.statusCode;
  if (response != null) {
    final body = _maybeJson(response.data);
    if (body != null) {
      final code = panStringOf(body, ['code', 'error', 'error_code', 'errno']);
      final msg = panStringOf(body, [
        'message',
        'error_msg',
        'error_description',
        'msg',
      ]);
      if (code != null || msg != null) {
        return panErrorFromJson(body, provider: provider, action: action);
      }
    }
  }
  if (status == 401) {
    return const PanException('授权已过期，请重新绑定', isAuthExpired: true);
  }
  if (status == 403) {
    return PanException('账号无权限访问该资源，请检查授权范围后重试');
  }
  if (status == 429) {
    return const PanException('接口限流，请稍后再试');
  }
  if (status != null) {
    return PanException('$action 失败：$provider 返回 HTTP $status');
  }
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.connectionError:
      return PanException('$action 失败：网络连接失败，请检查网络后重试');
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return PanException('$action 失败：接口响应超时，请稍后重试');
    case DioExceptionType.cancel:
      return PanException('$action 已取消');
    default:
      return PanException('$action 失败：${e.message ?? '网络请求异常'}');
  }
}

/// 从平台响应里取第一个存在的字符串字段（三家字段名不一致时用）。
String? panStringOf(Map json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is num) return value.toString();
  }
  return null;
}

/// 从平台响应里取第一个存在的整数字段（容忍字符串/浮点）。
int? panIntOf(Map json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// 把平台时间戳/ISO 字符串收敛为 UTC [DateTime]（秒/毫秒/ISO 三态兼容）。
DateTime? panDateTimeOf(dynamic value) {
  if (value is num) {
    final ms = value > 1000000000000 ? value.toInt() : value.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  if (value is String) return DateTime.tryParse(value.trim());
  return null;
}

/// 把平台过期时间（时间戳秒/毫秒或 ISO 字符串、expires_in 秒数）收敛为
/// UTC 秒时间戳；无法识别返回 null。
int? panUnixSecOf(dynamic value) {
  if (value is num) {
    return value > 1000000000000 ? value.toInt() ~/ 1000 : value.toInt();
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value.trim());
    if (parsed != null) return parsed.millisecondsSinceEpoch ~/ 1000;
    return int.tryParse(value.trim());
  }
  return null;
}

/// 缺少 refresh_token 时的前置校验（绑定缺失，不是授权失效）。
void panRequireRefreshToken(PanAccount account, String provider) {
  if (!account.hasRefreshToken) {
    throw PanException('未绑定$provider账号，请先在设置页粘贴凭据后重试');
  }
}

/// 缺少 access_token 时的前置校验（按授权失效处理，引导重新绑定）。
void panRequireAccessToken(PanAccount account, String provider) {
  if (!account.hasAccessToken) {
    throw PanException('$provider授权已过期，请重新绑定', isAuthExpired: true);
  }
}

/// 目录项必须是文件（目录/缺 id 都无法取直链）。
void panRequireFileEntry(String provider, PanEntry entry) {
  if (entry.folder) {
    throw PanException('$provider：该条目是目录，没有播放直链');
  }
  if (entry.id.isEmpty) {
    throw PanException('$provider：该文件缺少 id，无法获取直链');
  }
}

/// 把平台条目 Map 收敛为 [PanEntry]；三家字段名差异通过 [idKeys]/[nameKeys]
/// 声明，folder 兼容 `type=="folder"` / `dir==true` / `isdir==1` 三种写法。
PanEntry panEntryOf(
  Map item, {
  List<String> idKeys = const ['file_id', 'fs_id', 'fid'],
  List<String> nameKeys = const ['name', 'file_name', 'server_filename'],
  String? path,
}) {
  final name = panStringOf(item, nameKeys) ?? '未命名';
  final size = panIntOf(item, ['size']) ?? 0;
  return PanEntry(
    id: panStringOf(item, idKeys) ?? '',
    name: name,
    folder:
        item['type'] == 'folder' ||
        item['dir'] == true ||
        panIntOf(item, ['isdir']) == 1,
    size: size,
    modifiedAt: panDateTimeOf(
      item['updated_at'] ?? item['mtime'] ?? item['updated_at_ms'],
    ),
    path: path,
    extension: panExtensionOf(name),
  );
}

bool _isTokenError(String? code, int? codeNum) {
  if (codeNum != null) {
    // 百度开放平台鉴权错误码（官方 FAQ）：-6 身份验证失败、20016 access_token
    // 已过期、20017 access_token 无效、31045 access_token 验证未通过。
    return const [-6, 20016, 20017, 31045].contains(codeNum);
  }
  final c = (code ?? '').toLowerCase();
  if (c.isEmpty) return false;
  final invalid = c.contains('invalid');
  final token = c.contains('token');
  final grant = c.contains('grant');
  final expired = c.contains('expired');
  return (invalid && (token || grant)) || (token && expired);
}

bool _isTokenMessage(String? msg) {
  final m = (msg ?? '').toLowerCase();
  return m.contains('require login') ||
      m.contains('invalid token') ||
      m.contains('token expired') ||
      m.contains('invalid access token') ||
      m.contains('未登录');
}

Map<String, dynamic>? _maybeJson(dynamic data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  final text = data?.toString() ?? '';
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return null;
}
