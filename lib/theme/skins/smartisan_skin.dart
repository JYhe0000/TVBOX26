import 'package:flutter/material.dart';

import '../skin.dart';

/// Smartisan OS 皮肤（TV 变体）。
///
/// 取值来自 `smartisan-ui` 技能的 `references/tokens.md` 与 `device-behavior.md`
/// （Smartisan R2 真机实测 + Smartisan OS 8 框架资源）。**Kit 原始规格是
/// 432dp 手机竖屏且无暗色模式**，这里做了三项电视化取舍，均已在 AGENTS.md
/// §9 记录：
///
/// 1. 间距从 6dp 网格放大到 12 的倍数（12/18/24/36/48），字号放大到 10 英尺
///    可读档（正文 16、页头 30）。
/// 2. 描边整体升一档（Kit 0.4/0.5/0.8 → 0.6/0.9/1.2），否则在电视上被
///    压缩伪影吃掉。
/// 3. 焦点态取 Kit 的「按下」语言（整块换色、文字图标反白、瞬时无淡入），
///    但补 1.02 的轻微放大——3 米外纯换色对小卡片不够可辨。
class TvSmartisanSkin extends TvSkin {
  TvSmartisanSkin()
    : super(
        id: TvSkinId.smartisan,
        brightness: Brightness.light,
        bg: const Color(0xFFF0F0F0),
        bgGradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF4F4F4), Color(0xFFEFEFEF)],
        ),
        // [R2] 真机设置页底纹：周期 3.6dp 的 #f4f4f4 / #f2f2f2 竖条纹。
        bgStripes: const [Color(0xFFF4F4F4), Color(0xFFF1F1F1)],
        // 背景图**不对 smartisan 生效**：轻拟物亮色纸底不铺壁纸，`_SkinBackdrop`
        // 里 `wallpaperOpacity > 0` 判据直接把壁纸层跳过，避免壁纸透出来破坏白卡观感。
        wallpaperOpacity: 0,
        glowBlobs: const [],
        surface: Colors.white,
        surfaceAlt: const Color(0xFFFAFAFA),
        surfaceSubtle: const Color(0xFFF2F2F2),
        textPrimary: const Color(0xFF333333),
        // Kit: 标题/按钮字 #636363，副标题 #7f7f7f，说明 #9d9d9d。
        textSecondary: const Color(0xFF636363),
        textMuted: const Color(0xFF9D9D9D),
        textOnAccent: Colors.white,
        border: const Color(0xFFE2E2E2),
        borderSoft: const Color(0xFFF2F2F2),
        // 一屏一个强调色：锤子蓝 #5b87eb，渐变到 #5883eb。
        accent: const Color(0xFF5B87EB),
        accentPressed: const Color(0xFF4772E6),
        accentGradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF5B87EB), Color(0xFF5883EB)],
        ),
        accentSoft: const Color(0xFFE7EDFD),
        accentGlow: false,
        success: const Color(0xFF79AD31),
        warning: const Color(0xFFD44D44),
        danger: const Color(0xFFE5645A),
        // Kit 圆角全档保留：分段 3 / 小按钮 4 / 菜单输入 6 / 卡片 10 / 胶囊 100。
        radiusSm: 6,
        radiusMd: 10,
        radiusLg: 12,
        radiusPill: 999,
        spaceXs: 6,
        spaceSm: 12,
        spaceMd: 18,
        spaceLg: 24,
        spaceXl: 36,
        fontFamily: 'NotoSansSC',
        titleWeight: FontWeight.w700,
        focus: const TvFocusSkin(
          // Kit 列表行按下：整行变蓝 #5985eb、文字图标箭头全变白，瞬时无淡入。
          grow: 1.02,
          cardGrow: 1.06,
          duration: Duration(milliseconds: 64),
          cardDuration: Duration(milliseconds: 220),
          curve: Curves.easeOut,
          fillColor: Color(0xFF5985EB),
          borderColor: Color(0xFF3F68E2),
          borderWidth: 0.9,
          glowColor: Color(0x00000000),
          glowBlur: 0,
          glowSpread: 0,
          // 卡片常驻投影：`0 10px 16px rgba(0,0,0,.04)`。
          liftShadow: [
            BoxShadow(
              color: Color(0x0A000000),
              offset: Offset(0, 10),
              blurRadius: 13,
            ),
          ],
          tintContent: true,
          showFill: true,
          showGlow: false,
        ),
        surfaceSkin: const TvSurfaceSkin(
          // 白卡 + 0.8px 描边 + 极淡投影，**没有**毛玻璃（Kit 明确禁止）。
          panelFill: Colors.white,
          panelGradient: null,
          panelBorder: Color(0xFFE2E2E2),
          panelBorderWidth: 0.9,
          panelShadow: [
            BoxShadow(
              color: Color(0x0A000000),
              offset: Offset(0, 10),
              blurRadius: 13,
            ),
          ],
          blurSigma: 0,
          sheenColor: Color(0x00000000),
          rimColor: Color(0x00000000),
          // 内凹：滑块轨道 / 开关凹槽 / 分段选中块。
          insetWell: [
            BoxShadow(
              color: Color(0x1A000000),
              offset: Offset(0, 4),
              blurRadius: 9.5,
            ),
          ],
        ),
        motionFast: Duration(milliseconds: 150),
        motionPanel: Duration(milliseconds: 200),
        // Kit: 层级页横推 300ms、全屏页底升 300ms。
        motionPage: Duration(milliseconds: 300),
        topBarStyle: TvTopBarStyle.centeredBar,
        posterOverlay: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0x1A000000), Color(0xE6000000)],
          stops: [0.4, 0.66, 1],
        ),
        heroScrim: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x14000000), Color(0x99000000), Color(0xF2000000)],
          stops: [0, 0.55, 1],
        ),
        controlScrim: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000), Color(0xE6000000)],
          stops: [0, 0.45, 1],
        ),
      );
}
