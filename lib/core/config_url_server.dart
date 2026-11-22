import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 手机扫码填写配置地址 / 直播源地址：在局域网内起一个轻量 HTTP 服务
/// （复刻 [RemoteSearchServer] 的同构模式）。
///
/// 电视端展示二维码，手机扫码打开网页粘贴长 URL 并发送，电视端通过
/// [onUrl] 立即拿到地址填进输入框。仅在局域网内可访问。
class ConfigUrlServer {
  ConfigUrlServer({required this.onUrl});

  /// 手机端提交地址时回调（主 isolate）。
  final void Function(String url) onUrl;

  /// 起步端口，与 remote_search（9268-9273）、wallpaper_upload（9274-9279）
  /// 错开，避免端口冲突。
  static const int defaultPort = 9280;
  static const int _portAttempts = 6;

  HttpServer? _server;
  String? _baseUrl;
  Future<String>? _starting;

  /// 当前可访问地址（启动后有效），例如 `http://192.168.1.8:9280`。
  String? get baseUrl => _baseUrl;

  /// 启动服务（幂等、可重入），返回可访问地址。
  ///
  /// 用 [_starting] 守卫：并发调用共享同一个 future，重复调用只返回缓存地址，
  /// 避免在 `await _localAddress()`/`bind` 的间隙重入、起两个 [HttpServer]。
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
        throw const SocketException('没有可用端口，请关闭占用 9280-9285 的程序');
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
      final url = (request.uri.queryParameters['url'] ?? '').trim();

      if (path == '/' && request.method == 'GET') {
        await _writeHtml(response, _inputPage);
        return;
      }
      if (path == '/api/submit' && request.method == 'GET') {
        if (url.isEmpty) {
          await _writeJson(response, {'ok': false, 'error': 'empty url'});
          return;
        }
        onUrl(url);
        await _writeJson(response, {'ok': true, 'url': url});
        return;
      }
      if (path == '/submit' && request.method == 'GET') {
        // 兼容直接扫带地址的链接（例如分享出来的地址）。
        await _writeHtml(response, _sentPage(url));
        if (url.isNotEmpty) onUrl(url);
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
<title>TVBOX 填写地址</title>
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
  .field input{flex:1;min-width:0;border:0;background:transparent;color:#fff;font-size:16px;outline:none}
  .field input::placeholder{color:#5c6478}
  .clear{display:none;width:22px;height:22px;border-radius:50%;background:#2a3145;color:#9aa3b5;
         border:0;font-size:13px;line-height:1;cursor:pointer}
  .hint{font-size:12.5px;color:#7d869b;margin:14px 2px 0;line-height:1.6}
  footer{position:fixed;left:0;right:0;bottom:0;padding:14px 16px calc(14px + env(safe-area-inset-bottom));
         background:linear-gradient(180deg,rgba(11,13,20,0),#0b0d14 34%)}
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
      <div class="title">TVBOX 填写地址</div>
      <div class="sub">手机粘贴长链接，一键发送到电视</div>
    </div>
  </header>

  <div class="card">
    <div class="field">
      <span style="color:#5c6478;font-size:15px">🔗</span>
      <input id="url" type="url" inputmode="url" placeholder="粘贴配置或直播源地址"
             autocomplete="off" autocapitalize="off" spellcheck="false">
      <button class="clear" id="clear" aria-label="清空">✕</button>
    </div>
    <div class="hint">支持 http(s) 链接，粘贴后点下方「发送到电视」。</div>
  </div>
</div>

<footer><button class="send" id="send">发送到电视</button></footer>
<div class="toast" id="toast"></div>

<script>
(function(){
  var input = document.getElementById('url');
  var clearBtn = document.getElementById('clear');
  var toastEl = document.getElementById('toast');

  function sync(){
    clearBtn.style.display = input.value ? 'block' : 'none';
  }
  var toastTimer;
  function toast(msg){
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function(){ toastEl.classList.remove('show'); }, 2400);
  }
  var sending = false;
  function send(){
    var url = input.value.trim();
    if (!url) { input.focus(); toast('请先粘贴地址'); return; }
    if (sending) return;
    sending = true;
    var btn = document.getElementById('send');
    btn.disabled = true;
    btn.textContent = '发送中…';
    fetch('/api/submit?url=' + encodeURIComponent(url))
      .then(function(r){ return r.json(); })
      .then(function(data){
        if (data && data.ok){
          toast('已发送到电视，请看电视屏幕');
        } else {
          toast((data && data.error) || '发送失败，请重试');
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
  clearBtn.addEventListener('click', function(){
    input.value = '';
    sync();
    input.focus();
  });
  input.addEventListener('input', sync);
  input.addEventListener('keydown', function(e){
    if (e.key === 'Enter') { e.preventDefault(); send(); }
  });

  sync();
  input.focus();
})();
</script>
</body>
</html>
''';

  static String _sentPage(String url) => '''
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
    <p>已把 <strong>${_escapeHtml(url)}</strong> 发送到电视<br>请看电视屏幕</p>
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
