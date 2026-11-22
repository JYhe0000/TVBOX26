import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';

import '../../data/models.dart';
import '../../theme/ui.dart';
import 'common.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.vod,
    required this.onTap,
    this.showSource = false,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChange,
  });

  final VodItem vod;
  final VoidCallback onTap;
  final bool showSource;
  final bool autofocus;
  final FocusNode? focusNode;

  /// 卡片获焦/失焦回调（详情页推荐行用它做逐行焦点记忆，FOCUS-07）。
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final focus = skin.focus;
    final text = AppText.of(context);
    return TvFocusable(
      onTap: onTap,
      radius: skin.radiusMd,
      scale: focus.cardGrow,
      focusDuration: focus.cardDuration,
      autofocus: autofocus,
      focusNode: focusNode,
      onFocusChange: onFocusChange,
      semanticLabel: [
        vod.name,
        if (vod.remarks.trim().isNotEmpty) vod.remarks,
        if (vod.score.trim().isNotEmpty) '评分 ${vod.score}',
      ].join('，'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(skin.radiusSm + 4),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetworkPoster(url: vod.pic, radius: skin.radiusSm + 4),
                  DecoratedBox(
                    decoration: BoxDecoration(gradient: skin.posterOverlay),
                  ),
                  if (vod.remarks.isNotEmpty)
                    Positioned(
                      left: 9,
                      right: 9,
                      bottom: 9,
                      child: Row(
                        children: [
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.58),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                vod.remarks,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.meta.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (vod.score.isNotEmpty)
                    Positioned(
                      right: 9,
                      top: 9,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: skin.warning,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          vod.score,
                          style: text.meta.copyWith(
                            color: const Color(0xFF241300),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  if (showSource &&
                      (context.watch<AppController?>()?.showSourceBadges ??
                          true))
                    Positioned(
                      left: 9,
                      top: 9,
                      child: SiteBadge(label: vod.sourceName),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: skin.spaceSm),
          Text(
            vod.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.cardTitle,
          ),
          const SizedBox(height: 3),
          Text(
            vod.subtitle.isNotEmpty ? vod.subtitle : vod.remarks,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.label.copyWith(color: skin.textMuted),
          ),
        ],
      ),
    );
  }
}

class WideVodCard extends StatelessWidget {
  const WideVodCard({
    super.key,
    required this.vod,
    required this.onTap,
    this.trailing,
    this.subtitle,
    this.showSource = true,
    this.focusNode,
  });

  final VodItem vod;
  final VoidCallback onTap;
  final Widget? trailing;
  final String? subtitle;
  final FocusNode? focusNode;
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      onTap: onTap,
      radius: skin.radiusMd,
      scale: skin.focus.cardGrow,
      focusDuration: skin.focus.cardDuration,
      focusNode: focusNode,
      child: Container(
        padding: EdgeInsets.all(skin.spaceSm),
        decoration: BoxDecoration(
          color: skin.surfaceSubtle,
          borderRadius: BorderRadius.circular(skin.radiusSm + 4),
          border: Border.all(color: skin.borderSoft),
        ),
        child: IntrinsicHeight(
          // SliverList 的项没有有界高度；用 IntrinsicHeight 让 Row 以海报高度为准，
          // 内部 Column 的 Spacer 才能合法工作（否则布局异常导致整卡不绘制）。
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                // 竖版海报 2:3（AGENTS.md §9.7）：87×130 ≈ 2:3，避免 cover
                // 裁切人脸/片名（widgets P2-11）。
                width: 87,
                height: 130,
                child: NetworkPoster(url: vod.pic, radius: skin.radiusSm),
              ),
              SizedBox(width: skin.spaceSm + 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vod.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.cardTitle.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle ?? vod.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.label.copyWith(color: skin.textMuted),
                      ),
                      if (vod.remarks.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          vod.remarks,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.label.copyWith(color: skin.warning),
                        ),
                      ],
                      const Spacer(),
                      Row(
                        children: [
                          if (showSource &&
                              (context
                                      .watch<AppController?>()
                                      ?.showSourceBadges ??
                                  true))
                            SiteBadge(label: vod.sourceName),
                          const Spacer(),
                          ?trailing,
                        ],
                      ),
                    ],
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

/// A compact card used for "continue watching" rows.
class ContinueCard extends StatelessWidget {
  /// 卡片固定宽（16:9 横版卡）。ShelfRow 接入方的 `itemExtent` 取同值，
  /// 焦点记忆项滚出视口时才能按位置算滚动偏移。
  static const double cardWidth = 300;

  const ContinueCard({
    super.key,
    required this.entry,
    required this.onTap,
    this.onRemove,
    this.focusNode,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  /// 外部焦点节点：`ShelfRow` 的 itemBuilder 把每项节点透传进来，卡片不再
  /// 自建 FocusNode，交由 [TvFocusable] 挂接同一个节点——逐行焦点记忆
  /// （FOCUS-02）依赖「实际获焦的节点就是 ShelfRow 记录的节点」，卡片内部
  /// 另起节点会让记忆写不到 ShelfRow。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      onTap: onTap,
      radius: skin.radiusMd,
      scale: skin.focus.cardGrow,
      focusDuration: skin.focus.cardDuration,
      focusNode: focusNode,
      child: SizedBox(
        width: cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(skin.radiusSm + 4),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NetworkPoster(
                      url: entry.vod.pic,
                      radius: skin.radiusSm + 4,
                    ),
                    // 底部压暗渐变走 token：三皮肤都是黑色系，形状随
                    // skin.posterOverlay（§8.3），不写字面量。
                    DecoratedBox(
                      decoration: BoxDecoration(gradient: skin.posterOverlay),
                    ),
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        size: 48,
                        color: Colors.white,
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 10,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.episodeName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.label.copyWith(color: Colors.white),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: entry.progress,
                              minHeight: 4,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.25,
                              ),
                              valueColor: AlwaysStoppedAnimation(skin.accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (onRemove != null)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: GestureDetector(
                          onTap: onRemove,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: skin.spaceSm - 1),
            Text(
              entry.vod.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyStrong,
            ),
            const SizedBox(height: 3),
            Text(
              '${entry.sourceName} · ${entry.episodeName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.label.copyWith(color: skin.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
