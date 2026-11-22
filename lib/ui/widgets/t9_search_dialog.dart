import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/ui.dart';
import 'common.dart';
import 'tv_keyboard.dart';

/// 中间弹窗式 T9 搜索（直播频道搜索等）。
///
/// 弹窗里**没有任何 TextField**：只用遥控器九宫格输入，所以不会拉起系统
/// 软键盘（电视上软键盘既挡住画面又抢方向键）。键盘底行「扫码」交给
/// [onScan]，由调用方复用手机远程输入二维码（[TvSearchKeyboard.scan]）。
///
/// 每次按键通过 [onChanged] 实时回写（列表边输边筛），关闭后焦点还给
/// 打开弹窗前的节点（FOCUS-07），而不是落回页面根。
Future<void> showT9SearchDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '输入名称或拼音首字母',
  ValueChanged<String>? onChanged,
  VoidCallback? onScan,
  FocusNode? returnFocus,
}) async {
  // 触发节点由调用方显式传入：`requestFocus` 要到下一帧才生效，弹窗内
  // 抓 `primaryFocus` 可能还停在上一个节点上（关闭后就投错地方）。
  final previous = returnFocus ?? FocusManager.instance.primaryFocus;
  final skin = TvSkin.of(context);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    // 复用皮肤控制层的黑系遮罩色，保持底层内容压暗。
    barrierColor: skin.controlScrim.colors.first.withValues(alpha: 0.6),
    builder: (_) => _T9SearchDialog(
      title: title,
      initial: initial,
      hint: hint,
      onChanged: onChanged,
      onScan: onScan,
    ),
  );
  // FOCUS-07：关闭后焦点回到触发点。要等这一帧的路由收尾（ModalRoute 会把
  // 焦点还给下层 scope）跑完再投递，否则会被路由的恢复逻辑覆盖。
  if (previous != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (previous.context != null) previous.requestFocus();
    });
  }
}

class _T9SearchDialog extends StatefulWidget {
  const _T9SearchDialog({
    required this.title,
    required this.initial,
    required this.hint,
    this.onChanged,
    this.onScan,
  });

  final String title;
  final String initial;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onScan;

  @override
  State<_T9SearchDialog> createState() => _T9SearchDialogState();
}

class _T9SearchDialogState extends State<_T9SearchDialog> {
  late String _text = widget.initial;
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'dialog-t9');
  final FocusNode _firstKey = FocusNode(debugLabel: 't9-entry');
  final FocusNode _lastRow = FocusNode(debugLabel: 't9-last-row');
  final FocusNode _clearFocus = FocusNode(debugLabel: 't9-clear');
  final FocusNode _doneFocus = FocusNode(debugLabel: 't9-done');

  /// 清空等非键盘来源改写后 +1，重置 T9 多击循环（对照搜索页 `_kbReset`）。
  final ValueNotifier<int> _cycleReset = ValueNotifier<int>(0);

  /// 弹窗根键盘处理：BACK/ESC 关弹窗（spec §3 按键矩阵——BACK 在覆盖层
  /// 本层解决并消费，不透传给路由/壳层造成「多退一格」）。
  KeyEventResult _handleDialogKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _cycleReset.dispose();
    _scope.dispose();
    _firstKey.dispose();
    _lastRow.dispose();
    _clearFocus.dispose();
    _doneFocus.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged?.call(_text);

  void _onKey(String key, {bool replace = false}) {
    if (key == TvSearchKeyboard.scan) {
      widget.onScan?.call();
      return;
    }
    if (key == TvSearchKeyboard.backspace) {
      if (_text.isEmpty) return;
      setState(() => _text = _text.substring(0, _text.length - 1));
    } else if (replace && _text.isNotEmpty) {
      // T9 多击循环：同键连按替换末位字符。
      setState(() => _text = _text.substring(0, _text.length - 1) + key);
    } else {
      setState(() => _text = _text + key);
    }
    _emit();
  }

  void _clear() {
    if (_text.isEmpty) return;
    setState(() => _text = '');
    _cycleReset.value++;
    // 清空按钮即将卸载，立即把焦点交还稳定的键盘节点。
    _firstKey.requestFocus();
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final titleStyle = AppText.resolve(
      skin,
      AppText.bodyLargeSize + 3,
      FontWeight.w800,
      1.2,
    );
    return FocusScope(
      node: _scope,
      // 弹窗根监听 BACK/ESC：组件层（TvFocusable 只处理 OK）不消费这些键，
      // 冒泡到这里在本层关闭弹窗并消费，符合「覆盖层 BACK 本层解决」。
      onKeyEvent: _handleDialogKey,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(
          horizontal: skin.spaceXl * 2,
          vertical: skin.spaceLg,
        ),
        child: Container(
          width: 560,
          padding: EdgeInsets.fromLTRB(
            skin.spaceLg + 2,
            skin.spaceLg,
            skin.spaceLg + 2,
            skin.spaceLg - 2,
          ),
          decoration: BoxDecoration(
            // 普通搜索弹窗的面板与文字成对读取皮肤，兼容亮色主题。
            color: skin.surface.withValues(alpha: 247 / 255),
            borderRadius: BorderRadius.circular(skin.radiusLg),
            border: Border.all(color: skin.surfaceSkin.panelBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 40,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: Text(widget.title, style: titleStyle)),
                  Text(
                    '扫码可用手机输入',
                    style: text.meta.copyWith(color: skin.textMuted),
                  ),
                ],
              ),
              SizedBox(height: skin.spaceSm),
              // 当前输入只做展示：这里刻意不用 TextField，避免系统软键盘。
              Container(
                height: 52,
                padding: EdgeInsets.symmetric(horizontal: skin.spaceMd),
                decoration: BoxDecoration(
                  color: skin.surfaceSubtle,
                  borderRadius: BorderRadius.circular(skin.radiusSm + 1),
                  border: Border.all(color: skin.borderSoft),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: skin.textSecondary,
                    ),
                    SizedBox(width: skin.spaceXs + 2),
                    Expanded(
                      child: Text(
                        _text.isEmpty ? widget.hint : _text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _text.isEmpty
                            ? text.body.copyWith(color: skin.textMuted)
                            : text.bodyStrong,
                      ),
                    ),
                    if (_text.isNotEmpty) ...[
                      SizedBox(width: skin.spaceXs),
                      TvFocusable(
                        focusNode: _clearFocus,
                        onKeyEvent: (event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown) {
                            _firstKey.requestFocus();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        radius: skin.radiusPill,
                        scale: 1.0,
                        semanticLabel: '清空输入',
                        onTap: _clear,
                        child: Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: skin.surface,
                            shape: BoxShape.circle,
                            border: Border.all(color: skin.borderSoft),
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: skin.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: skin.spaceSm + 2),
              SizedBox(
                height: 288,
                child: TvSearchKeyboard(
                  autofocus: true,
                  entryFocus: _firstKey,
                  lastRowFocus: _lastRow,
                  upFocus: _text.isNotEmpty ? _clearFocus : _doneFocus,
                  downFocus: _doneFocus,
                  onKey: _onKey,
                  resetSignal: _cycleReset,
                ),
              ),
              SizedBox(height: skin.spaceSm + 2),
              TvFocusable(
                focusNode: _doneFocus,
                onKeyEvent: (event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    _lastRow.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    _firstKey.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                radius: skin.radiusSm,
                scale: 1.02,
                semanticLabel: '完成',
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: skin.accentGradient,
                    borderRadius: BorderRadius.circular(skin.radiusSm),
                  ),
                  child: Text(
                    '完 成',
                    style: text.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: skin.textOnAccent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
