package com.github.catvod.crawler;

import android.util.Log;
import androidx.annotation.Keep;

@Keep
public class SpiderDebug {
    private static final ThreadLocal<String> searchSite = new ThreadLocal<>();
    private static final ThreadLocal<String> failureHint = new ThreadLocal<>();

    public static void setSearchSite(String site) {
        failureHint.remove();
        if (site == null) searchSite.remove();
        else searchSite.set(site);
    }

    public static void log(Throwable failure) {
        if (failure == null) return;
        String site = searchSite.get();
        String type = failure.getClass().getSimpleName();
        Throwable cause = failure.getCause();
        Throwable current = failure;
        for (int i = 0; site != null && current != null && i < 8; i++, current = current.getCause()) {
            String hint = null;
            if (current instanceof java.net.UnknownHostException) hint = "域名解析失败";
            else if (current instanceof java.net.SocketTimeoutException) hint = "请求超时";
            else if (current instanceof java.net.ConnectException) hint = "连接失败";
            else if (current instanceof java.io.InterruptedIOException) hint = "请求中断";
            else if (current instanceof org.json.JSONException) hint = "响应格式异常";
            else if (current instanceof javax.crypto.BadPaddingException) hint = "响应解密失败";
            else if (current instanceof IndexOutOfBoundsException) hint = "数据解析越界";
            if (hint != null && failureHint.get() == null) failureHint.set(hint);
        }
        String detail = cause != null && cause != failure
                ? "，原因 " + cause.getClass().getSimpleName() : "";
        Log.d("TvboxSpider", (site == null ? "插件日志" : site + "插件日志")
                + "：" + type + detail);
    }

    // 保留宿主方法签名，不把插件原文中的地址或凭据写入日志。
    public static void log(String message) {}

    public static String ec(int code) { return ""; }
    public static String failureHint() { return failureHint.get(); }
}
