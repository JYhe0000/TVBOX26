import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/live_parser.dart';
import 'package:tvbox_flutter/data/models.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/pages/live_page.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/home_hero_carousel.dart';

void main() {
  group('LiveGroupFilterCache', () {
    final source = LiveParseResult(
      title: '测试',
      groups: [
        LiveGroup(
          name: '央视',
          channels: [
            LiveChannel(
              name: 'CCTV-1 综合',
              urls: const [],
              sourceNames: const [],
            ),
            LiveChannel(
              name: 'CCTV-5 体育',
              urls: const [],
              sourceNames: const [],
            ),
          ],
        ),
        LiveGroup(
          name: '卫视',
          channels: [
            LiveChannel(name: '湖南卫视', urls: const [], sourceNames: const []),
          ],
        ),
      ],
    );

    test('相同 source/query 复用结果，query 变化重新过滤', () {
      final cache = LiveGroupFilterCache();

      final all = cache.groupsFor(source, '');
      expect(cache.groupsFor(source, '  '), same(all));
      expect(all, hasLength(2));

      final cctv = cache.groupsFor(source, ' cctv ');
      expect(cctv, hasLength(1));
      expect(cctv.single.channels.map((channel) => channel.name), [
        'CCTV-1 综合',
        'CCTV-5 体育',
      ]);
      expect(cache.groupsFor(source, 'CCTV'), same(cctv));
      expect(cache.groupsFor(source, ''), same(all));

      final hunan = cache.groupsFor(source, '湖南');
      expect(hunan, hasLength(1));
      expect(hunan.single.name, '卫视');
      expect(hunan, isNot(same(cctv)));
    });

    test('source 被替换后不会误用旧过滤结果', () {
      final cache = LiveGroupFilterCache();
      final first = cache.groupsFor(source, '央视');
      final replacement = LiveParseResult(
        title: '新源',
        groups: [
          LiveGroup(
            name: '地方',
            channels: [
              LiveChannel(name: '央视地方台', urls: const [], sourceNames: const []),
            ],
          ),
        ],
      );

      final next = cache.groupsFor(replacement, '央视');
      expect(next, isNot(same(first)));
      expect(next.single.name, '地方');
    });
  });

  group('NetworkPoster 解码尺寸', () {
    Future<CachedNetworkImage> mountPoster(
      WidgetTester tester, {
      required Widget child,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.forSkin(TvSkinId.smartisan),
          home: Scaffold(body: child),
        ),
      );
      return tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage).first,
      );
    }

    testWidgets('普通海报按画布内显示尺寸限制内存解码', (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final image = await mountPoster(
        tester,
        child: const Center(
          child: SizedBox(
            width: 240,
            height: 360,
            child: NetworkPoster(url: 'https://images.test/poster.jpg'),
          ),
        ),
      );

      // WidgetTester 可能使用非 1.0 的设备像素比；这里验证有限布局会生成
      // 有界的解码尺寸，并保持海报的 2:3 比例。
      final dpr = tester.view.devicePixelRatio;
      final logicalViewSize = tester.view.physicalSize / dpr;
      final canvasScale = (logicalViewSize.width / 1280).clamp(
        0.0,
        logicalViewSize.height / 720,
      );
      final decodeScale = dpr * canvasScale;
      expect(image.memCacheWidth, (240 * decodeScale).ceil());
      expect(image.memCacheHeight, (360 * decodeScale).ceil());
      expect(image.fadeInDuration, Duration.zero);
      expect(image.fadeOutDuration, Duration.zero);
      expect(
        image.memCacheWidth! / image.memCacheHeight!,
        closeTo(240 / 360, 0.01),
      );
      expect(image.imageBuilder, isNotNull);
      final stableImage = image.imageBuilder!(
        tester.element(find.byType(CachedNetworkImage).first),
        CachedNetworkImageProvider('https://images.test/poster.jpg'),
      );
      expect(stableImage, isA<Image>());
      expect((stableImage as Image).gaplessPlayback, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('hero 右侧主海报保留源分辨率', (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final focus = FocusNode(debugLabel: 'hero-cta-test');
      addTearDown(focus.dispose);
      final image = await mountPoster(
        tester,
        child: HomeHeroCarousel(
          item: const VodItem(
            id: '1',
            name: '测试影片',
            pic: 'https://images.test/hero.jpg',
          ),
          itemCount: 1,
          index: 0,
          expanded: false,
          ctaFocus: focus,
          onTapItem: () {},
        ),
      );

      expect(image.memCacheWidth, isNull);
      expect(image.memCacheHeight, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
