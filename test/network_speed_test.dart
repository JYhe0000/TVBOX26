import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/network_speed.dart';

/// 网速 Widget 回归：默认 appStream 模式保持原行为，
/// video 模式覆盖「有会话速率+累计 / 无会话占位」两个显示分支。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('默认 appStream 模式：系统统计不可用时不显示（保持原行为）',
      (tester) async {
    await pump(tester, const NetworkSpeed());
    // 测试环境无 Android 方法通道，采不到速率时不渲染文字。
    expect(find.textContaining('KB/s'), findsNothing);
  });

  testWidgets('video 模式：有会话时显示速率与累计流量', (tester) async {
    await pump(
      tester,
      NetworkSpeed(
        mode: NetworkSpeedMode.video,
        activeSessions: () => 1,
        currentBytesPerSecond: () => 512 * 1024,
        totalServedBytes: () => 12 * 1024 * 1024,
      ),
    );
    // 首帧为占位，首帧后采样才出速率。
    await tester.pump();
    expect(find.text('视频流 512 KB/s · 累计 12.0 MB'), findsOneWidget);
  });

  testWidgets('video 模式：无会话时显示占位文案', (tester) async {
    await pump(
      tester,
      NetworkSpeed(
        mode: NetworkSpeedMode.video,
        activeSessions: () => 0,
        currentBytesPerSecond: () => 0,
        totalServedBytes: () => 0,
      ),
    );
    await tester.pump();
    expect(find.text('视频流空闲'), findsOneWidget);
    expect(find.textContaining('KB/s'), findsNothing);
  });

  testWidgets('video 模式：累计流量 GB 档换算', (tester) async {
    await pump(
      tester,
      NetworkSpeed(
        mode: NetworkSpeedMode.video,
        activeSessions: () => 2,
        currentBytesPerSecond: () => 900,
        totalServedBytes: () => 3 * 1024 * 1024 * 1024,
      ),
    );
    await tester.pump();
    expect(find.text('视频流 1 KB/s · 累计 3.0 GB'), findsOneWidget);
  });
}
