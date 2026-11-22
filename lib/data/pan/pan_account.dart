/// 网盘账号模型与持久化（三家厂商共用一份结构，差异字段进 [PanAccount.extra]）。
///
/// 安全边界（务必先读）：
/// - 本数据层**不内建任何 client_secret**；`clientId` / `clientSecret` /
///   `refreshToken` / `cookie` 一律由用户在 UI 粘贴后写入 [PanAccount]，
///   本层只负责携带与持久化。
/// - 账号数据**只存本机** shared_preferences（见 [PanAccountStore]），
///   与 `live_preferences` / `ui_skin_id` 同族 key，不上传任何服务器。
/// - 三家网盘接口均为非官方/半官方能力，各厂差异与风险见对应
///   `aliyun_pan.dart` / `baidu_pan.dart` / `quark_pan.dart` 文件头注。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage.dart';

/// 网盘厂商标识（枚举顺序即设置页展示顺序）。
enum PanProviderId { aliyun, baidu, quark }

extension PanProviderIdX on PanProviderId {
  /// 中文展示名（设置页 / 错误文案用）。
  String get label => switch (this) {
    PanProviderId.aliyun => '阿里云盘',
    PanProviderId.baidu => '百度网盘',
    PanProviderId.quark => '夸克网盘',
  };
}

/// [PanProviderId.name] 的反查；非法值返回 null（由调用方决定回落策略）。
PanProviderId? panProviderIdFromName(String? raw) {
  for (final id in PanProviderId.values) {
    if (id.name == raw) return id;
  }
  return null;
}

/// 网盘账号凭据。
///
/// 字段语义：
/// - [refreshToken]：长期凭据；阿里/百度走 OAuth 刷新，夸克 TV/OAuth 模式用。
/// - [accessToken] + [expiryUnixSec]：短期访问令牌与过期时间戳（UTC 秒）；
///   `expiryUnixSec == null` 表示平台不返回过期时间（夸克 Cookie 模式）。
/// - [clientId] / [clientSecret]：用户粘贴的开放平台应用密钥（百度必填、
///   阿里自建应用可选）；**本层不内建任何默认值**。
/// - [driveId]：阿里 `default_drive_id`（首次刷新后回填）。
/// - [cookie]：夸克登录态 Cookie（Cookie 模式；其余厂商留空）。
class PanAccount {
  const PanAccount({
    required this.provider,
    required this.refreshToken,
    this.accessToken = '',
    this.expiryUnixSec,
    this.userId = '',
    this.userName = '',
    this.clientId = '',
    this.clientSecret = '',
    this.driveId = '',
    this.cookie = '',
    this.extra = const {},
  });

  final PanProviderId provider;
  final String refreshToken;
  final String accessToken;

  /// access_token 过期时间戳（UTC 秒）；null = 平台不返回/长期有效。
  final int? expiryUnixSec;
  final String userId;
  final String userName;
  final String clientId;
  final String clientSecret;
  final String driveId;
  final String cookie;

  /// 平台差异字段的兜底位（如夸克 TV 模式的设备号），不参与核心流程。
  final Map<String, dynamic> extra;

  bool get hasRefreshToken => refreshToken.trim().isNotEmpty;
  bool get hasAccessToken => accessToken.trim().isNotEmpty;
  bool get hasCookie => cookie.trim().isNotEmpty;

  /// access_token 是否已过期（或距过期不足 [leadSeconds] 秒）。
  bool isTokenExpired({int leadSeconds = 120}) {
    final expiry = expiryUnixSec;
    if (expiry == null) return false;
    return expiry <
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + leadSeconds;
  }

  PanAccount copyWith({
    String? refreshToken,
    String? accessToken,
    int? expiryUnixSec,
    String? userId,
    String? userName,
    String? clientId,
    String? clientSecret,
    String? driveId,
    String? cookie,
    Map<String, dynamic>? extra,
  }) => PanAccount(
    provider: provider,
    refreshToken: refreshToken ?? this.refreshToken,
    accessToken: accessToken ?? this.accessToken,
    expiryUnixSec: expiryUnixSec ?? this.expiryUnixSec,
    userId: userId ?? this.userId,
    userName: userName ?? this.userName,
    clientId: clientId ?? this.clientId,
    clientSecret: clientSecret ?? this.clientSecret,
    driveId: driveId ?? this.driveId,
    cookie: cookie ?? this.cookie,
    extra: extra ?? this.extra,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider.name,
    'refreshToken': refreshToken,
    'accessToken': accessToken,
    if (expiryUnixSec != null) 'expiryUnixSec': expiryUnixSec,
    'userId': userId,
    'userName': userName,
    'clientId': clientId,
    'clientSecret': clientSecret,
    'driveId': driveId,
    'cookie': cookie,
    'extra': extra,
  };

  /// 宽容解析：字段缺失/类型错位不抛（脏数据降级为空串），
  /// 仅 [provider] 非法时抛 ArgumentError（由 store 捕获降级）。
  factory PanAccount.fromJson(Map json) {
    final provider = panProviderIdFromName(_string(json, 'provider'));
    if (provider == null) {
      throw ArgumentError('未知网盘厂商：${json['provider']}');
    }
    final extra = json['extra'];
    return PanAccount(
      provider: provider,
      refreshToken: _string(json, 'refreshToken') ?? '',
      accessToken: _string(json, 'accessToken') ?? '',
      expiryUnixSec: _int(json['expiryUnixSec']),
      userId: _string(json, 'userId') ?? '',
      userName: _string(json, 'userName') ?? '',
      clientId: _string(json, 'clientId') ?? '',
      clientSecret: _string(json, 'clientSecret') ?? '',
      driveId: _string(json, 'driveId') ?? '',
      cookie: _string(json, 'cookie') ?? '',
      extra: extra is Map ? Map<String, dynamic>.from(extra) : const {},
    );
  }

  static String? _string(Map json, String key) {
    final value = json[key];
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static int? _int(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// 通用刷新时机判断：access_token 缺失或距过期不足 [leadSeconds] 秒时返回 true。
///
/// UI 集成范式（与 AppController 的 setSkin 同款「调用方编排」风格）：
/// ```dart
/// if (panTokenNeedsRefresh(account)) {
///   account = await provider.refresh(account);
///   await store.save(account);
/// }
/// ```
bool panTokenNeedsRefresh(PanAccount account, {int leadSeconds = 120}) =>
    !account.hasAccessToken || account.isTokenExpired(leadSeconds: leadSeconds);

/// 网盘账号持久化：每个厂商一条 JSON 串，key 为 `pan_account_<provider>`。
///
/// 范式与 [StorageService] / `live_preferences` 一致：`toJson` → jsonEncode →
/// setString；读回走 [PanAccount.fromJson] 宽容解析，损坏 JSON 降级为空。
/// **账号数据只存本机 shared_preferences**；refresh_token / client_secret /
/// cookie 均以明文落盘（与 WebDAV 地址同级），后续如需加密在 store 层加解密
/// 即可，UI 层不用改。
class PanAccountStore {
  PanAccountStore(this.storage);

  final StorageService storage;

  static const String keyPrefix = 'pan_account_';

  static String accountKey(PanProviderId provider) =>
      'pan_account_${provider.name}';

  PanAccount? load(PanProviderId provider) {
    final raw = storage.getString(accountKey(provider));
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return PanAccount.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (error) {
      debugPrint('[pan] ${provider.name} 账号 JSON 损坏，已降级为空：$error');
    }
    return null;
  }

  Future<void> save(PanAccount account) => storage.setString(
    accountKey(account.provider),
    jsonEncode(account.toJson()),
  );

  Future<void> remove(PanProviderId provider) =>
      storage.remove(accountKey(provider));

  /// 全部已绑定账号（按 [PanProviderId.values] 顺序）。
  List<PanAccount> loadAll() {
    final result = <PanAccount>[];
    for (final provider in PanProviderId.values) {
      final account = load(provider);
      if (account != null) result.add(account);
    }
    return result;
  }
}
