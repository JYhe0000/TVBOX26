import 'package:flutter/material.dart';

import '../skin.dart';

/// Smartisan OS 暗色皮肤（TV 变体）。
///
/// 设计来源：由 [TvSmartisanSkin]（Smartisan OS 亮色）整体反转而来——把
/// #F0F0F0 纸底 + 白卡换成 #1B1B1D 黑底 + #262628 深灰卡，文字/描边/投影
/// 相应翻档，保留 Smartisan 轻拟物语言的全部结构特征：
///
/// 1. 竖条纹底纹（[bgStripes]）在暗底下换成同色系深条纹，纸感延续；
/// 2. 0.9px 细描边（[TvSurfaceSkin.panelBorderWidth]）不升档——与亮色皮肤
///    同规格的电视化取舍（描边升一档已在亮色文件里做过，这里只翻颜色）；
/// 3. 内凹阴影（[TvSurfaceSkin.insetWell]）在暗底上加深，凹槽感才读得出；
/// 4. 焦点态与亮色**完全一致**：整块换锤子蓝 + 内容反白 + 64ms 瞬时 +
///    1.02 轻微放大（[TvFocusSkin] 只翻 liftShadow 为深黑投影，颜色不动）。
///
/// 电视化取舍与亮色一致（间距 12 的倍数、10 英尺可读字号），另加两条暗色
/// 专属取舍：强调色在暗底略提亮（#5B87EB → #6C92F0）保证 3 米外可读；
/// 状态色（success/warning/danger）整体提亮一档，避免深底上发闷。
class TvSmartisanDarkSkin extends TvSkin {
  TvSmartisanDarkSkin()
    : super(
        id: TvSkinId.smartisanDark,
        brightness: Brightness.dark,
        bg: const Color(0xFF1B1B1D),
        bgGradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1F1F21), Color(0xFF1A1A1C)],
        ),
        // 亮色 R2 纸底纹（#f4f4f4 / #f2f2f2 竖条纹）的暗色对位：
        // #1E1E20 / #1C1C1E，周期与铺法跟亮色一致。
        bgStripes: const [Color(0xFF1E1E20), Color(0xFF1C1C1E)],
        // 与亮色 smartisan 一致：轻拟物底不铺壁纸，`wallpaperOpacity > 0`
        // 判据直接跳过壁纸层，避免壁纸透出破坏深灰卡观感。
        wallpaperOpacity: 0,
        glowBlobs: const [],
        surface: const Color(0xFF262628),
        surfaceAlt: const Color(0xFF2C2C2E),
        surfaceSubtle: const Color(0xFF202022),
        // 亮色 #333333 / #636363 / #9d9d9d 的反转对位（近白 / 中灰 / 浅灰）。
        textPrimary: const Color(0xFFF2F2F4),
        textSecondary: const Color(0xFFB8B8BC),
        textMuted: const Color(0xFF85858A),
        textOnAccent: Colors.white,
        border: const Color(0xFF3A3A3D),
        borderSoft: const Color(0xFF2A2A2D),
        // 一屏一个强调色：锤子蓝在暗底提亮一档（#6C92F0），按下态回到
        // 亮色的 #5B87EB 一带，渐变整体跟 accent 走。
        accent: const Color(0xFF6C92F0),
        accentPressed: const Color(0xFF5B7FE0),
        accentGradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6C92F0), Color(0xFF6589EA)],
        ),
        // 选中项底色：亮色 #E7EDFD 的暗色对位（暗蓝底）。
        accentSoft: const Color(0xFF232A3A),
        accentGlow: false,
        // 状态色整体提亮一档（#79AD31 → #93C84A 等），深底上才不发闷。
        success: const Color(0xFF93C84A),
        warning: const Color(0xFFE8665E),
        danger: const Color(0xFFF07E73),
        // 圆角全档与亮色完全一致（跨皮肤不变量）。
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
          // 与亮色完全同规格的「按下」语言：整块变蓝 #5985eb、文字图标
          // 全变白、64ms 瞬时无淡入、1.02 轻微放大；只把常驻投影换成
          // 深黑档（rgba(0,0,0,.35)），亮色的 .04 黑投影在暗底上看不见。
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
          liftShadow: [
            BoxShadow(
              color: Color(0x59000000),
              offset: Offset(0, 10),
              blurRadius: 13,
            ),
          ],
          tintContent: true,
          showFill: true,
          showGlow: false,
        ),
        surfaceSkin: const TvSurfaceSkin(
          // 深灰卡 + 0.9px 描边 + 深黑投影，**没有**毛玻璃（同亮色，
          // 跨皮肤模糊预算 0 处，见 AGENTS.md §9.6）。
          panelFill: Color(0xFF242426),
          panelGradient: null,
          panelBorder: Color(0xFF3A3A3D),
          panelBorderWidth: 0.9,
          panelShadow: [
            BoxShadow(
              color: Color(0x59000000),
              offset: Offset(0, 10),
              blurRadius: 13,
            ),
          ],
          blurSigma: 0,
          sheenColor: Color(0x00000000),
          rimColor: Color(0x00000000),
          // 内凹：滑块轨道 / 开关凹槽 / 分段选中块。暗底下阴影加深
          // （亮色 0x1A → 0x33），凹槽感才读得出；几何与亮色一致。
          insetWell: [
            BoxShadow(
              color: Color(0x33000000),
              offset: Offset(0, 4),
              blurRadius: 9.5,
            ),
          ],
        ),
        motionFast: Duration(milliseconds: 150),
        motionPanel: Duration(milliseconds: 200),
        // 与亮色一致：层级页横推 300ms、全屏页底升 300ms。
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
