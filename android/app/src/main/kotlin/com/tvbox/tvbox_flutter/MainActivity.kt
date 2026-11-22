package com.tvbox.tvbox_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import java.util.concurrent.Executor
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Rational
import androidx.core.content.ContextCompat

class MainActivity : FlutterActivity() {
    private var spiderBridge: SpiderBridge? = null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        spiderBridge?.close()
        spiderBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
    private var sniffer: WebView? = null
    private var pending: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private var expiry: Runnable? = null
    private var webProxy: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        spiderBridge = SpiderBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvbox/playback")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "receivedBytes" -> result.success(android.net.TrafficStats.getUidRxBytes(android.os.Process.myUid()))
                    "apps" -> {
                        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
                        val apps = packageManager.queryIntentActivities(query, 0).map { info ->
                            mapOf("package" to info.activityInfo.packageName,
                                "name" to info.loadLabel(packageManager).toString())
                        }.distinctBy { it["package"] }.sortedBy { it["name"] }
                        result.success(apps)
                    }
                    "launchApp" -> {
                        val target = call.argument<String>("package") ?: ""
                        val intent = packageManager.getLeanbackLaunchIntentForPackage(target)
                            ?: packageManager.getLaunchIntentForPackage(target)
                        try {
                            if (intent != null) { startActivity(intent); result.success(true) }
                            else result.success(false)
                        } catch (_: Exception) { result.success(false) }
                    }
                    "appDetails" -> {
                        val target = call.argument<String>("package") ?: packageName
                        try {
                            startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$target")))
                            result.success(true)
                        } catch (_: Exception) { result.success(false) }
                    }
                    "pip" -> {
                        if (Build.VERSION.SDK_INT < 26 || !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
                            result.success(false)
                        } else {
                            try {
                                val ratio = (call.argument<Number>("ratio")?.toDouble() ?: 1.777).coerceIn(0.42, 2.39)
                                result.success(enterPictureInPictureMode(PictureInPictureParams.Builder()
                                    .setAspectRatio(Rational((ratio * 1000).toInt(), 1000)).build()))
                            } catch (_: Exception) { result.success(false) }
                        }
                    }
                    "external" -> {
                        val url = call.argument<String>("url") ?: ""
                        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                        if (!url.startsWith("http://") && !url.startsWith("https://")) {
                            result.success(false)
                        } else {
                            try {
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(Uri.parse(url), "video/*")
                                    putExtra("title", call.argument<String>("title") ?: "TVBOX26")
                                    putExtra("position", call.argument<Number>("positionMs")?.toInt() ?: 0)
                                    putExtra("headers", headers.entries.flatMap { listOf(it.key, it.value) }.toTypedArray())
                                }
                                startActivity(Intent.createChooser(intent, "选择外部播放器"))
                                result.success(true)
                            } catch (_: Exception) { result.success(false) }
                        }
                    }
                    // ── 长驻后台播放（ForegroundMediaService）─────────────────────
                    "backgroundStart" -> {
                        val url = call.argument<String>("url") ?: ""
                        val title = call.argument<String>("title") ?: "TVBOX26"
                        val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                        val playing = call.argument<Boolean>("playing") ?: true
                        val intent = Intent(this, ForegroundMediaService::class.java)
                            .setAction(ForegroundMediaService.ACTION_START)
                            .putExtra(ForegroundMediaService.EXTRA_URL, url)
                            .putExtra(ForegroundMediaService.EXTRA_TITLE, title)
                            .putExtra(ForegroundMediaService.EXTRA_POSITION_MS, positionMs)
                            .putExtra(ForegroundMediaService.EXTRA_PLAYING, playing)
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    }
                    "backgroundUpdateState" -> {
                        val playing = call.argument<Boolean>("playing") ?: true
                        val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                        // 前台服务在跑时应用处于前台服务态，startService 不受后台启动限制；
                        // 若服务已死（极端场景），更新请求自然被忽略。
                        val intent = Intent(this, ForegroundMediaService::class.java)
                            .setAction(ForegroundMediaService.ACTION_UPDATE)
                            .putExtra(ForegroundMediaService.EXTRA_PLAYING, playing)
                            .putExtra(ForegroundMediaService.EXTRA_POSITION_MS, positionMs)
                        startService(intent)
                        result.success(true)
                    }
                    "backgroundStop" -> {
                        getSharedPreferences(ForegroundMediaService.PREFS_NAME, MODE_PRIVATE)
                            .edit().clear().apply()
                        val intent = Intent(this, ForegroundMediaService::class.java)
                            .setAction(ForegroundMediaService.ACTION_STOP)
                        stopService(intent)
                        result.success(true)
                    }
                    "backgroundRestore" -> {
                        // 读服务侧持久化的上次快照（与 Dart 侧 storage.dart 双写互为兜底）。
                        result.success(readPersistedPlayback())
                    }
                    // ── 长驻后台播放 end ────────────────────────────────────────
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvbox/web_sniffer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cancel" -> { finishSniff(null); result.success(null) }
                    "sniff" -> {
                        finishSniff(null)
                        val url = call.argument<String>("url") ?: ""
                        if (!url.startsWith("http://") && !url.startsWith("https://")) {
                            result.error("url", "仅支持 HTTP 页面", null)
                            return@setMethodCallHandler
                        }
                        pending = result
                        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                        val web = WebView(this)
                        sniffer = web
                        web.settings.javaScriptEnabled = true
                        web.settings.domStorageEnabled = true
                        web.settings.allowFileAccess = false
                        web.settings.allowContentAccess = false
                        headers.entries.firstOrNull { it.key.equals("User-Agent", true) }
                            ?.let { web.settings.userAgentString = it.value }
                        web.webViewClient = object : WebViewClient() {
                            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                                val target = request?.url?.toString() ?: return null
                                if (Regex("\\.(m3u8|mp4|mpd|flv|mkv|m4v)([?#]|$)", RegexOption.IGNORE_CASE).containsMatchIn(target)) {
                                    val playbackHeaders = headers.toMutableMap()
                                    playbackHeaders.putAll(request.requestHeaders)
                                    playbackHeaders.putIfAbsent("Referer", url)
                                    CookieManager.getInstance().getCookie(target)?.let { playbackHeaders["Cookie"] = it }
                                    handler.post {
                                        if (sniffer === web) finishSniff(mapOf("url" to target, "headers" to playbackHeaders))
                                    }
                                }
                                return null
                            }
                        }
                        val task = Runnable { if (sniffer === web) finishSniff(null) }
                        expiry = task
                        handler.postDelayed(task, (call.argument<Number>("timeoutMs")?.toLong() ?: 12000L).coerceIn(1L, 20000L))
                        applyWebViewProxy(call.argument<String>("proxy") ?: "") {
                            if (sniffer === web) web.loadUrl(url, headers)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // ── 应用内更新：安装已下载的 APK（lib/core/android_updater.dart）──────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvbox/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        try {
                            val file = java.io.File(path)
                            if (!file.exists()) {
                                result.success(false)
                            } else if (Build.VERSION.SDK_INT >= 26 &&
                                !packageManager.canRequestPackageInstalls()) {
                                // 先引导授权「安装未知应用」；用户允许后重新发起安装即可
                                startActivity(
                                    Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                                        .setData(Uri.parse("package:$packageName"))
                                )
                                result.success(false)
                            } else {
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    this, "$packageName.fileprovider", file)
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                startActivity(intent)
                                result.success(true)
                            }
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 长驻后台播放：服务经此 messenger 把通知动作回传 Dart（见 ForegroundMediaService）。
        ForegroundMediaService.bindMessenger(flutterEngine.dartExecutor.binaryMessenger)
    }

    /** 必须等待代理配置完成再加载页面；清空设置时撤销旧代理。 */
    private fun applyWebViewProxy(raw: String, ready: () -> Unit) {
        val proxy = raw.trim()
        if (proxy == webProxy || !WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            ready()
            return
        }
        try {
            val controller = ProxyController.getInstance()
            val executor = Executor { task -> handler.post(task) }
            val finished = Runnable { webProxy = proxy; ready() }
            if (proxy.isEmpty()) {
                controller.clearProxyOverride(executor, finished)
                return
            }
            val rule = if (proxy.contains("://")) proxy else "http://$proxy"
            controller.setProxyOverride(
                ProxyConfig.Builder()
                    .addProxyRule(rule)
                    .addBypassRule("localhost")
                    .addBypassRule("127.0.0.1")
                    .build(), executor, finished
            )
        } catch (_: Throwable) {
            ready()
        }
    }

    private fun finishSniff(value: Map<String, Any>?) {
        expiry?.let { handler.removeCallbacks(it) }
        expiry = null
        val result = pending
        pending = null
        sniffer?.apply { stopLoading(); destroy() }
        sniffer = null
        result?.success(value)
    }

    override fun onDestroy() {
        finishSniff(null)
        // 引擎随 Activity 销毁，清掉 messenger 引用，防止服务侧误用死通道。
        ForegroundMediaService.bindMessenger(null)
        super.onDestroy()
    }

    /// 读服务侧持久化的上次播放快照；没有（或已 stop 清掉）返回 null。
    /// 与 Dart 侧 storage.dart 的 'bg_playback_state' 双写互为兜底，Dart 侧为主源。
    private fun readPersistedPlayback(): Map<String, Any>? {
        val prefs = getSharedPreferences(ForegroundMediaService.PREFS_NAME, Context.MODE_PRIVATE)
        val url = prefs.getString(ForegroundMediaService.PREF_URL, null) ?: return null
        return mapOf(
            "url" to url,
            "title" to (prefs.getString(ForegroundMediaService.PREF_TITLE, "") ?: ""),
            "positionMs" to prefs.getLong(ForegroundMediaService.PREF_POSITION_MS, 0L),
            "playing" to prefs.getBoolean(ForegroundMediaService.PREF_PLAYING, false),
        )
    }
}
