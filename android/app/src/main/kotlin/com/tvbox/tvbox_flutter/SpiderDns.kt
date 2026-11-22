package com.tvbox.tvbox_flutter

import android.os.SystemClock
import android.util.LruCache
import okhttp3.Dns
import okhttp3.dnsoverhttps.DnsOverHttps
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.InetAddress
import java.util.concurrent.TimeUnit

// 保持 Dns 实例稳定，已初始化并缓存 OkHttpClient 的插件也能跟随设置。
object SpiderDns : Dns {
    private class Policy(val endpoints: List<HttpUrl>) {
        val cache = LruCache<String, Pair<Long, List<InetAddress>>>(256)
        val wire = endpoints.filter { it.encodedPath == "/dns-query" && it.host in setOf(
            "doh.pub", "dns.alidns.com", "doh.360.cn", "dns.google", "dns.adguard.com", "dns.quad9.net"
        ) }.associateWith { DnsOverHttps.Builder().client(bootstrap).url(it).post(true).build() }
    }
    @Volatile private var policy = Policy(emptyList())
    private val bootstrap by lazy {
        OkHttpClient.Builder().dns(Dns.SYSTEM).callTimeout(3, TimeUnit.SECONDS)
            .followRedirects(false).build()
    }

    fun configure(endpoints: List<String>) {
        val urls = endpoints.mapNotNull { it.toHttpUrlOrNull() }.filter { it.isHttps }.take(3)
        if (urls != policy.endpoints) policy = Policy(urls)
    }

    override fun lookup(hostname: String): List<InetAddress> {
        val active = policy
        if (active.endpoints.isEmpty() || !hostname.contains('.') || hostname.contains(':') ||
            hostname.all { it.isDigit() || it == '.' } || hostname.endsWith(".local", true) ||
            hostname.endsWith(".localhost", true)) return Dns.SYSTEM.lookup(hostname)
        active.cache.get(hostname)?.let { if (it.first > SystemClock.elapsedRealtime()) return it.second }
        for (endpoint in active.endpoints) {
            if (Thread.currentThread().isInterrupted) break
            try {
                active.wire[endpoint]?.let { return it.lookup(hostname) }
                val url = endpoint.newBuilder().setQueryParameter("name", hostname).setQueryParameter("type", "A").build()
                val request = Request.Builder().url(url).header("Accept", "application/dns-json").build()
                bootstrap.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@use
                    val source = response.body?.source() ?: return@use
                    if (source.request(65537)) return@use
                    val reply = JSONObject(source.readUtf8())
                    val answers = reply.optJSONArray("Answer") ?: return@use
                    if (reply.optInt("Status", -1) != 0) return@use
                    val addresses = mutableListOf<InetAddress>()
                    var ttl = 300
                    for (index in 0 until answers.length()) {
                        val answer = answers.optJSONObject(index) ?: continue
                        if (answer.optInt("type") != 1) continue
                        val parts = answer.optString("data").split('.')
                        if (parts.size != 4) continue
                        val numbers = parts.mapNotNull { it.toIntOrNull()?.takeIf { n -> n in 0..255 } }
                        if (numbers.size != 4) continue
                        addresses.add(InetAddress.getByAddress(hostname, ByteArray(4) { numbers[it].toByte() }))
                        ttl = minOf(ttl, answer.optInt("TTL", 60).coerceAtLeast(0))
                    }
                    if (addresses.isNotEmpty()) {
                        val result = addresses.toList()
                        active.cache.put(hostname, SystemClock.elapsedRealtime() + ttl * 1000L to result)
                        return result
                    }
                }
            } catch (_: Exception) {
                // 端点不可用时继续尝试，最终回退系统 DNS（包括 IPv6-only 域名）。
            }
        }
        return Dns.SYSTEM.lookup(hostname)
    }
}
