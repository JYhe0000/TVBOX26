import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_skill/flutter_skill.dart';
import 'package:provider/provider.dart';

import 'core/app_controller.dart';
import 'core/library_store.dart';
import 'theme/app_theme.dart';
import 'theme/skin.dart';
import 'ui/shell_page.dart';
import 'ui/splash_page.dart';
import 'ui/tv_canvas.dart';
import 'ui/widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // E2E 桥接：仅 debug 构建注入，release 包不含测试扩展。
  if (kDebugMode) FlutterSkillBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final controller = AppController();
  final library = LibraryStore();
  _runApp(controller, library);
}

// 首次启动与皮肤冷切换共用入口。相同类型的 runApp 会更新旧 Element，
// 必须由 createTvboxRoot 的新 key 强制卸载旧 Navigator、页面及 Scrollable。
void _runApp(AppController controller, LibraryStore library) {
  controller.onRestartRequested = () => _runApp(controller, library);
  runApp(createTvboxRoot(controller, library));
}

// 暴露完整挂载边界供回归测试使用，避免测试另写 harness 漏掉冷切换语义。
@visibleForTesting
Widget createTvboxRoot(AppController controller, LibraryStore library) {
  return KeyedSubtree(
    key: UniqueKey(),
    child: TvboxApp(controller: controller, library: library),
  );
}

class TvboxApp extends StatefulWidget {
  const TvboxApp({super.key, required this.controller, required this.library});

  final AppController controller;
  final LibraryStore library;

  @override
  State<TvboxApp> createState() => _TvboxAppState();
}

class _TvboxAppState extends State<TvboxApp> {
  bool _bootReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (!mounted) return;
    setState(() => _bootReady = true);
    if (!widget.controller.initialized) {
      await widget.controller.initialize();
    }
    if (mounted && !widget.library.initialized) {
      await widget.library.initialize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.controller),
        ChangeNotifierProvider.value(value: widget.library),
      ],
      // 皮肤与主题色都由根节点新 key 冷重启，避免旧 Scrollable 在主题变化时
      // 搬移内部 GlobalKey；其它设置仍走普通热更新。
      child: Selector<AppController, (TvSkinId, TvAccentColor)>(
        selector: (_, controller) => (
          controller.skinId,
          controller.accentColor,
        ),
        builder: (context, selection, _) => MaterialApp(
          title: 'TVBOX26',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.forSkin(
            selection.$1,
            accentColor: selection.$2,
          ),
          navigatorObservers: [kRouteObserver],
          // 先让旧树完成帧末 dispose 和焦点清理，再挂新页面；否则首页
          // 首帧可能读到旧路由已 inactive 的 primaryFocus.context。
          home: _bootReady ? const _BootstrapGate() : const SizedBox.shrink(),
          builder: (context, child) {
            if (child == null) return const SizedBox.shrink();
            return MediaQuery.withClampedTextScaling(
              // §9 不变量 2：正文 ≥12sp 是硬性下限。只钳上限会让用户把
              // 系统字体调到 0.8 时正文缩到 9.6sp，10 英尺外不可读；这里
              // 同时钳下限，保证任何系统字体设置下正文都不低于设计字号。
              minScaleFactor: 1.0,
              maxScaleFactor: 1.2,
              child: TvCanvas(child: child),
            );
          },
        ),
      ),
    );
  }
}

class _BootstrapGate extends StatelessWidget {
  const _BootstrapGate();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, _) {
        if (!controller.initialized ||
            (controller.loading && !controller.hasSites)) {
          return SplashPage(
            loading: controller.loading,
            error: controller.initError,
          );
        }
        if (!controller.hasSites) {
          return SplashPage(
            loading: false,
            error: controller.initError ?? '配置中没有可用站点',
          );
        }
        return const ShellPage();
      },
    );
  }
}
