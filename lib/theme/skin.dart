import 'package:flutter/material.dart';

/// 皮肤枚举（ios26 已移除）。顺序即设置页展示顺序，`TvSkinId.fromName` 用它做持久化回读。
enum TvSkinId {
  smartisan('Smartisan OS', '轻拟物 · 细描边 · 单强调色'),
  smartisanDark('Smartisan OS 暗色', '轻拟物 · 暗底细描边 · 单强调色'),
  netflix('默认', '纯黑电影感 · 白描边焦点');

  const TvSkinId(this.label, this.tagline);

  /// 设置页用的中文名称。
  final String label;

  /// 一句话说明，用于皮肤选择行的副标题。
  final String tagline;

  static TvSkinId fromName(String? raw) {
    for (final id in values) {
      if (id.name == raw) return id;
    }
    return TvSkinId.netflix;
  }
}

/// 可选主题强调色。`skinDefault` 表示沿用当前皮肤的品牌色。
enum TvAccentColor {
  skinDefault('跟随皮肤', null),
  blue('海盐蓝', Color(0xFF4F74CC)),
  green('森林绿', Color(0xFF34764F)),
  orange('暖阳橙', Color(0xFFAD5E19)),
  red('樱桃红', Color(0xFFB83D43)),
  purple('星空紫', Color(0xFF674EB0));

  const TvAccentColor(this.label, this.color);

  final String label;
  final Color? color;

  static TvAccentColor fromName(String? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return TvAccentColor.skinDefault;
  }
}

/// 焦点视觉语言。各皮肤最本质的差别不是配色，而是「焦点长什么样」，
/// 所以单独成类，不散落在各个颜色字段里（AGENTS.md §3）。
class TvFocusSkin {
  const TvFocusSkin({
    required this.grow,
    required this.cardGrow,
    required this.duration,
    required this.cardDuration,
    required this.curve,
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
    required this.glowColor,
    required this.glowBlur,
    required this.glowSpread,
    required this.liftShadow,
    required this.tintContent,
    required this.showFill,
    required this.showGlow,
  });

  /// 获焦放大系数。1.0 表示不缩放（smartisan 靠整块换色）。
  final double grow;

  /// 海报获焦放大系数。大屏海报需要比普通控件更清晰的焦点反馈。
  final double cardGrow;

  /// 焦点过渡时长。smartisan 取 64ms（按下即变），其余 180–220ms。
  final Duration duration;

  /// 海报焦点过渡时长；独立于普通控件，避免小尺寸缩放在大屏上难以察觉。
  final Duration cardDuration;

  final Curve curve;

  /// 获焦时的填充色。[showFill] 为 false 时不绘制。
  final Color fillColor;

  /// 获焦描边颜色与粗细。smartisan 与 netflix 靠它表达焦点。
  final Color borderColor;
  final double borderWidth;

  /// 获焦光晕。低端电视盒上光晕比 BackdropFilter 便宜得多，优先用它。
  final Color glowColor;
  final double glowBlur;
  final double glowSpread;

  /// 未获焦时的常驻投影（smartisan 卡片的 `0 10px 13px rgba(0,0,0,.04)`）。
  final List<BoxShadow> liftShadow;

  /// 获焦时子内容是否整体反色（smartisan 列表行整行变蓝、文字图标全变白）。
  final bool tintContent;

  final bool showFill;
  final bool showGlow;
}

/// 玻璃/卡片材质。皮肤之间差别最大的就是「面板是什么做的」。
class TvSurfaceSkin {
  const TvSurfaceSkin({
    required this.panelFill,
    required this.panelGradient,
    required this.panelBorder,
    required this.panelBorderWidth,
    required this.panelShadow,
    required this.blurSigma,
    required this.sheenColor,
    required this.rimColor,
    required this.insetWell,
    this.sheenGradient,
    this.insetGlow = const [],
    this.rimBottomColor = const Color(0x00000000),
    this.rimHeight = 1.0,
  });

  /// 面板底色。[panelGradient] 非 null 时优先用它。
  final Color panelFill;
  final Gradient? panelGradient;
  final Color panelBorder;
  final double panelBorderWidth;
  final List<BoxShadow> panelShadow;

  /// 背景模糊强度。0 表示不用 BackdropFilter（AGENTS.md §5.4：
  /// 每屏最多 1–2 处模糊，netflix 皮肤直接为 0）。
  final double blurSigma;

  /// 玻璃斜向高光。smartisan/netflix 为透明。
  final Color sheenColor;

  /// 玻璃斜向高光的多 stop 渐变（比单色 [sheenColor] 更接近液态玻璃的
  /// 斜放反光）。非 null 时优先于 [sheenColor]；smartisan/netflix 为 null。
  final Gradient? sheenGradient;

  /// 玻璃上沿亮边（iOS 26 的 specular rim）。
  final Color rimColor;

  /// 上沿亮边的厚度（设计像素）。亮边从 [rimColor] 向下渐隐到透明。
  /// smartisan/netflix 的 [rimColor] 透明，此值无影响。
  final double rimHeight;

  /// 玻璃下沿透光边（光从玻璃底部透出的浅色高光）。透明则不绘制。
  final Color rimBottomColor;

  /// 玻璃受光边缘的内发光（`BlurStyle.inner`，模拟玻璃边缘受光时的亮度
  /// 渐变）。smartisan/netflix 为空列表。
  final List<BoxShadow> insetGlow;

  /// 内凹槽（smartisan 开关轨道、滑块、分段选中块）。
  final List<BoxShadow> insetWell;
}

/// 一整套皮肤。新增可切换的视觉维度时加在这里，**不要**散落到页面里，
/// 页面只读 `TvSkin.of(context).xxx`（AGENTS.md §8）。
class TvSkin {
  const TvSkin({
    required this.id,
    required this.brightness,
    required this.bg,
    required this.bgGradient,
    required this.bgStripes,
    required this.wallpaperOpacity,
    required this.glowBlobs,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textOnAccent,
    required this.border,
    required this.borderSoft,
    required this.accent,
    required this.accentPressed,
    required this.accentGradient,
    required this.accentSoft,
    required this.accentGlow,
    required this.success,
    required this.warning,
    required this.danger,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusPill,
    required this.spaceXs,
    required this.spaceSm,
    required this.spaceMd,
    required this.spaceLg,
    required this.spaceXl,
    required this.fontFamily,
    required this.titleWeight,
    required this.focus,
    required this.surfaceSkin,
    required this.motionFast,
    required this.motionPanel,
    required this.motionPage,
    required this.topBarStyle,
    required this.posterOverlay,
    required this.heroScrim,
    required this.controlScrim,
  });

  final TvSkinId id;

  /// 亮色皮肤（smartisan）下 `ThemeData` 与系统 UI 状态栏图标要跟着翻。
  final Brightness brightness;

  // —— 背景 ——
  final Color bg;
  final Gradient bgGradient;

  /// 竖条纹颜色对。null 表示纯色底（仅 smartisan 用它做真机同款底纹）。
  final List<Color>? bgStripes;

  /// 用户自定义壁纸的叠加不透明度。ios26/netflix 为 0.32（壁纸透出），
  /// smartisan 为 0.06（淡铺），底色仍由 [bg]/[bgGradient] 决定。
  final double wallpaperOpacity;

  /// 氛围光斑颜色（三个径向渐变）。smartisan 为空列表；ios26/netflix 各三团。
  final List<Color> glowBlobs;

  // —— 面板 ——
  final Color surface;
  final Color surfaceAlt;
  final Color surfaceSubtle;

  // —— 文字 ——
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// 强调色/获焦填充之上的文字色（smartisan 整行变蓝时文字要变白）。
  final Color textOnAccent;

  // —— 描边 ——
  final Color border;
  final Color borderSoft;

  // —— 强调 ——
  final Color accent;
  final Color accentPressed;
  final Gradient accentGradient;

  /// 强调色的低透明度版（选中项底色）。
  final Color accentSoft;

  /// 选中项 / 品牌 logo 是否加 accent 软光晕。ios26 用（玻璃风、光晕和谐），
  /// smartisan（亮色）与 netflix（纯色、红只出现在品牌与进度条）不用。
  /// 与 [glowBlobs]（背景氛围光斑）解耦：二者过去被复用同一开关，导致
  /// netflix 打开壁纸光斑后选中项意外点亮 accent 光晕。
  final bool accentGlow;
  final Color success;
  final Color warning;
  final Color danger;

  // —— 形状（1280×720 设计画布坐标）——
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusPill;

  // —— 间距 ——
  final double spaceXs;
  final double spaceSm;
  final double spaceMd;
  final double spaceLg;
  final double spaceXl;

  // —— 字体 ——
  /// 统一打包字体族名（Noto Sans SC）。
  final String fontFamily;

  /// 标题字重。netflix 更粗更紧，smartisan 用 w700 且颜色偏灰。
  final FontWeight titleWeight;

  // —— 焦点 ——
  final TvFocusSkin focus;

  // —— 材质 ——
  final TvSurfaceSkin surfaceSkin;

  // —— 动效 ——
  final Duration motionFast;
  final Duration motionPanel;

  /// 转场时长，用于 `MaterialPageRoute` 级别的动画。
  final Duration motionPage;

  // —— 导航层形态 ——
  final TvTopBarStyle topBarStyle;

  // —— 图片遮罩 ——
  final Gradient posterOverlay;
  final Gradient heroScrim;

  /// 播放器控制层遮罩。三皮肤都必须是黑色系（视频上可读性优先，
  /// 只有不透明度与模糊量跟皮肤变）。
  final Gradient controlScrim;

  /// 皮肤切换的淡入淡出时长。整套配色同时 cross-fade，避免硬切刺眼。
  static const Duration crossFade = Duration(milliseconds: 320);

  /// 返回此皮肤应用指定强调色后的不可变副本。默认配色保持原样；
  /// Netflix 的白色焦点描边也不受主题色覆盖。
  TvSkin withAccentColor(TvAccentColor selection) {
    final selectedColor = selection.color;
    if (selectedColor == null) return this;

    final baseHsl = HSLColor.fromColor(selectedColor);
    final accent = brightness == Brightness.dark
        ? baseHsl
              .withLightness(
                (baseHsl.lightness + 0.12).clamp(0.0, 1.0).toDouble(),
              )
              .toColor()
        : selectedColor;
    final accentHsl = HSLColor.fromColor(accent);
    final accentPressed = accentHsl
        .withLightness(
          (accentHsl.lightness - 0.12).clamp(0.0, 1.0).toDouble(),
        )
        .toColor();
    final accentSoft = brightness == Brightness.dark
        ? accent.withValues(alpha: 0.2)
        : Color.alphaBlend(accent.withValues(alpha: 0.13), surface);
    final tintFocus = focus.showFill || focus.tintContent;
    final nextFocus = TvFocusSkin(
      grow: focus.grow,
      cardGrow: focus.cardGrow,
      duration: focus.duration,
      cardDuration: focus.cardDuration,
      curve: focus.curve,
      fillColor: focus.showFill ? accent : focus.fillColor,
      borderColor: tintFocus
          ? accentHsl
                .withLightness(
                  (accentHsl.lightness - 0.18).clamp(0.0, 1.0).toDouble(),
                )
                .toColor()
          : focus.borderColor,
      borderWidth: focus.borderWidth,
      glowColor: focus.glowColor,
      glowBlur: focus.glowBlur,
      glowSpread: focus.glowSpread,
      liftShadow: focus.liftShadow,
      tintContent: focus.tintContent,
      showFill: focus.showFill,
      showGlow: focus.showGlow,
    );

    return TvSkin(
      id: id,
      brightness: brightness,
      bg: bg,
      bgGradient: bgGradient,
      bgStripes: bgStripes,
      wallpaperOpacity: wallpaperOpacity,
      glowBlobs: glowBlobs,
      surface: surface,
      surfaceAlt: surfaceAlt,
      surfaceSubtle: surfaceSubtle,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textMuted: textMuted,
      textOnAccent: textOnAccent,
      border: border,
      borderSoft: borderSoft,
      accent: accent,
      accentPressed: accentPressed,
      accentGradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [accent, accentPressed],
      ),
      accentSoft: accentSoft,
      accentGlow: accentGlow,
      success: success,
      warning: warning,
      danger: danger,
      radiusSm: radiusSm,
      radiusMd: radiusMd,
      radiusLg: radiusLg,
      radiusPill: radiusPill,
      spaceXs: spaceXs,
      spaceSm: spaceSm,
      spaceMd: spaceMd,
      spaceLg: spaceLg,
      spaceXl: spaceXl,
      fontFamily: fontFamily,
      titleWeight: titleWeight,
      focus: nextFocus,
      surfaceSkin: surfaceSkin,
      motionFast: motionFast,
      motionPanel: motionPanel,
      motionPage: motionPage,
      topBarStyle: topBarStyle,
      posterOverlay: posterOverlay,
      heroScrim: heroScrim,
      controlScrim: controlScrim,
    );
  }

  static TvSkin of(BuildContext context) {
    final tokens = Theme.of(context).extension<TvSkinTokens>();
    assert(
      tokens != null,
      'TvSkin.of(context) 需要 MaterialApp.theme 里挂载 TvSkinTokens —— '
      '请在 main.dart 用 AppTheme.forSkin(skin) 生成主题，'
      'widget 测试用 AppTheme.forSkin(TvSkinId.smartisan)。',
    );
    return tokens!.skin;
  }

  /// 取不到皮肤时（widget 树挂在 `MaterialApp` 之外的极少数场合）返回 null。
  static TvSkin? maybeOf(BuildContext context) =>
      Theme.of(context).extension<TvSkinTokens>()?.skin;
}

/// 顶栏形态（历史设计意图，当前已无消费方）。
///
/// 2026-11-15 P0-1 根治后，壳层统一为单一 `Scaffold` + 悬浮 `_TopTabBar`
/// （`SkinSurface` 皮肤化），三皮肤不再按此枚举分叉。`TvSkin.topBarStyle`
/// 字段与这三个值仅作为「三皮肤曾设想不同顶栏形态」的设计意图记录保留；
/// 若未来重新引入差异化顶栏，再恢复壳层分支消费它。
enum TvTopBarStyle {
  /// 玻璃胶囊，浮在内容之上（ios26 历史形态，现未实现）。
  glassPinned,

  /// 居中标题栏，底部一道渐隐阴影，无描边（smartisan 历史形态，现未实现）。
  centeredBar,

  /// 透明浮层，只有内容，无栏体（netflix 历史形态，现未实现）。
  overlay,
}

/// `ThemeData` 扩展：皮肤随主题一起动，`TvSkin.of(context)` 不用额外
/// InheritedWidget，也不会在 `MaterialApp` 之外失效。
class TvSkinTokens extends ThemeExtension<TvSkinTokens> {
  const TvSkinTokens({required this.skin});

  final TvSkin skin;

  @override
  TvSkinTokens copyWith({TvSkin? skin}) =>
      TvSkinTokens(skin: skin ?? this.skin);

  @override
  TvSkinTokens lerp(ThemeExtension<TvSkinTokens>? other, double t) {
    if (other is! TvSkinTokens) return this;
    // 皮肤是整套语义值，线性插值会产生中间态脏色（例如亮底插到暗底）。
    // 切换时由 AppBackground 做 cross-fade，这里直接跟随目标值。
    return t < 0.5 ? this : other;
  }
}
