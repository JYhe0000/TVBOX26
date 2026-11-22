import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox_flutter/core/app_controller.dart';
import 'package:tvbox_flutter/core/library_store.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/data/site_api.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/home_page.dart';
import 'package:tvbox_flutter/ui/shell_page.dart';
import 'package:tvbox_flutter/ui/tv_canvas.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/home_hero_carousel.dart';

const _cover = 'https://images.test/cover.jpg';
const _nextCover = 'https://images.test/next-cover.jpg';
const _wallpaper = '/tmp/tvbox26-home-wallpaper.png';

class _HeroSiteApi extends SiteApi {
  @override
  Future<HomeData> home(SiteConfig site) async => const HomeData(
    categories: [],
    videos: [
      VodItem(id: '1', name: '测试轮播', pic: _cover),
      VodItem(id: '2', name: '下一张轮播', pic: _nextCover),
    ],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final id in TvSkinId.values) {
    testWidgets('${id.name} 轮播只在右侧绘制海报并保留壁纸', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = AppController(siteApi: _HeroSiteApi())
        ..config = const AppConfig(
          sites: [
            SiteConfig(key: 'test', name: '测试站点', api: 'https://api.test/'),
          ],
          parses: [],
          lives: [],
        )
        ..selectedSiteKey = 'test'
        ..initialized = true;
      addTearDown(controller.dispose);
      await controller.storage.init();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<LibraryStore>(create: (_) => LibraryStore()),
          ],
          child: MaterialApp(
            theme: AppTheme.forSkin(id),
            builder: (context, child) => TvCanvas(child: child!),
            home: const ShellPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final hero = find.byType(HomeHeroCarousel);
      final heroImage = find.descendant(
        of: hero,
        matching: find.byType(NetworkPoster),
      );
      final homeBlur = find.descendant(
        of: find.byType(HomePage),
        matching: find.byType(ImageFiltered),
      );
      expect(hero, findsOneWidget);
      expect(homeBlur, findsNothing);
      expect(tester.widget<NetworkPoster>(heroImage).url, _cover);
      final heroRect = tester.getRect(hero);
      final imageRect = tester.getRect(heroImage);
      expect(imageRect.right, heroRect.right);
      expect(imageRect.center.dx, greaterThan(heroRect.center.dx));
      expect(imageRect.width / imageRect.height, closeTo(16 / 9, 0.001));

      await controller.setWallpaperOverride(_wallpaper);
      await tester.pumpAndSettle();
      final wallpaperImage = find.byWidgetPredicate((widget) {
        if (widget is! Image) return false;
        final image = widget.image;
        return image is FileImage && image.file.path == _wallpaper;
      });
      expect(homeBlur, findsNothing);
      expect(tester.widget<NetworkPoster>(heroImage).url, _cover);
      if (id == TvSkinId.netflix) {
        expect(wallpaperImage, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(tester.widget<NetworkPoster>(heroImage).url, _nextCover);
        expect(wallpaperImage, findsOneWidget);
        expect(homeBlur, findsNothing);
      } else {
        expect(wallpaperImage, findsNothing);
      }

      await controller.setWallpaperOverride('');
      await tester.pumpAndSettle();
      expect(wallpaperImage, findsNothing);
      expect(
        tester.widget<NetworkPoster>(heroImage).url,
        tester.widget<HomeHeroCarousel>(hero).item.pic,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
