// player_focus.dart — 播放器焦点体系公共件（点播 player_page / 直播
// live_player_page 共用，focus-system-spec §5 的「状态机式焦点管理」）。
//
// 状态机（配合页面各自的 `_controlsVisible` × 侧栏开关）：
//
// | 状态                 | 焦点所在                     | 进入方式                          | 退出方式                              |
// | -------------------- | ---------------------------- | --------------------------------- | ------------------------------------- |
// | 控制层可见 × 侧栏关  | 控制层胶囊（默认 play 键）   | 首播就绪 / 方向键唤醒             | 顶行 UP / 底行 DOWN → 隐藏回画面      |
// | 控制层隐藏 × 侧栏关  | 页面根 root                  | 自动隐藏 / ESC / 顶行 UP / 底行 DOWN | 任意方向键 → 唤醒回胶囊              |
// | 控制层可见 × 侧栏开  | 侧栏作用域 panelScope 子树   | 「选集/线路」/「频道列表」触发键   | 关闭键 / BACK → 还焦触发键            |
// | 错误层 / 投屏 / 弹窗 | 对应作用域（页面自管）       | 解码失败 / 投屏开始 / 功能弹窗    | 关闭 → 回本机控制层                   |
//
// 页面只保留状态字段 + setState，焦点投递全部走本文件的节点集合与帧后
// 投焦方法——两个页面因此保持同构，修一处即修两处（AGENTS.md §3 规则
// 4/8/9/11 的落地位置）。

import 'package:flutter/material.dart';

import '../../theme/ui.dart';

/// 皮肤动效时长（`Duration + Duration` 在 Dart 里不是合法组合，所以把余量
/// 折算成毫秒再加，语义等价于「皮肤时长再稍慢一点」）。
Duration playerPanelMotion(
  BuildContext context,
  Duration base, {
  int extra = 0,
}) => AppMotion.duration(context, base) + Duration(milliseconds: extra);

/// 播放器页面的焦点节点集合（一个页面实例一套，dispose 时统一释放）。
///
/// debugLabel 是测试与真机 uiautomator 探针的锚点（`focused="true"` 行的
/// content-desc），改动标签会连带改测试，不要随意重命名。
class PlayerFocusNodes {
  PlayerFocusNodes({
    this.rootLabel = 'playerRoot',
    this.playLabel = 'playerPlay',
    this.panelScopeLabel = 'episodePanel',
    this.panelTriggerLabel = 'episodeTrigger',
  }) : root = FocusNode(debugLabel: rootLabel),
       play = FocusNode(debugLabel: playLabel),
       panelScope = FocusScopeNode(debugLabel: panelScopeLabel),
       panelTrigger = FocusNode(debugLabel: panelTriggerLabel);

  final String rootLabel;
  final String playLabel;
  final String panelScopeLabel;
  final String panelTriggerLabel;

  /// 页面根焦点：控制层隐藏时整棵控制层被 `ExcludeFocus` 排除，这里成为
  /// 唯一落点；方向键唤醒后由页面把焦点送回 [play]（AGENTS.md §3 规则 4）。
  final FocusNode root;

  /// 控制层「播放/暂停」键：控制层可见时的默认焦点落点（§3 规则 11：首播
  /// 就绪即投到这里，遥控器 OK 直接生效，不用先 ESC/DOWN 叫出焦点）。
  final FocusNode play;

  /// 侧栏（选集面板 / 频道面板）的焦点作用域：打开期间焦点收敛在子树内，
  /// 方向键不会穿到被盖住的控制层（Flutter 方向遍历按最近 FocusScope
  /// 收敛并在作用域边缘 stop）。
  final FocusScopeNode panelScope;

  /// 侧栏触发按钮（「选集 / 线路」/「频道列表」）：关侧栏后的第一归还位。
  final FocusNode panelTrigger;

  /// 打开侧栏前的焦点落点（AGENTS.md §3 规则 3：关闭覆盖层后焦点回原位，
  /// 持有引用而不是几何查找）。
  FocusNode? focusBeforePanel;

  /// 释放全部节点（页面 dispose 时调用）。
  void dispose() {
    root.dispose();
    play.dispose();
    panelScope.dispose();
    panelTrigger.dispose();
  }

  /// 帧后把焦点投到 [play]；`allow` 返回 false（侧栏开着 / 加载中 / 错误层
  /// 可见 / 投屏中 / 页面不在栈顶等）时放弃。
  ///
  /// 控制层刚挂回或刚解除 `ExcludeFocus` 时节点还没进焦点树，`requestFocus`
  /// 必须等一帧；`ensureVisualUpdate` 保证没有其它待绘制帧时也会补一帧，
  /// 否则焦点请求会滞留到下一次交互才执行。
  void focusPlayAfterFrame({required bool Function() allow}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!allow()) return;
      (play.context != null && play.canRequestFocus ? play : root)
          .requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 帧后归还侧栏焦点：开面板前的落点 → [panelTrigger] → [root]
  /// （AGENTS.md §3 规则 3 的优先级链）。
  ///
  /// 必须等面板撤下、控制层 `ExcludeFocus` 解除后再执行：换集/换台要
  /// `await _prepare`（会把 `_controlsVisible` 置回 false 再 true），早投
  /// 焦会让刚获焦的列表项悬空在隐藏的控制层上。
  void restorePanelFocusAfterFrame({required bool Function() allow}) {
    final previous = focusBeforePanel;
    focusBeforePanel = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!allow()) return;
      final target =
          previous != null &&
              previous.context != null &&
              previous.canRequestFocus
          ? previous
          : panelTrigger.context != null && panelTrigger.canRequestFocus
          ? panelTrigger
          : root;
      target.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 主焦点是否停在页面根（「控制层可见但焦点掉在根上」的补丁判定：
  /// 子路由 pop 返回、抢焦失败等瞬间会进入该状态，方向键需拉回胶囊）。
  bool get focusAtRoot {
    final primary = FocusManager.instance.primaryFocus;
    return primary == null || primary == root;
  }
}

/// 控制层显隐包装（点播/直播同构）：四层各管一件事，缺一不可——
///
/// - [AnimatedOpacity] 管淡入淡出：`opacity: 0` 时 `RenderAnimatedOpacity`
///   不绘制子层，淡入淡出动画完整保留（AGENTS.md §5.1 的 140–220ms）。
/// - [Offstage] 管布局与语义：隐藏时 `RenderOffstage.performLayout` 只让
///   子树过一遍布局，`paint`/`hitTest`/`visitChildrenForSemantics` 全部
///   短路，整棵控制层不再绘制、不再吃点击、不再进无障碍树——省 GPU。
/// - [ExcludeFocus] 管焦点：隐藏（或被侧栏/错误层/弹窗遮挡）时控制层内
///   所有节点都不参与焦点遍历，这是 AGENTS.md §3 硬性规则 4，不能用
///   `Visibility.maintain` 顶替（那会连带把 `ExcludeFocus` 一起摘掉）。
/// - [IgnorePointer] 管命中测试：隐藏时吞掉点击，避免误触。
class PlayerControlsLayer extends StatelessWidget {
  const PlayerControlsLayer({
    super.key,
    required this.visible,
    required this.focusExcluded,
    required this.child,
  });

  /// 控制层是否可见（页面的 `_controlsVisible`）。
  final bool visible;

  /// 可见之外的附加排除条件（侧栏打开 / 错误层可见 / 设置弹窗打开等）。
  final bool focusExcluded;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    return AnimatedOpacity(
      duration: playerPanelMotion(context, skin.motionFast, extra: 70),
      opacity: visible ? 1 : 0,
      child: Offstage(
        offstage: !visible,
        child: ExcludeFocus(
          excluding: !visible || focusExcluded,
          child: IgnorePointer(ignoring: !visible, child: child),
        ),
      ),
    );
  }
}
