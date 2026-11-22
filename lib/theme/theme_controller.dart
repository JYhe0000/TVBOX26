import 'package:flutter/foundation.dart';

import '../data/storage.dart';
import 'skin.dart';
import 'skins/netflix_skin.dart';
import 'skins/smartisan_dark_skin.dart';
import 'skins/smartisan_skin.dart';

/// 皮肤注册表。新增皮肤只改这里 + 加一个 `skins/xxx_skin.dart`。
///
/// 皮肤状态本身挂在 `AppController.skinId`（启动前 `MaterialApp.theme` 就要
/// 读它，所以和 `ui_tab_index` 一样走 `StorageService`）。这个文件只提供
/// 注册表与 `ChangeNotifier` 形态的 [ThemeController]，给需要独立于
/// `AppController` 观察皮肤的场合用（例如设置页的即时预览）。
final Map<TvSkinId, TvSkin> kSkins = <TvSkinId, TvSkin>{
  TvSkinId.smartisan: TvSmartisanSkin(),
  TvSkinId.smartisanDark: TvSmartisanDarkSkin(),
  TvSkinId.netflix: TvNetflixSkin(),
};

TvSkin skinFor(
  TvSkinId id, {
  TvAccentColor accentColor = TvAccentColor.skinDefault,
}) => (kSkins[id] ?? kSkins[TvSkinId.netflix]!).withAccentColor(accentColor);

/// 皮肤预览状态：当前皮肤 + 持久化。跟随 shell 的 `ui_tab_index` 同款写法。
///
/// 生产的单一真相是 `AppController.skinId`（`MaterialApp.theme` 在构建期就要
/// 读它，所以必须在 `initialize()` 里同步回读）。这个类是给「不经过
/// `AppController` 的场合」用的轻量封装，key 与 `AppController.skinStorageKey`
/// 保持一致。
class ThemeController extends ChangeNotifier {
  ThemeController({StorageService? storage, TvSkinId initial = TvSkinId.netflix})
    : _storage = storage ?? StorageService(),
      _id = initial;

  final StorageService _storage;
  TvSkinId _id;

  TvSkinId get id => _id;
  TvSkin get skin => skinFor(_id);

  /// 启动时回读。存储不可用（widget 测试、首次启动）时保持默认皮肤。
  void restore() {
    final saved = TvSkinId.fromName(
      _storage.getString(AppControllerSkinKeys.storageKey, _id.name),
    );
    if (saved != _id) {
      _id = saved;
      notifyListeners();
    }
  }

  Future<void> select(TvSkinId id) async {
    if (id == _id) return;
    _id = id;
    notifyListeners();
    await _storage.setString(AppControllerSkinKeys.storageKey, id.name);
  }
}

/// 皮肤持久化 key。单独放这里避免 `theme` 层反向依赖 `core` 层。
class AppControllerSkinKeys {
  const AppControllerSkinKeys._();

  static const String storageKey = 'ui_skin_id';
}
