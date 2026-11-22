package com.tvbox.tvbox_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// 长驻后台播放前台服务（参考 TVBox 原版 PlayService.java 改写为 Kotlin）。
///
/// 职责：startForeground 保活 + 媒体通知（标题/副标题/播放/暂停/停止）+
/// 音频焦点监听 + 自停清理。播放状态的唯一真相在 Dart 侧，本服务不维护
/// 第二份播放进度，只透传动作与展示快照。
///
/// 通知动作回传 Flutter 的时序（选广播而非直接 MethodChannel 的原因：
/// 广播不依赖 Flutter 引擎存活，且 PendingIntent 由系统持有，最稳）：
/// 1. 用户点通知按钮 → 系统派发明确广播到服务内部动态注册的 [ActionReceiver]；
/// 2. [ActionReceiver] 在主线程调 [notifyDart]，经 'tvbox/playback' 的
///    backgroundAction 方法把动作字符串回传 Dart；
/// 3. Dart 侧（BackgroundPlayback.onAction）真正执行 play/pause/stop，
///    再回调 backgroundUpdateState 刷新通知内容。
/// 引擎已销毁时 [notifyDart] 静默失败（通知仍在，服务继续保活）。
class ForegroundMediaService : Service() {

    companion object {
        /// 通知渠道与通知 id（全应用唯一）。
        private const val CHANNEL_ID = "tvbox_media_playback"
        private const val NOTIFY_ID = 1001

        /// 与 'tvbox/playback' 通道同名，见 MainActivity / android_playback.dart。
        private const val CHANNEL_NAME = "tvbox/playback"

        /// startService 的意图动作（与通知广播动作区分命名）。
        const val ACTION_START = "com.tvbox.tvbox_flutter.media.START"
        const val ACTION_UPDATE = "com.tvbox.tvbox_flutter.media.UPDATE"
        const val ACTION_STOP = "com.tvbox.tvbox_flutter.media.STOP"

        /// 通知按钮 / 音频焦点事件回传 Dart 的动作字符串（协议面）。
        const val NOTIFY_PLAY = "play"
        const val NOTIFY_PAUSE = "pause"
        const val NOTIFY_STOP = "stop"
        const val NOTIFY_AUDIO_FOCUS_LOST = "audioFocusLost"

        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_PLAYING = "playing"

        /// 服务自留的持久化文件（与 Dart 侧 storage.dart 的 bg_playback_state
        /// 双写互为兜底；Dart 侧为主源，这里保证原生侧也能自洽恢复）。
        const val PREFS_NAME = "tvbox_media_playback"
        const val PREF_URL = "url"
        const val PREF_TITLE = "title"
        const val PREF_POSITION_MS = "positionMs"
        const val PREF_PLAYING = "playing"

        /// MainActivity 启动时注入、销毁时清空；服务借此把动作回传 Dart。
        private var messenger: BinaryMessenger? = null
        fun bindMessenger(m: BinaryMessenger?) {
            messenger = m
        }

        /// 进程内当前展示快照（跨 onStartCommand 调用保持）。
        private var mediaUrl: String = ""
        private var mediaTitle: String = ""
        private var positionMs: Long = 0L
        private var playing: Boolean = false
    }

    private var foregroundStarted = false
    private var audioFocusGranted = false
    private var audioFocusRequest: AudioFocusRequest? = null
    private val handler = Handler(Looper.getMainLooper())
    private var actionReceiver: ActionReceiver? = null
    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        mediaSession = MediaSession(this, "TVBOX26").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { notifyDart(NOTIFY_PLAY) }
                override fun onPause() { notifyDart(NOTIFY_PAUSE) }
                override fun onStop() { notifyDart(NOTIFY_STOP) }
            })
            isActive = true
        }
        // 动态注册：服务存活期间通知按钮才可点，onDestroy 统一注销。
        val receiver = ActionReceiver()
        actionReceiver = receiver
        val filter = IntentFilter().apply {
            addAction(broadcastAction(NOTIFY_PLAY))
            addAction(broadcastAction(NOTIFY_PAUSE))
            addAction(broadcastAction(NOTIFY_STOP))
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                mediaUrl = intent.getStringExtra(EXTRA_URL) ?: ""
                mediaTitle = intent.getStringExtra(EXTRA_TITLE) ?: "TVBOX26"
                positionMs = intent.getLongExtra(EXTRA_POSITION_MS, 0L).coerceAtLeast(0L)
                playing = intent.getBooleanExtra(EXTRA_PLAYING, true)
                persistState()
                if (!foregroundStarted) {
                    // 首次启动必须先 startForeground，否则 ANR / 崩溃。
                    startForeground(NOTIFY_ID, buildNotification())
                    foregroundStarted = true
                    requestAudioFocus()
                } else {
                    // 重复 start 幂等：服务已在跑，只换通知内容。
                    notifyUpdate()
                }
            }
            ACTION_UPDATE -> {
                playing = intent.getBooleanExtra(EXTRA_PLAYING, playing)
                positionMs = intent.getLongExtra(EXTRA_POSITION_MS, positionMs).coerceAtLeast(0L)
                persistState()
                if (foregroundStarted) notifyUpdate()
            }
            ACTION_STOP -> {
                clearPersistedState()
                stopSelf()
            }
        }
        // 播放态由 Dart 侧 restore 恢复，服务不重建播放。
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 用户从最近任务划掉：视为结束播放，自停 + 清通知 + 清持久化。
        clearPersistedState()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        actionReceiver?.let { unregisterReceiver(it) }
        actionReceiver = null
        abandonAudioFocus()
        if (foregroundStarted) stopForeground(true)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── 通知 ──────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
        // IMPORTANCE_LOW：无提示音/振动，只在通知栏常驻，避免电视端响铃打扰。
        val channel = NotificationChannel(CHANNEL_ID, "媒体播放", NotificationManager.IMPORTANCE_LOW).apply {
            setSound(null, null)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        mediaSession?.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, mediaTitle).build())
        mediaSession?.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionMs, if (playing) 1f else 0f).build())
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(mediaTitle)
            .setContentText(contentText())
            .setContentIntent(openAppIntent())
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_play,
                    "播放",
                    broadcastPendingIntent(NOTIFY_PLAY),
                ),
            )
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_pause,
                    "暂停",
                    broadcastPendingIntent(NOTIFY_PAUSE),
                ),
            )
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "停止",
                    broadcastPendingIntent(NOTIFY_STOP),
                ),
            )
            .setOngoing(true)
            .build()
    }

    /// 副标题：影片位置，格式 mm:ss / h:mm:ss；暂停态明示「已暂停」。
    private fun contentText(): String {
        val h = positionMs / 3_600_000L
        val m = positionMs / 60_000L % 60L
        val s = positionMs / 1000L % 60L
        val clock = if (h > 0) {
            String.format("%d:%02d:%02d", h, m, s)
        } else {
            String.format("%02d:%02d", m, s)
        }
        return (if (playing) "正在播放" else "已暂停") + " · " + clock
    }

    private fun notifyUpdate() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
        manager.notify(NOTIFY_ID, buildNotification())
    }

    /// 点击通知回到 App 主页（不拉起新播放，只回前台）。
    private fun openAppIntent(): PendingIntent {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// 通知按钮 → 明确广播 → [ActionReceiver]，时序见类头注。
    private fun broadcastPendingIntent(action: String): PendingIntent {
        val intent = Intent(broadcastAction(action)).setPackage(packageName)
        return PendingIntent.getBroadcast(
            this,
            // 用动作名 hashCode 区分请求码，避免三个按钮共用一个 PendingIntent。
            action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ── 通知动作回传 Dart ─────────────────────────────────────────────

    /// 通知按钮 / 音频焦点事件统一走 backgroundAction 回 Dart；引擎不在时静默失败。
    private fun notifyDart(action: String) {
        val m = messenger ?: return
        // 广播接收者本身即主线程，这里 post 只是兜底双保险。
        handler.post {
            try {
                MethodChannel(m, CHANNEL_NAME).invokeMethod(
                    "backgroundAction",
                    mapOf("action" to action),
                )
            } catch (_: Exception) {
            }
        }
    }

    /// 动态注册的接收者：只回传动作，不直接改播放态（单一真相在 Dart）。
    private inner class ActionReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                broadcastAction(NOTIFY_PLAY) -> notifyDart(NOTIFY_PLAY)
                broadcastAction(NOTIFY_PAUSE) -> notifyDart(NOTIFY_PAUSE)
                broadcastAction(NOTIFY_STOP) -> {
                    notifyDart(NOTIFY_STOP)
                    clearPersistedState()
                    stopSelf()
                }
            }
        }
    }

    // ── 音频焦点 ──────────────────────────────────────────────────────

    private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS,
            // 短暂丢失：电视盒子场景按暂停处理最稳，避免与系统提示音混播。
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                notifyDart(NOTIFY_AUDIO_FOCUS_LOST)
        }
    }

    private fun requestAudioFocus() {
        val am = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return
        audioFocusGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build(),
                )
                .setOnAudioFocusChangeListener(audioFocusListener)
                .build()
            // 释放时必须用同一个 request 对象，故持有引用。
            audioFocusRequest = request
            am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                audioFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonAudioFocus() {
        if (!audioFocusGranted) return
        val am = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return
        val request = audioFocusRequest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && request != null) {
            am.abandonAudioFocusRequest(request)
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(audioFocusListener)
        }
        audioFocusRequest = null
        audioFocusGranted = false
    }

    // ── 持久化（原生侧兜底快照）───────────────────────────────────────

    private fun persistState() {
        // 显式 Editor 写法，不依赖 core-ktx 的 edit {} 扩展（classpath 不保证）。
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().apply {
            putString(PREF_URL, mediaUrl)
            putString(PREF_TITLE, mediaTitle)
            putLong(PREF_POSITION_MS, positionMs)
            putBoolean(PREF_PLAYING, playing)
            apply()
        }
    }

    private fun clearPersistedState() {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().apply {
            clear()
            apply()
        }
    }
}

/// 通知按钮广播动作名（限制在本应用包内，避免与其他应用撞 action）。
private fun broadcastAction(action: String) = "com.tvbox.tvbox_flutter.media.action.$action"
