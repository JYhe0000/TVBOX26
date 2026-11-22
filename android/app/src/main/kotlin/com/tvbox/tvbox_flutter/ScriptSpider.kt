package com.tvbox.tvbox_flutter

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.github.catvod.crawler.Spider
import com.whl.quickjs.android.QuickJSLoader
import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.QuickJSContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.FutureTask

/// JS 单次调用超时（QuickJS 死循环不可中断，只能弃用该实例）。
internal class ScriptTimeoutException : Exception()

/// 实例已被淘汰/释放（并发竞态），调用方重试即可。
internal class ScriptDestroyedException : Exception()

internal class ScriptSpider(private val api: String, private val key: String) : Spider() {
    private lateinit var js: QuickJSContext
    private lateinit var assetManager: android.content.res.AssetManager
    private var deadline = 0L
    private var requests = 0
    private val origin = URI(api)

    /// 正在执行的调用数：>0 时宿主不得淘汰并 destroy 本实例。
    val inFlight = java.util.concurrent.atomic.AtomicInteger()

    /// QuickJSContext 有线程亲和性（checkSameThread）：创建、调用、销毁都必须
    /// 在同一个线程。每个脚本站独享一条执行线程（参考 Box JsSpider.executor）。
    private val executor = java.util.concurrent.Executors.newSingleThreadExecutor(
        object : java.util.concurrent.ThreadFactory {
            override fun newThread(runnable: Runnable): Thread =
                Thread(runnable, "TvboxJS-${api.hashCode()}").apply { isDaemon = true }
        },
    )
    private val destroyed = java.util.concurrent.atomic.AtomicBoolean(false)

    /// 预编译的空模块字节码：模块加载失败时返回它，避免在 QuickJS 原生
    /// 模块加载回调里再次调用 compileModule（重入原生层会导致 SIGSEGV）。
    /// 必须在任何 evaluateModule 之前赋值——回调里绝不能返回 null/空字节码，
    /// 否则模块解析失败会释放整棵模块树（含根模块），引发 use-after-free。
    private lateinit var emptyModule: ByteArray

    /// 静态 import 的远程模块：在 evaluateModule 之前于本线程预取+预编译，
    /// 回调里直接命中缓存，避免「解析阶段失败 → 释放整棵模块树 → UAF」。
    private val preloadedModules = HashMap<String, ByteArray>()
    @Volatile
    private var jsThreadId = -1L

    /// 在本实例的 QuickJS 线程上执行；已在目标线程时直接跑（避免自等待死锁）。
    fun <T> onJsThread(block: () -> T): T {
        if (destroyed.get()) throw ScriptDestroyedException()
        if (Thread.currentThread().id == jsThreadId) return block()
        val task = FutureTask<T>(object : java.util.concurrent.Callable<T> {
            override fun call(): T = block()
        })
        try {
            if (executor.isShutdown) throw ScriptDestroyedException()
            executor.execute(task)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // destroy() 与本次调用并发：实例已释放，交由上层重试。
            throw ScriptDestroyedException()
        }
        return try {
            // QuickJS 死循环不可中断；超时后弃用整个实例，避免 lane 线程永久占用。
            task.get(35, java.util.concurrent.TimeUnit.SECONDS)
        } catch (failure: java.util.concurrent.ExecutionException) {
            // 还原真实异常，便于 atStage 给出「站点初始化/搜索」阶段信息。
            throw failure.cause ?: failure
        } catch (failure: java.util.concurrent.TimeoutException) {
            destroyed.set(true)
            runCatching { executor.shutdownNow() }
            throw ScriptTimeoutException()
        } catch (failure: InterruptedException) {
            Thread.currentThread().interrupt()
            throw ScriptDestroyedException()
        }
    }

    /// 只在本实例线程内调用，按库名缓存编译产物（不同 QuickJSContext 的字节码不通用）。
    private val compiledCache = HashMap<String, ByteArray>()

    /// 参考 Box 的 FileUtils.loadModule 行为：这几个库一律读内置副本，
    /// 不管脚本里写的是 CDN 还是镜像地址。
    private val forcedAssets = listOf("gbk.js", "模板.js", "cat.js")

    override fun init(context: Context, ext: String) {
        check(Build.SUPPORTED_ABIS.any { it == "arm64-v8a" || it == "armeabi-v7a" })
        QuickJSLoader.init()
        assetManager = context.applicationContext.assets
        jsThreadId = Thread.currentThread().id
        js = QuickJSContext.create()
        js.setConsole { line -> Log.d("TvboxJS", line) }
        try {
            js.setMemoryLimit(48 * 1024 * 1024)
            js.setModuleLoader(object : QuickJSContext.BytecodeModuleLoader() {
                // 这两个回调由 QuickJS 原生层直接调用：异常若跨 JNI 抛回，
                // 原生层会在异常未清空时继续 FindClass，进程会 SIGABRT
                // （真机日志：JNI FindClass called with pending exception
                //  java.net.SocketTimeoutException）。所以这里只返回安全值。
                override fun moduleNormalizeName(base: String, name: String): String =
                    runCatching { resolveModuleName(base, name) }.getOrDefault(name)

                override fun getModuleBytecode(name: String): ByteArray {
                    preloadedModules[name]?.let { return it.copyOf() }
                    // cheerio / crypto-js 是每个脚本站都要的大库，参考 Box
                    // 缓存编译产物，避免每个站点初始化都重编译一遍。
                    val key = cacheKey(name)
                    if (key != null) compiledCache[key]?.let { return it }
                    return runCatching { moduleBytecode(name) }.fold(
                        onSuccess = { bytecode ->
                            // 只缓存成功产物，失败时不能污染后续站点。
                            if (key != null) compiledCache[key] = bytecode
                            bytecode
                        },
                        onFailure = { failure ->
                            if (failure is VirtualMachineError || failure is ThreadDeath) throw failure
                            val message = failure.message ?: failure.javaClass.simpleName
                            Log.w("TvboxSpider", "JS 模块加载失败 $name：$message")
                            // 不能在回调里抛异常，也不能在回调里重入原生层编译：
                            // 返回 init 阶段预编译好的空模块，缺模块表现为普通 JS 导入错误。
                            emptyModule.copyOf()
                        },
                    )
                }
            })
            js.getGlobalObject().set("__tvRequest", JSCallFunction { args ->
                // 同上：JS → Java 的回调里不能抛异常。
                runCatching {
                    val options = JSONObject(args.getOrNull(1)?.toString() ?: "{}")
                    val raw = options.optJSONObject("headers")
                    val headers = raw?.keys()?.asSequence()
                        ?.associateWith { raw.getString(it) }.orEmpty()
                    check(options.optString("method", "GET").equals("GET", true))
                    fetch(origin.resolve(args[0].toString()), headers, 4 * 1024 * 1024)
                        .toString()
                }.getOrElse { failure ->
                    if (failure is VirtualMachineError || failure is ThreadDeath) throw failure
                    val message = failure.message ?: failure.javaClass.simpleName
                    Log.d("TvboxSpider", "JS 请求失败：$message")
                    JSONObject()
                        .put("code", -1)
                        .put("content", "")
                        .put("headers", JSONObject())
                        .toString()
                }
            })
            js.evaluate("""
                // net.js 的 req/http 最终走全局 _http；这里统一指向同一个 Java 请求桥。
                globalThis._http = (url, opts = {}) => JSON.parse(__tvRequest(url, JSON.stringify(opts)));
                globalThis.req = globalThis.http = globalThis._http;
                globalThis.__tvCall = (method, args) => {
                    globalThis.__tvResult = null;
                    const fn = globalThis.__tvSpider[method];
                    const result = typeof fn === 'function' ? fn.apply(globalThis.__tvSpider, args) : null;
                    const finish = value => globalThis.__tvResult = JSON.stringify({value});
                    if (result && typeof result.then === 'function') result.then(finish, () => finish(null));
                    else finish(result);
                };
            """.trimIndent())
            budget()
            // 用非空源码，避免个别 QuickJS 构建对空模块返回空字节码。
            emptyModule = js.compileModule("export default null;", "__tv_empty__")
            // 与参考 Box JsSpider 一致：站点脚本先在顶层编译/执行，bootstrap 的
            // import 命中 QuickJS 的 loaded_modules 缓存，不再走原生模块加载回调。
            // （在回调里编译站点脚本会重入原生层，是 JS_GetModuleExport 崩溃的温床。）
            val siteSource = moduleSource(api)
            if (!siteSource.startsWith("//")) {
                // 静态远程 import 全部提前拉取/编译；失败就在 evaluateModule 之前
                // 干净失败，绝不把「解析失败」带进原生模块加载流程。
                preloadRemoteModules(api, siteSource, 0)
            }
            val bootstrapTarget = if (siteSource.startsWith("//")) {
                // //bb / //DRPY 是预编译字节码，直接 execute 注册成模块。
                js.execute(moduleBytecode(api), "$key.js")
                "$key.js"
            } else {
                js.evaluateModule(siteSource, api)
                api
            }
            js.evaluateModule("""
                import * as module from ${JSONObject.quote(bootstrapTarget)};
                globalThis.__tvCat = typeof module.__jsEvalReturn === 'function';
                const factory = globalThis.__tvCat ? module.__jsEvalReturn : module.default;
                globalThis.__tvSpider = typeof factory === 'function' ? factory() : factory;
            """.trimIndent(), origin.resolve("./__tvbox_bootstrap__.js").toString())
            val value = runCatching { org.json.JSONTokener(ext).nextValue() }.getOrDefault(ext)
            val cat = js.evaluate("globalThis.__tvCat") == true
            invoke("init", if (cat) JSONObject().put("stype", 3).put("skey", key).put("ext", value) else value)
        } catch (failure: Throwable) {
            destroyed.set(true)
            runCatching { if (::js.isInitialized) js.destroy() }
            // 当前就在执行器线程内，shutdownNow 会给自己打中断标记；用 shutdown 即可。
            runCatching { executor.shutdown() }
            throw failure
        }
    }

    private fun budget() {
        deadline = SystemClock.elapsedRealtime() + 30_000
        requests = 0
    }

    private fun checked(uri: URI): URI {
        require(uri.scheme.equals("https", ignoreCase = true) && uri.userInfo == null &&
            uri.host.equals(origin.host, true) &&
            (if (uri.port < 0) 443 else uri.port) == (if (origin.port < 0) 443 else origin.port))
        return uri
    }

    /// 模块名解析：assets:// 走内置脚本；https 相对路径仍限同一站点。
    private fun resolveModuleName(base: String, name: String): String {
        if (name.contains("://")) return name
        if (base.startsWith("assets://")) {
            return normalizeAssetPath("${base.substringBeforeLast('/')}/$name")
        }
        val resolved = origin.resolve(base).resolve(name)
        require(resolved.scheme.equals("https", ignoreCase = true) ||
            resolved.scheme.equals("http", ignoreCase = true)) { "模块地址无效" }
        return resolved.toString()
    }

    private fun normalizeAssetPath(path: String): String {
        val parts = ArrayDeque<String>()
        for (segment in path.removePrefix("assets://").split('/')) {
            when (segment) {
                "", "." -> {}
                ".." -> {
                    if (parts.isNotEmpty()) parts.removeLast()
                }
                else -> parts.addLast(segment)
            }
        }
        return "assets://" + parts.joinToString("/")
    }

    /// 模块字节码：内置库是 QuickJS 预编译产物（`//DRPY` / `//bb` 前缀），
    /// 直接解码；其余按源码编译。与参考 Box JsSpider.getModuleBytecode 一致。
    private fun moduleBytecode(name: String): ByteArray {
        val source = moduleSource(name)
        if (source.startsWith("//DRPY")) {
            return Base64.decode(source.removePrefix("//DRPY"), Base64.URL_SAFE)
        }
        if (source.startsWith("//bb")) {
            return byteFF(Base64.decode(source.removePrefix("//bb"), Base64.DEFAULT))
        }
        return js.compileModule(source, name)
    }

    /** `//bb` 产物的头处理：去掉 4 字节前缀并标记版本，参考 Box byteFF。 */
    private fun byteFF(bytes: ByteArray): ByteArray {
        require(bytes.size > 4) { "模块字节码长度不足" }
        val out = ByteArray(bytes.size - 4)
        out[0] = 1
        System.arraycopy(bytes, 5, out, 1, bytes.size - 5)
        return out
    }

    /** 递归预取静态 import 的远程模块（含传递依赖），限深度与数量。 */
    private fun preloadRemoteModules(entry: String, source: String, depth: Int) {
        if (depth > 4 || preloadedModules.size >= 24) return
        for (raw in remoteImports(source)) {
            val name = resolveModuleName(entry, raw)
            if (preloadedModules.containsKey(name)) continue
            try {
                val text = moduleSource(name)
                preloadedModules[name] = moduleBytecode(name)
                preloadRemoteModules(name, text, depth + 1)
            } catch (failure: Throwable) {
                Log.w("TvboxSpider", "JS 模块预加载失败 $name：${failure.message ?: failure.javaClass.simpleName}")
                throw failure
            }
        }
    }

    private fun remoteImports(source: String): List<String> {
        val pattern = Regex("""(?:from\s*|import\s*\(\s*|import\s+)['"](https?://[^'"]+)['"]""")
        return pattern.findAll(source).map { it.groupValues[1] }.toList()
    }

    /// 模块源码：内置库优先（gbk / 模板 / cat），其次 assets://，最后同域 https。
    private fun moduleSource(name: String): String {
        forcedAssets.firstOrNull { name.contains(it) }?.let { file ->
            return readAsset("js/lib/$file") ?: error("内置脚本缺失：js/lib/$file")
        }
        if (name.startsWith("assets://")) {
            return readAsset(name.removePrefix("assets://"))
                ?: error("assets 缺失：${name.removePrefix("assets://")}")
        }
        if (!name.contains("://")) {
            readAsset("js/lib/${name.trimStart('/')}")?.let { return it }
        }
        val response = fetch(
            URI(name),
            emptyMap(),
            2 * 1024 * 1024,
            enforceOrigin = false,
            countRequest = false,
        )
        val code = response.getInt("code")
        check(code in 200..299) { "HTTP $code" }
        return response.getString("content")
    }

    private fun readAsset(path: String): String? {
        val name = path.removePrefix("/")
        if (name.isEmpty() || name.contains("..")) return null
        return runCatching {
            assetManager.open(name).use { it.readBytes().toString(Charsets.UTF_8) }
        }.getOrNull()
    }

    private fun fetch(
        uri: URI,
        headers: Map<String, String>,
        limit: Int,
        enforceOrigin: Boolean = true,
        countRequest: Boolean = true,
    ): JSONObject {
        val name = uri.toString()
        // assets:// 是宿主内置脚本/数据，与 https 一样通过 req() 读取。
        if (name.startsWith("assets://")) {
            val content = readAsset(name.removePrefix("assets://")) ?: error("assets 缺失")
            return JSONObject().put("code", 200).put("content", content)
                .put("headers", JSONObject())
        }
        // 模块加载不计入 req() 的 12 次配额（否则脚本自身请求会被挤掉）。
        if (countRequest) requests++
        check(requests <= 12 && SystemClock.elapsedRealtime() < deadline)
        // 模块加载允许任意 http/https 主机（与参考 Box FileUtils.loadModule 一致，
        // 脚本常从 CDN 导入模块）；脚本主动 req() 仍限同域，避免 SSRF。
        val target = if (enforceOrigin) {
            checked(uri)
        } else {
            require((uri.scheme.equals("https", ignoreCase = true) ||
                uri.scheme.equals("http", ignoreCase = true)) &&
                uri.userInfo == null && !uri.host.isNullOrEmpty()) { "模块地址无效" }
            uri
        }
        val connection = target.toURL().openConnection() as HttpURLConnection
        try {
            // 模块加载允许跟随跳转（同域 req() 仍禁止，避免 SSRF）。
            connection.instanceFollowRedirects = !enforceOrigin
            connection.connectTimeout = 6_000
            connection.readTimeout = 8_000
            connection.setRequestProperty("User-Agent", "okhttp/3.15")
            connection.setRequestProperty("Accept", "*/*")
            headers.forEach { (name, value) ->
                if (!name.equals("host", true)) connection.setRequestProperty(name, value)
            }
            val code = connection.responseCode
            val body = (if (code >= 400) connection.errorStream else connection.inputStream)?.use { input ->
                val out = ByteArrayOutputStream()
                val bytes = ByteArray(8192)
                while (true) {
                    check(SystemClock.elapsedRealtime() < deadline)
                    val count = input.read(bytes)
                    if (count < 0) break
                    require(out.size() + count <= limit)
                    out.write(bytes, 0, count)
                }
                out.toString("UTF-8")
            }.orEmpty()
            val responseHeaders = JSONObject()
            connection.headerFields.forEach { (name, values) -> if (name != null) responseHeaders.put(name, values.joinToString(", ")) }
            return JSONObject().put("code", code).put("content", body).put("headers", responseHeaders)
        } finally {
            connection.disconnect()
        }
    }

    private fun invoke(name: String, vararg args: Any?): Any? {
        budget()
        js.evaluate("__tvCall(${JSONObject.quote(name)}, ${JSONArray(args.toList())})")
        val result = js.evaluate("globalThis.__tvResult") as? String ?: error("脚本未完成")
        return JSONObject(result).opt("value").takeUnless { it == JSONObject.NULL }
    }

    private fun text(name: String, vararg args: Any?): String = invoke(name, *args)?.toString().orEmpty()

    override fun homeContent(filter: Boolean) = text("home", filter)
    override fun homeVideoContent() = text("homeVod")
    override fun categoryContent(id: String, page: String, filter: Boolean, ext: HashMap<String, String>) =
        text("category", id, page, filter, JSONObject(ext))
    override fun detailContent(ids: List<String>) = text("detail", ids.first())
    override fun searchContent(key: String, quick: Boolean, page: String) = text("search", key, quick, page)
    override fun playerContent(flag: String, id: String, flags: List<String>) = text("play", flag, id, JSONArray(flags))

    override fun proxyLocal(params: Map<String, String>): Array<Any?>? {
        val res = invoke("proxy", JSONObject(params)) as? JSONArray ?: return null
        if (res.length() < 2) return null
        val body = res.optString(2)
        val headers = res.optJSONObject(3)?.let { obj -> obj.keys().asSequence().associateWith { obj.getString(it) } }
        return arrayOf(res.optInt(0, 200), res.optString(1, "application/octet-stream"), if (res.optInt(4) == 1 && body.contains("base64,")) {
            android.util.Base64.decode(body.substringAfter("base64,"), android.util.Base64.DEFAULT)
        } else body, headers)
    }

    override fun destroy() {
        if (!destroyed.compareAndSet(false, true)) return
        // 销毁也必须在创建线程执行，否则 checkSameThread 抛异常 → 原生内存不释放。
        // destroy 与 shutdown 放同一个任务，保证不留下「已 shutdown 但未 destroy」的尾巴。
        try {
            executor.execute {
                runCatching { if (::js.isInitialized) js.destroy() }
                executor.shutdown()
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // 已 shutdown：init 失败路径已清理过。
        }
    }

    private fun cacheKey(name: String): String? = when {
        name.contains("cheerio.min.js") -> "cheerio.min"
        name.contains("crypto-js.js") -> "crypto-js"
        else -> null
    }
}
