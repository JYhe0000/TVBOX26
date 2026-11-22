import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox_flutter/ui/tv_canvas.dart';

const _probeKey = ValueKey<String>('tv-canvas-probe');

class _CanvasProbe extends StatelessWidget {
  const _CanvasProbe({required this.onMedia});

  final ValueChanged<MediaQueryData> onMedia;

  @override
  Widget build(BuildContext context) {
    onMedia(MediaQuery.of(context));
    return ColoredBox(
      key: _probeKey,
      color: Colors.blue,
      child: const SizedBox.expand(),
    );
  }
}

Widget _harness(
  ValueChanged<MediaQueryData> onMedia,
  EdgeInsets viewInsets,
) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        viewInsets: viewInsets,
        padding: const EdgeInsets.all(8),
        viewPadding: const EdgeInsets.all(16),
        textScaler: TextScaler.linear(1.25),
      ),
      child: TvCanvas(child: child ?? const SizedBox.shrink()),
    ),
    home: _CanvasProbe(onMedia: onMedia),
  );
}

void main() {
  const cases = [
    ('720p', Size(1280, 720), Rect.fromLTWH(0, 0, 1280, 720), 1.0),
    ('1080p', Size(1920, 1080), Rect.fromLTWH(0, 0, 1920, 1080), 1.5),
    ('4K', Size(3840, 2160), Rect.fromLTWH(0, 0, 3840, 2160), 3.0),
    ('16:10', Size(1920, 1200), Rect.fromLTWH(0, 60, 1920, 1080), 1.5),
    ('21:9', Size(2520, 1080), Rect.fromLTWH(300, 0, 1920, 1080), 1.5),
  ];

  for (final (label, screen, bounds, scale) in cases) {
    testWidgets(
      '$label 画布完整且等比，内部 MediaQuery 使用设计坐标',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = screen;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        late MediaQueryData innerMedia;
        const insets = EdgeInsets.fromLTRB(30, 12, 18, 300);
        await tester.pumpWidget(
          _harness((media) => innerMedia = media, insets),
        );

        final box = tester.renderObject<RenderBox>(find.byKey(_probeKey));
        expect(box.size, const Size(1280, 720));
        final rect = Rect.fromPoints(
          box.localToGlobal(Offset.zero),
          box.localToGlobal(Offset(box.size.width, box.size.height)),
        );
        expect(rect.left, closeTo(bounds.left, 0.01));
        expect(rect.top, closeTo(bounds.top, 0.01));
        expect(rect.right, closeTo(bounds.right, 0.01));
        expect(rect.bottom, closeTo(bounds.bottom, 0.01));

        expect(innerMedia.size, const Size(1280, 720));
        expect(innerMedia.padding, EdgeInsets.zero);
        expect(innerMedia.viewPadding, EdgeInsets.zero);
        expect(innerMedia.viewInsets, insets / scale);
        expect(innerMedia.textScaler.scale(16), 20);
      },
    );
  }
}
