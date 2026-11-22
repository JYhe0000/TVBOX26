import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../theme/ui.dart';

/// 详情页的满版剧照背景层（izuko `TvHeroBackdrop` + `TvDetailsBlurredBackdrop`
/// 的本仓表达）。
///
/// 结构（自下而上）：
/// 1. 皮肤底色渐变兜底（剧照未到位 / 加载失败时露出来）；
/// 2. **同一张剧照的放大模糊版**铺满全屏，向 `skin.bg` 收拢的渐变蒙层——
///    暗色皮肤（smartisan_dark / netflix）下读作「剧照模糊压黑」，亮色
///    皮肤（smartisan）下读作「剧照柔化 + 纸底渐层」，同一机制、全部走
///    token，不按皮肤 id 分叉（AGENTS.md §8.4）；
/// 3. 详情页的清晰 2:3 海报与标题由页面内容层绘制；本层只负责其下垫着
///    的模糊底与蒙层，保证双栏布局在滚动时仍保持统一氛围。
///
/// 模糊用 [ImageFiltered] 而不是 [BackdropFilter]：前者是静态图的一次性
/// 栅格化（外包 [RepaintBoundary] 后只栅格一次），不占 AGENTS.md §5.4
/// 每屏 BackdropFilter ≤ 2 的预算；netflix 的 `surfaceSkin.blurSigma`
/// 恒为 0 也与此无关——本层是背景图自身的模糊，不是面板玻璃。
class DetailBackdrop extends StatelessWidget {
  const DetailBackdrop({
    super.key,
    required this.imageUrl,
    required this.child,
  });

  /// 剧照地址（`VodItem.pic`）。为空时只画皮肤底色渐变。
  final String imageUrl;

  /// 页面内容（滚动视图 + 浮层按钮），铺在本层之上。
  final Widget child;

  /// 模糊强度（设计像素）。一张图糊掉细节后双线性放大看不出原分辨率，
  /// 低端盒子上也只是一次性成本。
  static const double _blurSigma = 28;

  /// 放大系数：模糊会吃掉图的边缘，放大一圈裁掉，铺满不留缝。
  static const double _overscan = 1.12;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final url = normalizeBackdropUrl(imageUrl);
    final hasImage = url.isNotEmpty;
    // 蒙层：从「下半区顶部」的 bg 82% 渐到 55% 处的全不透明 bg。
    // 暗色皮肤下这是「模糊压黑」，亮色皮肤下是「纸底渐层」——同一个
    // 渐变、颜色取 skin.bg，观感由皮肤自己决定。
    final scrim = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [skin.bg.withValues(alpha: 0.82), skin.bg],
      stops: const [0, 0.55],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底色渐变兜底：AppBackground 的皮肤底之上再垫一层，保证模糊图
        // 加载期间也有完整的皮肤观感（纸底 / 黑底）。
        DecoratedBox(decoration: BoxDecoration(gradient: skin.bgGradient)),
        if (hasImage) ...[
          Positioned.fill(
            child: RepaintBoundary(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: _blurSigma,
                  sigmaY: _blurSigma,
                ),
                child: Transform.scale(
                  scale: _overscan,
                  child: _BackdropImage(url: url),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(decoration: BoxDecoration(gradient: scrim)),
          ),
        ],
        child,
      ],
    );
  }

  static String normalize(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('//') ? 'https:$trimmed' : trimmed;
  }
}

/// 剧照地址规范化（`//` 补协议、去空白）。[DetailBackdrop] 与
/// [DetailHeroImage] 共用，保证两层取图地址一致、共享解码缓存。
String normalizeBackdropUrl(String url) => DetailBackdrop.normalize(url);

/// 模糊层里的网络图。占位与失败都静默（底层的皮肤渐变已经是完整观感，
/// 不需要再画占位图标）；与 `NetworkPoster` 一样走 `cached_network_image`
/// 缓存，清晰 hero 层用同一个 URL 时共享解码缓存。
class _BackdropImage extends StatelessWidget {
  const _BackdropImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, _) => const SizedBox.shrink(),
      errorWidget: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

/// 遗留的清晰 hero 图层组件，当前详情页改用 2:3 海报，不再铺设这张横幅。
class DetailHeroImage extends StatelessWidget {
  const DetailHeroImage({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final url = normalizeBackdropUrl(imageUrl);
    if (url.isEmpty) return const SizedBox.shrink();
    // 底缘渐隐：透明 → skin.bg。暗色皮肤下是压黑渐隐、亮色皮肤下是
    // 纸底渐层——与下半区蒙层同一套「颜色跟皮肤」的表达（§8.3 压图
    // 渐变黑系仅用于视频/图片上的前景元素，这里渐变的终点是页面底色，
    // 由 skin.bg 决定明暗）。
    final fade = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [skin.bg.withValues(alpha: 0), skin.bg],
      stops: const [0.42, 1],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) => const SizedBox.shrink(),
        ),
        DecoratedBox(decoration: BoxDecoration(gradient: fade)),
      ],
    );
  }
}
