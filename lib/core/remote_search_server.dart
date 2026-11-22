import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 手机远程搜索：在局域网内起一个轻量 HTTP 服务（复刻 Box 的 Remote 功能）。
///
/// 电视端展示二维码，手机扫码打开网页输入关键词并发送，
/// 电视端通过 [onQuery] 立即执行搜索。仅在局域网内可访问。
class RemoteSearchServer {
  RemoteSearchServer({
    required this.onQuery,
    this.hotWords,
    this.suggest,
  });

  /// 手机端提交关键词时回调（主 isolate）。
  final void Function(String query) onQuery;

  /// 电视端热词，供手机页面「热门搜索」使用。
  final List<String> Function()? hotWords;

  /// 拼音/关键词联想，供手机页面输入提示使用。
  final Future<List<String>> Function(String query)? suggest;

  static const int defaultPort = 9268;
  static const int _portAttempts = 6;

  HttpServer? _server;
  String? _baseUrl;
  Future<String>? _starting;

  /// 当前可访问地址（启动后有效），例如 `http://192.168.1.8:9268`。
  String? get baseUrl => _baseUrl;

  /// 启动服务（幂等、可重入），返回可访问地址。
  ///
  /// 原实现把幂等判断放在 `await _localAddress()`/`bind` 之前，连点会
  /// 在 await 间隙重入、起两个 [HttpServer]，先起的那个泄漏。这里用
  /// [_starting] 守卫：并发调用共享同一个 future，重复调用只返回缓存地址。
  Future<String> start() {
    final existing = _server;
    if (existing != null) return Future.value(_baseUrl ?? '');
    return _starting ??= _doStart();
  }

  Future<String> _doStart() async {
    try {
      final address = await _localAddress();
      HttpServer? server;
      for (var i = 0; i < _portAttempts; i++) {
        try {
          server = await HttpServer.bind(
            InternetAddress.anyIPv4,
            defaultPort + i,
          );
          break;
        } on SocketException {
          // 端口被占用，顺延一个端口继续尝试。
        }
      }
      if (server == null) {
        throw const SocketException('没有可用端口，请关闭占用 9268-9273 的程序');
      }
      _server = server;
      _baseUrl = 'http://$address:${server.port}';
      server.listen(_handle, onError: (_) {});
      return _baseUrl!;
    } finally {
      _starting = null;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _baseUrl = null;
    await server?.close(force: true);
  }

  /// 优先取 Wi-Fi 网卡地址，避免手机插着数据网络时拿到蜂窝地址。
  Future<String> _localAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    NetworkInterface? wifi;
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (name.startsWith('wlan') || name.startsWith('en')) {
        wifi = interface;
        break;
      }
    }
    final chosen = wifi ?? (interfaces.isEmpty ? null : interfaces.first);
    if (chosen != null && chosen.addresses.isNotEmpty) {
      return chosen.addresses.first.address;
    }
    return '127.0.0.1';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    try {
      final path = request.uri.path;
      final query = (request.uri.queryParameters['q'] ?? '').trim();

      if (path == '/' && request.method == 'GET') {
        await _writeHtml(response, _inputPage);
        return;
      }
      if (path == '/api/hot' && request.method == 'GET') {
        await _writeJson(response, {'words': hotWords?.call() ?? const []});
        return;
      }
      if (path == '/api/suggest' && request.method == 'GET') {
        final words = query.isEmpty
            ? <String>[]
            : (await suggest?.call(query) ?? const <String>[]);
        await _writeJson(response, {'words': words});
        return;
      }
      if (path == '/api/search' && request.method == 'GET') {
        if (query.isEmpty) {
          await _writeJson(response, {'ok': false, 'error': 'empty query'});
          return;
        }
        onQuery(query);
        await _writeJson(response, {'ok': true, 'query': query});
        return;
      }
      if (path == '/search' && request.method == 'GET') {
        // 兼容直接扫带关键词的链接（例如分享出来的地址）。
        await _writeHtml(response, _sentPage(query));
        if (query.isNotEmpty) onQuery(query);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _writeHtml(HttpResponse response, String html) async {
    final bytes = utf8.encode(html);
    response.headers.contentType = ContentType(
      'text',
      'html',
      charset: 'utf-8',
    );
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> _writeJson(HttpResponse response, Object data) async {
    final bytes = utf8.encode(jsonEncode(data));
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  static const String _inputPage = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0b0d14">
<title>TVBOX 远程搜索</title>
<style>
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
       background:#0b0d14;color:#fff;min-height:100vh;
       padding:max(18px,env(safe-area-inset-top)) 16px calc(96px + env(safe-area-inset-bottom))}
  .wrap{max-width:520px;margin:0 auto}
  header{display:flex;align-items:center;gap:10px;margin:6px 0 18px}
  .logo{width:34px;height:34px;border-radius:11px;background:linear-gradient(135deg,#ff5a52,#c0252b);
        display:flex;align-items:center;justify-content:center;font-weight:800;font-size:15px}
  .title{font-size:17px;font-weight:800;letter-spacing:.3px}
  .sub{font-size:12px;color:#7d869b;margin-top:2px}
  .card{background:#141826;border:1px solid rgba(255,255,255,.07);border-radius:18px;padding:16px}
  .field{display:flex;align-items:center;gap:10px;background:#0b0d14;border:1px solid #2a3145;
         border-radius:13px;padding:12px 14px;transition:border-color .2s}
  .field:focus-within{border-color:#e5484d}
  .field input{flex:1;min-width:0;border:0;background:transparent;color:#fff;font-size:17px;outline:none}
  .field input::placeholder{color:#5c6478}
  .clear{display:none;width:22px;height:22px;border-radius:50%;background:#2a3145;color:#9aa3b5;
         border:0;font-size:13px;line-height:1;cursor:pointer}
  .label{font-size:12.5px;color:#7d869b;margin:18px 0 9px;display:flex;justify-content:space-between;align-items:center}
  .label button{background:none;border:0;color:#5c6478;font-size:12px;padding:2px}
  .chips{display:flex;flex-wrap:wrap;gap:8px}
  .chip{background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.09);color:#e6e9f2;
        border-radius:999px;padding:8px 14px;font-size:13.5px;cursor:pointer}
  .chip:active{background:rgba(255,255,255,.14)}
  .chip.hot{color:#ffb4ae;border-color:rgba(229,72,77,.28);background:rgba(229,72,77,.1)}
  .empty{color:#5c6478;font-size:13px;padding:4px 0}
  footer{position:fixed;left:0;right:0;bottom:0;padding:14px 16px calc(14px + env(safe-area-inset-bottom));
         background:linear-gradient(180deg,rgba(11,13,20,0),#0b0d14 34%);}
  .send{display:block;width:100%;max-width:520px;margin:0 auto;font-size:16.5px;font-weight:700;
        padding:15px 0;border:0;border-radius:14px;color:#fff;cursor:pointer;
        background:linear-gradient(135deg,#ff5a52,#c0252b);box-shadow:0 10px 26px rgba(229,72,77,.28)}
  .send:disabled{opacity:.55;box-shadow:none}
  .toast{position:fixed;left:50%;bottom:calc(92px + env(safe-area-inset-bottom));transform:translateX(-50%) translateY(8px);
         background:rgba(28,34,48,.96);border:1px solid rgba(255,255,255,.1);color:#fff;font-size:13.5px;
         padding:10px 16px;border-radius:12px;opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;white-space:nowrap}
  .toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="logo">TV</div>
    <div>
      <div class="title">TVBOX 远程搜索</div>
      <div class="sub">手机上打字，电视上直接搜</div>
    </div>
  </header>

  <div class="card">
    <div class="field">
      <span style="color:#5c6478;font-size:15px">🔍</span>
      <input id="q" placeholder="输入片名或拼音首字母" autocomplete="off" autocapitalize="off" spellcheck="false">
      <button class="clear" id="clear" aria-label="清空">✕</button>
    </div>

    <div class="label" id="sugLabel" style="display:none"><span>联想</span></div>
    <div class="chips" id="sug"></div>

    <div class="label"><span>热门搜索</span></div>
    <div class="chips" id="hot"><div class="empty">加载中…</div></div>

    <div class="label"><span>最近搜索</span><button id="clearHist">清空</button></div>
    <div class="chips" id="hist"><div class="empty">还没有记录</div></div>
  </div>
</div>

<footer><button class="send" id="send">发送到电视</button></footer>
<div class="toast" id="toast"></div>

<script>
(function(){
  var input = document.getElementById('q');
  var clearBtn = document.getElementById('clear');
  var sugBox = document.getElementById('sug');
  var sugLabel = document.getElementById('sugLabel');
  var hotBox = document.getElementById('hot');
  var histBox = document.getElementById('hist');
  var toastEl = document.getElementById('toast');
  var KEY = 'tvbox_remote_history';

  function history(){
    try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch(e){ return []; }
  }
  function saveHistory(list){
    try { localStorage.setItem(KEY, JSON.stringify(list.slice(0, 10))); } catch(e){}
  }
  function remember(q){
    var list = history().filter(function(x){ return x !== q; });
    list.unshift(q);
    saveHistory(list);
    renderHistory();
  }
  var toastTimer;
  function toast(msg){
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function(){ toastEl.classList.remove('show'); }, 2200);
  }
  function chip(text, cls, onTap){
    var el = document.createElement('button');
    el.className = 'chip' + (cls ? ' ' + cls : '');
    el.textContent = text;
    el.addEventListener('click', onTap);
    return el;
  }
  function renderHistory(){
    var list = history();
    histBox.innerHTML = '';
    if (!list.length){
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = '还没有记录';
      histBox.appendChild(empty);
      return;
    }
    list.forEach(function(word){
      histBox.appendChild(chip(word, '', function(){
        input.value = word;
        sync();
        send();
      }));
    });
  }
  function renderHot(words){
    hotBox.innerHTML = '';
    if (!words || !words.length){
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = '暂无热门词';
      hotBox.appendChild(empty);
      return;
    }
    words.slice(0, 12).forEach(function(word){
      hotBox.appendChild(chip(word, 'hot', function(){
        input.value = word;
        sync();
        send();
      }));
    });
  }
  var sugTimer;
  var sugToken = 0;
  function sync(){
    clearBtn.style.display = input.value ? 'block' : 'none';
    var q = input.value.trim();
    clearTimeout(sugTimer);
    if (!q){
      sugBox.innerHTML = '';
      sugLabel.style.display = 'none';
      return;
    }
    sugTimer = setTimeout(function(){
      var token = ++sugToken;
      fetch('/api/suggest?q=' + encodeURIComponent(q))
        .then(function(r){ return r.json(); })
        .then(function(data){
          if (token !== sugToken) return;
          var words = (data && data.words) || [];
          sugBox.innerHTML = '';
          sugLabel.style.display = words.length ? 'flex' : 'none';
          words.slice(0, 8).forEach(function(word){
            sugBox.appendChild(chip(word, '', function(){
              input.value = word;
              sync();
              send();
            }));
          });
        })
        .catch(function(){});
    }, 220);
  }
  var sending = false;
  function send(){
    var q = input.value.trim();
    if (!q) { input.focus(); return; }
    if (sending) return;
    sending = true;
    var btn = document.getElementById('send');
    btn.disabled = true;
    btn.textContent = '发送中…';
    fetch('/api/search?q=' + encodeURIComponent(q))
      .then(function(r){ return r.json(); })
      .then(function(data){
        if (data && data.ok){
          remember(q);
          toast('已发送「' + q + '」到电视');
        } else {
          toast('发送失败，请重试');
        }
      })
      .catch(function(){ toast('连接失败，请确认手机和电视在同一 Wi-Fi'); })
      .then(function(){
        sending = false;
        btn.disabled = false;
        btn.textContent = '发送到电视';
      });
  }

  document.getElementById('send').addEventListener('click', send);
  document.getElementById('clear').addEventListener('click', function(){
    input.value = '';
    sync();
    input.focus();
  });
  document.getElementById('clearHist').addEventListener('click', function(){
    saveHistory([]);
    renderHistory();
  });
  input.addEventListener('input', sync);
  input.addEventListener('keydown', function(e){
    if (e.key === 'Enter') { e.preventDefault(); send(); }
  });

  renderHistory();
  fetch('/api/hot')
    .then(function(r){ return r.json(); })
    .then(function(data){ renderHot(data && data.words); })
    .catch(function(){ renderHot([]); });
  input.focus();
})();
</script>
</body>
</html>
''';

  static String _sentPage(String query) => '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>已发送</title>
<style>
  body{margin:0;font-family:-apple-system,"PingFang SC",sans-serif;background:#0b0d14;color:#fff;
       min-height:100vh;display:flex;align-items:center;justify-content:center}
  .box{text-align:center;padding:0 24px}
  .ok{width:64px;height:64px;border-radius:50%;margin:0 auto 18px;
      background:rgba(76,195,138,.14);color:#4cc38a;font-size:32px;line-height:64px}
  p{color:#9aa3b5;font-size:14px;line-height:1.8;margin:0}
  strong{color:#fff}
</style>
</head>
<body>
  <div class="box">
    <div class="ok">✓</div>
    <p>已把 <strong>${_escapeHtml(query)}</strong> 发送到电视<br>请看电视屏幕</p>
  </div>
</body>
</html>
''';

  static String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
