import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/ui.dart';

/// A large, top-anchored notice that replaces SnackBar on TV.
///
/// tvOS anti-pattern: a floating toast at the bottom is easy to miss from
/// 10 feet away and competes with the player controls. This banner sits
/// directly under the top tab bar, never takes focus, and stays for 3 seconds.
class TvNotice {
  TvNotice._();

  static OverlayEntry? _entry;

  static void show(BuildContext context, String message, {bool error = false}) {
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    // Only one notice at a time; a newer message replaces the old one.
    _entry?.remove();
    _entry = null;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _NoticeBanner(
        message: message,
        error: error,
        onDone: () {
          if (!identical(_entry, entry)) return;
          entry.remove();
          _entry = null;
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _NoticeBanner extends StatefulWidget {
  const _NoticeBanner({
    required this.message,
    required this.error,
    required this.onDone,
  });

  final String message;
  final bool error;
  final VoidCallback onDone;

  @override
  State<_NoticeBanner> createState() => _NoticeBannerState();
}

class _NoticeBannerState extends State<_NoticeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduced = AppMotion.reduced(context);
    _controller.duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 200);
    _controller.forward();
    _timer = Timer(
      reduced ? const Duration(seconds: 4) : const Duration(seconds: 3),
      _hide,
    );
  }

  Future<void> _hide() async {
    if (!mounted) return;
    await _controller.reverse();
    if (!mounted) return;
    widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    final accent = widget.error ? skin.danger : skin.success;
    return IgnorePointer(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 88),
          child: Align(
            alignment: Alignment.topCenter,
            child: AnimatedBuilder(
              animation: curved,
              builder: (context, child) {
                return Opacity(
                  opacity: curved.value,
                  child: Transform.translate(
                    offset: Offset(0, -8 * (1 - curved.value)),
                    child: child,
                  ),
                );
              },
              child: Semantics(
                liveRegion: true,
                label: widget.message,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 720),
                  margin: EdgeInsets.symmetric(horizontal: skin.spaceLg),
                  padding: EdgeInsets.fromLTRB(
                    skin.spaceMd + 2,
                    skin.spaceSm + 4,
                    skin.spaceLg - 2,
                    skin.spaceSm + 4,
                  ),
                  decoration: BoxDecoration(
                    // 通知条底色跟皮肤面板色、文字跟皮肤文字色（§8.1 面板走
                    // skin），状态色只落在描边与图标上，三皮肤下都自洽可读。
                    color: skin.surface,
                    borderRadius: BorderRadius.circular(skin.radiusMd),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.45),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.error
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 24,
                        color: accent,
                      ),
                      SizedBox(width: skin.spaceSm + 2),
                      Flexible(
                        child: Text(
                          widget.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          // 文字跟皮肤（bodyStrong 默认 skin.textPrimary），
                          // 与改读 skin.surface 的底色配套，三皮肤下自洽。
                          style: AppText.of(context).bodyStrong,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drop-in replacement for `ScaffoldMessenger.showSnackBar` on TV.
void showAppSnack(BuildContext context, String message, {bool error = false}) {
  TvNotice.show(context, message, error: error);
}
