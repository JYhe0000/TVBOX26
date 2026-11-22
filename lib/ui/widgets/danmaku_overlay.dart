import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../data/danmaku_service.dart';
import '../../theme/ui.dart';

class DanmakuOverlay extends StatelessWidget {
  const DanmakuOverlay({
    super.key,
    required this.video,
    required this.comments,
    this.opacity = 0.8,
    this.large = false,
  });
  final ValueListenable<VideoPlayerValue> video;
  final List<DanmakuComment> comments;
  final double opacity;
  final bool large;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: video,
          builder: (context, value, _) {
            final position = value.position.inMilliseconds;
            // 二分定位，避免每次进度更新扫描整份弹幕。
            var low = 0;
            var high = comments.length;
            while (low < high) {
              final middle = (low + high) ~/ 2;
              if (comments[middle].timeMs < position - 6000) {
                low = middle + 1;
              } else {
                high = middle;
              }
            }
            final active = <DanmakuComment>[];
            for (
              var i = low;
              i < comments.length && comments[i].timeMs <= position;
              i++
            ) {
              if (active.length < 6) active.add(comments[i]);
            }
            return LayoutBuilder(
              builder: (context, box) => Stack(
                children: [
                  for (var i = 0; i < active.length; i++)
                    Positioned(
                      top: 70 + i * (large ? 42.0 : 32.0),
                      left:
                          box.maxWidth -
                          (position - active[i].timeMs) /
                              6000 *
                              (box.maxWidth + 500),
                      child: Opacity(
                        opacity: opacity,
                        child: Text(
                          active[i].text,
                          maxLines: 1,
                          style:
                              (large
                                      ? AppText.of(context).section
                                      : AppText.of(context).bodyLarge)
                                  .copyWith(
                                    // 弹幕覆盖视频，恒为白字黑色阴影以保证跨皮肤可读。
                                    color: Colors.white,
                                    shadows: const [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 3,
                                        offset: Offset(1, 1),
                                      ),
                                    ],
                                  ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
