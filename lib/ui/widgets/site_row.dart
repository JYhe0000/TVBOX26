import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/site_api.dart';
import '../../theme/ui.dart';
import 'common.dart';

/// 站点选择行：首页侧栏与「我的」页共用。
///
/// 只负责外观，焦点与点击由外层 `TvFocusable` 提供。
class SiteRow extends StatelessWidget {
  const SiteRow({
    super.key,
    required this.site,
    required this.selected,
    this.iconOverride,
  });

  final SiteConfig site;
  final bool selected;

  /// 搜索页的「搜索范围」面板复用本行时传一个放大镜图标，避免语义错位。
  final IconData? iconOverride;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final icon = iconOverride ??
        (site.isSpider ? Icons.extension_rounded : Icons.dns_rounded);
    // smartisan 获焦时外层 TvFocusable 的填充（整块换蓝）画在子内容之下，
    // 这里的实色底（accentSoft / surfaceSubtle）会把它盖住、退化成细描边。
    // 获焦反白态下让出底色、文字图标切 textOnAccent（整块换蓝 + 内容反白）。
    final tinted = TvFocusTint.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: skin.spaceMd,
        vertical: skin.spaceSm + 4,
      ),
      decoration: BoxDecoration(
        color: tinted
            ? Colors.transparent
            : (selected ? skin.accentSoft : skin.surfaceSubtle),
        borderRadius: BorderRadius.circular(skin.radiusSm + 2),
        border: Border.all(
          color: tinted
              ? Colors.transparent
              : (selected ? skin.accent : skin.borderSoft),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tinted
                  ? Colors.transparent
                  : (selected
                        ? skin.accent.withValues(alpha: 0.2)
                        : skin.surfaceSubtle),
              borderRadius: BorderRadius.circular(skin.radiusSm - 1),
            ),
            child: Icon(
              icon,
              size: 20,
              color: tinted
                  ? skin.textOnAccent
                  : (selected ? skin.accent : skin.textSecondary),
            ),
          ),
          SizedBox(width: skin.spaceSm + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge.copyWith(
                    fontWeight: FontWeight.w600,
                    color: tinted
                        ? skin.textOnAccent
                        : (selected ? skin.accent : skin.textPrimary),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  site.isSpider
                      ? SiteApi.supportsJar(site) ? 'Spider · JAR' : SiteApi.supportsJs(site) ? 'Spider · JS' : 'Spider · 不兼容'
                      : '${site.typeLabel} · 可搜索',
                  style: text.label.copyWith(
                    color: tinted ? skin.textOnAccent : skin.textMuted,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: skin.spaceSm),
          if (selected)
            Text(
              '当前',
              style: text.label.copyWith(
                color: tinted ? skin.textOnAccent : skin.accent,
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: tinted ? skin.textOnAccent : skin.textMuted,
            ),
        ],
      ),
    );
  }
}
