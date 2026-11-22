import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_flutter/data/pan/pan_account.dart';
import 'package:tvbox_flutter/data/pan/pan_qr_login.dart';
import 'package:tvbox_flutter/theme/ui.dart';
import 'package:tvbox_flutter/ui/widgets/common.dart';
import 'package:tvbox_flutter/ui/widgets/pan_qr_dialog.dart';

/// 扫码登录弹窗的 TV 契约：
/// - 打开即有一个可见焦点（FOCUS-06），落在「关闭」；
/// - 轮询到 confirmed 后自动关闭并把账号回传给调用方；
/// - 过期态给出「重新生成二维码」这一可操作出口。
///
/// 用 [FakeQrLogin] 顶掉真实网络，测试只验证 UI/焦点/状态机。
void main() {
  Future<void> pumpHost(
    WidgetTester tester,
    PanQrLogin login,
    void Function(PanAccount?) onResult,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forSkin(TvSkinId.smartisan),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TvFocusable(
                autofocus: true,
                semanticLabel: '打开扫码',
                onTap: () async {
                  onResult(
                    await showPanQrLogin(
                      context,
                      PanProviderId.aliyun,
                      login: login,
                    ),
                  );
                },
                child: const Text('打开扫码'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开扫码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
  }

  testWidgets('打开后默认焦点在关闭按钮且显示等待扫码', (tester) async {
    final login = FakeQrLogin();
    await pumpHost(tester, login, (_) {});
    expect(find.text('等待手机扫码…'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    final closeFocus = Focus.of(tester.element(find.text('关闭')));
    expect(closeFocus.hasFocus, isTrue);
    // 清理：关闭弹窗，避免 pending timer 报红。
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('轮询 confirmed 后自动关闭并回传账号', (tester) async {
    final login = FakeQrLogin(confirmAfterPolls: 1);
    PanAccount? result;
    await pumpHost(tester, login, (value) => result = value);
    expect(find.text('等待手机扫码…'), findsOneWidget);
    // 轮询间隔 2s；pump 过一轮定时器。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('等待手机扫码…'), findsNothing);
    expect(result?.refreshToken, 'rt-from-fake');
    expect(result?.provider, PanProviderId.aliyun);
  });

  testWidgets('过期后显示重新生成入口，点击会重建二维码', (tester) async {
    final login = FakeQrLogin(expireAfterPolls: 1);
    await pumpHost(tester, login, (_) {});
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('二维码已过期，请重新生成'), findsOneWidget);
    expect(find.text('重新生成二维码'), findsOneWidget);
    expect(login.created, 1);
    await tester.tap(find.text('重新生成二维码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(login.created, 2);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
}

/// 可控状态机：不发起任何网络请求。
class FakeQrLogin extends PanQrLogin {
  FakeQrLogin({this.confirmAfterPolls, this.expireAfterPolls});

  final int? confirmAfterPolls;
  final int? expireAfterPolls;
  int created = 0;
  int polls = 0;

  @override
  Future<PanQrSession> create(PanProviderId provider) async {
    created++;
    polls = 0;
    return PanQrSession(
      provider: provider,
      qrContent: 'https://example.com/qr-$created',
      pollToken: 'token-$created',
    );
  }

  @override
  Future<PanQrPoll> poll(PanQrSession session) async {
    polls++;
    if (confirmAfterPolls != null && polls >= confirmAfterPolls!) {
      return const PanQrPoll(
        PanQrState.confirmed,
        account: PanAccount(
          provider: PanProviderId.aliyun,
          refreshToken: 'rt-from-fake',
        ),
      );
    }
    if (expireAfterPolls != null && polls >= expireAfterPolls!) {
      return const PanQrPoll(PanQrState.expired);
    }
    return const PanQrPoll(PanQrState.waiting);
  }
}
