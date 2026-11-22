package com.tvbox.tvbox_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.github.catvod.crawler.Spider
import com.github.catvod.crawler.SpiderDebug
import dalvik.system.DexClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import java.lang.reflect.InvocationTargetException
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import javax.net.ssl.HttpsURLConnection

internal class SpiderBridge(private val context: Context, messenger: BinaryMessenger) {
    private class JarDownloadFailure(message: String) : Exception(message)
    private class SpiderResetFailure : Exception()
    private class EmptyPluginResponse(val hint: String) : Exception()
    private class MissingSpiderClass(val api: String, cause: ClassNotFoundException) : Exception(cause)
    private class SpiderStageFailure(val stage: String, cause: Throwable) : Exception(cause)

    private inline fun <T> atStage(stage: String, block: () -> T): T = try {
        block()
    } catch (failure: InvocationTargetException) {
        val cause = failure.targetException ?: failure
        if (cause is VirtualMachineError || cause is ThreadDeath) throw cause
        throw SpiderStageFailure(stage, cause)
    } catch (failure: LinkageError) {
        throw SpiderStageFailure(stage, failure)
    } catch (failure: Exception) {
        throw SpiderStageFailure(stage, failure)
    }

    private fun diagnostic(stage: String, failure: Throwable): String {
        val cause = failure.cause ?: failure
        val type = cause.javaClass.simpleName
        // 不记录异常原文：第三方插件可能把带凭据的 URL 写进异常消息。
        val frames = cause.stackTrace.take(6).joinToString(" <- ") {
            "${it.className}.${it.methodName}:${it.lineNumber}"
        }
        Log.w("TvboxSpider", "$stage: $type $frames")
        return "Spider $stage 失败（$type）"
    }

    private val channel = MethodChannel(messenger, "tvbox/spider")
    private val main = Handler(Looper.getMainLooper())
    private class Lane(threads: Int = 1) {
        val worker = ThreadPoolExecutor(threads, threads, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8))
        // 多线程 lane（scriptLane）并发访问，必须并发容器。
        val spiders = ConcurrentHashMap<List<String>, ScriptSpider>(8, 0.75f, 1)
    }

    private val jarLanes = List(5) { Lane() }
    // 每个 JS 站点有独立 QuickJSContext，可并行；单线程会让一个慢脚本卡住所有 JS 站。
    private val scriptLane = Lane(3)
    private val parseLane = Lane()
    private val jarSearch = ThreadPoolExecutor(5, 5, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8))
    private class JarSite {
        val lock = ReentrantLock()
        var users = 0
        var spider: Spider? = null
    }
    private val jarSites = LinkedHashMap<List<String>, JarSite>(32, 0.75f, true)
    private class SearchTask(
        val worker: ThreadPoolExecutor,
        val result: MethodChannel.Result,
        private val interruptRunning: Boolean,
    ) {
        lateinit var task: FutureTask<Unit>
        fun cancel() {
            // QuickJS 执行期间保留线程，等它返回后再处理后续调用。
            task.cancel(interruptRunning)
            worker.remove(task)
            result.error("spider_cancelled", "搜索已取消", null)
        }
    }
    // 主线程登记/取消，worker 线程完成时移除，必须用并发容器。
    private val searches = ConcurrentHashMap<String, SearchTask>()
    private val loaders = LinkedHashMap<String, FutureTask<DexClassLoader>>(16, 0.75f, true)
    @Volatile private var generation = 0

    init {
        channel.setMethodCallHandler { call, originalResult ->
            if (call.method == "cancelSearch") {
                call.argument<String>("requestId")?.let { searches.remove(it)?.cancel() }
                originalResult.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "reset") {
                generation++
                cancelSearches()
                originalResult.success(null)
                return@setMethodCallHandler
            }
            val current = generation
            call.argument<List<String>>("dohEndpoints")?.let { SpiderDns.configure(it) }
            val queuedAt = SystemClock.elapsedRealtime()
            val expires = queuedAt + 18_000
            val api = call.argument<String>("api").orEmpty()
            val jar = call.argument<String>("jar").orEmpty()
            val ext = call.argument<String>("ext").orEmpty()
            val key = call.argument<String>("key").orEmpty()
            val site = listOf(key, jar, api, ext)
            val script = isScript(api)
            val searchSite = if (call.method == "search") {
                if (script) "JS Spider" else api.takeIf { it.matches(Regex("csp_[A-Za-z_][A-Za-z0-9_]*")) }
            } else null
            val lane = when {
                call.method == "parse" -> parseLane
                script -> scriptLane
                else -> jarLanes[Math.floorMod(site.hashCode(), jarLanes.size)]
            }
            val worker = if (call.method == "search" && !script) jarSearch else lane.worker
            val requestId = if (call.method == "search") call.argument<String>("requestId") else null
            val searchTask = requestId?.let { SearchTask(worker, originalResult, !script) }
            val result = if (requestId == null) originalResult else object : MethodChannel.Result {
                private fun complete(block: () -> Unit) {
                    if (searchTask != null && searches[requestId] === searchTask) {
                        searches.remove(requestId)
                        block()
                    }
                }
                override fun success(value: Any?) = complete { originalResult.success(value) }
                override fun error(code: String, message: String?, details: Any?) =
                    complete { originalResult.error(code, message, details) }
                override fun notImplemented() = complete { originalResult.notImplemented() }
            }
            try {
                val operation = Runnable {
                    val startedAt = SystemClock.elapsedRealtime()
                    val queuedMs = startedAt - queuedAt
                    val operationLabel = when (call.method) {
                        "search" -> searchSite?.let { "$it 搜索" }
                        "player" -> (api.takeIf { it.matches(Regex("csp_[A-Za-z_][A-Za-z0-9_]*")) } ?: "JS Spider") + " 取址"
                        else -> null
                    }
                    if (operationLabel != null) SpiderDebug.setSearchSite(operationLabel)
                    try {
                        if (current != generation) {
                            main.post { result.error("spider_reset", "Spider 配置已变更", null) }
                            return@Runnable
                        }
                        if (startedAt >= expires) {
                            if (searchSite != null) Log.w("TvboxSpider", "$searchSite 搜索排队超时，等待 ${queuedMs}ms")
                            main.post { result.error("spider_timeout", "Spider 排队超时，请重试此站", null) }
                            return@Runnable
                        }
                        if (call.method == "parse") {
                            val name = call.argument<String>("name").orEmpty()
                            val flag = call.argument<String>("flag").orEmpty()
                            val url = call.argument<String>("url").orEmpty()
                            val type = call.argument<Int>("type") ?: 0
                            require(key.matches(Regex("[A-Za-z0-9_]+")) && type in 2..3)
                            val entries = call.argument<Map<String, Any>>("entries").orEmpty()
                            val loader = jarLoader(jar, current)
                            check(current == generation)
                            val cls = loader.loadClass("com.github.catvod.parser.${if (type == 2) "Json" else "Mix"}$key")
                            val parsed = if (type == 2) {
                                cls.getMethod("parse", LinkedHashMap::class.java, String::class.java)
                                    .invoke(null, LinkedHashMap(entries), url)
                            } else {
                                val maps = LinkedHashMap(entries.mapValues { (_, v) -> HashMap(v as Map<*, *>) })
                                cls.getMethod("parse", LinkedHashMap::class.java, String::class.java, String::class.java, String::class.java)
                                    .invoke(null, maps, name, "${flag}111", url)
                            }
                            val json = parsed?.toString().orEmpty()
                            require(json.length <= 4 * 1024 * 1024)
                            main.post {
                                if (current == generation) result.success(json)
                                else result.error("spider_reset", "Spider 配置已变更", null)
                            }
                            return@Runnable
                        }
                        val filter = call.argument<Boolean>("filter") == true
                        val id = call.argument<String>("id").orEmpty()
                        val page = call.argument<String>("page") ?: "1"
                        val invoke: (Spider) -> Any? = { spider ->
                            check(current == generation && !Thread.currentThread().isInterrupted &&
                                searchTask?.task?.isCancelled != true)
                            when (call.method) {
                                "home" -> {
                                    val home = atStage("首页分类") {
                                        JSONObject(spider.homeContent(true).orEmpty().ifBlank { "{}" })
                                    }
                                    if ((home.optJSONArray("list")?.length() ?: 0) == 0) {
                                        try {
                                            atStage("首页推荐") {
                                                val latest = spider.homeVideoContent().orEmpty()
                                                if (latest.isNotBlank()) JSONObject(latest).optJSONArray("list")?.let { home.put("list", it) }
                                            }
                                        } catch (failure: SpiderStageFailure) {
                                            if ((home.optJSONArray("class")?.length() ?: 0) == 0) throw failure
                                            diagnostic(failure.stage, failure)
                                        }
                                    }
                                    home.toString()
                                }
                                "latest" -> spider.homeVideoContent()
                                "category" -> spider.categoryContent(id, page, filter,
                                    HashMap(call.argument<Map<String, String>>("filters").orEmpty()))
                                "search" -> atStage("搜索") {
                                    val response = search(spider, script, id, page).orEmpty()
                                    if (response.isBlank()) SpiderDebug.failureHint()?.let { throw EmptyPluginResponse(it) }
                                    require(response.length <= 4 * 1024 * 1024)
                                    if (searchSite != null && searchTask?.task?.isCancelled != true) {
                                        val count = runCatching {
                                            JSONObject(response).optJSONArray("list")?.length()
                                        }.getOrNull()
                                        val status = if (response.isBlank()) "无响应内容" else
                                            count?.let { "$it 条结果" } ?: "未返回列表"
                                        Log.d("TvboxSpider", "$searchSite 搜索完成：$status，排队 ${queuedMs}ms，执行 ${SystemClock.elapsedRealtime() - startedAt}ms")
                                    }
                                    response
                                }
                                "detail" -> spider.detailContent(listOf(id))
                                "player" -> atStage("站点取址") {
                                    val raw = spider.playerContent(call.argument<String>("flag").orEmpty(), id,
                                        call.argument<List<String>>("flags").orEmpty()).orEmpty()
                                    require(raw.length <= 4 * 1024 * 1024)
                                    val hasUrl = runCatching { JSONObject(raw).optString("url").isNotBlank() }.getOrDefault(false)
                                    Log.d("TvboxSpider", "$operationLabel 已返回，含地址=$hasUrl，耗时 ${SystemClock.elapsedRealtime() - startedAt}ms")
                                    if (!hasUrl) SpiderDebug.failureHint()?.let { throw EmptyPluginResponse(it) }
                                    raw
                                }
                                "proxy" -> proxy(spider, if (script) null else jarLoader(jar, current), call.argument<Map<String, String>>("params").orEmpty())
                                else -> error("未知 Spider 操作")
                            }
                        }
                        val payload = if (script) {
                            val spider = scriptInstance(site, api, ext, key)
                            try {
                                spider.onJsThread { invoke(spider) }
                            } finally {
                                spider.inFlight.decrementAndGet()
                                evictIdleScripts(scriptLane.spiders, site)
                            }
                        } else {
                            withJarSite(site, jar, api, ext, current, invoke)
                        }
                        if (payload is String) require(payload.length <= 4 * 1024 * 1024)
                        main.post {
                            if (current == generation) result.success(if (payload is String) payload.ifBlank { "{}" } else payload)
                            else result.error("spider_reset", "Spider 配置已变更", null)
                        }
                    } catch (failure: JarDownloadFailure) {
                        main.post { result.error("spider_download", failure.message, null) }
                    } catch (failure: MissingSpiderClass) {
                        Log.w("TvboxSpider", "${failure.api} 当前 JAR 缺少站点类")
                        main.post {
                            result.error("spider_missing_class", "当前配置的 JAR 缺少站点插件 ${failure.api}", null)
                        }
                    } catch (_: SpiderResetFailure) {
                        main.post { result.error("spider_reset", "Spider 配置已变更", null) }
                    } catch (_: ScriptTimeoutException) {
                        main.post { result.error("spider_timeout", "脚本执行超时，已终止此站", null) }
                    } catch (_: ScriptDestroyedException) {
                        main.post { result.error("spider_failed", "脚本实例已释放，请重试此站", null) }
                    } catch (failure: SpiderStageFailure) {
                        val stage = if (searchSite != null) {
                            "$searchSite ${failure.stage}（排队 ${queuedMs}ms，执行 ${SystemClock.elapsedRealtime() - startedAt}ms）"
                        } else {
                            failure.stage
                        }
                        diagnostic(stage, failure)
                        val type = failure.cause?.javaClass?.simpleName ?: failure.javaClass.simpleName
                        val hint = (failure.cause as? EmptyPluginResponse)?.hint ?: type
                        val message = "${failure.stage}失败（$hint）"
                        main.post { result.error("spider_stage", message, null) }
                    } catch (failure: Exception) {
                        main.post { result.error("spider_failed", "Spider 调用失败（${failure.javaClass.simpleName}）", null) }
                    } catch (failure: LinkageError) {
                        main.post { result.error("spider_abi", "JAR 与当前 Spider 运行时不兼容", null) }
                    } finally {
                        if (operationLabel != null) SpiderDebug.setSearchSite(null)
                    }
                }
                if (searchTask == null || requestId == null) {
                    worker.execute(operation)
                } else {
                    searchTask.task = FutureTask(operation, Unit)
                    searches.put(requestId, searchTask)?.cancel()
                    worker.execute(searchTask.task)
                }
            } catch (_: RejectedExecutionException) {
                result.error("spider_busy", "Spider 正忙，请稍后重试", null)
            }
        }
    }

    private fun cancelSearches() {
        val pending = searches.values.toList()
        searches.clear()
        pending.forEach { it.cancel() }
    }

    private fun search(spider: Spider, script: Boolean, query: String, page: String): String? {
        // 参考 Box 优先使用两参数入口，只有插件未实现时才走分页版本。
        if (script || spider.javaClass.getMethod(
                "searchContent", String::class.java, Boolean::class.javaPrimitiveType,
            ).declaringClass == Spider::class.java
        ) {
            return spider.searchContent(query, false, page)
        }
        return spider.searchContent(query, false)
    }

    private fun proxy(spider: Spider, loader: DexClassLoader?, params: Map<String, String>): Map<String, Any> {
        val args = HashMap(params)
        val legacy = loader?.let {
            try {
                it.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy", Map::class.java)
            } catch (_: ClassNotFoundException) {
                null
            } catch (_: NoSuchMethodException) {
                null
            }
        }
        val value = (legacy?.invoke(null, args) as? Array<*>) ?: spider.proxyLocal(args)
        require(value != null && value.size >= 3)
        val limit = 8 * 1024 * 1024
        val body = when (val source = value[2]) {
            is InputStream -> source.use { stream ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val size = stream.read(buffer)
                    if (size == -1) break
                    require(out.size() + size <= limit)
                    out.write(buffer, 0, size)
                }
                out.toByteArray()
            }
            is ByteArray -> source
            is String -> source.toByteArray(Charsets.UTF_8)
            null -> byteArrayOf()
            else -> error("不支持的代理响应")
        }
        require(body.size <= limit)
        val headers = value.getOrNull(3) as? Map<*, *>
        return mapOf(
            "status" to (value[0] as Number).toInt(),
            "mime" to (value[1] as? String ?: "application/octet-stream"),
            "body" to body,
            "headers" to headers.orEmpty().entries.mapNotNull { (key, header) ->
                if (key is String && header is String) key to header else null
            }.toMap(),
        )
    }

    fun close() {
        channel.setMethodCallHandler(null)
        generation++
        cancelSearches()
        jarSearch.shutdownNow()
        for (lane in jarLanes + scriptLane + parseLane) {
            lane.worker.queue.clear()
            lane.worker.execute {
                // 正在执行的 JS 调用不能 destroy（QuickJS 上下文会被抽走），
                // 交给 GC；其余实例立即释放。
                val iterator = lane.spiders.entries.iterator()
                while (iterator.hasNext()) {
                    val spider = iterator.next().value
                    if (spider.inFlight.get() > 0) continue
                    iterator.remove()
                    runCatching { spider.destroy() }
                }
            }
            lane.worker.shutdown()
        }
        val idle = synchronized(jarSites) {
            jarSites.entries.filter { it.value.users == 0 }.map { jarSites.remove(it.key)?.spider }
        }
        if (idle.isNotEmpty()) Thread { idle.forEach { runCatching { it?.destroy() } } }.start()
        synchronized(loaders) { loaders.clear() }
    }

    private fun isScript(api: String): Boolean {
        val url = runCatching { java.net.URI(api) }.getOrNull() ?: return false
        return url.scheme == "https" && !url.host.isNullOrEmpty() && url.userInfo == null && url.path.endsWith(".js")
    }

    private fun scriptInstance(key: List<String>, api: String, ext: String, site: String): ScriptSpider {
        val spiders = scriptLane.spiders
        spiders[key]?.let {
            // 先登记占用再返回，淘汰逻辑看到 inFlight>0 就不会 destroy。
            it.inFlight.incrementAndGet()
            return it
        }
        val spider = ScriptSpider(api, site)
        // 创建与后续调用/销毁都在该实例自己的 QuickJS 线程上（线程亲和性）。
        atStage("站点初始化") { spider.onJsThread { spider.init(context, ext) } }
        spider.inFlight.incrementAndGet()
        val existing = spiders.putIfAbsent(key, spider)
        if (existing != null) {
            spider.inFlight.decrementAndGet()
            runCatching { spider.destroy() }
            existing.inFlight.incrementAndGet()
            return existing
        }
        evictIdleScripts(spiders, key)
        return spider
    }

    /** 超上限时淘汰一个空闲的 JS 站点实例（不能碰 inFlight>0 的）。 */
    private fun evictIdleScripts(
        spiders: ConcurrentHashMap<List<String>, ScriptSpider>,
        keep: List<String>,
    ) {
        if (spiders.size <= 8) return
        val victim = spiders.entries.firstOrNull {
            it.key != keep && it.value.inFlight.get() == 0
        } ?: return
        if (spiders.remove(victim.key, victim.value)) {
            runCatching { victim.value.destroy() }
        }
    }

    private fun withJarSite(
        key: List<String>,
        jar: String,
        api: String,
        ext: String,
        current: Int,
        invoke: (Spider) -> Any?,
    ): Any? {
        val site = synchronized(jarSites) {
            if (current != generation) throw SpiderResetFailure()
            jarSites.getOrPut(key) { JarSite() }.also { it.users++ }
        }
        try {
            site.lock.lockInterruptibly()
            try {
                if (current != generation || Thread.currentThread().isInterrupted) {
                    throw SpiderResetFailure()
                }
                val spider = site.spider ?: createJarSpider(jar, api, ext, current).also { created ->
                    // 与 LRU 的 remove 互斥，避免「已摘出 map 又写入 spider」的泄漏。
                    synchronized(jarSites) { site.spider = created }
                }
                return invoke(spider)
            } finally {
                site.lock.unlock()
            }
        } finally {
            val evicted = synchronized(jarSites) {
                site.users--
                if (site.users == 0 && (current != generation || site.spider == null)) {
                    jarSites.remove(key)?.spider
                } else if (jarSites.size > 32) {
                    val idleKey = jarSites.entries.firstOrNull { it.value.users == 0 }?.key
                    idleKey?.let { jarSites.remove(it)?.spider }
                } else null
            }
            runCatching { evicted?.destroy() }
        }
    }

    private fun createJarSpider(jar: String, api: String, ext: String, current: Int): Spider {
        require(api.matches(Regex("csp_[A-Za-z_][A-Za-z0-9_]*")))
        val loader = jarLoader(jar, current)
        check(current == generation && !Thread.currentThread().isInterrupted)
        val spiderClass = try {
            atStage("站点类加载") {
                loader.loadClass("com.github.catvod.spider.${api.removePrefix("csp_")}")
            }
        } catch (failure: SpiderStageFailure) {
            val cause = failure.cause
            if (cause is ClassNotFoundException) throw MissingSpiderClass(api, cause)
            throw failure
        }
        val spider = atStage("站点实例创建") {
            spiderClass.asSubclass(Spider::class.java).getDeclaredConstructor().newInstance()
        }
        try {
            atStage("站点初始化") { spider.init(context, ext) }
        } catch (failure: SpiderStageFailure) {
            runCatching { spider.destroy() }
            throw failure
        }
        return spider
    }

    private fun jarLoader(jar: String, current: Int): DexClassLoader {
        val task = synchronized(loaders) {
            check(current == generation)
            loaders[jar] ?: run {
                // 不同配置源可能各带一份 JAR；超上限淘汰最旧的一份，而不是抛异常。
                if (loaders.size >= 16) loaders.remove(loaders.keys.first())
                FutureTask { load(jar, current) }.also { loaders[jar] = it }
            }
        }
        // 同一份 JAR 只下载和初始化一次。其他 JAR 不受这次加载阻塞。
        task.run()
        try {
            return task.get()
        } catch (failure: ExecutionException) {
            synchronized(loaders) { if (loaders[jar] === task) loaders.remove(jar) }
            throw failure.cause ?: failure
        }
    }

    private fun load(reference: String, current: Int): DexClassLoader {
        val url = URL(reference.substringBefore(";md5;"))
        val md5 = reference.substringAfter(";md5;", "").trim()
        require(url.protocol == "https" && url.userInfo == null && url.host.isNotEmpty())
        require(md5.isEmpty() || md5.matches(Regex("[a-fA-F0-9]{32}")))
        val dir = File(context.filesDir, "csp").apply { mkdirs() }
        // 与参考 Box 一致按 URL 摘要做磁盘缓存：同一 JAR 不必每次冷启动重下。
        val cacheFile = File(dir, "${md5(url.toString())}.jar")
        // 无 md5 时按参考 Box 的一周 TTL 过期，避免源更新后永远用旧缓存。
        val fresh = md5.isNotEmpty() ||
            cacheFile.lastModified() > System.currentTimeMillis() - 7 * 24 * 60 * 60 * 1000L
        if (cacheFile.isFile && cacheFile.length() > 0 && fresh) {
            val cached = runCatching { md5(cacheFile) }.getOrDefault("")
            if (md5.isEmpty() || cached.equals(md5, true)) {
                Log.d("TvboxSpider", "JAR 命中缓存 ${cacheFile.name}（${cacheFile.length()} 字节）")
                return classLoader(cacheFile, dir, current)
            }
            // 校验不匹配说明配置里的 md5 已更新，旧缓存必须删掉。
            deleteQuietly(cacheFile)
        }
        val temp = File.createTempFile("spider-", ".jar", dir)
        val started = android.os.SystemClock.elapsedRealtime()
        Log.d("TvboxSpider", "JAR 下载开始 ${url.host}${url.path.takeLast(48)}")
        try {
            val digest = MessageDigest.getInstance("MD5")
            val connection = openJarConnection(url, started, current)
            try {
                connection.inputStream.use { input ->
                    FileOutputStream(temp).use { out ->
                        // Android 14 要求动态加载文件只读；已打开的描述符仍能写入。
                        check(temp.setReadOnly())
                        val buffer = ByteArray(8192)
                        var total = 0
                        while (true) {
                            checkDownloadBudget(started, current)
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > 24 * 1024 * 1024) throw JarDownloadFailure("Spider JAR 超过下载大小限制")
                            digest.update(buffer, 0, count)
                            out.write(buffer, 0, count)
                        }
                    }
                }
            } finally {
                connection.disconnect()
            }
            Log.d(
                "TvboxSpider",
                "JAR 下载完成 ${temp.length()} 字节，耗时 ${android.os.SystemClock.elapsedRealtime() - started}ms",
            )
            if (md5.isNotEmpty() && !digest.digest().joinToString("") { "%02x".format(it) }.equals(md5, true)) {
                throw JarDownloadFailure("Spider JAR 校验不匹配，请更新配置源")
            }
            // 下载成功的 JAR 落到缓存；改名失败（跨卷等）不影响本次加载。
            val cached = runCatching {
                if (temp.renameTo(cacheFile)) cacheFile else temp
            }.getOrDefault(temp)
            cached.setReadOnly()
            return try {
                classLoader(cached, dir, current)
            } catch (failure: Throwable) {
                // 缓存文件损坏/不兼容：删掉它，下次重新下载，避免永久命中坏缓存。
                if (cached.absolutePath == cacheFile.absolutePath) deleteQuietly(cacheFile)
                throw failure
            }
        } catch (failure: Throwable) {
            deleteQuietly(temp)
            throw failure
        }
    }

    /** 只读文件（Android 14 动态加载要求）也要能删干净，先恢复可写。 */
    private fun deleteQuietly(file: File) {
        runCatching { if (file.exists()) file.setWritable(true) }
        runCatching { file.delete() }
    }

    private fun classLoader(file: File, dir: File, current: Int): DexClassLoader {
        check(current == generation)
        val loader = DexClassLoader(file.absolutePath, dir.absolutePath, null, context.classLoader)
        val init = try {
            loader.loadClass("com.github.catvod.spider.Init")
        } catch (_: ClassNotFoundException) {
            null
        }
        if (init != null) {
            try {
                atStage("JAR 全局初始化") {
                    init.getMethod("init", Context::class.java).invoke(null, context)
                }
            } catch (failure: SpiderStageFailure) {
                // 与参考 Box 一致：全局初始化异常不阻止尝试创建站点实例。
                diagnostic(failure.stage, failure)
            }
        }
        return loader
    }

    private fun md5(value: String): String = MessageDigest.getInstance("MD5")
        .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun md5(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun checkDownloadBudget(started: Long, current: Int) {
        if (current != generation) throw JarDownloadFailure("Spider 配置已变更，请重试")
        // 参考 Box 的 JarLoader 不设总时长上限；电视端网络慢，这里放宽到 60 秒。
        if (android.os.SystemClock.elapsedRealtime() - started >= 60_000) {
            throw JarDownloadFailure("Spider JAR 下载超时")
        }
    }

    private fun openJarConnection(initial: URL, started: Long, current: Int): HttpsURLConnection {
        var url = initial
        repeat(5) { hop ->
            checkDownloadBudget(started, current)
            val connection = url.openConnection() as HttpsURLConnection
            var keep = false
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 8_000
                connection.readTimeout = 10_000
                // 与参考 Box 的 OkGo 一致：部分 CDN 会拒绝空 UA。
                connection.setRequestProperty("User-Agent", "okhttp/3.15")
                connection.setRequestProperty("Accept", "*/*")
                val status = connection.responseCode
                checkDownloadBudget(started, current)
                if (status in 200..299) {
                    keep = true
                    return connection
                }
                if (status !in setOf(301, 302, 303, 307, 308)) {
                    throw JarDownloadFailure("Spider JAR 下载失败（HTTP $status）")
                }
                // 与参考 Box 一致允许跳转（无 md5 时不做校验），仍限 HTTPS 与 5 跳。
                if (hop == 4) throw JarDownloadFailure("Spider JAR 下载跳转次数过多")
                val location = connection.getHeaderField("Location")?.takeIf { it.isNotBlank() }
                    ?: throw JarDownloadFailure("Spider JAR 下载跳转缺少目标地址")
                val next = runCatching { URL(url, location) }.getOrNull()
                if (next == null || next.protocol != "https" || next.userInfo != null || next.host.isEmpty()) {
                    throw JarDownloadFailure("Spider JAR 下载跳转目标不是有效的 HTTPS 地址")
                }
                url = next
            } finally {
                if (!keep) connection.disconnect()
            }
        }
        throw JarDownloadFailure("Spider JAR 下载跳转次数过多")
    }
}
