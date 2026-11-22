import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/ui.dart';
import 'common.dart';

/// T9 遥控器搜索键盘（手机九宫格布局的 TV 版）。
///
/// - 3×4 键位：`1` 常用符号、`2 ABC` … `9 WXYZ`、底行 `输入法 / 0 空格 / 退格`；
/// - 多击循环：900ms 内重复按同一键依次取下一个字符（2 → A → B → C → 2），
///   按其它键立即提交当前字符并开始新循环；
/// - 输出的是字母/数字，交给页面拼进搜索框，拼音首字母联想照常工作。
class TvSearchKeyboard extends StatefulWidget {
  const TvSearchKeyboard({
    super.key,
    required this.onKey,
    this.resetSignal,
    this.autofocus = false,
    this.entryFocus,
    this.lastRowFocus,
    this.upFocus,
    this.downFocus,
  });

  /// 回调值：普通字符；[scan] 打开手机远程搜索；[backspace] 删除末位。
  /// [replace] 为 true 时表示多击循环，应替换末位字符而不是追加。
  final void Function(String key, {bool replace}) onKey;

  /// 页面在非键盘来源改写输入框后 +1：键盘据此重置多击循环
  /// （remote_input P1-3，历史/联想/清空/远程注入/提交回写都会触发）。
  /// 为 null（独立使用/测试）时不监听。
  final ValueListenable<int>? resetSignal;

  /// 弹窗等独立场景：键位挂载后把焦点投到第一个数字键（FOCUS-06）。
  /// 页面内嵌键盘不需要（焦点由页面入口节点负责）。
  final bool autofocus;
  final FocusNode? entryFocus;
  final FocusNode? lastRowFocus;
  final FocusNode? upFocus;
  final FocusNode? downFocus;

  static const String backspace = '\u0008';
  static const String scan = '\u0000';

  /// 多击循环窗口：超时后同一键重新从第一个字符开始。
  static const Duration cycleWindow = Duration(milliseconds: 900);

  /// T9 键位映射：数字 -> 多击循环字符（字母在前，数字收尾）。
  static const Map<String, List<String>> _groups = {
    '1': ['1', '.', '-', '?', '!'],
    '2': ['A', 'B', 'C', '2'],
    '3': ['D', 'E', 'F', '3'],
    '4': ['G', 'H', 'I', '4'],
    '5': ['J', 'K', 'L', '5'],
    '6': ['M', 'N', 'O', '6'],
    '7': ['P', 'Q', 'R', 'S', '7'],
    '8': ['T', 'U', 'V', '8'],
    '9': ['W', 'X', 'Y', 'Z', '9'],
    '0': ['0', ' '],
  };

  @override
  State<TvSearchKeyboard> createState() => _TvSearchKeyboardState();
}

class _TvSearchKeyboardState extends State<TvSearchKeyboard> {
  // 数字三行与功能行共用稳定的 4×3 坐标，不使用几何遍历的方向历史。
  final List<FocusNode> _nodes = List.generate(
    12,
    (index) => FocusNode(debugLabel: 't9-key-$index'),
  );
  FocusNode _node(int index) => switch (index) {
    0 => widget.entryFocus ?? _nodes[index],
    10 => widget.lastRowFocus ?? _nodes[index],
    _ => _nodes[index],
  };

  KeyEventResult _handleDirection(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final index = List.generate(12, _node).indexWhere((item) => item.hasFocus);
    if (index < 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    FocusNode? target;
    if (key == LogicalKeyboardKey.arrowUp) {
      target = index >= 3 ? _node(index - 3) : widget.upFocus;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      target = index < 9 ? _node(index + 3) : widget.downFocus;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (index % 3 > 0) target = _node(index - 1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (index % 3 < 2) target = _node(index + 1);
    } else {
      return KeyEventResult.ignored;
    }
    if (target != null && target.canRequestFocus) {
      target.requestFocus();
      return KeyEventResult.handled;
    }
    // 嵌入页面的上下边界继续交给页面；左右边界不能串行或逃出弹窗。
    return key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  String? _cycleKey;
  int _cycleIndex = 0;
  Timer? _cycleTimer;

  @override
  void initState() {
    super.initState();
    widget.resetSignal?.addListener(_resetCycle);
  }

  @override
  void didUpdateWidget(covariant TvSearchKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetSignal != widget.resetSignal) {
      oldWidget.resetSignal?.removeListener(_resetCycle);
      widget.resetSignal?.addListener(_resetCycle);
    }
  }

  @override
  void dispose() {
    widget.resetSignal?.removeListener(_resetCycle);
    _cycleTimer?.cancel();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _resetCycle() {
    _cycleTimer?.cancel();
    _cycleTimer = null;
    _cycleKey = null;
    _cycleIndex = 0;
  }

  void _tapDigit(String digit) {
    final chars = TvSearchKeyboard._groups[digit]!;
    final cycling = _cycleKey == digit;
    _cycleIndex = cycling ? (_cycleIndex + 1) % chars.length : 0;
    _cycleKey = digit;
    widget.onKey(chars[_cycleIndex], replace: cycling);
    _cycleTimer?.cancel();
    _cycleTimer = Timer(TvSearchKeyboard.cycleWindow, _resetCycle);
  }

  @override
  Widget build(BuildContext context) {
    final keyGap = TvSkin.of(context).spaceSm;
    return Focus(
      skipTraversal: true,
      onKeyEvent: _handleDirection,
      child: Column(
        children: [
          for (final (rowIndex, row) in [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ].indexed) ...[
            Expanded(
              child: Padding(
                // 按键放大时仍留出清晰分隔，避免焦点态与邻键贴合。
                padding: EdgeInsets.symmetric(horizontal: keyGap / 2),
                child: Row(
                  children: [
                    for (var i = 0; i < row.length; i++) ...[
                      if (i > 0) SizedBox(width: keyGap),
                      Expanded(
                        child: _DigitKey(
                          digit: row[i],
                          focusNode: _node(int.parse(row[i]) - 1),
                          onTap: _tapDigit,
                          autofocus: widget.autofocus && row[i] == '1',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (rowIndex < 2) SizedBox(height: keyGap),
          ],
          SizedBox(height: keyGap),
          SizedBox(
            height: 62,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: keyGap / 2),
              child: Row(
                children: [
                  Expanded(
                    child: _FunctionKey(
                      label: '扫码',
                      focusNode: _node(9),
                      icon: Icons.qr_code_2_rounded,
                      onTap: () {
                        _resetCycle();
                        widget.onKey(TvSearchKeyboard.scan);
                      },
                    ),
                  ),
                  SizedBox(width: keyGap),
                  Expanded(
                    child: _DigitKey(
                      digit: '0',
                      focusNode: _node(10),
                      onTap: _tapDigit,
                      hint: '空格',
                    ),
                  ),
                  SizedBox(width: keyGap),
                  Expanded(
                    child: _FunctionKey(
                      label: '退格',
                      focusNode: _node(11),
                      icon: Icons.backspace_outlined,
                      onTap: () {
                        _resetCycle();
                        widget.onKey(TvSearchKeyboard.backspace);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({
    required this.digit,
    required this.onTap,
    this.hint,
    this.autofocus = false,
    required this.focusNode,
  });

  final String digit;
  final ValueChanged<String> onTap;
  final String? hint;
  final bool autofocus;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final letters = switch (digit) {
      '1' => hint ?? '符',
      '0' => hint ?? '空格',
      _ =>
        TvSearchKeyboard._groups[digit]!
            .take(TvSearchKeyboard._groups[digit]!.length - 1)
            .join(),
    };
    return TvFocusable(
      focusNode: focusNode,
      radius: skin.radiusSm + 2,
      scale: 1.04,
      autofocus: autofocus,
      semanticLabel: '键 $digit $letters',
      onTap: () => onTap(digit),
      child: Container(
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusSm + 2),
          border: Border.all(color: skin.borderSoft),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              digit,
              style: text.section.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              letters,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.meta.copyWith(
                letterSpacing: 1.2,
                color: skin.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FunctionKey extends StatelessWidget {
  const _FunctionKey({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.focusNode,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return TvFocusable(
      focusNode: focusNode,
      radius: skin.radiusSm + 2,
      scale: 1.04,
      semanticLabel: label,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusSm + 2),
          border: Border.all(color: skin.borderSoft),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: skin.textSecondary),
            SizedBox(width: skin.spaceXs + 1),
            Text(label, style: AppText.of(context).bodyStrong),
          ],
        ),
      ),
    );
  }
}
