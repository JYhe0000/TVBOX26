package com.github.catvod.crawler;

import android.content.Context;
import androidx.annotation.Keep;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import okhttp3.Dns;

// CatVod 插件 ABI。方法签名必须与外部插件编译时一致。
@Keep
public class Spider {
    public void init(Context context) throws Exception {}
    public void init(Context context, String ext) throws Exception { init(context); }
    public String homeContent(boolean filter) throws Exception { return ""; }
    public String homeVideoContent() throws Exception { return ""; }
    public String categoryContent(String id, String page, boolean filter,
            HashMap<String, String> ext) throws Exception { return ""; }
    public String detailContent(List<String> ids) throws Exception { return ""; }
    public String searchContent(String key, boolean quick) throws Exception { return ""; }
    public String searchContent(String key, boolean quick, String page) throws Exception {
        return searchContent(key, quick);
    }
    public String playerContent(String flag, String id, List<String> flags) throws Exception { return ""; }
    public boolean manualVideoCheck() throws Exception { return false; }
    public boolean isVideoFormat(String url) throws Exception { return false; }
    public Object[] proxyLocal(Map<String, String> params) throws Exception { return null; }
    public void cancelByTag() {}
    public void destroy() {}
    public String liveContent(String url) { return ""; }
    public static Dns safeDns() { return com.tvbox.tvbox_flutter.SpiderDns.INSTANCE; }
}
