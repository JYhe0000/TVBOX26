import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../theme/ui.dart';
import 'common.dart';

/// 手机远程搜索弹窗：展示局域网地址二维码，手机扫码后在网页上输入关键词。
Future<void> showRemoteSearchDialog(BuildContext context, String url) {
  final skin = TvSkin.of(context);
  final title = AppText.resolve(
    skin,
    AppText.bodyLargeSize + 3,
    FontWeight.w800,
    1.2,
  );
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    // 复用皮肤控制层的黑系遮罩色，保持底层内容压暗。
    barrierColor: skin.controlScrim.colors.first.withValues(alpha: 0.6),
    builder: (dialogContext) {
      final dialogText = AppText.of(dialogContext);
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
            // 普通搜索弹窗的面板与文字成对读取皮肤，兼容亮色主题。
            color: skin.surface.withValues(alpha: 247 / 255),
            borderRadius: BorderRadius.circular(skin.radiusLg),
            border: Border.all(
              color: skin.surfaceSkin.panelBorder,
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
              Text('手机远程搜索', style: title),
              SizedBox(height: skin.spaceXs),
              Text(
                '用手机扫码，在手机上打字，电视立刻出结果。手机与电视需连接同一 Wi-Fi。',
                style: dialogText.label.copyWith(
                  height: 1.7,
                  color: skin.textSecondary,
                ),
              ),
              SizedBox(height: skin.spaceMd),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    // 二维码保持白底黑码，保证三套皮肤下的扫码对比度。
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(skin.radiusSm + 2),
                  ),
                  child: QrImageView(
                    data: url,
                    version: QrVersions.auto,
                    size: 168,
                    gapless: true,
                  ),
                ),
              ),
              SizedBox(height: skin.spaceSm),
              Center(
                child: Text(
                  url,
                  style: dialogText.label.copyWith(
                      color: skin.textSecondary,
                  ),
                ),
              ),
              SizedBox(height: skin.spaceMd),
              for (final (index, step) in const [
                '手机扫码，打开「TVBOX 远程搜索」网页',
                '输入片名，或用热门搜索 / 联想词一键填入',
                '点「发送到电视」，本页会自动关闭并开始搜索',
              ].indexed)
                Padding(
                  padding: EdgeInsets.only(bottom: skin.spaceXs + 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        margin: const EdgeInsets.only(top: 1),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: skin.accent.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${index + 1}',
                          // 徽标序号：meta 档 12sp 已是下限（§9.2），18px 圆内
                          // 不再收紧；序号沿用皮肤强调色。
                          style: dialogText.meta.copyWith(
                            fontWeight: FontWeight.w700,
                            color: skin.accent,
                          ),
                        ),
                      ),
                      SizedBox(width: skin.spaceXs + 2),
                      Expanded(
                        child: Text(
                          step,
                          style: dialogText.meta.copyWith(
                            height: 1.55,
                            color: skin.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              SizedBox(height: skin.spaceXs),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: skin.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: skin.spaceXs + 1),
                  Text(
                    '等待手机提交…',
                    style: dialogText.meta.copyWith(
                      color: skin.textMuted,
                    ),
                  ),
                ],
              ),
              SizedBox(height: skin.spaceSm + 2),
              // TvFocusable 提供皮肤焦点视觉，是弹窗内唯一可获焦动作，
              // 进弹窗默认焦点落在「返回搜索」上（FOCUS-06）。
              TvFocusable(
                autofocus: true,
                radius: skin.radiusSm,
                scale: 1.02,
                semanticLabel: '返回搜索',
                onTap: () => Navigator.of(dialogContext).pop(),
                child: Container(
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(
                    horizontal: skin.spaceLg,
                    vertical: skin.spaceSm + 2,
                  ),
                  decoration: BoxDecoration(
                    color: skin.textPrimary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(skin.radiusSm),
                    border: Border.all(
                      color: skin.border,
                    ),
                  ),
                  child: Text(
                    '返回搜索',
                    style: dialogText.bodyStrong,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
