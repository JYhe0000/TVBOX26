import 'package:flutter/material.dart';

import '../theme/skin.dart';

/// Fixed 1280×720 design canvas, uniformly scaled to the real screen.
///
/// 720p / 1080p / 4K 16:9 panels render the same layout at different scales.
/// Other aspect ratios keep the full canvas undistorted via `contain`, leaving
/// unused bars in the active skin's background color rather than stretching or
/// cropping the design; layouts do not expand to consume those bars.
///
/// Inside the canvas the [MediaQuery] is rewritten:
/// - `size` is pinned to the design canvas;
/// - system `padding` / `viewPadding` are zeroed (immersive sticky mode means
///   no status or navigation bars on Android TV);
/// - `viewInsets` are kept but converted into canvas coordinates, so software
///   keyboards (e.g. the Leanback IME panel) still push content correctly;
/// - `textScaler` is preserved so user font scaling still applies.
class TvCanvas extends StatelessWidget {
  const TvCanvas({super.key, required this.child});

  /// Design canvas width in logical pixels.
  static const double designWidth = 1280;

  /// Design canvas height in logical pixels.
  static const double designHeight = 720;

  /// Scale factor applied on the current screen (1.0 at 1280×720,
  /// 1.5 at 1080p, 3.0 at 4K).
  static double scaleOf(BuildContext context) =>
      _fitScale(MediaQuery.sizeOf(context));

  /// Horizontal page margin for browse / search / mine screens.
  static const double pagePad = 40.0;

  /// Horizontal page margin for the live two-column screen.
  static const double livePad = 28.0;

  /// Horizontal page margin for detail (content column 1280 − 2×80 = 1120).
  static const double detailPad = 80.0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = _fitScale(media.size);
    final background = TvSkin.maybeOf(context)?.bg ??
        Theme.of(context).colorScheme.surface;
    return ColoredBox(
      color: background,
      child: FittedBox(
        fit: BoxFit.contain,
        clipBehavior: Clip.none,
        child: SizedBox(
          width: designWidth,
          height: designHeight,
          child: MediaQuery(
            data: media.copyWith(
              size: const Size(designWidth, designHeight),
              padding: EdgeInsets.zero,
              viewPadding: EdgeInsets.zero,
              viewInsets: media.viewInsets / scale,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  /// The uniform scale [FittedBox] applies for BoxFit.contain on this screen.
  static double _fitScale(Size screen) {
    final sx = screen.width / designWidth;
    final sy = screen.height / designHeight;
    return sx < sy ? sx : sy;
  }
}
