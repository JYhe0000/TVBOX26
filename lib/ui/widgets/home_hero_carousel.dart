import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/ui.dart';
import '../tv_canvas.dart';
import 'common.dart';

/// 首页顶部「热门轮播」hero（izuko 探索页 trending carousel 的版式移植）。
///
/// 沿用 izuko `TvExplorationPage` 的信息区和遥控器交互：
/// - 右侧保留一张 16:9 主海报，左侧信息区直接沿用页面底色或壁纸；
/// - 焦点进入 hero（「查看详情」获焦）时信息区展开——简介与按钮浮出，
///   移开收回；左右键手动切换；自动推进的开关在页面侧（展开态才计时，
///   减弱动态 / 非当前路由时停表，手动切换重置计时）；
/// - 圆点指示器不可聚焦（izuko 同），当前项为胶囊。
///
/// hero 高度与圆点尺寸是纯布局常量；颜色/圆角/字号/间距/动效
/// 全部走皮肤 token。
class HomeHeroCarousel extends StatelessWidget {
  const HomeHeroCarousel({
    super.key,
    required this.item,
    required this.itemCount,
    required this.index,
    required this.expanded,
    required this.ctaFocus,
    required this.onTapItem,
    this.onCtaKeyEvent,
  });

  final VodItem item;

  /// 轮播总条目数（= 圆点数）。
  final int itemCount;

  /// 当前项下标。
  final int index;

  /// 焦点是否在 hero 内：展开简介与「查看详情」。
  final bool expanded;

  /// 「查看详情」的焦点节点（页面持有：shell 入口焦点 / FOCUS-06 落点
  /// 都挂它）。
  final FocusNode ctaFocus;

  final VoidCallback onTapItem;

  /// CTA 上的按键钩子（页面用它接左右键手动切换轮播）。
  final KeyEventResult Function(KeyEvent event)? onCtaKeyEvent;

  // —— 纯布局常量（izuko TV_CAROUSEL_HERO_TUNING 换算到 1280×720 画布）——

  /// hero 区高度（izuko 轮播图高 = 页高 0.67 含文字带；这里取 440，
  /// 下方仍留半行「为你推荐」露头，与 izuko
  /// tv-explore-hero 的首屏构图一致）。
  static const double heroHeight = 440;
  static const double _artWidth = heroHeight * 16 / 9;

  // 向左借出空间给标题，右缘仍留在海报渐隐区，避免挡住主体。
  static const double _textLeft = 192;
  static const double _textTop = 100;
  static const double _textWidth = 512;
  static const double _titleHeight = 124;

  /// 圆点指示器（izuko TV_CAROUSEL_DOT_*）。
  static const double dotSize = 6;
  static const double dotSelectedWidth = 20;
  static const double dotGap = 8;
  static const double dotInactiveAlpha = 0.4;

  /// 自动换片需等标题尾部可读；不溢出时沿用首页的默认停留时长。
  static Duration titleReadingDuration(BuildContext context, String title) {
    final layout = _HeroTitleLayout.resolve(context, title);
    return layout.travel == Duration.zero
        ? Duration.zero
        : layout.travel + layout.pause * 2;
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final motion = AppMotion.duration(context, skin.motionPanel);
    final summary = item.content.trim();
    final meta = _metaLine(item);
    return SizedBox(
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            width: _artWidth,
            height: heroHeight,
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, TvSkin.crossFade),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              child: _HeroArtwork(key: ValueKey(item.pic), imageUrl: item.pic),
            ),
          ),
          // 标题与元信息常驻，展开时简介与 CTA 浮出。
          Positioned(
            left: _textLeft,
            top: _textTop,
            width: _textWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _textWidth,
                  height: _titleHeight,
                  child: _HeroTitle(
                    key: ValueKey((index, item.id)),
                    title: item.name,
                    animate: expanded,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.section.copyWith(color: skin.textSecondary),
                  ),
                ],
                SizedBox(height: skin.spaceMd),
                // 展开态：简介 + 「查看详情」浮出（AnimatedSlide 轻微上移，
                // 占位常驻不引起页面重排；收回时淡出下沉）。
                AnimatedOpacity(
                  opacity: expanded ? 1 : 0,
                  duration: motion,
                  curve: Curves.easeOutCubic,
                  child: AnimatedSlide(
                    offset: expanded ? Offset.zero : const Offset(0, 0.08),
                    duration: motion,
                    curve: Curves.easeOutCubic,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (summary.isNotEmpty) ...[
                          Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.body.copyWith(height: 1.5),
                          ),
                          SizedBox(height: skin.spaceMd),
                        ],
                        _HeroAction(
                          focusNode: ctaFocus,
                          semanticLabel: '查看详情：${item.name}',
                          onTap: onTapItem,
                          onKeyEvent: onCtaKeyEvent,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 圆点指示器（右下，不可聚焦）。
          Positioned(
            right: TvCanvas.pagePad,
            bottom: skin.spaceLg,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < itemCount; i++) ...[
                  if (i > 0) SizedBox(width: dotGap),
                  AnimatedContainer(
                    duration: AppMotion.duration(context, skin.motionFast),
                    curve: Curves.easeOutCubic,
                    width: i == index ? dotSelectedWidth : dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      color: skin.textPrimary.withValues(
                        alpha: i == index ? 0.95 : dotInactiveAlpha,
                      ),
                      borderRadius: BorderRadius.circular(skin.radiusPill),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 元信息行：评分 · 备注 · 年份/地区/类型（单行显示）。
  String _metaLine(VodItem vod) {
    return [
      if (vod.score.trim().isNotEmpty) '评分 ${vod.score}',
      if (vod.remarks.trim().isNotEmpty) vod.remarks,
      if (vod.subtitle.trim().isNotEmpty) vod.subtitle,
    ].join(' · ');
  }
}

class _HeroTitleLayout {
  const _HeroTitleLayout({
    required this.title,
    required this.style,
    required this.scaler,
    required this.direction,
    required this.overflow,
    required this.pause,
    required this.travel,
  });

  final String title;
  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final double overflow;
  final Duration pause;
  final Duration travel;

  static final _lineBreaks = RegExp(r'\s*[\r\n]+\s*');

  static _HeroTitleLayout resolve(BuildContext context, String name) {
    final title = name.replaceAll(_lineBreaks, ' ');
    final direction = Directionality.of(context);
    // 标题是固定高度槽，缩放到两倍仍保留完整单行字形。
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 2);
    final base = AppText.of(context).display.copyWith(inherit: false);
    final bold = MediaQuery.boldTextOf(context);
    // 海报旁标题仍是视觉主角；长标题优先收一档，而不是直接截字。
    final compact = base.copyWith(fontSize: 52, height: 1.1);
    var style = base.copyWith(fontSize: 64, height: 1.1);
    double measure(TextStyle style) => TextPainter.computeWidth(
      text: TextSpan(
        text: title,
        style: bold
            ? style.merge(const TextStyle(fontWeight: FontWeight.bold))
            : style,
      ),
      textDirection: direction,
      textScaler: scaler,
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );

    const width = HomeHeroCarousel._textWidth;
    var measured = measure(style);
    if (measured > width) {
      style = compact;
      measured = measure(style);
    }
    final overflow = measured > width ? measured - width : 0.0;
    final motion = AppMotion.duration(context, TvSkin.of(context).motionPage);
    final travel = motion * (overflow / 24);
    final travelLimit = motion * 30;
    return _HeroTitleLayout(
      title: title,
      style: style,
      scaler: scaler,
      direction: direction,
      overflow: overflow,
      pause: motion * 3,
      travel: travel < travelLimit ? travel : travelLimit,
    );
  }
}

class _HeroTitle extends StatelessWidget {
  const _HeroTitle({super.key, required this.title, required this.animate});

  final String title;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final layout = _HeroTitleLayout.resolve(context, title);
    final shouldAnimate =
        animate &&
        layout.travel > Duration.zero &&
        ModalRoute.isCurrentOf(context) != false &&
        TickerMode.valuesOf(context).enabled;
    final titleText = Text(
      layout.title,
      key: const ValueKey('home-hero-title'),
      style: layout.style,
      textScaler: layout.scaler,
      maxLines: !shouldAnimate && layout.overflow > 0 ? 2 : 1,
      softWrap: !shouldAnimate,
      overflow: shouldAnimate ? TextOverflow.visible : TextOverflow.ellipsis,
    );

    if (!shouldAnimate) {
      // 停动时给长标题两行；大字体下仍不把简介和按钮向下挤。
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: SizedBox(width: HomeHeroCarousel._textWidth, child: titleText),
      );
    }

    final duration = layout.pause + layout.travel;
    final start = layout.pause.inMicroseconds / duration.inMicroseconds;
    final distance = layout.direction == TextDirection.ltr
        ? -layout.overflow
        : layout.overflow;
    // 只移动溢出的距离。一次走完后停在尾部，没有循环计时器或焦点节点。
    return Semantics(
      label: layout.title,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: ClipRect(
          key: const ValueKey('home-hero-title-viewport'),
          child: OverflowBox(
            alignment: AlignmentDirectional.centerStart,
            minWidth: 0,
            maxWidth: double.infinity,
            child: TweenAnimationBuilder<double>(
              key: ValueKey((layout.title, duration, distance)),
              tween: Tween(begin: 0, end: distance),
              duration: duration,
              curve: Interval(start, 1),
              builder: (_, offset, child) => Transform.translate(
                offset: Offset(offset, 0),
                transformHitTests: false,
                child: child,
              ),
              child: titleText,
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroArtwork extends StatelessWidget {
  const _HeroArtwork({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.trim().isEmpty) return const SizedBox.expand();
    final skin = TvSkin.of(context);
    // 左半张过渡到页面底图，底边在指示器上方融入页面。
    const leftFade = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Colors.transparent, Colors.transparent, Colors.white],
      stops: [0, 0.18, 0.46],
    );
    const bottomFade = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.white, Colors.white, Colors.transparent],
      stops: [0, 0.7, 0.9],
    );
    return ClipRect(
      clipper: const _HeroArtworkClipper(),
      child: ShaderMask(
        shaderCallback: leftFade.createShader,
        blendMode: BlendMode.dstIn,
        child: ShaderMask(
          shaderCallback: bottomFade.createShader,
          blendMode: BlendMode.dstIn,
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetworkPoster(
                url: imageUrl,
                radius: 0,
                decodeToDisplaySize: false,
              ),
              DecoratedBox(decoration: BoxDecoration(gradient: skin.heroScrim)),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroArtworkClipper extends CustomClipper<Rect> {
  const _HeroArtworkClipper();

  @override
  Rect getClip(Size size) {
    // 裁掉蒙版边界处因非整数缩放而漏出的像素。左、下切口都在透明带内。
    return Rect.fromLTRB(8, 2, size.width, size.height - 8);
  }

  @override
  bool shouldReclip(_HeroArtworkClipper oldClipper) => false;
}

/// hero 上的「查看详情」胶囊。获焦时让位给皮肤焦点填充。
class _HeroAction extends StatelessWidget {
  const _HeroAction({
    required this.focusNode,
    required this.semanticLabel,
    required this.onTap,
    this.onKeyEvent,
  });

  final FocusNode focusNode;
  final String semanticLabel;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event)? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      key: const ValueKey('home-hero-cta'),
      focusNode: focusNode,
      radius: skin.radiusPill,
      onTap: onTap,
      onKeyEvent: onKeyEvent,
      semanticLabel: semanticLabel,
      child: Builder(
        builder: (context) {
          final tinted = TvFocusTint.of(context);
          return AnimatedContainer(
            duration: AppMotion.duration(context, skin.motionFast),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: skin.spaceLg,
              vertical: skin.spaceSm,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(skin.radiusPill),
              color: tinted ? null : skin.surface,
              border: Border.all(
                color: tinted ? Colors.transparent : skin.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '查看详情',
                  style: text.bodyStrong.copyWith(
                    color: tinted ? skin.textOnAccent : skin.textPrimary,
                  ),
                ),
                SizedBox(width: skin.spaceXs),
                Icon(
                  Icons.chevron_right_rounded,
                  size: skin.spaceMd + 4,
                  color: tinted ? skin.textOnAccent : skin.textPrimary,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
