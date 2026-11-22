import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../theme/ui.dart';
import '../tv_canvas.dart';

/// 播放中控制层自动隐藏的延迟（遥控器无操作）。
///
/// 电视端 10 英尺操作节奏偏慢，5~6 秒会让控制层挡画面太久；3 秒既能看清
/// 当前集数与进度，又不会长时间遮挡。暂停 / 面板打开时不自动隐藏。
const Duration kControlsAutoHide = Duration(seconds: 3);

/// TV 端列表的预构建窗口。设计画布坐标下约覆盖一屏内容，避免滚动时
/// 大量同步创建 widget，又不会像无限制预构建那样把整页图片提前解码。
const double kTvListCacheExtent = 420;

/// 多行海报/频道网格的预构建窗口。网格方向键依赖缓存区内节点，至少保留
/// 两行，具体网格可按卡片高度使用更大的值。
const double kTvGridCacheExtent = 720;

// ===========================================================================
// 焦点体系公共基建（docs/focus-system-spec.md §4/§5）
//
// 三件套：
// - [ShelfFocusMemory]：横排（ShelfRow）焦点记忆的公共实现——「受控记忆
//   节点 + 记忆下标」的持有器，进出横排恢复上次位置（spec §4-3）。直播
//   分组栏 / 我的继续观看行等 F2/F4 页面直接构造消费，不再各自复制
//   `_railFocus/_railIndex`、`_shelfMemoryFocus/_shelfMemoryIndex` 的散件
//   样板（ShelfRow 的 memoryFocus/memoryIndex 契约见 shelf_row.dart 头注）。
// - [FocusDispatchMap]：页面方向键投递表（spec §5 显式投递范式的公共
//   实现）——「区块 × 方向」登记目标，运行期按当前焦点所在区块查表投递。
//   每格三态：[FocusNode] 投递、null 边界吞键、[FocusDispatchMap.pass]
//   放行给壳层/框架。页面根 Focus（skipTraversal）挂它，替代各页面自写
//   的 `_handleNavKey/_layerOf` 分支链。
// - [deliverFocusNode]：确定性投递原语（requestFocus + 最小滚动揭示），
//   ShelfFocusMemory 与 FocusDispatchMap 内部共用。
// ===========================================================================

/// 皮肤化的背景层。取代原先的 `AppColors.bg` + 三团硬编码光斑：
/// 每套皮肤自己决定是「氛围光斑 + 壁纸」（ios26、netflix，纯黑底上叠壁纸）、
/// 「竖条纹纸底」（smartisan）还是其它。
///
/// 皮肤切换时用 [AnimatedSwitcher] 做 320ms 交叉淡化——亮底与暗底之间
/// 直接硬切在客厅大屏上很刺眼，而 `ThemeExtension.lerp` 只做阈值切换，
/// 渐变交给这一层。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.wallpaper = ''});

  final Widget child;
  final String wallpaper;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final imageUrl = _normalize(wallpaper);
    // 背景图模糊开关：全局外观设置，默认关闭（直接铺图）。
    final blurBackground = context.watch<AppController>().blurBackground;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: TvSkin.crossFade,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: KeyedSubtree(
            key: ValueKey<TvSkinId>(skin.id),
            child: _SkinBackdrop(
              skin: skin,
              imageUrl: imageUrl,
              blur: blurBackground,
            ),
          ),
        ),
        child,
      ],
    );
  }

  static String _normalize(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('//') ? 'https:$trimmed' : trimmed;
  }
}

class _SkinBackdrop extends StatelessWidget {
  const _SkinBackdrop({
    required this.skin,
    required this.imageUrl,
    required this.blur,
  });

  final TvSkin skin;
  final String imageUrl;

  /// 背景图是否做高斯模糊（由全局外观开关控制，默认 false）。
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final stripes = skin.bgStripes;
    return DecoratedBox(
      decoration: BoxDecoration(gradient: skin.bgGradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (stripes != null)
            // smartisan 真机底纹：`repeating-linear-gradient(90deg, …)`，
            // 用 CustomPaint 而不是一张平铺图，缩放时不糊。
            CustomPaint(painter: _StripePainter(stripes[0], stripes[1], 7.2)),
          if (imageUrl.isNotEmpty && skin.wallpaperOpacity > 0)
            // 背景图默认直接铺（blur=false）；开启背景模糊开关时做高斯模糊。
            Opacity(
              opacity: skin.wallpaperOpacity,
              child: blur
                  ? ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: _wallpaperImage(imageUrl),
                    )
                  : _wallpaperImage(imageUrl),
            ),
          // 氛围光斑：ios26/netflix 各三团；smartisan 给空列表，自然跳过。
          for (var i = 0; i < skin.glowBlobs.length; i++)
            _GlowBlob(
              alignment: _blobAlignments[i % _blobAlignments.length],
              color: skin.glowBlobs[i],
              size: _blobSizes[i % _blobSizes.length],
            ),
          if (skin.glowBlobs.isNotEmpty)
            // 光斑之上压一层暗调，保证内容对比度（tvOS DISTANCE-02）。
            // 压暗恒为黑系（§8.3 压图/压背景的前景恒黑白），不跟皮肤。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [const Color(0x22000000), const Color(0x66000000)],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 背景图：本地路径（`/` 或 `file://` 开头）用 [Image.file] 加载，否则走
  /// 网络缓存。`file://` 前缀需剥掉再交给 [File]。每次 build 新建一个
  /// `FileImage`（其缓存 key 按实例身份），恰好保证覆盖写同路径后能读到新图。
  Widget _wallpaperImage(String url) {
    if (url.startsWith('file://')) {
      return Image.file(
        File(url.substring('file://'.length)),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    if (url.startsWith('/')) {
      return Image.file(
        File(url),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      errorWidget: (_, _, _) => const SizedBox.shrink(),
    );
  }

  static const _blobAlignments = [
    Alignment(-1.15, -0.95),
    Alignment(1.15, -0.25),
    Alignment(0.35, 1.2),
  ];

  static const _blobSizes = [420.0, 360.0, 420.0];
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({
    required this.alignment,
    required this.color,
    required this.size,
  });

  final Alignment alignment;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}

/// 竖条纹底纹。`period` 是条纹周期（设计像素），TV 上用 7.2 而不是
/// smartisan 手机的 3.6——1px 细纹在 3 米外会摩尔纹。
class _StripePainter extends CustomPainter {
  _StripePainter(this.base, this.stripe, this.period);

  final Color base;
  final Color stripe;
  final double period;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final paint = Paint()..color = stripe;
    for (double x = 0; x < size.width; x += period) {
      canvas.drawRect(Rect.fromLTWH(x, 0, period / 2, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) =>
      oldDelegate.base != base ||
      oldDelegate.stripe != stripe ||
      oldDelegate.period != period;
}

/// 皮肤化的玻璃/卡片面板。取代原先写死「毛玻璃 + 白色 11% 斜向渐变 + 12%
/// 描边」的 `GlassPanel`：
///
/// - ios26：磨砂玻璃 + 上沿高光边（`surfaceSkin.rimColor`）。
/// - smartisan：白卡 + 0.9px 描边 + 极淡投影，**零模糊**（Kit 禁止毛玻璃）。
/// - netflix：纯 `#141414` 平板，无描边无模糊。
///
/// `blurSigma` 为 0 时不进 [BackdropFilter]——每屏模糊数量是 AGENTS.md
/// §5.4 的硬预算，netflix 皮肤整站 0 处。
///
/// ## 材质实现（毛玻璃，不依赖任何玻璃 shader 包）
///
/// ios26 面板是「毛玻璃」：半透明填充 + `BackdropFilter` 模糊（`blurSigma`
/// 20，浮层 ×1.3）+ 细描边/高光。早期版本曾接入第三方全屏玻璃 shader，
/// 但在 Android TV 的 Skia 上会把文字下沿渲成「黄色下划线」伪影，且真折射
/// 只在 Impeller 的 premium 档存在——已全部移除，依赖也已删除。
///
/// 现在的玻璃参数全部来自 [TvSkin.surfaceSkin] 的静态 token（`panelFill` /
/// `panelGradient` / `panelBorder` / `sheenGradient` / `insetGlow` / `rimColor`），
/// 不再有用户可调的透明度/高光滑杆。
class SkinSurface extends StatelessWidget {
  const SkinSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius,
    this.tint,
    this.onTap,
    this.floating = false,
    this.bordered = true,
    this.enableBlur = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 圆角，缺省取 `skin.radiusMd`。
  final double? radius;

  /// 覆盖皮肤底色（例如顶栏要更暗的一档）。
  final Color? tint;

  final VoidCallback? onTap;

  /// 浮层（顶栏、悬浮操作条）：ios26 下换成更强的模糊与不透明度。
  final bool floating;

  /// 是否画描边。netflix 的 `panelBorderWidth` 为 0，传 true 也不会画出线。
  final bool bordered;

  /// 是否启用背景模糊；关闭时仍保留皮肤材质与高光，用于控制同屏模糊预算。
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final material = skin.surfaceSkin;
    final resolvedRadius = radius ?? skin.radiusMd;
    // 毛玻璃：模糊强度取皮肤 token；浮层（顶栏/悬浮条）加强 1.3 倍。
    final sigma = !enableBlur
        ? 0.0
        : (floating && material.blurSigma > 0
              ? material.blurSigma * 1.3
              : material.blurSigma);
    final fill = tint ?? material.panelFill;
    final gradient = tint == null ? material.panelGradient : null;

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? fill : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(resolvedRadius),
        border: bordered
            ? Border.all(
                color: material.panelBorder,
                width: material.panelBorderWidth,
              )
            : null,
        boxShadow: material.panelShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(resolvedRadius),
        child: Stack(
          children: [
            if (sigma > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: gradient == null ? fill : null,
                        gradient: gradient,
                      ),
                    ),
                  ),
                ),
              ),
            Padding(padding: padding, child: child),
            // 边缘内发光：毛玻璃边缘受光（insetGlow 非空时绘制）。
            if (material.insetGlow.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(resolvedRadius),
                      boxShadow: material.insetGlow,
                    ),
                  ),
                ),
              ),
            // 斜向高光：毛玻璃的受光层（sheenGradient 非空或 sheenColor 非透明）。
            if (material.sheenGradient != null || material.sheenColor.a > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(resolvedRadius),
                      gradient:
                          material.sheenGradient ??
                          LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              material.sheenColor,
                              material.sheenColor.withValues(alpha: 0),
                            ],
                          ),
                    ),
                  ),
                ),
              ),
            // 上沿亮边：iOS 26 的 specular rim（自上而下渐隐）。
            if (material.rimColor.a > 0)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: material.rimHeight,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          material.rimColor,
                          material.rimColor.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // 下沿透光边：玻璃底部透出的浅色高光（自下而上渐隐）。
            if (material.rimBottomColor.a > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: material.rimHeight,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          material.rimBottomColor,
                          material.rimBottomColor.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (onTap == null) return content;
    return GestureDetector(onTap: onTap, child: content);
  }
}

/// 玻璃/卡片面板的旧名。阶段 5 会把全项目 17 处调用点改成 [SkinSurface]，
/// 现在先保留别名，让阶段 1 的改动能单独验收。
typedef GlassPanel = SkinSurface;

/// 内容根节点的顶内边距（shell 注入的悬浮顶栏让位量）。
///
/// [ShellPage] 给整页套了一层 `MediaQuery`，`padding.top` 比画布自身多
/// [kTopBarHeight]；页面外面再套 [TvCanvas] 的话画布会把 padding 归零。
/// 取两者之差就是「顶栏占掉的高度」，与 `SafeArea` 的算法一致，页面根
/// 直接用 `EdgeInsets.only(top: contentTopInset(context))` 即可让开顶栏。
double contentTopInset(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  if (media == null) return 0;
  // 画布把 padding 与 viewPadding 一起归零，所以 padding 里剩下的就是
  // shell 注入的顶栏让位量；viewInsets（软键盘）不算进来。
  return media.padding.top > 0 ? media.padding.top : 0;
}

/// 标记「当前处于 [TvFocusable] 的获焦反白态」。
///
/// smartisan 的焦点语言是「整块换蓝 + 内容反白」：填充由 [TvFocusable]
/// 画在子内容之下，子组件若自带不透明底色会把它整块盖住、退化成细描边
/// （widgets_audit P1-3）。[TvFocusTint] 让子组件（SiteRow、GlassChip 等）
/// 在获焦反白态时读到 [active]，从而让出底色、把文字/图标切到
/// [TvSkin.textOnAccent]——带显式颜色的文本需由子组件配合翻色；继承的
/// 默认文字与图标颜色则由 `_FocusTint` 按皮肤参数动画过渡。
class TvFocusTint extends InheritedWidget {
  const TvFocusTint({super.key, required this.active, required super.child});

  /// 是否处于获焦反白态。未包在 [TvFocusable] 内时恒为 false。
  final bool active;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvFocusTint>()?.active ??
      false;

  @override
  bool updateShouldNotify(TvFocusTint oldWidget) => active != oldWidget.active;
}

/// A focus-aware clickable area that works with both touch and a TV remote.
///
/// 焦点视觉全部来自 [TvSkin.focus]：smartisan 系是整块换色 + 内容反白，
/// netflix 是白描边 + 放大。所有皮肤共用同一份动画实现，只读取各自 token。
/// 全局路由观察器：供页面订阅「从子路由返回」（didPopNext），
/// 在返回后把焦点重新投回本页落点（播放器/设置页 pop 后焦点曾落到
/// 路由 scope 上 = 死焦点，遥控器全失灵）。
final RouteObserver<ModalRoute<dynamic>> kRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

// ---------------------------------------------------------------------------
// 焦点体系公共实现（spec §4-3 行焦点记忆 / §5 显式投递范式）
// ---------------------------------------------------------------------------

/// 确定性投递焦点：立即 `requestFocus`（按键路径上同步执行，不落
/// post-frame 队列——旧方向键晚到覆盖新落点是曾经的死键根因），
/// `ensureVisualUpdate` 催一帧，帧末对目标做最小滚动揭示。
///
/// 目标未挂载（网格缓存区外的行 / 横向列表滚远的项）时：
/// `FocusNode.requestFocus` 走 reparent 钩子，节点挂载时焦点自动落位；
/// 帧末揭示发现 context 为空自动跳过。首页网格、直播网格、各横排的
/// 显式投递共用这一份（spec §5 模板的「有目标」分支）。
void deliverFocusNode(FocusNode target) {
  target.requestFocus();
  WidgetsBinding.instance.ensureVisualUpdate();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final context = target.context;
    if (context == null || !context.mounted) return;
    if (!target.hasFocus) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.0,
      // 显式对齐可同时揭示上方和下方目标；keepVisibleAtEnd 只会向下
      // 揭示，逐层 UP 时会把真实焦点留在视口上方。
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      duration: AppMotion.scrollDuration(context),
      curve: AppMotion.scrollCurve,
    );
  });
}

/// 在页面级垂直滚动里把 [node] 揭示到可见（spec §5）。
///
/// 与 [deliverFocusNode] 的分工：deliver 的 `Scrollable.ensureVisible`
/// 只滚**最近**的一个 Scrollable（横向 shelf / 网格自己），嵌套横向
/// 列表里的节点（分类 chips、推荐行卡片）垂直方向仍可能被页面滚动
/// 挡住——本函数按全局坐标换算直接滚页面级垂直 position。已完整可见
/// 则不动（keepVisibleAtEnd 最小滚动）。减弱动态时时长安 skin 语义。
void revealInPageScroll(FocusNode node, ScrollController pageScroll) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = node.context;
    if (target == null || !target.mounted) return;
    if (!node.hasFocus || !pageScroll.hasClients) return;
    final box = target.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    pageScroll.position.ensureVisible(
      box,
      alignment: 0.0,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      duration: AppMotion.scrollDuration(target),
      curve: AppMotion.scrollCurve,
    );
  });
}

/// 横排（[ShelfRow]）焦点记忆的公共持有器（spec §4-3 的公共实现）。
///
/// 组合「受控记忆节点 + 记忆下标 + 行滚动控制器」三件套，替代各页面
/// 复制的散件：
///
/// ```dart
/// final shelf = ShelfFocusMemory(
///   debugLabel: 'live-rail-memory',
///   itemExtent: _railItemExtent, // 每项主轴尺寸（滚远归零时算位置）
/// );
/// ShelfRow(
///   memoryFocus: shelf.focus,       // 受控记忆节点（挂记忆下标项）
///   memoryIndex: shelf.index,       // 受控记忆下标
///   onFocusIndex: shelf.syncIndex,  // 行内移动回写记忆
///   controller: shelf.scroll,       // 行滚动（滚远回收时归零回行首）
///   ...
/// )
/// // 从别的区块 UP/DOWN/LEFT 进入本行（spec §5「有目标」分支）：
/// shelf.focusHere(pageScroll: _pageScroll); // 页面级垂直滚动可选
/// ...
/// @override
/// void dispose() { shelf.dispose(); super.dispose(); }
/// ```
///
/// 记忆项滚出视口（横向滚远被 `ListView` 回收）时：[focusHere] 先按
/// `itemExtent` 把行滚回记忆项应在的位置，再投递焦点；记忆项仍未挂载
/// （兜底）时下标归零、行滚回首项再投——宁可退回首项，也不让焦点停在
/// 暗处（首页 `_focusShelf` 同款语义的公共化）。
class ShelfFocusMemory {
  ShelfFocusMemory({
    int initialIndex = 0,
    this.debugLabel = 'shelf-memory',
    this.itemExtent,
  }) : focus = FocusNode(debugLabel: debugLabel),
       index = ValueNotifier<int>(initialIndex),
       scroll = ScrollController();

  /// 受控记忆节点：挂 `ShelfRow.memoryFocus`，也是页面侧显式投递的
  /// 目标（「网格首行 UP / 分类栏 DOWN → 记忆项」直接投它）。
  final FocusNode focus;

  /// 受控记忆下标：挂 `ShelfRow.memoryIndex` + `ShelfRow.onFocusIndex`
  /// 回写（[syncIndex]）。
  final ValueNotifier<int> index;

  /// 行滚动控制器：挂 `ShelfRow.controller`；记忆项滚远时 [focusHere]
  /// 用它把行滚回记忆项应在的位置（归零兜底同款）。
  final ScrollController scroll;

  bool _disposed = false;
  int _focusRequest = 0;

  /// 调试标签（挂到 [focus] 上，体系测试的断言锚点）。
  final String debugLabel;

  /// 每项主轴尺寸（横向 = 宽度；null = 每项自决宽，不做位置换算，
  /// 滚动交给 `requestFocus` 的框架 ensureVisible）。
  final double? itemExtent;

  /// `ShelfRow.onFocusIndex` 直接挂这个：行内移动同步记忆下标。
  void syncIndex(int value) {
    if (!_disposed) index.value = value;
  }

  /// 确定性投递焦点到记忆项（spec §5「有目标」分支的横排版）：
  /// 1. 行先滚到记忆项应在的位置（[itemExtent] 已知时）；
  /// 2. `requestFocus` + `ensureVisualUpdate`（未挂载时挂载后自动落位）；
  /// 3. 帧末兜底——记忆项仍未获焦：已挂载则补投一次（当帧才挂上的
  ///    情形）；仍未挂载（滚远被回收）则下标归零、行滚回首项再投；
  /// 4. 传了 [pageScroll] 时顺带做页面级垂直揭示（记忆行整体滚出
  ///    垂直视口的情况，如首页推荐行在网格之下）。
  void focusHere({ScrollController? pageScroll}) {
    if (_disposed) return;
    final request = ++_focusRequest;
    final controller = scroll;
    final i = index.value;
    final extent = itemExtent;
    if (extent != null && extent > 0 && controller.hasClients) {
      // 记忆项在滚动内容里的起始偏移 = 首项内边距 + i ×（每项 + 间距）；
      // 首项内边距与 viewport 内边距相消，直接按项距换算。
      final stride = extent + _separator;
      final target = (i * stride).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );
      if ((controller.position.pixels - target).abs() > 1) {
        final focusContext = focus.context;
        final duration = focusContext == null
            ? Duration.zero
            : AppMotion.scrollDuration(focusContext);
        if (duration == Duration.zero) {
          controller.jumpTo(target);
        } else {
          unawaited(
            controller
                .animateTo(
                  target,
                  duration: duration,
                  curve: AppMotion.scrollCurve,
                )
                .then((_) {
                  if (_disposed ||
                      request != _focusRequest ||
                      !focus.hasFocus) {
                    return;
                  }
                  if (pageScroll != null) revealInPageScroll(focus, pageScroll);
                }),
          );
        }
      }
    }
    focus.requestFocus();
    WidgetsBinding.instance.ensureVisualUpdate();
    if (pageScroll != null) revealInPageScroll(focus, pageScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || request != _focusRequest || focus.hasFocus) return;
      if (mounted0(focus)) {
        // 当帧挂载完成但焦点未落（reparent 钩子的边界情形）：补投一次。
        focus.requestFocus();
        return;
      }
      // 记忆项滚远被回收：下标归零回行首（宁可退回首项，不让焦点
      // 停在暗处），行滚回 0 后帧末再投。
      index.value = 0;
      if (controller.hasClients && controller.position.pixels > 0.5) {
        controller.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed ||
            !mounted0(focus) ||
            focus.hasFocus ||
            !focus.canRequestFocus) {
          return;
        }
        focus.requestFocus();
      });
    });
  }

  /// ShelfRow 项间距（focusHere 的位置换算用；构造时未知皮肤 token，
  /// 优先从挂树 context 读 `TvSkin.spaceMd`，读不到用构造兜底值）。
  double _separator = 0;

  /// 供页面在拿到 context 后同步项间距（didChangeDependencies / build，
  /// 幂等）：`ShelfRow.separator` 传了什么这里就同步什么。
  void syncSeparator(double value) => _separator = value;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _focusRequest++;
    focus.dispose();
    index.dispose();
    scroll.dispose();
  }
}

/// 判断 [node] 是否仍有挂树 context（ShelfFocusMemory 的帧末守卫——
/// 持有器没有 State，用节点的挂载状态代替 mounted）。
bool mounted0(FocusNode node) => node.context?.mounted ?? false;

/// 页面级方向键投递表（spec §5 显式投递范式的公共实现）。
///
/// 页面在根 `Focus`（skipTraversal，不参与遍历）的 onKeyEvent 里挂一张
/// 表，运行期按「当前焦点所在区块 × 方向」查表投递：
///
/// ```dart
/// enum _Zone { header, row, grid }
///
/// // build 里登记（区块结构变化时先 clear 再重登）：
/// _dispatch
///   ..bind(_Zone.header, LogicalKeyboardKey.arrowDown, (_) => heroCta)
///   ..bindAll(_Zone.grid,
///     up: (f) => ..., down: (f) => ..., left: (f) => ..., right: (f) => ...);
///
/// // 页面根 Focus：
/// Focus(
///   focusNode: _navKeyFocus, // skipTraversal: true
///   onKeyEvent: (node, event) =>
///       _dispatch.handle(event, _zoneOf) ?? KeyEventResult.ignored,
///   ...
/// )
/// ```
///
/// resolver（`Object? Function(FocusNode focused)`）三态返回（spec §5
/// 「每个格子要么显式投递、要么明确 ignored」的格内表达）：
/// - [FocusNode]：**投递**（[deliverFocusNode]：requestFocus + 最小滚动
///   揭示）→ handled；
/// - `null`：**边界吞键**（消费事件、焦点不动——页面底 DOWN / 行尾
///   RIGHT，防止事件落到框架几何遍历造成跳丢）→ handled；
/// - [FocusDispatchMap.pass]：**放行**（ignored，交壳层 LEFT→侧栏通道
///   或框架兜底——行首 LEFT / 最左列 LEFT，spec §3 唯一进侧栏入口）。
///
/// zoneOf 返回 null（焦点不在任何登记区块，如提示横幅/空态按钮）→
/// handle 返回 null → 调用方 ignored（框架兜底，与重建前行为一致）。
class FocusDispatchMap {
  FocusDispatchMap({this.debugLabel});

  /// 调试标签（诊断输出用，可选）。
  final String? debugLabel;

  /// 「放行」哨兵：resolver 返回它表示该格交给上层（壳层 LEFT 通道/
  /// 框架几何遍历）。与 null（吞键）区分。
  static const Object pass = _PassSentinel();

  final Map<Object, Map<LogicalKeyboardKey, Object? Function(FocusNode)>>
  _table = {};

  /// 登记 [zone] 在 [key] 方向上的投递（同格重复登记后者覆盖）。
  void bind(
    Object zone,
    LogicalKeyboardKey key,
    Object? Function(FocusNode focused) target,
  ) {
    _table.putIfAbsent(
      zone,
      () => <LogicalKeyboardKey, Object? Function(FocusNode)>{},
    )[key] = target;
  }

  /// 四方向一次登记（未传的方向不登记 → handle 返回 null → ignored）。
  void bindAll(
    Object zone, {
    Object? Function(FocusNode focused)? up,
    Object? Function(FocusNode focused)? down,
    Object? Function(FocusNode focused)? left,
    Object? Function(FocusNode focused)? right,
  }) {
    if (up != null) bind(zone, LogicalKeyboardKey.arrowUp, up);
    if (down != null) bind(zone, LogicalKeyboardKey.arrowDown, down);
    if (left != null) bind(zone, LogicalKeyboardKey.arrowLeft, left);
    if (right != null) bind(zone, LogicalKeyboardKey.arrowRight, right);
  }

  /// 清空登记（区块结构变化——切分类/换站点/数据重载/皮肤切换重建
  /// 后重新登记用）。
  void clear() => _table.clear();

  /// 处理一个按键事件。[zoneOf] 从当前焦点的 context 判定所在区块
  /// （页面自写：沿 element 祖先链找最近的区块包装 widget）。
  ///
  /// 返回 null = 该格未登记（或事件不是 keydown/repeat 方向键、焦点
  /// 缺失、区块未登记）——调用方 `?? KeyEventResult.ignored` 交给壳层
  /// 或框架。返回非 null = 已处理（投递 / 吞键 / 放行三态见类文档）。
  KeyEventResult? handle(
    KeyEvent event,
    Object? Function(BuildContext focusContext) zoneOf,
  ) {
    // keydown 与长按 repeat 都走显式投递：repeat 放给框架会落回几何
    // 遍历，网格行落点不可控（死键/跳丢的根因之一，直播页同款语义）。
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return null;
    }
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (focus == null || context == null) return null;
    final zone = zoneOf(context);
    if (zone == null) return null;
    final resolver = _table[zone]?[key];
    if (resolver == null) return null;
    final result = resolver(focus);
    if (identical(result, pass)) return KeyEventResult.ignored;
    if (result is FocusNode) {
      deliverFocusNode(result);
      return KeyEventResult.handled;
    }
    // null = 边界吞键：焦点原地不动，消费事件防止框架几何遍历跳丢。
    return KeyEventResult.handled;
  }
}

/// [FocusDispatchMap.pass] 的哨兵类型（私有，外部只认常量）。
class _PassSentinel {
  const _PassSentinel();
}

class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.radius,
    this.scale,
    this.focusDuration,
    this.padding = EdgeInsets.zero,
    this.focusedBorder,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
    this.onFocusChange,
    this.onKeyEvent,
    this.allowKeyRepeat = false,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 圆角，缺省 `skin.radiusMd`。
  final double? radius;

  /// 覆盖皮肤给的放大系数（海报行需要更夸张的 1.1）。
  final double? scale;

  /// 仅需自定义该控件过渡节奏时覆盖皮肤默认时长；仍尊重减弱动态设置。
  final Duration? focusDuration;
  final EdgeInsetsGeometry padding;

  /// 覆盖皮肤给的焦点描边色（例如「在线」绿点行）。
  final Color? focusedBorder;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Screen-reader label for icon-only controls (ACCESS-01).
  final String? semanticLabel;

  /// Lets a parent pause autoplay or update an ambient backdrop when focus
  /// enters or leaves this item.
  final ValueChanged<bool>? onFocusChange;

  /// Optional key handling before the default select/enter handling, used by
  /// the top tab bar to move focus down into the page deterministically.
  final KeyEventResult Function(KeyEvent event)? onKeyEvent;
  final bool allowKeyRepeat;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode _node;
  bool _ownsNode = false;
  bool _focused = false;
  bool _nodeInitialized = false;

  @override
  void initState() {
    super.initState();
    _adoptNode();
  }

  void _adoptNode() {
    if (_nodeInitialized) {
      _node.removeListener(_onFocusChanged);
      if (_ownsNode) _node.dispose();
    }
    _nodeInitialized = true;
    _ownsNode = false;
    if (widget.focusNode != null) {
      _node = widget.focusNode!;
    } else {
      _node = FocusNode(debugLabel: 'TvFocusable');
      _ownsNode = true;
    }
    _node.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _adoptNode();
      // 外部节点在重建时换入（例如轮播把入口焦点挂到新的当前页），
      // 焦点态要跟着新节点走，否则焦点环会画在旧节点上。
      if (_node.hasFocus != _focused) {
        setState(() => _focused = _node.hasFocus);
      }
    }
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _node.hasFocus);
    widget.onFocusChange?.call(_node.hasFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChanged);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  /// OK 只消费一次、方向键默认 ignored（焦点体系重建契约，spec §3 矩阵）：
  /// - 只处理 keydown（[TvFocusable.allowKeyRepeat] 时含长按 repeat），
  ///   keyup 及其余一律 ignored；
  /// - 自定义 [TvFocusable.onKeyEvent] 优先（返回非 ignored 即消费，
  ///   如 hero CTA 的左右翻页）——OK 不会同时被钩子与默认逻辑各消费
  ///   一次：钩子消费即返回，未消费才走默认 OK 分支；
  /// - OK（select/enter/space/gameButtonA）触发 [TvFocusable.onTap] 并
  ///   消费；onTap 为空（禁用态等）时**不消费**，放行上层/框架——避免
  ///   「吞键但无动作」的静默死键（spec §3 死键判据）；
  /// - 方向键一律 ignored：页面层投递表（[FocusDispatchMap]）优先，
  ///   其次壳层 LEFT→侧栏通道，最后框架几何遍历——组件层不吞不投。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent &&
        !(widget.allowKeyRepeat && event is KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final custom = widget.onKeyEvent?.call(event);
    if (custom != null && custom != KeyEventResult.ignored) return custom;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      final onTap = widget.onTap;
      // 无动作不消费：OK 放行给上层（弹窗的默认按钮 / 页面的 OK 钩子），
      // 消费但无动作 = 静默死键。
      if (onTap == null) return KeyEventResult.ignored;
      onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final focus = skin.focus;
    // ACCESS-04: keep the focus indication, drop the movement when the user
    // asked the system to reduce motion.
    final reduced = AppMotion.reduced(context);
    final duration = AppMotion.duration(
      context,
      widget.focusDuration ?? focus.duration,
    );
    final scale = _focused && !reduced ? (widget.scale ?? focus.grow) : 1.0;
    final borderColor = widget.focusedBorder ?? focus.borderColor;

    final focusContent = Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _node.requestFocus();
          widget.onTap?.call();
        },
        child: AnimatedScale(
          scale: scale,
          duration: duration,
          curve: focus.curve,
          child: AnimatedContainer(
            duration: duration,
            curve: focus.curve,
            padding: widget.padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                widget.radius ?? skin.radiusMd,
              ),
              // FOCUS-01: never colour alone — scale, fill, glow and border are
              // combined per skin (see TvFocusSkin).
              boxShadow: _focused ? _focusedShadows(focus) : focus.liftShadow,
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                widget.radius ?? skin.radiusMd,
              ),
              // 前景描边不会参与布局，避免获焦时挤压海报、改变图片解码尺寸。
              border: Border.all(
                color: _focused ? borderColor : Colors.transparent,
                width: _focused ? focus.borderWidth : 0,
              ),
            ),
            child: _FocusTint(
              focused: _focused,
              color: focus.showFill ? focus.fillColor : null,
              radius: widget.radius ?? skin.radiusMd,
              tintContent: focus.tintContent,
              onAccent: skin.textOnAccent,
              duration: duration,
              curve: focus.curve,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
    if (widget.semanticLabel == null) return focusContent;
    return Semantics(
      container: true,
      button: true,
      label: widget.semanticLabel,
      child: focusContent,
    );
  }

  List<BoxShadow> _focusedShadows(TvFocusSkin focus) {
    final shadows = <BoxShadow>[...focus.liftShadow];
    if (!focus.showGlow || focus.glowBlur <= 0) return shadows;
    shadows.add(
      BoxShadow(
        color: focus.glowColor,
        blurRadius: focus.glowBlur,
        spreadRadius: focus.glowSpread,
        offset: const Offset(0, 8),
      ),
    );
    return shadows;
  }
}

/// 获焦填充 + 内容反白。smartisan 的「整行变蓝、文字图标箭头全变白」需要
/// 子内容跟着翻色，所以这里提供一个 `DefaultTextStyle` 与 `IconTheme`，
/// 而不是要求每个调用点自己判断焦点态。
class _FocusTint extends StatelessWidget {
  const _FocusTint({
    required this.focused,
    required this.color,
    required this.radius,
    required this.tintContent,
    required this.onAccent,
    required this.duration,
    required this.curve,
    required this.child,
  });

  final bool focused;
  final Color? color;
  final double radius;
  final bool tintContent;
  final Color onAccent;
  final Duration duration;
  final Curve curve;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tinted = focused && tintContent && (color?.a ?? 0) > 0;
    final theme = Theme.of(context);
    final textStyle = DefaultTextStyle.of(context).style;
    return TvFocusTint(
      active: tinted,
      child: AnimatedContainer(
        duration: duration,
        curve: curve,
        decoration: BoxDecoration(
          color: tinted ? color : null,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: AnimatedTheme(
          data: theme.copyWith(
            iconTheme: theme.iconTheme.copyWith(
              color: tinted ? onAccent : theme.iconTheme.color,
            ),
          ),
          duration: duration,
          curve: curve,
          child: AnimatedDefaultTextStyle(
            style: tinted ? textStyle.copyWith(color: onAccent) : textStyle,
            duration: duration,
            curve: curve,
            child: child,
          ),
        ),
      ),
    );
  }
}

class NetworkPoster extends StatelessWidget {
  const NetworkPoster({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.radius,
    this.decodeToDisplaySize = true,
  });

  final String url;
  final BoxFit fit;
  final double? radius;

  /// 是否按显示尺寸限制解码像素。需要保留清晰原图的 hero 图应关闭。
  final bool decodeToDisplaySize;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final imageUrl = url.trim().startsWith('//')
        ? 'https:${url.trim()}'
        : url.trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = View.of(context);
        final dpr = view.devicePixelRatio;
        // TvCanvas 会把固定设计画布缩放到实际视图；解码目标也纳入该缩放，
        // 保证 1080p/4K 输出仍然清晰。
        final logicalViewSize = view.physicalSize / dpr;
        final canvasScale = (logicalViewSize.width / TvCanvas.designWidth)
            .clamp(0.0, logicalViewSize.height / TvCanvas.designHeight)
            .toDouble();
        final decodeScale = dpr * canvasScale;
        int? decodeDimension(double dimension) {
          if (!decodeToDisplaySize || !dimension.isFinite || dimension <= 0) {
            return null;
          }
          return (dimension * decodeScale).ceil().clamp(1, 1 << 30);
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(radius ?? skin.radiusSm + 4),
          child: imageUrl.isEmpty
              ? _placeholder(skin)
              : CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: fit,
                  memCacheWidth: decodeDimension(constraints.maxWidth),
                  memCacheHeight: decodeDimension(constraints.maxHeight),
                  // 网格回收后同一位置可能切换到另一张图；新图解码期间保留旧帧，
                  // 避免焦点滚动时先闪占位图再闪入封面。
                  imageBuilder: (context, imageProvider) => Image(
                    image: imageProvider,
                    fit: fit,
                    gaplessPlayback: true,
                  ),
                  placeholder: (_, _) => _placeholder(skin, loading: true),
                  errorWidget: (_, _, _) => _placeholder(skin),
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                ),
        );
      },
    );
  }

  Widget _placeholder(TvSkin skin, {bool loading = false}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [skin.surfaceAlt, skin.surface],
        ),
      ),
      child: Center(
        child: Icon(
          loading ? Icons.image_outlined : Icons.movie_filter_outlined,
          color: skin.textMuted.withValues(alpha: 0.7),
          size: 34,
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(4, 0, 4, 12),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 4,
            height: 22,
            decoration: BoxDecoration(
              gradient: skin.accentGradient,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          SizedBox(width: skin.spaceSm),
          Text(title, style: text.section),
          if (subtitle != null) ...[
            SizedBox(width: skin.spaceSm),
            Expanded(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.label.copyWith(color: skin.textMuted),
              ),
            ),
          ] else
            const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class SiteBadge extends StatelessWidget {
  const SiteBadge({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        // 徽标永远压在海报图上，所以底与描边硬约束为黑色系半透明，
        // 不跟皮肤（否则 smartisan 的白底徽标在图上看不见）。
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.label.copyWith(
              color: Colors.white.withValues(alpha: 0.92),
            ),
          ),
        ],
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = '正在加载…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          SizedBox(height: skin.spaceMd),
          Text(
            label,
            style: AppText.of(context).bodyLarge
                .copyWith(color: skin.textSecondary),
          ),
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
    this.icon = Icons.cloud_off_rounded,
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(skin.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: skin.danger.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: skin.danger, size: 32),
            ),
            SizedBox(height: skin.spaceMd + 2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyLarge.copyWith(
                color: skin.textSecondary,
                height: 1.55,
              ),
            ),
            if (onRetry != null) ...[
              SizedBox(height: skin.spaceLg),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.actionLabel,
  });

  final String message;
  final IconData icon;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(skin.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: skin.textMuted.withValues(alpha: 0.6)),
            SizedBox(height: skin.spaceMd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.of(context).bodyLarge
                  .copyWith(color: skin.textMuted, height: 1.55),
            ),
            if (action != null && actionLabel != null) ...[
              SizedBox(height: skin.spaceLg - 2),
              OutlinedButton(onPressed: action, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.focusNode,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  /// 供页面把方向键导航精确投递到某一项（例如搜索页中栏第一项）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      radius: skin.radiusPill,
      scale: 1.06,
      focusNode: focusNode,
      onTap: onTap,
      child: Builder(
        builder: (context) {
          // smartisan 获焦时 TvFocusable 的填充画在子内容之下，这里的实色
          // 底（surfaceSubtle / accentGradient）会把它盖住、退化成细描边。
          // 获焦反白态下让出底色、文字图标切 textOnAccent（整块换蓝 + 反白）。
          final tinted = TvFocusTint.of(context);
          return AnimatedContainer(
            duration: AppMotion.duration(context, skin.motionFast),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: skin.spaceLg - 4,
              vertical: skin.spaceSm + 2,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(skin.radiusPill),
              gradient: !tinted && selected ? skin.accentGradient : null,
              color: !tinted && !selected ? skin.surfaceSubtle : null,
              border: Border.all(
                color: tinted || selected ? Colors.transparent : skin.border,
              ),
              boxShadow: selected && skin.accentGlow
                  ? [
                      BoxShadow(
                        color: skin.accent.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 18,
                    color: tinted || selected
                        ? skin.textOnAccent
                        : skin.textSecondary,
                  ),
                  const SizedBox(width: 7),
                ],
                Text(
                  label,
                  style: text.bodyStrong.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: tinted || selected
                        ? skin.textOnAccent
                        : skin.textSecondary,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
