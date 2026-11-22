import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_controller.dart';
import '../core/utils.dart';
import '../theme/ui.dart';
import 'widgets/common.dart';
import 'widgets/tv_sheet.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key, this.loading = true, this.error});

  final bool loading;
  final String? error;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  Future<void> _enterUrl() async {
    final controller = context.read<AppController>();
    final input = TextEditingController(text: controller.configUrl);
    // 启动屏的配置入口走 TV 侧栏，不用 AlertDialog：对话框在 10 英尺外
    // 标题与按钮都偏小，而且抢焦点后返回键语义容易乱（AGENTS.md §2 反模式）。
    final url = await showTvSheet<String>(
      context,
      title: '配置接口',
      subtitle: '填入 TVBox JSON 配置地址，加载成功后自动保存',
      builder: (_) => _ConfigUrlForm(controller: input),
    );
    if (url == null || url.trim().isEmpty) return;
    await controller.loadConfig(url);
    if (!mounted) return;
    if (controller.actionError != null) {
      showAppSnack(context, controller.actionError!, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final skin = TvSkin.of(context);
    return Scaffold(
      backgroundColor: skin.bg,
      body: AppBackground(
        wallpaper: controller.wallpaper,
        child: SafeArea(
          // 720 画布内内容高度 < 720，不需要滚动；用 Center 固定构图。
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.82, end: 1),
                    duration: AppMotion.duration(
                      context,
                      const Duration(milliseconds: 700),
                    ),
                    curve: Curves.easeOutBack,
                    builder: (context, scale, child) =>
                        Transform.scale(scale: scale, child: child),
                    child: Container(
                      width: 94,
                      height: 94,
                      decoration: BoxDecoration(
                        gradient: skin.accentGradient,
                        borderRadius: BorderRadius.circular(skin.radiusLg + 4),
                        boxShadow: !skin.accentGlow
                            ? null
                            : [
                                BoxShadow(
                                  color: skin.accent.withValues(alpha: 0.45),
                                  blurRadius: 44,
                                  spreadRadius: 4,
                                ),
                              ],
                      ),
                      child: Icon(
                        Icons.live_tv_rounded,
                        color: skin.textOnAccent,
                        size: 48,
                      ),
                    ),
                  ),
                  SizedBox(height: skin.spaceLg + 2),
                  Text(
                    'TVBOX 26',
                    style: AppText.of(context).display.copyWith(
                      fontSize: 34,
                      letterSpacing: 1.5,
                      color: skin.textPrimary,
                    ),
                  ),
                  SizedBox(height: skin.spaceXs),
                  Text(
                    'Flutter Edition',
                    style: TextStyle(
                      fontSize: AppText.bodyStrongSize,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w600,
                      color: skin.accent,
                      fontFamily: skin.fontFamily,
                    ),
                  ),
                  SizedBox(height: skin.spaceXl),
                  if (controller.loading || widget.loading)
                    const _BootLoading()
                  else if (widget.error != null)
                    _BootError(
                      message: widget.error!,
                      onRetry: controller.initialize,
                      onBuiltIn: controller.useBuiltInConfig,
                      onConfig: _enterUrl,
                    )
                  else
                    const _BootLoading(label: '正在进入…'),
                  SizedBox(height: skin.spaceXl + 10),
                  Text(
                    '参考 TVBox 开源项目重制  ·  仅用于技术学习与本地播放',
                    textAlign: TextAlign.center,
                    style: AppText.of(context).label.copyWith(
                      color: skin.textMuted.withValues(alpha: 0.75),
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 配置地址表单：侧栏里的输入区 + 加载按钮。
class _ConfigUrlForm extends StatefulWidget {
  const _ConfigUrlForm({required this.controller});

  final TextEditingController controller;

  @override
  State<_ConfigUrlForm> createState() => _ConfigUrlFormState();
}

class _ConfigUrlFormState extends State<_ConfigUrlForm> {
  late final FocusNode _field = FocusNode(debugLabel: 'config-url-field');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(widget.controller.text);

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Padding(
      padding: EdgeInsets.all(skin.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvFocusable(
            radius: skin.radiusSm,
            scale: 1.0,
            autofocus: true,
            focusNode: _field,
            onTap: () => _field.requestFocus(),
            child: TextField(
              focusNode: _field,
              controller: widget.controller,
              keyboardType: TextInputType.url,
              style: text.bodyLarge,
              decoration: InputDecoration(
                hintText: 'https://example.com/tvbox.json',
                prefixIcon: Icon(
                  Icons.link_rounded,
                  color: skin.textSecondary,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          SizedBox(height: skin.spaceLg),
          TvFocusable(
            radius: skin.radiusSm,
            semanticLabel: '加载配置',
            onTap: _submit,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: skin.accentGradient,
                borderRadius: BorderRadius.circular(skin.radiusSm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_rounded,
                    size: 18,
                    color: skin.textOnAccent,
                  ),
                  SizedBox(width: skin.spaceXs),
                  Text(
                    '加载配置',
                    style: text.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: skin.textOnAccent,
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

class _BootLoading extends StatelessWidget {
  const _BootLoading({this.label = '正在加载配置…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return SkinSurface(
      radius: skin.radiusLg - 2,
      padding: EdgeInsets.symmetric(
        horizontal: skin.spaceLg + 2,
        vertical: skin.spaceLg - 4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          SizedBox(width: skin.spaceSm + 5),
          Text(
            label,
            style: AppText.of(context).bodyLarge.copyWith(
              color: skin.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({
    required this.message,
    required this.onRetry,
    required this.onBuiltIn,
    required this.onConfig,
  });

  final String message;
  final Future<void> Function() onRetry;
  final Future<void> Function() onBuiltIn;
  final VoidCallback onConfig;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    const buttons = 48.0;
    return SkinSurface(
      radius: skin.radiusLg,
      padding: EdgeInsets.all(skin.spaceLg - 2),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded, color: skin.danger, size: 36),
          SizedBox(height: skin.spaceSm + 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.of(context).bodyStrong.copyWith(
              color: skin.textSecondary,
              height: 1.55,
            ),
          ),
          SizedBox(height: skin.spaceLg - 4),
          Row(
            children: [
              Expanded(
                child: TvFocusable(
                  radius: skin.radiusSm,
                  scale: 1.02,
                  semanticLabel: '使用内置源',
                  onTap: onBuiltIn,
                  child: Container(
                    height: buttons,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: skin.surfaceSubtle,
                      borderRadius: BorderRadius.circular(skin.radiusSm),
                      border: Border.all(color: skin.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.playlist_play_rounded,
                          size: 18,
                          color: skin.textSecondary,
                        ),
                        SizedBox(width: skin.spaceXs),
                        Text(
                          '内置源',
                          style: text.bodyStrong.copyWith(
                            fontWeight: FontWeight.w600,
                            color: skin.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(width: skin.spaceSm),
              Expanded(
                child: TvFocusable(
                  radius: skin.radiusSm,
                  autofocus: true,
                  semanticLabel: '重试加载',
                  onTap: onRetry,
                  child: Container(
                    height: buttons,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: skin.accentGradient,
                      borderRadius: BorderRadius.circular(skin.radiusSm),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: skin.textOnAccent,
                        ),
                        SizedBox(width: skin.spaceXs),
                        Text(
                          '重试',
                          style: text.bodyStrong.copyWith(
                            fontWeight: FontWeight.w700,
                            color: skin.textOnAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: skin.spaceSm),
          TvFocusable(
            radius: skin.radiusSm,
            scale: 1.02,
            semanticLabel: '输入配置接口',
            onTap: onConfig,
            child: Container(
              width: double.infinity,
              height: buttons,
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link_rounded, size: 17, color: skin.accent),
                  SizedBox(width: skin.spaceXs),
                  Text(
                    '输入配置接口',
                    style: text.bodyStrong.copyWith(
                      fontWeight: FontWeight.w600,
                      color: skin.accent,
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