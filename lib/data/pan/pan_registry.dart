/// 三家网盘实现注册表：设置页遍历 / 目录浏览入口按厂商取实现。
///
/// 新增厂商时：实现 [PanProvider] → 在此注册 → 设置页自动遍历到（无需改其它处）。
library;

import 'aliyun_pan.dart';
import 'baidu_pan.dart';
import 'pan_account.dart';
import 'pan_provider.dart';
import 'quark_pan.dart';

/// 已注册的网盘实现（顺序即设置页展示顺序）。
final Map<PanProviderId, PanProvider> kPanProviders = {
  PanProviderId.aliyun: AliyunPan(),
  PanProviderId.baidu: BaiduPan(),
  PanProviderId.quark: QuarkPan(),
};

/// 按厂商取实现；未注册抛 ArgumentError。
PanProvider panProviderFor(PanProviderId id) {
  final provider = kPanProviders[id];
  if (provider == null) {
    throw ArgumentError('未注册的网盘厂商：${id.name}');
  }
  return provider;
}
