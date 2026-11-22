import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dlna/dlna_control.dart';
import '../../core/dlna/dlna_discovery.dart';
import '../../core/utils.dart';
import '../../theme/ui.dart';
import 'common.dart';

/// 一次投屏的目标：要投的视频直链、标题与起始位置。
class CastTarget {
  const CastTarget({
    required this.url,
    required this.title,
    this.positionMs = 0,
  });

  final String url;
  final String title;
  final int positionMs;
}

/// 设备选择弹窗（中心 Dialog，t9_search_dialog 范式）。
///
/// 选中设备后立刻下发 `SetAVTransportURI → Seek → Play`，三步全部成功才
/// `pop(device)`；失败弹窗内给出中文提示并保留设备列表可重选。
/// [DlnaControlException] 会补充「源可能要求特定请求头」的诚实边界。
/// 关闭后焦点归还 [returnFocus]（FOCUS-07，参照 t9_search_dialog）。
Future<DlnaDevice?> showCastDialog(
  BuildContext context, {
  required CastTarget target,
  FocusNode? returnFocus,
  DlnaDiscovery? discovery,
  DlnaControl? control,
}) async {
  // 触发节点显式传入：requestFocus 下一帧才生效，弹窗内抓 primaryFocus
  // 可能还停在上一个节点上（关闭后就投错地方）。
  final previous = returnFocus ?? FocusManager.instance.primaryFocus;
  final skin = TvSkin.of(context);
  final device = await showDialog<DlnaDevice>(
    context: context,
    barrierDismissible: false,
    // 复用皮肤控制层的黑系遮罩色压暗视频画面。
    barrierColor: skin.controlScrim.colors.first.withValues(alpha: 0.6),
    builder: (_) => _CastDialog(
      target: target,
      discovery: discovery,
      control: control,
    ),
  );
  // FOCUS-07：关闭后焦点回到触发点，等路由收尾帧跑完再投递。
  if (previous != null && previous.context != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (previous.context != null) previous.requestFocus();
    });
  }
  return device;
}

class _CastDialog extends StatefulWidget {
  const _CastDialog({
    required this.target,
    this.discovery,
    this.control,
  });

  final CastTarget target;
  final DlnaDiscovery? discovery;
  final DlnaControl? control;

  @override
  State<_CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<_CastDialog> {
  late final DlnaDiscovery _discovery = widget.discovery ?? DlnaDiscovery();
  late final DlnaControl _control = widget.control ?? DlnaControl();

  bool _scanning = false;
  List<DlnaDevice> _devices = const [];
  DlnaDevice? _pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _devices = const [];
      _error = null;
    });
    try {
      await _discovery.scan(
        // 设备逐台推送：首台到达即刷新列表，不等满 8 秒。
        onDevices: (devices) {
          if (!mounted) return;
          setState(() => _devices = devices);
        },
      );
    } catch (_) {
      // 网络栈异常按空结果处理，空态文案会给出操作建议。
    }
    if (!mounted) return;
    setState(() => _scanning = false);
  }

  Future<void> _connect(DlnaDevice device) async {
    if (_pending != null) return;
    setState(() {
      _pending = device;
      _error = null;
    });
    try {
      await _control.setUri(device, widget.target.url, widget.target.title);
      final positionMs = widget.target.positionMs;
      if (positionMs > 0) {
        try {
          await _control.seek(device, positionMs);
        } catch (_) {
          // 个别渲染器不支持 REL_TIME seek：忽略，从片头播。
        }
      }
      await _control.play(device);
      if (mounted) Navigator.of(context).pop(device);
    } on DlnaControlException catch (error) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _error =
            '${error.message}。该视频源可能要求特定请求头，投屏失败时请改用本机播放。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _error = '投屏连接失败，请重试或改用本机播放';
      });
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape && _pending == null) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Focus(
      onKeyEvent: _handleKey,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(
          horizontal: skin.spaceXl * 2,
          vertical: skin.spaceLg,
        ),
        child: Container(
          width: 600,
          padding: EdgeInsets.fromLTRB(
            skin.spaceLg + 2,
            skin.spaceLg,
            skin.spaceLg + 2,
            skin.spaceLg - 2,
          ),
          decoration: BoxDecoration(
            // 弹窗本体成对读取皮肤（t9 范式）：遮罩已把视频压暗，亮色面板
            // 在三套皮肤下都可读。
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
                  Icon(Icons.cast_rounded, size: 24, color: skin.textSecondary),
                  SizedBox(width: skin.spaceSm),
                  Expanded(
                    child: Text('投屏到设备', style: text.bodyLarge.copyWith(
                      fontWeight: FontWeight.w800,
                    )),
                  ),
                  _refreshButton(skin, text),
                  SizedBox(width: skin.spaceSm),
                  _closeButton(skin),
                ],
              ),
              SizedBox(height: skin.spaceSm + 2),
              // 主体自定高度（列表有 ConstrainedBox 上限），不用 Expanded：
              // Dialog 高度由内容撑开。
              _body(skin, text),
              if (_error != null) ...[
                SizedBox(height: skin.spaceSm),
                Text(
                  _error!,
                  style: text.label.copyWith(color: skin.danger, height: 1.5),
                ),
              ],
              SizedBox(height: skin.spaceSm + 2),
              Text(
                '投屏通过 DLNA 直接传输视频地址，无法携带站点请求头，部分源可能播放失败',
                style: text.meta.copyWith(color: skin.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Column 主体：连接中 / 扫描中 / 空态 / 设备列表。
  Widget _body(TvSkin skin, TvTextScale text) {
    final pending = _pending;
    if (pending != null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: skin.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
            SizedBox(height: skin.spaceMd),
            Text('正在连接 ${pending.friendlyName}…', style: text.bodyStrong),
          ],
        ),
      );
    }
    if (_devices.isEmpty) {
      if (_scanning) {
        return Padding(
          padding: EdgeInsets.symmetric(vertical: skin.spaceXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
              SizedBox(height: skin.spaceMd),
              Text('正在搜索局域网投屏设备…', style: text.bodyStrong),
            ],
          ),
        );
      }
      return Padding(
        padding: EdgeInsets.symmetric(vertical: skin.spaceLg),
        child: Text(
          '未发现局域网投屏设备，请确认电视与设备在同一网络',
          textAlign: TextAlign.center,
          style: text.body.copyWith(color: skin.textMuted, height: 1.5),
        ),
      );
    }
    return _listArea(skin, text);
  }

  /// 设备列表：固定上限高度，避免设备多时把弹窗顶出屏幕。
  Widget _listArea(TvSkin skin, TvTextScale text) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _devices.length,
        separatorBuilder: (_, _) => SizedBox(height: skin.spaceSm),
        itemBuilder: (context, index) {
          final device = _devices[index];
          return _deviceRow(skin, text, device, autofocus: index == 0);
        },
      ),
    );
  }

  Widget _deviceRow(TvSkin skin, TvTextScale text, DlnaDevice device,
      {bool autofocus = false}) {
    return TvFocusable(
      autofocus: autofocus,
      radius: skin.radiusSm,
      scale: 1.02,
      semanticLabel: '投屏到 ${device.friendlyName}',
      onTap: () => _connect(device),
      child: Builder(
        builder: (context) {
          // smartisan 获焦填充画在子内容之下：反白态让出实色底、
          // 文字图标切 textOnAccent（TvFocusTint 契约，参照 GlassChip）。
          final tinted = TvFocusTint.of(context);
          return SkinSurface(
            enableBlur: false,
            radius: skin.radiusSm,
            tint: tinted ? Colors.transparent : skin.surfaceSubtle,
            padding: EdgeInsets.symmetric(
              horizontal: skin.spaceMd,
              vertical: skin.spaceSm + 2,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.tv_rounded,
                  size: 22,
                  color: tinted ? skin.textOnAccent : skin.textSecondary,
                ),
                SizedBox(width: skin.spaceSm),
                Expanded(
                  child: Text(
                    device.friendlyName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyStrong.copyWith(
                      color: tinted ? skin.textOnAccent : skin.textPrimary,
                    ),
                  ),
                ),
                if (device.productName != null &&
                    device.productName!.isNotEmpty) ...[
                  SizedBox(width: skin.spaceSm),
                  Text(
                    device.productName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.meta.copyWith(color: skin.textMuted),
                  ),
                ],
                SizedBox(width: skin.spaceSm),
                Icon(
                  Icons.cast_connected_rounded,
                  size: 20,
                  color: tinted ? skin.textOnAccent : skin.textMuted,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _refreshButton(TvSkin skin, TvTextScale text) {
    return TvFocusable(
      radius: skin.radiusPill,
      scale: 1.02,
      semanticLabel: '重新扫描设备',
      onTap: _scan,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceMd - 2,
          vertical: skin.spaceXs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh_rounded, size: 18, color: skin.textSecondary),
            SizedBox(width: skin.spaceXs),
            Text('重新扫描', style: text.label.copyWith(color: skin.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _closeButton(TvSkin skin) {
    return TvFocusable(
      // 兜底焦点落点（FOCUS-06）：设备行挂载后 autofocus 会自然接管。
      autofocus: true,
      radius: skin.radiusPill,
      semanticLabel: '关闭投屏弹窗',
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: skin.surface,
          shape: BoxShape.circle,
          border: Border.all(color: skin.borderSoft),
        ),
        child: Icon(Icons.close_rounded, size: 18, color: skin.textSecondary),
      ),
    );
  }
}

/// 投屏中控制面板（覆盖播放页）。
///
/// 材质遵循 AGENTS.md §8.3 播放器控制层策略：全屏遮罩读
/// `skin.controlScrim`，前景钉黑白（smartisan 亮色皮肤的深字压视频
/// 不可读），面板外壳走 `SkinSurface`（完整读皮肤底色/描边），内层
/// `ColoredBox(skin.controlScrim.colors.last)` 局部衬底保证白字对比度。
/// 进度每 2 秒轮询 `GetPositionInfo`，左右键 ±10 秒 Seek，返回键
/// = 「回到本机播放」（由 [onExitLocal] 结束投屏并续播本机）。
class CastControlPanel extends StatefulWidget {
  const CastControlPanel({
    super.key,
    required this.device,
    required this.control,
    required this.onExitLocal,
    required this.onStopped,
    this.focusScope,
    this.onPositionChanged,
    this.onPlayingChanged,
  });

  final DlnaDevice device;

  final DlnaControl control;

  /// 回到本机播放：调用方停止投屏并按 [onPositionChanged] 报告的进度续播。
  final VoidCallback onExitLocal;

  /// 结束投屏（本机保持暂停）。
  final VoidCallback onStopped;

  /// 页面持有的焦点作用域：焦点意外飘出面板时由页面重投回来。
  final FocusScopeNode? focusScope;

  final ValueChanged<int>? onPositionChanged;
  final ValueChanged<bool>? onPlayingChanged;

  @override
  State<CastControlPanel> createState() => _CastControlPanelState();
}

class _CastControlPanelState extends State<CastControlPanel> {
  static const _pollInterval = Duration(seconds: 2);
  static const _seekStepSeconds = 10;

  int _positionMs = 0;
  int _durationMs = 0;
  bool _playing = true;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted || _busy) return;
    _busy = true;
    try {
      final info = await widget.control.positionInfo(widget.device);
      final state = await widget.control.transportInfo(widget.device);
      if (!mounted) return;
      final playing = state == 'PLAYING';
      setState(() {
        _positionMs = info.positionMs;
        _durationMs = info.durationMs;
        _playing = playing;
      });
      widget.onPositionChanged?.call(info.positionMs);
      widget.onPlayingChanged?.call(playing);
    } catch (_) {
      // 轮询失败静默：设备短暂离线不打断面板，下一轮再试。
    } finally {
      _busy = false;
    }
  }

  Future<void> _togglePlay() async {
    if (_busy) return;
    _busy = true;
    final next = !_playing;
    setState(() => _playing = next);
    try {
      if (next) {
        await widget.control.play(widget.device);
      } else {
        await widget.control.pause(widget.device);
      }
      widget.onPlayingChanged?.call(next);
    } catch (_) {
      if (mounted) setState(() => _playing = !next);
    } finally {
      _busy = false;
    }
  }

  Future<void> _seekRelative(int seconds) async {
    if (_busy) return;
    final maxMs = _durationMs > 0 ? _durationMs : 1 << 40;
    final target = (_positionMs + seconds * 1000).clamp(0, maxMs);
    setState(() => _positionMs = target);
    widget.onPositionChanged?.call(target);
    try {
      await widget.control.seek(widget.device, target);
    } catch (_) {
      // 设备不支持 seek：本地进度显示以轮询值为准，下一轮自动回正。
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      // 返回 = 结束投屏并回到本机播放（弹层关闭语义）。
      widget.onExitLocal();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return FocusScope(
      node: widget.focusScope,
      child: Focus(
        onKeyEvent: _handleKey,
        child: DecoratedBox(
          // 全屏遮罩：controlScrim（三皮肤均为黑系，§8.3）。
          decoration: BoxDecoration(gradient: skin.controlScrim),
          child: Center(
            child: SkinSurface(
              floating: true,
              radius: skin.radiusLg,
              padding: EdgeInsets.all(skin.spaceSm + 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(skin.radiusLg),
                // §8.3 胶囊同款：外壳跟皮肤材质，内容区衬控制遮罩深底，
                // 白前景三皮肤可读。
                child: ColoredBox(
                  color: skin.controlScrim.colors.last,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: skin.spaceLg,
                        vertical: skin.spaceLg,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _headerRow(text),
                          SizedBox(height: skin.spaceLg),
                          _progressRow(skin, text),
                          SizedBox(height: skin.spaceLg),
                          _buttonRow(skin, text),
                          SizedBox(height: skin.spaceMd),
                          Text(
                            '正在通过 ${widget.device.friendlyName} 播放 · DLNA 不携带站点请求头，失败时请回到本机播放',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.meta.copyWith(
                              color: Colors.white.withValues(alpha: 0.55),
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
        ),
      ),
    );
  }

  /// 设备名 + 投屏状态行。前景恒白（§8.3：压在视频遮罩上）。
  Widget _headerRow(TvTextScale text) {
    return Row(
      children: [
        const Icon(Icons.cast_connected_rounded, size: 24, color: Colors.white),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            widget.device.friendlyName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.section.copyWith(color: Colors.white),
          ),
        ),
        Text(
          _playing ? '投屏中 · 播放' : '投屏中 · 已暂停',
          style: text.label.copyWith(
            color: Colors.white.withValues(alpha: 0.72),
          ),
        ),
      ],
    );
  }

  /// 进度行：左右键 ±10 秒（长按连发），OK 切播放/暂停。
  Widget _progressRow(TvSkin skin, TvTextScale text) {
    final progress = _durationMs > 0
        ? (_positionMs / _durationMs).clamp(0.0, 1.0)
        : 0.0;
    return TvFocusable(
      radius: skin.radiusPill,
      // 全宽轨道不缩放，避免越出内容列（进度条同款约束）。
      scale: 1,
      allowKeyRepeat: true,
      semanticLabel:
          '投屏进度，左右键快退或快进 $_seekStepSeconds 秒，确定键播放或暂停',
      onTap: _togglePlay,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _seekRelative(-_seekStepSeconds);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _seekRelative(_seekStepSeconds);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceSm,
          vertical: skin.spaceSm,
        ),
        child: Column(
          children: [
            SizedBox(
              height: 8,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(skin.radiusPill),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress,
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: skin.spaceSm - 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatMilliseconds(_positionMs),
                  style: text.bodyLarge.copyWith(color: Colors.white),
                ),
                Text(
                  _durationMs > 0 ? formatMilliseconds(_durationMs) : '--:--',
                  style: text.bodyLarge.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buttonRow(TvSkin skin, TvTextScale text) {
    return Row(
      children: [
        _pillButton(
          icon: _playing
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          label: _playing ? '暂停' : '播放',
          autofocus: true,
          onTap: _togglePlay,
        ),
        SizedBox(width: skin.spaceLg),
        _pillButton(
          icon: Icons.tv_rounded,
          label: '回到本机播放',
          onTap: widget.onExitLocal,
        ),
        SizedBox(width: skin.spaceLg),
        _pillButton(
          icon: Icons.stop_circle_outlined,
          label: '结束投屏',
          onTap: widget.onStopped,
        ),
      ],
    );
  }

  /// 胶囊按钮：白前景（§8.3 压视频硬约束），焦点语言交给 [TvFocusable]。
  Widget _pillButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool autofocus = false,
  }) {
    final skin = TvSkin.of(context);
    return TvFocusable(
      autofocus: autofocus,
      radius: skin.radiusPill,
      semanticLabel: label,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: skin.spaceLg - 4,
          vertical: skin.spaceSm + 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: Colors.white),
            SizedBox(width: AppSpacing.sm),
            Text(
              label,
              style: AppText.of(context).bodyLarge.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
