import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../theme/ui.dart';
import 'common.dart';

/// 手机扫码填写地址弹窗：展示局域网地址二维码，手机扫码后在网页上粘贴
/// 配置接口地址或直播源地址，电视端自动填入。结构与 [showRemoteSearchDialog]
/// 高度对齐，通过 [title] 参数区分配置/直播源文案。
Future<void> showConfigUrlDialog(
  BuildContext context,
  String url,
  String title,
) {
  final skin = TvSkin.of(context);
  final titleStyle = AppText.resolve(
    skin,
    AppText.bodyLargeSize + 3,
    FontWeight.w800,
    1.2,
  );
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    // 遮罩恒为黑系半透明（§8.3 压内容的钉死色），不跟皮肤。
    barrierColor: const Color(0x99000000),
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
            // 二维码卡片是压在内容上的控件层：恒深色底 + 钉死白字（§8.3）。
            // 不跟皮肤——smartisan 亮底会撞白字、深底会撞深字，统一取
            // 「深底 + 白字」保证三皮肤可读（与 tv_sheet 侧栏同策略）。
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
              // 深底 + 钉死白字：不读皮肤文字色（smartisan 深字压深底 ≈1.5:1）。
              Text(title, style: titleStyle.copyWith(color: Colors.white)),
              SizedBox(height: skin.spaceXs),
              Text(
                '用手机扫码，在手机上粘贴地址，电视立刻填入。手机与电视需连接同一 Wi-Fi。',
                style: dialogText.label.copyWith(
                  height: 1.7,
                  color: Colors.white.withValues(alpha: 0.78),
                ),
              ),
              SizedBox(height: skin.spaceMd),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
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
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
              SizedBox(height: skin.spaceMd),
              for (final (index, step) in const [
                '手机扫码，打开地址输入网页',
                '在手机上粘贴或输入地址',
                '点「发送到电视」，本页会自动关闭并填入地址',
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
                          // 不再收紧；accent 属语义强调色，深底上保留（§8.3）。
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
                            color: Colors.white.withValues(alpha: 0.82),
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
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
              SizedBox(height: skin.spaceSm + 2),
              // 深底上钉死白字（§8.3 控件层前景恒黑白）。原 TextButton 在 TV 上
              // 无皮肤焦点视觉，改包 TvFocusable 成为弹窗内唯一可获焦动作，
              // 进弹窗默认焦点落在「返回」上（FOCUS-06）。
              TvFocusable(
                autofocus: true,
                radius: skin.radiusSm,
                scale: 1.02,
                semanticLabel: '返回',
                onTap: () => Navigator.of(dialogContext).pop(),
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
                    '返回',
                    style: dialogText.bodyStrong.copyWith(color: Colors.white),
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
