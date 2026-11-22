import 'package:flutter/material.dart';

import 'skin.dart';
import 'theme_controller.dart';

/// 旧色板的**唯一**保留处。
///
/// 阶段 1–4 会把 23 个文件里 253 处 `AppColors.x` / `AppGradients.x` 迁到
/// `TvSkin`；迁移完成前保留这个类，让仓库保持在可编译、可 `flutter analyze`
/// 0 issues 的状态（AGENTS.md §7 的验收线）。
///
/// **新代码禁止引用**：页面里用 `TvSkin.of(context)`，取不到 skin 的场合
/// （常量默认值、构造期）也请把颜色作为参数传进来。
class AppColors {
  static const bg = Color(0xFF05060A);
  static const bgElevated = Color(0xFF0C0E15);
  static const surface = Color(0xFF121521);
  static const surfaceLight = Color(0xFF1A1E2C);
  static const primary = Color(0xFFFF4D4F);
  static const primaryDark = Color(0xFFC6232B);
  static const orange = Color(0xFFFFA940);
  static const blue = Color(0xFF5B8CFF);
  static const green = Color(0xFF39D98A);
  static const text = Color(0xFFF5F7FA);
  static const textSecondary = Color(0xFFB3B9C9);
  static const textMuted = Color(0xFF7D8496);
  static const border = Color(0x33FFFFFF);
  static const glass = Color(0x1AFFFFFF);
  static const glassStrong = Color(0x2EFFFFFF);
  static const danger = Color(0xFFFF5C5C);
}

/// 旧渐变，取值与 iOS 26 皮肤对齐。迁移完成前保留。
class AppGradients {
  static const brand = LinearGradient(
    colors: [AppColors.primary, Color(0xFFFF7A45)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const posterOverlay = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, Color(0x22000000), Color(0xE6000000)],
    stops: [0.35, 0.62, 1],
  );

  static const page = RadialGradient(
    center: Alignment(-0.8, -0.9),
    radius: 1.6,
    colors: [Color(0x33FF4D4F), AppColors.bg],
    stops: [0, 0.55],
  );
}

/// 10-foot type scale。字号是**跨皮肤不变量**（AGENTS.md §9）：三套皮肤观感
/// 差得再远，10 英尺外的可读下限也不能破。皮肤通过 [TvSkin.titleWeight]
/// 与颜色改变观感，字号只在这里定义。
///
/// 运行时从 `context` 取，返回随皮肤变化的 [TextStyle]（颜色/字重/字体回退）。
/// 用 `AppText.of(context).pageTitle` 而不是 `AppText.pageTitle`。
class AppText {
  const AppText._();

  /// Hero / 详情主标题。
  static const double displaySize = 38;

  /// 页头（一行，TV 布局规则）。
  static const double pageTitleSize = 30;

  /// 分区标题（shelf / grid 上方）。
  static const double sectionSize = 22;

  /// 卡片标题 / 列表行标题。
  static const double cardTitleSize = 17;

  /// 强调正文与按钮。
  static const double bodyLargeSize = 16;

  static const double bodySize = 14;
  static const double bodyStrongSize = 15;

  /// 元数据旁的次要标签。
  static const double labelSize = 13;

  /// 纯辅助信息 —— 不要用来承载用户必须读的内容。
  static const double metaSize = 12;

  /// 中文排版下 `height` 固定 1.3–1.5，避免皮肤换字体后行高跳动。
  static TextStyle resolve(TvSkin skin, double size, FontWeight weight, double height) {
    return TextStyle(
      fontSize: size,
      fontWeight: weight,
      height: height,
      color: skin.textPrimary,
      fontFamily: skin.fontFamily,
    );
  }

  static TvTextScale of(BuildContext context) =>
      TvTextScale._(TvSkin.of(context));
}

/// 绑定到当前皮肤的排版档。页面里写 `final t = AppText.of(context);`
/// 然后用 `t.pageTitle` / `t.label.copyWith(color: ...)`。
class TvTextScale {
  TvTextScale._(TvSkin skin)
    : display = AppText.resolve(
        skin,
        AppText.displaySize,
        FontWeight.w900,
        1.12,
      ).copyWith(letterSpacing: -0.4),
      pageTitle = AppText.resolve(
        skin,
        AppText.pageTitleSize,
        skin.titleWeight,
        1.2,
      ).copyWith(letterSpacing: -0.3),
      section = AppText.resolve(
        skin,
        AppText.sectionSize,
        skin.titleWeight,
        1.25,
      ),
      cardTitle = AppText.resolve(
        skin,
        AppText.cardTitleSize,
        FontWeight.w700,
        1.3,
      ),
      bodyLarge = AppText.resolve(
        skin,
        AppText.bodyLargeSize,
        FontWeight.w500,
        1.5,
      ),
      body = AppText.resolve(skin, AppText.bodySize, FontWeight.w500, 1.5),
      bodyStrong = AppText.resolve(
        skin,
        AppText.bodyStrongSize,
        FontWeight.w600,
        1.4,
      ),
      label = AppText.resolve(skin, AppText.labelSize, FontWeight.w600, 1.35),
      meta = AppText.resolve(skin, AppText.metaSize, FontWeight.w500, 1.3),
      muted = AppText.resolve(
        skin,
        AppText.labelSize,
        FontWeight.w600,
        1.35,
      ).copyWith(color: skin.textMuted);

  final TextStyle display;
  final TextStyle pageTitle;
  final TextStyle section;
  final TextStyle cardTitle;
  final TextStyle bodyLarge;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle label;

  /// 辅助元数据。默认色就是 [TvSkin.textMuted]。
  final TextStyle meta;
  final TextStyle muted;
}

/// 跨皮肤不变的间距尺。皮肤可以整体放大/收紧（`TvSkin.space*`），
/// 但页面里绝大多数间距直接用这个尺，保证三套皮肤的节奏一致。
class AppSpacing {
  const AppSpacing._();

  static const xs = 6.0;
  static const sm = 10.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// 动效。基础时长来自皮肤（smartisan 64ms 的瞬时焦点 vs netflix 220ms），
/// 但「尊重减弱动态」这条跨皮肤一致。
class AppMotion {
  const AppMotion._();

  /// 覆盖层/面板兜底时长，皮肤没给就用它。
  static const panel = Duration(milliseconds: 220);

  /// ACCESS-04: honour the system "reduce motion" switch. Focus indication
  /// stays visible, only the movement is removed.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static Duration duration(BuildContext context, Duration value) =>
      reduced(context) ? Duration.zero : value;

  /// 焦点过渡：时长与曲线都归皮肤管，减弱动态时归零。
  static Duration focus(BuildContext context, TvSkin skin) =>
      duration(context, skin.focus.duration);

  /// 焦点变化引发的页面滚动（TV 焦点跟随）：非线性减速曲线，比线性或
  /// `Curves.easeOutCubic` 更顺滑，让焦点上/下移动时包围它的垂直滚动
  /// 平滑不生硬。所有「焦点变化驱动的滚动」统一用它，别在页面里各写一条。
  static const Curve scrollCurve = Curves.easeOutQuart;

  /// 焦点滚动时长：读皮肤 `motionPanel`（≈200–220ms），经 [duration] 尊重
  /// 「减弱动态」。取不到皮肤（少数挂在 `MaterialApp` 之外的场合）回落
  /// [panel]。
  static Duration scrollDuration(BuildContext context) =>
      duration(context, TvSkin.maybeOf(context)?.motionPanel ?? panel);
}

/// 兼容入口：`AppTheme.dark()` 仍有调用方（widget 测试的 harness）。
/// 生产代码请改用 [AppTheme.forSkin]。
class AppTheme {
  const AppTheme._();

  /// 深色皮肤的 `ThemeData`（兼容入口，widget 测试 harness 用）。
  static ThemeData dark() => forSkin(TvSkinId.netflix);

  static ThemeData forSkin(
    TvSkinId id, {
    TvAccentColor accentColor = TvAccentColor.skinDefault,
  }) => forSkinData(skinFor(id, accentColor: accentColor));

  static ThemeData forSkinData(TvSkin skin) {
    final scheme = ColorScheme.fromSeed(
      seedColor: skin.accent,
      brightness: skin.brightness,
      primary: skin.accent,
      onPrimary: skin.textOnAccent,
      secondary: skin.accent,
      onSecondary: skin.textOnAccent,
      surface: skin.surface,
      onSurface: skin.textPrimary,
      error: skin.danger,
      onError: skin.textOnAccent,
      outline: skin.border,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: skin.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      extensions: <ThemeExtension<dynamic>>[
        TvSkinTokens(skin: skin),
      ],
    );
    final textTheme = base.textTheme.apply(
      bodyColor: skin.textPrimary,
      displayColor: skin.textPrimary,
      fontFamily: skin.fontFamily,
    );
    return base.copyWith(
      // 10-foot UI type scale: body text stays legible across a living room
      // (tvOS DISTANCE-01/02), never below ~12.5sp even for secondary labels.
      textTheme: textTheme.copyWith(
        displayLarge: textTheme.displayLarge?.copyWith(
          fontSize: 44,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.6,
        ),
        displayMedium: textTheme.displayMedium?.copyWith(
          fontSize: 36,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.4,
        ),
        headlineLarge: textTheme.headlineLarge?.copyWith(
          fontSize: AppText.pageTitleSize,
          fontWeight: skin.titleWeight,
          letterSpacing: -0.3,
        ),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontSize: 25,
          fontWeight: skin.titleWeight,
        ),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontSize: 21,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontSize: AppText.bodyLargeSize,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: textTheme.titleSmall?.copyWith(
          fontSize: AppText.labelSize + 1.5,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          fontSize: AppText.bodyLargeSize,
          height: 1.5,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(
          fontSize: AppText.bodySize + 1,
          height: 1.5,
        ),
        bodySmall: textTheme.bodySmall?.copyWith(
          fontSize: AppText.labelSize,
          height: 1.45,
          fontWeight: FontWeight.w500,
        ),
        labelLarge: textTheme.labelLarge?.copyWith(
          fontSize: AppText.bodySize + 1,
          fontWeight: FontWeight.w700,
        ),
        labelMedium: textTheme.labelMedium?.copyWith(
          fontSize: AppText.labelSize,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: textTheme.labelSmall?.copyWith(
          fontSize: AppText.metaSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        foregroundColor: skin.textPrimary,
      ),
      dividerTheme: DividerThemeData(color: skin.borderSoft, thickness: 0.6),
      iconTheme: IconThemeData(color: skin.textPrimary),
      dialogTheme: DialogThemeData(
        backgroundColor: skin.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(skin.radiusLg),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: skin.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(skin.radiusLg + 4),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: skin.surfaceAlt,
        contentTextStyle: TextStyle(color: skin.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(skin.radiusSm),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: skin.surfaceSubtle,
        hintStyle: TextStyle(color: skin.textMuted),
        labelStyle: TextStyle(color: skin.textSecondary),
        contentPadding: EdgeInsets.symmetric(
          horizontal: skin.spaceMd,
          vertical: skin.spaceSm + 4,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(skin.radiusSm),
          borderSide: BorderSide(color: skin.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(skin.radiusSm),
          borderSide: BorderSide(color: skin.accent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(skin.radiusSm),
          borderSide: BorderSide(color: skin.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(skin.radiusSm),
          borderSide: BorderSide(color: skin.danger, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: skin.accent,
          foregroundColor: skin.textOnAccent,
          minimumSize: Size(0, skin.spaceLg + skin.spaceMd),
          padding: EdgeInsets.symmetric(
            horizontal: skin.spaceLg,
            vertical: skin.spaceSm + 4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(skin.radiusSm),
          ),
          textStyle: TextStyle(
            fontSize: AppText.bodyLargeSize,
            fontWeight: FontWeight.w700,
            fontFamily: skin.fontFamily,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: skin.textPrimary,
          minimumSize: Size(0, skin.spaceLg + skin.spaceMd),
          padding: EdgeInsets.symmetric(
            horizontal: skin.spaceLg,
            vertical: skin.spaceSm + 4,
          ),
          side: BorderSide(color: skin.border, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(skin.radiusSm),
          ),
          textStyle: TextStyle(
            fontSize: AppText.bodyLargeSize,
            fontWeight: FontWeight.w600,
            fontFamily: skin.fontFamily,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: skin.textSecondary,
          textStyle: TextStyle(
            fontSize: AppText.bodySize + 1,
            fontWeight: FontWeight.w600,
            fontFamily: skin.fontFamily,
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: skin.surfaceSubtle,
        selectedColor: skin.accent,
        labelStyle: TextStyle(color: skin.textSecondary),
        secondaryLabelStyle: TextStyle(
          color: skin.textOnAccent,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide(color: skin.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(skin.radiusPill),
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: skin.accent,
        inactiveTrackColor: skin.border,
        thumbColor: skin.textPrimary,
        overlayColor: skin.accentSoft,
        trackHeight: 3,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: skin.accent,
        linearTrackColor: skin.border,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: skin.textPrimary,
        unselectedLabelColor: skin.textMuted,
        indicatorColor: skin.accent,
        dividerColor: Colors.transparent,
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: _SkinPageTransitions(skin.motionPage),
        },
      ),
    );
  }
}

/// 转场时长跟皮肤走。`FadeForwardsPageTransitionsBuilder` 的时长不可配，
/// 这里包一层把「先淡出旧页、再淡入新页」的节奏调到皮肤的 `motionPage`。
class _SkinPageTransitions extends PageTransitionsBuilder {
  const _SkinPageTransitions(this.motion);

  final Duration motion;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        // 位移量极小（1.2% 画布高），只为给淡入一点方向感，
        // 不做 tvOS 那种整页横推（AGENTS.md §5.1 帧率优先）。
        position: Tween<Offset>(
          begin: const Offset(0, 0.012),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
