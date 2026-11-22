import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../theme/ui.dart';
import '../widgets/common.dart';
import '../widgets/epg_overlay.dart';
import '../../core/app_controller.dart';
import '../../core/player_backend.dart';
import '../widgets/network_speed.dart';
import '../../core/utils.dart';
import '../../core/live_preferences.dart';
import '../../data/epg_service.dart';
import '../../data/playback_error.dart';
import '../widgets/tv_sheet.dart';
import '../widgets/channel_password_dialog.dart';
import '../widgets/player_focus.dart';

class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    required this.group,
    this.initialIndex = 0,
    this.httpHeaders = const {},
    this.epgUrl = '',
    this.groups = const [],
    this.preferences = const LivePreferences(),
    this.initialUnlocked = false,
  });

  final LiveGroup group;
  final int initialIndex;
  final Map<String, String> httpHeaders;
  final String epgUrl;
  final List<LiveGroup> groups;
  final LivePreferences preferences;
  final bool initialUnlocked;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage>
    with WidgetsBindingObserver, RouteAware {
  PlayerBackend? _video;
  Timer? _hideTimer;
  Timer? _numberTimer;
  Timer? _clockTimer;
  String _digits = '';
  late LiveGroup _group = widget.group;
  late LivePreferences _preferences = widget.preferences;
  String? _replayUrl;
  String? _replayTitle;
  bool _overlayOpen = false;
  bool _routeSubscribed = false;
  bool _routeCovered = false;

  bool get _isCurrentRoute =>
      mounted && !_routeCovered && ModalRoute.of(context)?.isCurrent == true;
  final Set<LiveChannel> _unlocked = {};
  DateTime _now = DateTime.now();
  late int _channelIndex = widget.initialIndex.clamp(
    0,
    widget.group.channels.length - 1,
  );
  int _sourceIndex = 0;
  int _requestToken = 0;
  bool _loading = true;
  bool _controlsVisible = true;
  bool _channelPanel = false;
  bool _errorVisible = false;
  String? _error;
  final FocusNode _retryFocus = FocusNode(debugLabel: 'liveRetry');
  final FocusNode _errorSourceFocus = FocusNode(debugLabel: 'liveErrorSource');
  final FocusNode _errorNextFocus = FocusNode(debugLabel: 'liveErrorNext');

  /// 直播播放器焦点节点集合（页面根 / 中央播放键 / 频道面板作用域 /
  /// 频道列表触发键 + 开面板前的落点记忆）。状态机与帧后投焦统一见
  /// player_focus.dart 头注（与点播侧同构）；debugLabel（liveRoot /
  /// livePlay / channelPanel / channelTrigger）是测试与真机探针锚点。
  late final PlayerFocusNodes _focus = PlayerFocusNodes(
    rootLabel: 'liveRoot',
    playLabel: 'livePlay',
    panelScopeLabel: 'channelPanel',
    panelTriggerLabel: 'channelTrigger',
  );

  /// 频道面板行焦点节点（index → 节点）：频道列表可能几百项，方向键
  /// 必须按 index 显式投递 + ensureVisible（AGENTS.md §3 规则 7 的
  /// cacheExtent 死键问题，同 home_page `_posterNodes` 范式）。换组
  /// （跨组换台）后旧组的高位残留节点在下次开面板时统一回收。
  final Map<int, FocusNode> _channelNodes = {};
  int _channelFocusRequest = 0;

  /// 频道面板「关闭」按钮与顶行「返回」按钮的焦点节点。
  final FocusNode _panelCloseFocus = FocusNode(debugLabel: 'channelPanelClose');
  final FocusNode _backFocus = FocusNode(debugLabel: 'liveBack');

  /// 频道面板列表滚动控制器：目标行在缓存区外（未挂载）时按视口 80%
  /// 向目标方向滚动推进，帧后重试投递（见 [_focusChannelIndex]）。
  final ScrollController _channelScroll = ScrollController();

  int _lastSyncMs = -1;

  LiveChannel get _channel => _group.channels[_channelIndex];

  String get _url {
    if (_replayUrl != null) return _replayUrl!;
    final urls = _channel.urls;
    if (urls.isEmpty) return '';
    return urls[_sourceIndex.clamp(0, urls.length - 1)];
  }

  String get _sourceName {
    if (_channel.sourceNames.isEmpty) return '线路 1';
    return _channel.sourceNames[_sourceIndex.clamp(
      0,
      _channel.sourceNames.length - 1,
    )];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterFullscreen();
    if (widget.initialUnlocked) _unlocked.add(_channel);
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    // 硬件级唤醒兜底（见 [_rawKeyWake]）。
    HardwareKeyboard.instance.addHandler(_rawKeyWake);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prepare();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 子路由 pop 后焦点会停在路由 scope（AGENTS.md §3 规则 9）；路由只能在
    // didChangeDependencies 之后读取，不能放 initState。
    final route = ModalRoute.of(context);
    if (route != null && !_routeSubscribed) {
      _routeSubscribed = true;
      kRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // 避免自动隐藏定时器在覆盖路由期间操作底层焦点；回调也会独立校验
    // 路由当前性，以覆盖已经进入事件队列的 timer。
    _routeCovered = true;
    _hideTimer?.cancel();
  }

  Future<void> _enterFullscreen() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> _leaveFullscreen() async {
    try {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await WakelockPlus.disable();
    } catch (_) {}
  }

  Future<void> _prepare({int? channelIndex, int? sourceIndex}) async {
    _hideTimer?.cancel();
    if (channelIndex != null) {
      final next = channelIndex.clamp(0, _group.channels.length - 1);
      // 只有真正换台才重置线路；失败后的「重试」应保持当前线路。
      if (next != _channelIndex) _sourceIndex = 0;
      _channelIndex = next;
    }
    if (sourceIndex != null) {
      _sourceIndex = sourceIndex.clamp(0, _channel.urls.length - 1);
    }
    if (_channel.password.isNotEmpty && !_unlocked.contains(_channel)) {
      _overlayOpen = true;
      final allowed = await unlockChannel(context, _channel.password);
      _overlayOpen = false;
      if (!mounted) return;
      if (!allowed) {
        setState(() {
          _loading = false;
          _errorVisible = true;
          _error = '频道已锁定，请重试并输入密码，或选择其他频道';
        });
        _focusError();
        return;
      }
      _unlocked.add(_channel);
    }
    final token = ++_requestToken;
    final previous = _video;
    _video = null;
    previous
      ?..removeListener(_onVideoStateChanged)
      ..removeListener(_onTick)
      ..close();
    _lastSyncMs = -1;
    setState(() {
      _loading = true;
      _error = null;
      _errorVisible = false;
      _controlsVisible = false;
    });
    if (_isCurrentRoute && !_channelPanel && !_overlayOpen) {
      _focus.root.requestFocus();
    }
    if (_url.isEmpty) {
      setState(() {
        _loading = false;
        _error = '这个频道没有可用播放地址';
        _errorVisible = true;
        _controlsVisible = true;
      });
      _focusError();
      return;
    }
    try {
      final headers = widget.httpHeaders.isEmpty
          ? const {'User-Agent': 'okhttp/3.15'}
          : widget.httpHeaders;
      final useMediaKit = context.read<AppController?>()?.liveMediaKit ?? false;
      // 网络策略（代理/DoH）在工厂内接入：改写 URL 或 mpv http-proxy；
      // 直播 m3u8 的分片也会经本地代理持续回源，换台即断开旧会话。
      final PlayerBackend video = await createPlayerBackend(
        useMediaKit: useMediaKit,
        url: _url,
        headers: headers,
      );
      _video = video;
      // 直播没有进度条，但缓冲/播放态仍走 video 的 ValueListenableBuilder
      // 局部重建；这里只处理「必须整屏换状态」的解码失败（AGENTS.md §5.5）。
      video.addListener(_onVideoStateChanged);
      await video.initialize().timeout(
        Duration(seconds: _preferences.timeoutSeconds),
      );
      if (!mounted || token != _requestToken) {
        await video.close();
        return;
      }
      video.addListener(_onTick);
      await video.play();
      if (!mounted || token != _requestToken) return;
      final app = context.read<AppController?>();
      if (app != null && _replayUrl == null) {
        await app.storage.setJsonList('live_last_channel', [
          {
            'source': app.activeLiveSource?.url ?? '',
            'group': _group.name,
            'channel': _channel.name,
          },
        ]);
      }
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _controlsVisible = true;
      });
      _focusPlay();
      _scheduleHide();
    } catch (error) {
      if (!mounted || token != _requestToken) return;
      final failed = _video;
      _video = null;
      failed
        ?..removeListener(_onVideoStateChanged)
        ..removeListener(_onTick)
        ..close();
      setState(() {
        _loading = false;
        _error = _friendly(error);
        _errorVisible = true;
        // 保持控制层的可见状态，错误层显示后由 _focusError 显式投焦到「重试」。
        _controlsVisible = true;
      });
      _focusError();
    }
  }

  String _friendly(Object error) {
    return friendlyPlaybackError(error);
  }

  List<LiveGroup> get _groups =>
      widget.groups.isEmpty ? [widget.group] : widget.groups;

  bool _handleChannelKey(LogicalKeyboardKey key) {
    final digit = RegExp(r'^[0-9]$').hasMatch(key.keyLabel)
        ? key.keyLabel
        : null;
    if (digit != null) {
      _numberTimer?.cancel();
      setState(() => _digits = (_digits.length >= 4 ? '' : _digits) + digit);
      _numberTimer = Timer(const Duration(milliseconds: 1200), _commitNumber);
      return true;
    }
    if (_digits.isNotEmpty &&
        (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select)) {
      _commitNumber();
      return true;
    }
    final step = key == LogicalKeyboardKey.channelUp
        ? 1
        : key == LogicalKeyboardKey.channelDown
        ? -1
        : !_controlsVisible && key == LogicalKeyboardKey.arrowUp
        ? 1
        : !_controlsVisible && key == LogicalKeyboardKey.arrowDown
        ? -1
        : 0;
    if (step == 0) return false;
    _stepChannel(_preferences.reverse ? -step : step);
    return true;
  }

  void _commitNumber() {
    _numberTimer?.cancel();
    final number = int.tryParse(_digits);
    if (!mounted) return;
    setState(() => _digits = '');
    var ordinal = 0;
    for (final group in _groups) {
      for (var i = 0; i < group.channels.length; i++) {
        final channel = group.channels[i];
        ordinal++;
        if ((channel.number > 0 ? channel.number : ordinal) == number) {
          _group = group;
          _switchChannel(i);
          return;
        }
      }
    }
    showAppSnack(context, '没有这个频道号，请查看频道列表');
  }

  void _stepChannel(int step) {
    final target = _channelIndex + step;
    if (target >= 0 && target < _group.channels.length) {
      _switchChannel(target);
    } else if (_preferences.crossGroup && _groups.length > 1) {
      final index = _groups.indexOf(_group);
      _group = _groups[(index + step + _groups.length) % _groups.length];
      _switchChannel(step > 0 ? 0 : _group.channels.length - 1);
    } else {
      _switchChannel(
        (target + _group.channels.length) % _group.channels.length,
      );
    }
  }

  Future<void> _showReplay() async {
    _hideTimer?.cancel();
    _overlayOpen = true;
    final channel = _channel;
    try {
      final now = DateTime.now();
      final results = await Future.wait(
        List.generate(
          channel.catchupDays.clamp(1, 7),
          (day) => EpgService().load(
            widget.epgUrl,
            channel.epgId.isEmpty ? channel.name : channel.epgId,
            now: now.subtract(Duration(days: day)),
          ),
        ),
      );
      if (!mounted || !identical(channel, _channel)) return;
      final programmes =
          results
              .expand((schedule) => schedule.programmes)
              .where(
                (p) =>
                    p.end.isBefore(now) &&
                    channel.replayUrl(p.start, p.end, now: now) != null,
              )
              .toList()
            ..sort((a, b) => b.start.compareTo(a.start));
      final selected = await showTvSheet<EpgProgramme>(
        context,
        title: '节目回看',
        subtitle: '${channel.name} · 最近 ${channel.catchupDays} 天',
        builder: (sheetContext) {
          final skin = TvSkin.of(sheetContext);
          final text = AppText.of(sheetContext);
          return programmes.isEmpty
              ? const Center(child: Text('暂无可回看的节目'))
              : ListView.separated(
                  padding: EdgeInsets.all(skin.spaceLg),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(
                    kTvListCacheExtent,
                  ),
                  addAutomaticKeepAlives: false,
                  itemCount: programmes.length,
                  separatorBuilder: (_, _) => SizedBox(height: skin.spaceSm),
                  itemBuilder: (_, i) {
                    final p = programmes[i];
                    return TvFocusable(
                      autofocus: i == 0,
                      onTap: () => Navigator.pop(sheetContext, p),
                      child: Padding(
                        padding: EdgeInsets.all(skin.spaceMd),
                        child: Text(
                          '${p.start.month}/${p.start.day} ${p.start.hour}:${'${p.start.minute}'.padLeft(2, '0')}  ${p.title}',
                          style: text.bodyStrong.copyWith(color: Colors.white),
                        ),
                      ),
                    );
                  },
                );
        },
      );
      if (!mounted || selected == null) return;
      _replayUrl = channel.replayUrl(selected.start, selected.end);
      _replayTitle = selected.title;
      await _prepare();
    } catch (_) {
      if (mounted) showAppSnack(context, '节目单加载失败，请稍后重试', error: true);
    } finally {
      _overlayOpen = false;
      if (mounted) {
        _focusPlay();
        _scheduleHide();
      }
    }
  }

  Future<void> _showLiveSettings() async {
    _hideTimer?.cancel();
    _overlayOpen = true;
    await showTvSheet<void>(
      context,
      title: '直播设置',
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final skin = TvSkin.of(context);
          final text = AppText.of(context);
          void change(LivePreferences value) {
            update(() => _preferences = value);
            setState(() {});
            // 独立挂载播放器也可用，正式入口由 AppController 持久化。
            final controllers = this.context.read<AppController?>();
            controllers?.setLivePreferences(value);
          }

          Widget row(String label, VoidCallback tap) => TvFocusable(
            onTap: tap,
            child: Padding(
              padding: EdgeInsets.all(skin.spaceMd),
              child: Text(
                label,
                style: text.bodyLarge.copyWith(color: Colors.white),
              ),
            ),
          );
          return ListView(
            padding: EdgeInsets.all(skin.spaceLg),
            scrollCacheExtent: const ScrollCacheExtent.pixels(
              kTvListCacheExtent,
            ),
            addAutomaticKeepAlives: false,
            children: [
              row('连接超时：${_preferences.timeoutSeconds} 秒', () {
                const values = [8, 12, 20, 30];
                change(
                  _preferences.copyWith(
                    timeoutSeconds:
                        values[(values.indexOf(_preferences.timeoutSeconds) +
                                1) %
                            values.length],
                  ),
                );
              }),
              row(
                '跨组换台：${_preferences.crossGroup ? '开' : '关'}',
                () => change(
                  _preferences.copyWith(crossGroup: !_preferences.crossGroup),
                ),
              ),
              row(
                '反向换台：${_preferences.reverse ? '开' : '关'}',
                () => change(
                  _preferences.copyWith(reverse: !_preferences.reverse),
                ),
              ),
              row(
                '显示时间：${_preferences.showClock ? '开' : '关'}',
                () => change(
                  _preferences.copyWith(showClock: !_preferences.showClock),
                ),
              ),
              row(
                '缓冲信息：${_preferences.showNetwork ? '开' : '关'}',
                () => change(
                  _preferences.copyWith(showNetwork: !_preferences.showNetwork),
                ),
              ),
            ],
          );
        },
      ),
    );
    _overlayOpen = false;
    if (mounted) _scheduleHide();
  }

  /// 控制器级监听：解码失败这类事件必须换整屏状态（错误层），
  /// 其余播放态变化由 `video` 的监听局部重建，不再每帧 setState。
  void _onVideoStateChanged() {
    final video = _video;
    if (video == null || !mounted) return;
    if (video.value.hasError && !_errorVisible) {
      _hideTimer?.cancel();
      setState(() {
        _loading = false;
        _error = friendlyPlaybackError(video.value.errorDescription ?? '');
        _errorVisible = true;
        _controlsVisible = true;
      });
      _focusError();
    }
  }

  /// 直播的时间轴监听：**不做 UI 重建**。
  ///
  /// 直播没有进度条，原先的 `setState(() {})` 每帧重建整页（控制层、错误层、
  /// 频道面板全部重跑 build），是 AGENTS.md §5.5 的硬违规。播放态与缓冲态
  /// 由 `_buildControls` 里的 `ValueListenableBuilder` 局部重建。
  ///
  /// 这里只兜一件 `ValueListenableBuilder` 覆盖不到的事：直播流被服务端
  /// 重定向/重连后 `position` 会瞬间归零，画面还是上一秒的内容。发现这种
  /// 回绕就重挂一次画面（`setState` 一次，不是每帧）。
  void _onTick() {
    final video = _video;
    if (video == null || !mounted) return;
    final positionMs = video.value.position.inMilliseconds;
    final lastSync = _lastSyncMs;
    _lastSyncMs = positionMs;
    if (lastSync < 0 || positionMs + 1000 >= lastSync) return;
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_video?.value.isPlaying != true ||
        _channelPanel ||
        _overlayOpen ||
        _errorVisible ||
        _loading ||
        !_controlsVisible ||
        !_isCurrentRoute) {
      return;
    }
    _hideTimer = Timer(kControlsAutoHide, () {
      if (mounted &&
          _isCurrentRoute &&
          !_channelPanel &&
          !_overlayOpen &&
          !_loading &&
          !_errorVisible) {
        _hideControls();
      }
    });
  }

  /// 隐藏控制层（自动隐藏 / ESC / 顶行 UP / 中央键 DOWN 的统一出口，
  /// 与 player_page 的 _hideControls 同构）：先 setState 再显式把焦点
  /// 还给页面根——所有隐藏入口都在 ExcludeFocus 生效前归还根节点，
  /// 避免焦点落到被本页盖住的下一路由节点上（AGENTS.md §3 规则 4/8）。
  void _hideControls() {
    if (!_isCurrentRoute) return;
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
    _focus.root.requestFocus();
  }

  /// 硬件级唤醒兜底：控制层隐藏后焦点可能落到被盖住的下一路由节点上
  /// （「焦点在暗处」），方向键送不到 `_focus.root`；这里订阅全局硬件键盘流，
  /// 任何键先唤醒控制层。频道面板打开时不拦（面板有自己的焦点作用域）。
  bool _rawKeyWake(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted ||
        !_isCurrentRoute ||
        _channelPanel ||
        _overlayOpen ||
        _errorVisible) {
      return false;
    }
    if (_handleChannelKey(event.logicalKey)) return true;
    if (_controlsVisible) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return true;
    }
    _showControls();
    return true;
  }

  void _showControls() {
    if (!_controlsVisible) {
      // 唤醒的第一帧就把焦点移到播放/暂停按钮（AGENTS.md §3 规则 4）：
      // 控制层隐藏时整棵子树被 ExcludeFocus 排除，不接管焦点的话
      // 焦点会停在页面根，方向键与 OK 都落不到控件上。
      setState(() => _controlsVisible = true);
      _focusPlay();
    } else {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  /// 把焦点显式移到中央「播放/暂停」键（控制层可见态的默认落点）。
  /// 统一走 [PlayerFocusNodes.focusPlayAfterFrame]：等控制层挂回/解除
  /// ExcludeFocus 后节点进了焦点树再请求（与点播侧同构）。
  void _focusPlay() => _focus.focusPlayAfterFrame(
    allow: () =>
        mounted &&
        _controlsVisible &&
        !_channelPanel &&
        !_overlayOpen &&
        !_loading &&
        !_errorVisible &&
        _isCurrentRoute,
  );

  /// 子路由（扫码解锁、密码弹窗、节目单等）返回后重投焦点，避免停在
  /// 路由 scope（AGENTS.md §3 规则 9）。与 player_page 同构：sheet 自己会
  /// 还焦触发键，这里只同步收根兜底，帧末仍没人还焦时按状态机收归。
  @override
  void didPopNext() {
    _routeCovered = false;
    if (!mounted || !_isCurrentRoute || _channelPanel || _overlayOpen) {
      return;
    }
    if (_errorVisible) {
      _focusError();
      return;
    }
    _focus.root.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrentRoute) return;
      if (_errorVisible) return;
      final primary = FocusManager.instance.primaryFocus;
      // 已被覆盖层还焦（primary 是活着的别的节点）→ 不抢；primary 为空
      // 或挂在已销毁的路由节点上（context == null）都算「没人还焦」。
      if (primary != null &&
          primary != _focus.root &&
          primary.context != null) {
        return;
      }
      if (_controlsVisible && !_channelPanel && !_loading) {
        if (_focus.play.canRequestFocus) {
          _focus.play.requestFocus();
        } else {
          _focus.root.requestFocus();
        }
      }
      if (_controlsVisible) _scheduleHide();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 错误层可见时把焦点投到「重试」（与点播侧 _focusError 对齐）。
  void _focusError() {
    _hideTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_errorVisible ||
          _loading ||
          _channelPanel ||
          _overlayOpen ||
          !_isCurrentRoute) {
        return;
      }
      if (_retryFocus.context != null && _retryFocus.canRequestFocus) {
        _retryFocus.requestFocus();
      } else {
        _focus.root.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _openChannelPanel() {
    // AGENTS.md §3 规则 3：关闭侧栏后焦点回到触发按钮，而不是页面根。
    _focus.focusBeforePanel ??= FocusManager.instance.primaryFocus;
    setState(() {
      _channelPanel = true;
      _controlsVisible = true;
    });
    _hideTimer?.cancel();
    // 回收上次会话/换组残留的未挂树频道节点（节点表按 index 复用，
    // 仍挂树或持焦的一律保留，避免长会话下节点无限增长）。
    _channelNodes.removeWhere((_, node) {
      if (node.context != null || node.hasFocus) return false;
      node.dispose();
      return true;
    });
    // 面板打开 → 焦点直达「当前频道」行（FOCUS-06：覆盖层打开后第一落点
    // 就是内容主项，比落在关闭按钮上少一次移动）；无频道时退回面板作用域
    // （关闭按钮）。页面主体被控制层的 ExcludeFocus 挡在外面，UP/DOWN
    // 不会跑到面板之外（FOCUS-08）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_channelPanel) return;
      if (_group.channels.isEmpty) {
        _focus.panelScope.requestFocus();
        return;
      }
      _focusChannelIndex(_channelIndex, down: true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 频道行焦点节点（懒创建，index 为键；换组时行会重新挂到同 index 的
  /// 节点上，节点表跨组复用是安全的——残留的高位节点在开面板时回收）。
  FocusNode _channelNode(int index) => _channelNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'channel-$index'),
  );

  /// 按 index 确定性投递焦点到频道行：目标行已挂载（视口内/缓存区）→ 当帧
  /// requestFocus + 帧后 ensureVisible；未挂载（缓存区外）→ requestFocus
  /// 先挂起（FocusNode 挂树时自动生效，同 home_page 网格范式），同时按
  /// 方向滚动一个视口的 80% 把目标行推进缓存区，帧后重试——长列表 UP/DOWN
  /// 跨出视口也不断链（AGENTS.md §3 规则 7 的 cacheExtent 死键问题）。
  void _focusChannelIndex(int index, {required bool down, int retry = 0}) {
    final request = ++_channelFocusRequest;
    if (index < 0 || index >= _group.channels.length) return;
    final node = _channelNode(index);
    node.requestFocus();
    WidgetsBinding.instance.ensureVisualUpdate();
    final ctx = node.context;
    if (ctx != null && ctx.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _channelFocusRequest || !node.hasFocus) {
          return;
        }
        final target = node.context;
        if (target != null && target.mounted) {
          Scrollable.ensureVisible(
            target,
            alignment: 0.5,
            duration: AppMotion.scrollDuration(context),
            curve: AppMotion.scrollCurve,
          );
        }
      });
      return;
    }
    // 缓存区外：滚动推进后重试（最多 8 次 ≈ 6 个视口，覆盖常规频道数）。
    if (!_channelScroll.hasClients || retry >= 8) return;
    final position = _channelScroll.position;
    final step = position.viewportDimension * 0.8 * (down ? 1 : -1);
    final target = (position.pixels + step)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < 0.5) return;
    void retryFocus() {
      if (!mounted || !_channelPanel || request != _channelFocusRequest) {
        return;
      }
      _focusChannelIndex(index, down: down, retry: retry + 1);
    }

    final duration = AppMotion.scrollDuration(context);
    if (duration == Duration.zero) {
      position.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) => retryFocus());
    } else {
      position
          .animateTo(target, duration: duration, curve: AppMotion.scrollCurve)
          .then((_) => retryFocus());
    }
  }

  /// 频道行方向键（单列纵向列表的显式投递，AGENTS.md §3 规则 7）：
  /// UP/DOWN 按 index ±1 移动；首行 UP → 面板「关闭」按钮；末行 DOWN
  /// 显式吞（面板底）。LEFT/RIGHT 放行（单列无横向语义，面板作用域内
  /// 几何遍历无候选即停）。
  KeyEventResult _handleChannelItemKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index > 0) {
        _focusChannelIndex(index - 1, down: false);
      } else {
        // 首行 UP → 面板头「关闭」按钮（面板顶唯一可获焦控件）。
        _panelCloseFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (index + 1 < _group.channels.length) {
        _focusChannelIndex(index + 1, down: true);
      }
      // 末行 DOWN：面板底，显式吞。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _closeChannelPanel() {
    _channelFocusRequest++;
    setState(() => _channelPanel = false);
    _restorePanelFocus();
    _scheduleHide();
  }

  /// 焦点归还：优先给开面板前的落点，拿不到就退回「频道列表」触发按钮，
  /// 最后才是页面根（AGENTS.md §3 规则 3）。`_switchChannel` 也走这条路
  /// ——换台要 await `_prepare`，早 requestFocus 会让节点悬空在控制层隐藏
  /// 的瞬间。统一走 [PlayerFocusNodes.restorePanelFocusAfterFrame]（帧后
  /// 执行：等面板撤下且控制层 ExcludeFocus 解除；重建前这里是同步版，
  /// 面板关闭当帧 ExcludeFocus 尚未解除，同步还焦会落空）。
  void _restorePanelFocus() => _focus.restorePanelFocusAfterFrame(
    allow: () =>
        mounted &&
        _controlsVisible &&
        !_channelPanel &&
        !_overlayOpen &&
        !_loading &&
        !_errorVisible &&
        _isCurrentRoute,
  );

  void _toggleControls() {
    if (_channelPanel) {
      _closeChannelPanel();
      return;
    }
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  Future<void> _switchChannel(int index) async {
    if (index < 0 || index >= _group.channels.length) return;
    _channelFocusRequest++;
    _replayUrl = null;
    _replayTitle = null;
    // 换台可能是从错误层的「下一个频道」进来的，此时频道面板没开、
    // 控制层也没获焦，`primaryFocus` 多半是页面根，记下来反而会把焦点
    // 抢回根。只在面板确实开着时才记录来源焦点。
    if (_channelPanel) {
      _focus.focusBeforePanel ??= FocusManager.instance.primaryFocus;
    }
    setState(() {
      _channelPanel = false;
      _channelIndex = index;
      _sourceIndex = 0;
    });
    // `_prepare` 里有 await，且会 `_controlsVisible = false`；此时立刻
    // requestFocus 会让刚获焦的列表项悬空。等画面就绪之后再归还焦点。
    await _prepare(channelIndex: index);
    if (!mounted) return;
    // 只有「面板当时开着」才记了来源焦点；从错误层进来时没记，此时焦点本来
    // 就不在控制层上，别硬塞回触发按钮（会抢掉错误层按钮的焦点）。
    if (_focus.focusBeforePanel != null) {
      _restorePanelFocus();
    }
    _scheduleHide();
  }

  Future<void> _switchSource() async {
    if (_channel.urls.length <= 1) return;
    await _prepare(sourceIndex: (_sourceIndex + 1) % _channel.urls.length);
  }

  Future<void> _togglePlay() async {
    final video = _video;
    if (video == null) return;
    if (video.value.isPlaying) {
      await video.pause();
      _hideTimer?.cancel();
    } else {
      await video.play();
      _scheduleHide();
    }
    // 播放/暂停图标走 video 的监听局部重建，这里不再整页 setState。
    if (mounted) _showControls();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // MEDIA-07 / P1-3：切后台时暂停直播流，避免持续拉流耗流量/占解码器；
    // 回前台保持暂停并唤出控制层，让用户明确看到暂停态（直播不自动续播）。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _hideTimer?.cancel();
      _video?.pause();
    } else if (state == AppLifecycleState.resumed &&
        mounted &&
        _isCurrentRoute &&
        !_channelPanel &&
        !_overlayOpen) {
      if (_errorVisible) {
        _focusError();
        return;
      }
      if (_loading) {
        _focus.root.requestFocus();
        return;
      }
      setState(() => _controlsVisible = true);
      _focusPlay();
      _scheduleHide();
    }
  }

  /// 控制层顶行（返回/换源/回看/设置/频道列表）的方向键：UP = 回画面
  /// （隐藏控制层，「控制层可见 → 隐藏」的显式上行出口，与「任意方向键
  /// 唤醒」互逆）；DOWN = 中央播放键。LEFT/RIGHT 行内走几何。
  KeyEventResult _handleLiveTopRowKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _hideControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focus.play.canRequestFocus) _focus.play.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_errorVisible && !_channelPanel && !_overlayOpen) {
      if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
        Navigator.maybePop(context);
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final step = switch (key) {
          LogicalKeyboardKey.arrowLeft => -1,
          LogicalKeyboardKey.arrowRight => 1,
          LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowDown => 0,
          _ => null,
        };
        if (step != null) {
          final actions = [
            _retryFocus,
            if (_channel.urls.length > 1) _errorSourceFocus,
            if (_channelIndex + 1 < _group.channels.length) _errorNextFocus,
          ];
          final current = actions.indexOf(
            FocusManager.instance.primaryFocus ?? _focus.root,
          );
          final next = current < 0
              ? 0
              : (current + step).clamp(0, actions.length - 1);
          actions[next].requestFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 面板开着时焦点被关在 `_focus.panelScope` 作用域里，方向键只在这棵子树里走，
    // 页面根收不到——这里不用特判。
    //
    // 返回键语义优先级链（AGENTS.md §3 硬性规则 5）：频道面板 → 关面板；
    // 否则控制层可见 → 只隐藏控制层（不是退出页面）；否则 → `Navigator.maybePop`。
    // escape 与 `PopScope` 不重复处理：遥控器返回键走 `onPopInvokedWithResult`
    // （`canPop:false` 时页面不退出、只关面板），escape 只在这里兜底。
    if (key == LogicalKeyboardKey.escape) {
      if (_channelPanel) {
        // 统一走清理方法，别绕过焦点归还与 `_scheduleHide`（AGENTS.md §3）。
        _closeChannelPanel();
        return KeyEventResult.handled;
      }
      if (_controlsVisible) {
        // 统一走 _hideControls（setState + ExcludeFocus 生效前归还根焦点）。
        _hideControls();
        return KeyEventResult.handled;
      }
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }
    // REMOTE-03（a11y P1-1）：遥控器媒体播放/暂停键在控制层隐藏时也必须切换
    // 播放，不能被下面的「唤醒控制层」分支吞掉。
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (!_controlsVisible) {
      // 控制层隐藏时任何方向键都只负责唤醒，唤醒后焦点落在播放/暂停按钮上
      // （§3 硬性规则 4）。这里把按键吞掉，避免「左右键既唤醒又移焦点」。
      _showControls();
      return KeyEventResult.handled;
    }
    _scheduleHide();
    // 直播没有进度条，左右键就是焦点在顶栏/中央按钮之间的普通方向移动，
    // 页面根不插手（也不存在「既 seek 又移焦点」）。
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    kRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_rawKeyWake);
    _hideTimer?.cancel();
    _numberTimer?.cancel();
    _clockTimer?.cancel();
    _focus.dispose();
    _channelScroll.dispose();
    for (final node in _channelNodes.values) {
      node.dispose();
    }
    _panelCloseFocus.dispose();
    _backFocus.dispose();
    _retryFocus.dispose();
    _errorSourceFocus.dispose();
    _errorNextFocus.dispose();
    _video
      ?..removeListener(_onVideoStateChanged)
      ..removeListener(_onTick)
      ..close();
    _leaveFullscreen();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final skin = TvSkin.of(context);
    return PopScope(
      canPop: !_channelPanel,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _channelPanel) _closeChannelPanel();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus.root,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video != null && video.value.isInitialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: video.value.aspectRatio <= 0
                        ? 16 / 9
                        : video.value.aspectRatio,
                    child: video.buildVideo(context),
                  ),
                )
              else
                const ColoredBox(color: Colors.black),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                ),
              ),
              if (_loading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 38,
                        height: 38,
                        child: CircularProgressIndicator(strokeWidth: 2.6),
                      ),
                      SizedBox(height: skin.spaceMd),
                      Text(
                        '正在连接 ${_channel.name}…',
                        style: AppText.of(context).bodyStrong.copyWith(
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
              if (video != null)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: video,
                  builder: (context, value, _) {
                    // 缓冲指示不再每帧重建整页，只重建这个小圈。
                    return value.isBuffering && !_loading
                        ? const Center(
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            ),
                          )
                        : const SizedBox.shrink();
                  },
                ),
              // 控制层隐藏时整棵子树（顶栏返回/换源/频道列表、中央播放、底部
              // 信息）一起退出绘制与命中测试，省 GPU；`ExcludeFocus` 排除焦点。
              _wrapControls(skin, video),
              if (_digits.isNotEmpty)
                Positioned(
                  top: 80,
                  right: 80,
                  child: Text(
                    _digits,
                    style: AppText.of(context).display
                        .copyWith(color: Colors.white),
                  ),
                ),
              if (_errorVisible) _buildError(),
              // 面板只在打开时挂进树里：关闭后连同 `FocusScope` 一起销毁，
              // 面板内节点不会留在焦点树里抢方向键（AGENTS.md §3 规则 4）。
              // Positioned 必须是 Stack 的直接子节点（ParentDataWidget 不能
              // 隔着 FocusScope/Semantics 生效——2026-11-19 修：原先是
              // FocusScope 包 Positioned，打开面板即抛 ParentDataWidget
              // 断言），作用域放里层。
              if (_channelPanel)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: 400,
                  child: FocusScope(
                    node: _focus.panelScope,
                    child: _buildChannelPanel(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 控制层显隐包装：统一走 [PlayerControlsLayer]（AnimatedOpacity 淡入
  /// 淡出 + Offstage 省 GPU + ExcludeFocus 焦点排除 + IgnorePointer 命中
  /// 排除，见 player_focus.dart 头注）。与点播侧同构，只有附加排除条件
  /// 不同（直播是频道面板 / 设置弹窗 / 错误层）。
  Widget _wrapControls(TvSkin skin, PlayerBackend? video) {
    return PlayerControlsLayer(
      visible: _controlsVisible,
      focusExcluded: _channelPanel || _overlayOpen || _errorVisible,
      child: _buildControls(video),
    );
  }

  /// 皮肤动效时长（`Duration + Duration` 在 Dart 里不是合法组合，
  /// 所以把余量折算成毫秒再加，语义等价于「皮肤时长再稍慢一点」）。
  Duration _panelMotion(Duration base, {int extra = 0}) =>
      playerPanelMotion(context, base, extra: extra);

  /// 控制层主体。直播没有进度条，唯一随 `video` 高频变化的是播放/暂停图标；
  /// 只把它包在 [ValueListenableBuilder] 里，10Hz 的位置通知只重建这一个按钮，
  /// 不再重建整棵控制层（AGENTS.md §5.5 / P0-6 10Hz 整树重建）。
  Widget _buildControls(PlayerBackend? video) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    if (video == null) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(decoration: BoxDecoration(gradient: skin.controlScrim)),
        Positioned(
          left: skin.spaceSm + 4,
          right: skin.spaceSm + 4,
          top: MediaQuery.paddingOf(context).top + (skin.spaceSm - 2),
          // 顶行（返回/换源/回看/设置/频道列表）：UP = 回画面、DOWN =
          // 中央播放键（_handleLiveTopRowKey）；行内 LEFT/RIGHT 走几何。
          child: Focus(
            canRequestFocus: false,
            debugLabel: 'liveTopRow',
            onKeyEvent: _handleLiveTopRowKey,
            child: Row(
              children: [
                _RoundIcon(
                  icon: Icons.arrow_back_rounded,
                  semanticLabel: '返回',
                  focusNode: _backFocus,
                  onTap: () => Navigator.maybePop(context),
                ),
                SizedBox(width: skin.spaceSm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const _LiveBadge(),
                          SizedBox(width: skin.spaceSm - 2),
                          Flexible(
                            child: Text(
                              _channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // 控制层文字硬约束白色：视频亮度不可控，
                              // smartisan 的深色字在画面上读不出来。
                              style: text.bodyLarge.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: skin.spaceXs - 3),
                      EpgOverlay(url: widget.epgUrl, channel: _channel.name),
                      Text(
                        '${_group.name}  ·  $_sourceName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.label.copyWith(
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                      if (_replayTitle != null)
                        Text(
                          '回看 · $_replayTitle',
                          style: text.bodyStrong.copyWith(color: Colors.white),
                        ),
                      if (_preferences.showClock)
                        Text(
                          '${_now.hour}:${'${_now.minute}'.padLeft(2, '0')}',
                          style: text.label.copyWith(color: Colors.white),
                        ),
                      if (_preferences.showNetwork) const NetworkSpeed(),
                      if (_preferences.showNetwork)
                        ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: video,
                          builder: (_, value, _) => Text(
                            value.isBuffering
                                ? '正在缓冲'
                                : '连接正常 · ${value.size.width.toInt()}×${value.size.height.toInt()}',
                            style: text.label.copyWith(color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_channel.urls.length > 1)
                  TextButton.icon(
                    onPressed: _switchSource,
                    // §8.3：控制层文字硬约束白色，不读 skin.textSecondary（P1-B）。
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text(
                      '换源 ${_sourceIndex + 1}/${_channel.urls.length}',
                    ),
                  ),
                SizedBox(width: skin.spaceXs),
                if (_channel.catchupSource.isNotEmpty &&
                    widget.epgUrl.isNotEmpty)
                  _RoundIcon(
                    icon: Icons.history_rounded,
                    semanticLabel: '节目回看',
                    onTap: _showReplay,
                  ),
                if (_replayUrl != null)
                  _RoundIcon(
                    icon: Icons.live_tv_rounded,
                    semanticLabel: '返回直播',
                    onTap: () {
                      _replayUrl = null;
                      _replayTitle = null;
                      _prepare();
                    },
                  ),
                _RoundIcon(
                  icon: Icons.settings_rounded,
                  semanticLabel: '直播设置',
                  onTap: _showLiveSettings,
                ),
                _RoundIcon(
                  icon: Icons.playlist_play_rounded,
                  semanticLabel: '频道列表',
                  focusNode: _focus.panelTrigger,
                  onTap: _openChannelPanel,
                ),
              ],
            ),
          ),
        ),
        Center(
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: video,
            builder: (context, value, _) => TvFocusable(
              radius: skin.radiusPill,
              focusNode: _focus.play,
              semanticLabel: value.isPlaying ? '暂停' : '播放',
              onTap: _togglePlay,
              // 中央播放键的方向键（控制层内最下沿的交互控件）：DOWN = 回
              // 画面（隐藏控制层）；UP → 顶行「返回」键；LEFT/RIGHT 显式吞
              // （中央无同行控件，防几何遍历甩到顶行按钮组）。
              onKeyEvent: (event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.arrowDown) {
                  _hideControls();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowUp) {
                  if (_backFocus.canRequestFocus) _backFocus.requestFocus();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowLeft ||
                    key == LogicalKeyboardKey.arrowRight) {
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Container(
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
                child: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: skin.spaceMd + 4,
          right: skin.spaceMd + 4,
          bottom: MediaQuery.paddingOf(context).bottom + (skin.spaceMd + 2),
          child: Row(
            children: [
              Icon(
                Icons.hd_rounded,
                size: skin.spaceMd + 1,
                color: Colors.white.withValues(alpha: 0.36),
              ),
              SizedBox(width: skin.spaceXs),
              Text(
                '直播 · ${_group.channels.length} 个频道',
                style: text.label.copyWith(
                  color: Colors.white.withValues(alpha: 0.36),
                ),
              ),
              const Spacer(),
              Text(
                _sourceName,
                style: text.label.copyWith(
                  color: Colors.white.withValues(alpha: 0.24),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.75),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Padding(
            padding: EdgeInsets.all(skin.spaceLg + 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.signal_wifi_connected_no_internet_4_rounded,
                  color: skin.danger,
                  size: 44,
                ),
                SizedBox(height: skin.spaceMd - 2),
                Text(
                  _error ?? '播放失败，请重试',
                  textAlign: TextAlign.center,
                  style: text.bodyStrong.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.6,
                  ),
                ),
                SizedBox(height: skin.spaceLg - 4),
                Wrap(
                  spacing: skin.spaceSm,
                  runSpacing: skin.spaceSm,
                  alignment: WrapAlignment.center,
                  children: [
                    _errorAction(
                      focusNode: _retryFocus,
                      onTap: () => _prepare(channelIndex: _channelIndex),
                      icon: Icons.refresh_rounded,
                      label: '重试',
                    ),
                    if (_channel.urls.length > 1)
                      _errorAction(
                        focusNode: _errorSourceFocus,
                        onTap: _switchSource,
                        icon: Icons.swap_horiz_rounded,
                        label: '切换线路',
                      ),
                    if (_channelIndex + 1 < _group.channels.length)
                      _errorAction(
                        focusNode: _errorNextFocus,
                        onTap: () => _switchChannel(_channelIndex + 1),
                        icon: Icons.skip_next_rounded,
                        label: '下一个频道',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorAction({
    required FocusNode focusNode,
    required VoidCallback onTap,
    required IconData icon,
    required String label,
  }) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return TvFocusable(
      focusNode: focusNode,
      semanticLabel: label,
      radius: skin.radiusMd,
      onTap: onTap,
      child: Builder(
        builder: (context) {
          final tinted = TvFocusTint.of(context);
          // 错误提示浮在视频上，白字搭配局部黑底，获焦视觉由 TvFocusable 提供。
          final foreground = tinted ? skin.textOnAccent : Colors.white;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: tinted ? null : Colors.black.withValues(alpha: 0.48),
              borderRadius: BorderRadius.circular(skin.radiusMd),
              border: Border.all(
                color: tinted
                    ? Colors.transparent
                    : Colors.white.withValues(alpha: 0.36),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: skin.spaceMd,
                vertical: skin.spaceSm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: foreground),
                  SizedBox(width: skin.spaceXs),
                  Text(
                    label,
                    style: text.bodyStrong.copyWith(color: foreground),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 频道面板。宽度是设计常量 400（固定 1280×720 画布，不做设备判断；
  /// Positioned 由 build 套在 Stack 直下，FocusScope 里层）。滑入用
  /// [TweenAnimationBuilder] 而不是 `AnimatedPositioned`——面板只在打开时
  /// 挂进树里，入场即「从右侧 400+20 处滑到 0」。
  Widget _buildChannelPanel() {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    final panel = Material(
      color: Colors.transparent,
      child: Container(
        // 侧栏压在视频上：底色与描边硬约束深色（跟皮肤会让 smartisan
        // 亮色面板糊在画面上），只有圆角/间距/字号跟皮肤。
        decoration: BoxDecoration(
          color: const Color(0xF20A0C12),
          border: Border(
            left: BorderSide(
              color: Colors.white.withValues(alpha: 0.13),
              width: skin.surfaceSkin.panelBorderWidth,
            ),
          ),
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(skin.radiusMd),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(skin.radiusMd),
          ),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    skin.spaceMd + 2,
                    skin.spaceMd - 2,
                    skin.spaceSm - 2,
                    skin.spaceSm,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '频道列表',
                        style: text.cardTitle.copyWith(color: Colors.white),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: _closeChannelPanel,
                        tooltip: '关闭',
                        focusNode: _panelCloseFocus,
                        icon: const Icon(Icons.close_rounded),
                        color: Colors.white,
                        // DOWN → 几何落到频道行（面板头唯一的下行候选）。
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _channelScroll,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(
                      kTvListCacheExtent,
                    ),
                    addAutomaticKeepAlives: false,
                    padding: EdgeInsets.fromLTRB(
                      skin.spaceMd - 2,
                      0,
                      skin.spaceMd - 2,
                      skin.spaceMd,
                    ),
                    // 焦点行 DOWN/UP 的目标行必须在缓存区里已挂载，
                    // 显式投递才能落位（AGENTS.md §3 规则 7）。
                    itemCount: _group.channels.length,
                    itemBuilder: (context, index) {
                      final channel = _group.channels[index];
                      final selected = index == _channelIndex;
                      return Padding(
                        padding: EdgeInsets.only(bottom: skin.spaceXs),
                        child: TvFocusable(
                          radius: skin.radiusSm - 3,
                          scale: 1.01,
                          focusNode: _channelNode(index),
                          semanticLabel: channel.name,
                          onKeyEvent: (event) =>
                              _handleChannelItemKey(index, event),
                          onTap: () => _switchChannel(index),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: skin.spaceMd - 4,
                              vertical: skin.spaceSm,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? skin.accent.withValues(alpha: 0.18)
                                  : Colors.white.withValues(alpha: 0.035),
                              borderRadius: BorderRadius.circular(
                                skin.radiusSm - 3,
                              ),
                              border: Border.all(
                                color: selected
                                    ? skin.accent
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.live_tv_rounded,
                                  size: skin.spaceMd,
                                  color: selected
                                      ? skin.accent
                                      : Colors.white.withValues(alpha: 0.46),
                                ),
                                SizedBox(width: skin.spaceSm - 1),
                                Expanded(
                                  child: Text(
                                    channel.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyStrong.copyWith(
                                      color: selected
                                          ? skin.accent
                                          : Colors.white.withValues(
                                              alpha: 0.86,
                                            ),
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                if (channel.urls.length > 1)
                                  Text(
                                    '${channel.urls.length}源',
                                    style: text.meta.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.42,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Positioned 已由调用方套在 Stack 直下（FocusScope 里层，见 build）；
    // 这里只返回滑入动画 + 面板本体；400 是设计常量（Positioned 由 build
    // 套在 Stack 直下），滑出距离按「面板宽 + 20」算。
    const panelWidth = 400.0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: _panelMotion(skin.motionPanel, extra: 40),
      curve: Curves.easeOutCubic,
      builder: (context, slide, child) => Transform.translate(
        offset: Offset((panelWidth + 20) * slide, 0),
        child: child,
      ),
      child: panel,
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.icon,
    required this.onTap,
    this.focusNode,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// 「频道列表」触发按钮用它，关面板后焦点归还给它（AGENTS.md §3 规则 3）。
  final FocusNode? focusNode;

  /// 纯图标按钮的无障碍标签（ACCESS-01）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      radius: TvSkin.of(context).radiusPill,
      focusNode: focusNode,
      semanticLabel: semanticLabel,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          // 图标底压在视频画面上：底色/图标色硬约束黑白（跟随皮肤会在
          // smartisan 亮色下与控制层文字一起糊掉），圆角跟皮肤。
          color: Colors.black.withValues(alpha: 0.3),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Icon(icon, size: 21, color: Colors.white),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    final skin = TvSkin.of(context);
    final text = AppText.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: skin.spaceSm - 2,
        vertical: skin.spaceXs - 3,
      ),
      decoration: BoxDecoration(
        // 压在视频画面上：取强调色板里的「危险」色做 LIVE 底，
        // 三个皮肤下都是品牌红/橙系，文字统一用强调之上的前景色。
        color: skin.danger,
        borderRadius: BorderRadius.circular(skin.radiusSm - 3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.fiber_manual_record,
            size: skin.spaceSm - 2,
            color: skin.textOnAccent,
          ),
          SizedBox(width: skin.spaceXs - 3),
          Text(
            'LIVE',
            style: text.meta.copyWith(
              fontWeight: FontWeight.w800,
              color: skin.textOnAccent,
            ),
          ),
        ],
      ),
    );
  }
}
