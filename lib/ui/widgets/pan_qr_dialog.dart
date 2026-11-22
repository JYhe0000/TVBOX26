import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/pan/pan_account.dart';
import '../../data/pan/pan_provider.dart';
import '../../data/pan/pan_qr_login.dart';
import '../../theme/ui.dart';
import 'common.dart';

/// 网盘扫码登录弹窗：电视端展示二维码，手机 App 扫码确认后回传
/// [PanAccount]（阿里 refresh_token / 夸克 Cookie / 百度 BDUSS Cookie）。
///
/// 视觉沿用 [showConfigUrlDialog] 的「深底 + 钉死白字」控件层策略
/// （§8.3）：smartisan 亮底会把白字/白底二维码撞掉，故不跟皮肤底色，
/// 只有字号、圆角、间距读 token。
///
/// 返回 null 表示用户取消或扫码过期未重试。
Future<PanAccount?> showPanQrLogin(
  BuildContext context,
  PanProviderId provider, {
  PanQrLogin? login,
}) {
  return showDialog<PanAccount>(
    context: context,
    barrierDismissible: true,
    // 遮罩恒为黑系半透明（§8.3 压内容的钉死色）。
    barrierColor: const Color(0x99000000),
    builder: (_) => _PanQrDialog(provider: provider, login: login),
  );
}

class _PanQrDialog extends StatefulWidget {
  const _PanQrDialog({required this.provider, this.login});

  final PanProviderId provider;

  /// 测试注入用；生产为 null（内部按默认域名创建）。
  final PanQrLogin? login;

  @override
  State<_PanQrDialog> createState() => _PanQrDialogState();
}

class _PanQrDialogState extends State<_PanQrDialog> {
  /// 轮询间隔：三家接口都是秒级状态，2s 兼顾及时性与请求量。
  static const Duration _pollInterval = Duration(seconds: 2);

  late final PanQrLogin _login = widget.login ?? PanQrLogin();

  PanQrSession? _session;
  PanQrState _state = PanQrState.waiting;
  String? _message;
  Timer? _timer;
  bool _polling = false;

  /// 会话代次：重新生成后旧请求的回包直接丢弃，避免覆盖新二维码状态。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    // 首帧后再发起请求：`_start` 里的 setState 总在挂载完成后执行。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _session = null;
      _state = PanQrState.waiting;
      _message = null;
    });
    try {
      final session = await _login.create(widget.provider);
      if (!mounted || generation != _generation) return;
      setState(() => _session = session);
      _timer = Timer.periodic(_pollInterval, (_) => _poll(generation));
    } on PanException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = PanQrState.error;
        _message = error.message;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = PanQrState.error;
        _message = '二维码生成失败，请稍后重试或改用手动粘贴凭据';
      });
    }
  }

  Future<void> _poll(int generation) async {
    final session = _session;
    if (_polling || session == null) return;
    _polling = true;
    try {
      final result = await _login.poll(session);
      if (!mounted || generation != _generation) return;
      if (result.state == PanQrState.confirmed && result.account != null) {
        _timer?.cancel();
        Navigator.of(context).pop(result.account);
        return;
      }
      setState(() {
        _state = result.state;
        _message = result.message;
      });
      if (result.state == PanQrState.expired ||
          result.state == PanQrState.error) {
        _timer?.cancel();
      }
    } finally {
      _polling = false;
    }
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
    final label = widget.provider.label;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        padding: EdgeInsets.fromLTRB(
          skin.spaceLg + 2,
          skin.spaceLg,
          skin.spaceLg + 2,
          skin.spaceLg - 2,
        ),
        decoration: BoxDecoration(
          // 控件层恒深底（§8.3 压内容 / 浮层的钉死色豁免）。
          color: const Color(0xF70C0E15),
          borderRadius: BorderRadius.circular(skin.radiusLg),
          border: Border.all(
            color: skin.surfaceSkin.panelBorderWidth == 0
                ? Colors.white.withValues(alpha: 0.12)
                : skin.surfaceSkin.panelBorder,
          ),
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
            Text(
              '$label · 扫码登录',
              style: titleStyle.copyWith(color: Colors.white),
            ),
            SizedBox(height: skin.spaceXs),
            Text(
              '用手机 $label App 扫码并在手机上确认。凭据只保存在本机，电视端不保存账号密码。',
              style: text.label.copyWith(
                height: 1.7,
                color: Colors.white.withValues(alpha: 0.78),
              ),
            ),
            SizedBox(height: skin.spaceMd),
            Center(child: _qr(skin, text)),
            SizedBox(height: skin.spaceSm),
            Center(child: _statusLine(skin, text)),
            SizedBox(height: skin.spaceSm + 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TvFocusable(
                  radius: skin.radiusSm,
                  scale: 1.02,
                  semanticLabel: '刷新二维码',
                  onTap: _start,
                  child: Container(
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(
                      horizontal: skin.spaceLg,
                      vertical: skin.spaceSm + 2,
                    ),
                    decoration: BoxDecoration(
                      color: skin.accent.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(skin.radiusSm),
                      border: Border.all(
                        color: skin.accent.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Text(
                      _state == PanQrState.expired || _state == PanQrState.error
                          ? '重新生成二维码'
                          : '刷新二维码',
                      style: text.bodyStrong.copyWith(color: Colors.white),
                    ),
                  ),
                ),
                SizedBox(width: skin.spaceSm),
                // 进弹窗默认焦点落在「关闭」上（FOCUS-06：每屏唯一可见焦点；
                // 等待扫码期间用户唯一合理动作是退出）。
                TvFocusable(
                  autofocus: true,
                  radius: skin.radiusSm,
                  scale: 1.02,
                  semanticLabel: '关闭',
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(
                      horizontal: skin.spaceLg,
                      vertical: skin.spaceSm + 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(skin.radiusSm),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.32),
                      ),
                    ),
                    child: Text(
                      '关闭',
                      style: text.bodyStrong.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: skin.spaceSm),
            Text(
              '扫码走网页端登录接口，厂商改版时可能失效；失败可在上一级改用手动粘贴凭据。',
              style: text.meta.copyWith(
                height: 1.5,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qr(TvSkin skin, TvTextScale text) {
    final session = _session;
    // 二维码必须纯白底（三皮肤统一），否则手机识别率下降。
    final box = Container(
      width: 192,
      height: 192,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(skin.radiusSm + 2),
      ),
      child: session == null
          ? Center(
              child: Text(
                '正在获取二维码…',
                style: text.meta.copyWith(color: Colors.black54),
              ),
            )
          : session.qrIsImage
          ? Image.network(
              session.qrContent,
              fit: BoxFit.contain,
              // 二维码是唯一登录入口，加载失败必须给出可操作提示。
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              errorBuilder: (context, error, stack) => Center(
                child: Text(
                  '二维码图片加载失败\n请点「刷新二维码」',
                  textAlign: TextAlign.center,
                  style: text.meta.copyWith(color: Colors.black54),
                ),
              ),
            )
          : QrImageView(
              data: session.qrContent,
              version: QrVersions.auto,
              gapless: true,
            ),
    );
    return box;
  }

  Widget _statusLine(TvSkin skin, TvTextScale text) {
    final (color, message) = switch (_state) {
      PanQrState.waiting => (skin.success, '等待手机扫码…'),
      PanQrState.scanned => (skin.warning, '已扫码，请在手机上确认'),
      PanQrState.expired => (skin.danger, '二维码已过期，请重新生成'),
      PanQrState.error => (skin.danger, _message ?? '登录失败，请重新生成二维码'),
      PanQrState.confirmed => (skin.success, '登录成功'),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: skin.spaceXs + 1),
        Flexible(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: text.meta.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
        ),
      ],
    );
  }
}
