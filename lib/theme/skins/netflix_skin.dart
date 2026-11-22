import 'package:flutter/material.dart';

import '../skin.dart';

/// Netflix 皮肤。
///
/// 取的是 Netflix 电视端（Roku / Android TV / tvOS）的观感，而不是网页版：
/// 纯黑底、无玻璃无渐变面板、封面图说话、焦点靠一圈白描边 + 轻微放大，
/// 红只出现在品牌与进度条上。全站 `blurSigma = 0`——Netflix 的界面里没有
/// 毛玻璃，这也顺带让低端电视盒的帧率最稳。
///
/// 背景层（壁纸 + 氛围光斑）已与 ios26 对齐：底色仍是纯黑，壁纸以 0.32
/// 叠加、光斑同 ios26 三团，让首页 hero 外的氛围不再是一片死黑。
class TvNetflixSkin extends TvSkin {
  TvNetflixSkin()
    : super(
        id: TvSkinId.netflix,
        brightness: Brightness.dark,
        bg: const Color(0xFF000000),
        bgGradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF000000), Color(0xFF0A0A0A)],
        ),
        bgStripes: null,
        // 与 ios26 一致：吃壁纸（0.32）+ 三团氛围光斑。底色仍是纯黑，
        // 壁纸叠在纯黑上比 ios26 的 #05060A 底更暗一档，这是 netflix 的特征。
        wallpaperOpacity: 0.32,
        glowBlobs: const [
          Color(0x44FF4D4F),
          Color(0x2E5B8CFF),
          Color(0x1FFF7A45),
        ],
        surface: const Color(0xFF141414),
        surfaceAlt: const Color(0xFF1F1F1F),
        surfaceSubtle: const Color(0xFF181818),
        textPrimary: const Color(0xFFFFFFFF),
        textSecondary: const Color(0xFFB3B3B3),
        textMuted: const Color(0xFF808080),
        textOnAccent: Colors.white,
        border: const Color(0x33FFFFFF),
        borderSoft: const Color(0x1AFFFFFF),
        accent: const Color(0xFFE50914),
        accentPressed: const Color(0xFFB20710),
        accentGradient: const LinearGradient(
          colors: [Color(0xFFE50914), Color(0xFFB20710)],
        ),
        accentSoft: const Color(0x1FE50914),
        accentGlow: false,
        success: const Color(0xFF46D369),
        warning: const Color(0xFFFFB800),
        danger: const Color(0xFFE50914),
        // 接近方角：Netflix 的卡片圆角只有 4。
        radiusSm: 3,
        radiusMd: 4,
        radiusLg: 6,
        radiusPill: 999,
        spaceXs: 6,
        spaceSm: 10,
        spaceMd: 16,
        spaceLg: 24,
        spaceXl: 36,
        fontFamily: 'NotoSansSC',
        titleWeight: FontWeight.w900,
        focus: const TvFocusSkin(
          // Netflix 焦点：白描边 + 放大，不变色、不发光。
          grow: 1.08,
          cardGrow: 1.08,
          duration: Duration(milliseconds: 220),
          cardDuration: Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          fillColor: Color(0x00000000),
          borderColor: Color(0xFFFFFFFF),
          borderWidth: 3,
          glowColor: Color(0x40000000),
          glowBlur: 12,
          glowSpread: 0,
          liftShadow: [
            BoxShadow(
              color: Color(0x99000000),
              offset: Offset(0, 6),
              blurRadius: 14,
            ),
          ],
          tintContent: false,
          showFill: false,
          showGlow: true,
        ),
        surfaceSkin: const TvSurfaceSkin(
          panelFill: Color(0xFF141414),
          panelGradient: null,
          panelBorder: Color(0x00000000),
          panelBorderWidth: 0,
          panelShadow: [
            BoxShadow(
              color: Color(0x66000000),
              offset: Offset(0, 4),
              blurRadius: 10,
            ),
          ],
          blurSigma: 0,
          sheenColor: Color(0x00000000),
          rimColor: Color(0x00000000),
          insetWell: [
            BoxShadow(
              color: Color(0x99000000),
              offset: Offset(0, 2),
              blurRadius: 6,
            ),
          ],
        ),
        motionFast: Duration(milliseconds: 140),
        motionPanel: Duration(milliseconds: 200),
        motionPage: Duration(milliseconds: 260),
        topBarStyle: TvTopBarStyle.overlay,
        posterOverlay: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0x33000000), Color(0xF2000000)],
          stops: [0.45, 0.72, 1],
        ),
        heroScrim: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB3000000), Color(0xFF000000)],
          stops: [0, 0.6, 1],
        ),
        controlScrim: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xE6000000), Color(0x1A000000), Color(0xF2000000)],
          stops: [0, 0.5, 1],
        ),
      );
}
