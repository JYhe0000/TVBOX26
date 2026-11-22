// 自定义背景图回归测试。
//
// 覆盖两个行为：
//   1. 上传背景图后切换主题（皮肤）不丢失 —— 皮肤是「冷切换」：`setSkin` 只
//      持久化 skinId 并触发 onRestartRequested 重新 runApp（见 main.dart 的
//      _runApp），controller 实例不重建；壁纸覆盖 `wallpaperOverride` 挂在
//      同一个 controller 上，靠 `ui_wallpaper_file`（wallpaperStorageKey）持久化。
//   2. 壁纸对 ios26 / netflix 生效（smartisan 不铺）—— 由 `TvSkin.wallpaperOpacity`
//      决定：ios26 / netflix = 0.32，smartisan = 0；`AppBackground` → `_SkinBackdrop`
//      里 `imageUrl.isNotEmpty && skin.wallpaperOpacity > 0` 才画壁纸层。
//
// 用法：flutter test test/wallpaper_skin_test.dart
//   期望：全绿。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';

/// 最小 harness：只挂 [AppBackground]，验证壁纸层是否出现。
///
/// [AppBackground] 读 `TvSkin.of(context)`（来自 `AppTheme.forSkin` 的主题扩展）
/// 与 `context.watch<AppController>().blurBackground`（来自 Provider）。这里用
/// 本地路径，所以 ios26 下壁纸层是 `Image.file`（`Image` 类型）。
Widget wallpaperHarness(TvSkinId skin, String wallpaper) {
  return ChangeNotifierProvider<AppController>.value(
    value: AppController(),
    child: MaterialApp(
      theme: AppTheme.forSkin(skin),
      home: AppBackground(
        wallpaper: wallpaper,
        child: const SizedBox.expand(),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ---------------------------------------------------------------------------
  // 组 A：壁纸覆盖持久化 + 冷切换不丢失
  // ---------------------------------------------------------------------------
  group('壁纸覆盖持久化与冷切换', () {
    test('setWallpaperOverride 写字段并持久化到 ui_wallpaper_file', () async {
      final controller = AppController();
      await controller.storage.init();

      await controller.setWallpaperOverride('/tmp/wallpaper.jpg');

      expect(controller.wallpaperOverride, '/tmp/wallpaper.jpg');
      expect(
        controller.storage.getString(AppController.wallpaperStorageKey),
        '/tmp/wallpaper.jpg',
      );
    });

    test('冷切换皮肤不清除壁纸覆盖（字段与持久化都保留）', () async {
      final controller = AppController();
      await controller.storage.init();
      await controller.setWallpaperOverride('/tmp/wallpaper.jpg');
      var restarts = 0;
      controller.onRestartRequested = () => restarts++;

      await controller.setSkin(TvSkinId.netflix);

      expect(restarts, 1, reason: 'setSkin 必须触发一次冷重启回调');
      expect(controller.skinId, TvSkinId.netflix);
      // 冷切换只改 skinId，不碰壁纸字段与持久化。
      expect(controller.wallpaperOverride, '/tmp/wallpaper.jpg');
      expect(
        controller.storage.getString(AppController.wallpaperStorageKey),
        '/tmp/wallpaper.jpg',
      );
    });

    testWidgets(
      '冷启动：新 controller 经 initialize → _loadSettings 回读壁纸与皮肤',
      (tester) async {
        final first = AppController();
        await first.storage.init();
        await first.setWallpaperOverride('/tmp/wallpaper.jpg');
        await first.setSkin(TvSkinId.netflix);

        // 冷重启：新 controller（新 StorageService 实例，共享同一份
        // SharedPreferences）走 initialize() → storage.init() → _loadSettings()
        // 回读两个 key。用 runAsync 让 rootBundle 读内置配置走真实异步
        // （否则 FakeAsync 下 rootBundle.loadString 不返回）。
        final second = AppController();
        await tester.runAsync(() => second.initialize());

        expect(second.wallpaperOverride, '/tmp/wallpaper.jpg');
        expect(second.skinId, TvSkinId.netflix);
      },
    );

    test('清除覆盖（传空串）持久化空串、字段复位', () async {
      final controller = AppController();
      await controller.storage.init();
      await controller.setWallpaperOverride('/tmp/wallpaper.jpg');
      await controller.setWallpaperOverride('');

      expect(controller.wallpaperOverride, '');
      expect(
        controller.storage.getString(AppController.wallpaperStorageKey),
        '',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 组 B：壁纸对 netflix 生效（smartisan 不铺）
  // ---------------------------------------------------------------------------
  group('壁纸对 netflix 生效（smartisan 不铺）', () {
    test('wallpaperOpacity：netflix > 0，smartisan = 0', () {
      expect(TvNetflixSkin().wallpaperOpacity, greaterThan(0));
      expect(TvSmartisanSkin().wallpaperOpacity, 0);
    });

    testWidgets('netflix 铺壁纸（有 Image），smartisan 不铺（无 Image）', (tester) async {
      const wallpaper = '/tmp/tvbox26_wallpaper_test.jpg';

      await tester.pumpWidget(wallpaperHarness(TvSkinId.netflix, wallpaper));
      expect(
        find.byType(Image),
        findsWidgets,
        reason: 'netflix wallpaperOpacity=0.32，应画出壁纸 Image',
      );
      await tester.pumpWidget(const SizedBox());

      await tester.pumpWidget(wallpaperHarness(TvSkinId.smartisan, wallpaper));
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'smartisan wallpaperOpacity=0，跳过壁纸层',
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}
