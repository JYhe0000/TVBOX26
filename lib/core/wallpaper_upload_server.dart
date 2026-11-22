import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 手机扫码上传图片到电视：在局域网内起一个轻量 HTTP 服务（复刻 Box 的
/// Remote 功能同构模式，见 [RemoteSearchServer]）。
///
/// 电视端展示二维码，手机扫码打开上传页选择一张本地图片，页面把图片读成
/// base64 塞进 JSON 提交，电视端通过 [onImageReceived] 立即拿到图片原始
/// 字节与文件名。仅在局域网内可访问。
class WallpaperUploadServer {
  WallpaperUploadServer({required this.onImageReceived});

  /// 手机端上传完成时回调（主 isolate），bytes 是图片原始字节，filename 是
  /// 原始文件名。
  final void Function(Uint8List bytes, String filename) onImageReceived;

  /// 起步端口，与 remote_search_server 的 9268-9273 错开，避免端口冲突。
  static const int defaultPort = 9274;
  static const int _portAttempts = 6;

  /// 图片上限 8MB；base64 膨胀约 4/3，JSON body 上限放宽到 12MB。
  static const int _maxImageBytes = 8 * 1024 * 1024;
  static const int _maxBodyBytes = 12 * 1024 * 1024;

  HttpServer? _server;
  String? _baseUrl;
  Future<String>? _starting;

  /// 当前可访问地址（启动后有效），例如 `http://192.168.1.8:9274`。
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
        throw const SocketException('没有可用端口，请关闭占用 9274-9279 的程序');
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
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    try {
      if (request.method == 'OPTIONS') {
        // 预检请求：直接放行，避免手机端浏览器因跨域预检卡住。
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      final path = request.uri.path;
      if (path == '/' && request.method == 'GET') {
        await _writeHtml(response, _uploadPage);
        return;
      }
      if (path == '/api/upload' && request.method == 'POST') {
        await _handleUpload(request, response);
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

  Future<void> _handleUpload(
    HttpRequest request,
    HttpResponse response,
  ) async {
    try {
      final bodyBytes = await request.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      if (bodyBytes.length > _maxBodyBytes) {
        await _writeJson(response, {'ok': false, 'error': '图片过大，请选择 8MB 以内的图片'});
        return;
      }
      final body = utf8.decode(bodyBytes);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        await _writeJson(response, {'ok': false, 'error': '无效的请求数据'});
        return;
      }
      final name = (decoded['name'] as String?)?.trim() ?? '';
      final data = decoded['data'] as String?;
      if (data == null || data.isEmpty) {
        await _writeJson(response, {'ok': false, 'error': '缺少图片数据'});
        return;
      }
      // 前端 FileReader.readAsDataURL 的 DataURL 按 MIME 规范（RFC 2045）允许
      // 每 76 字符插入换行，部分移动浏览器/WebView 也确实会插；Dart 的
      // base64Decode 是严格解码器，遇空白（\n \r \t 空格）会抛 FormatException，
      // 真实手机上传大图（几 MB）因此报「上传失败」。解码前先剥掉所有空白。
      final bytes = base64Decode(data.replaceAll(RegExp(r'\s'), ''));
      if (bytes.isEmpty) {
        await _writeJson(response, {'ok': false, 'error': '无效的图片数据'});
        return;
      }
      if (bytes.length > _maxImageBytes) {
        await _writeJson(response, {'ok': false, 'error': '图片过大，请选择 8MB 以内的图片'});
        return;
      }
      onImageReceived(
        Uint8List.fromList(bytes),
        name.isEmpty ? 'upload.jpg' : name,
      );
      await _writeJson(response, {'ok': true, 'name': name});
    } catch (_) {
      try {
        await _writeJson(response, {'ok': false, 'error': '上传失败，请重试'});
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

  static const String _uploadPage = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0b0d14">
<title>上传背景图</title>
<style>
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
       background:#0b0d14;color:#fff;min-height:100vh;
       padding:max(18px,env(safe-area-inset-top)) 16px calc(96px + env(safe-area-inset-bottom))}
  .wrap{max-width:520px;margin:0 auto}
  header{display:flex;align-items:center;gap:10px;margin:6px 0 18px}
  .logo{width:34px;height:34px;border-radius:11px;background:linear-gradient(135deg,#5b87eb,#3f68e2);
        display:flex;align-items:center;justify-content:center;font-weight:800;font-size:15px}
  .title{font-size:17px;font-weight:800;letter-spacing:.3px}
  .sub{font-size:12px;color:#7d869b;margin-top:2px}
  .card{background:#141826;border:1px solid rgba(255,255,255,.07);border-radius:18px;padding:16px}
  .pick{position:relative;overflow:hidden;display:flex;flex-direction:column;align-items:center;gap:6px;padding:30px 16px;text-align:center;
        border:1.5px dashed #2a3145;border-radius:14px;cursor:pointer;transition:border-color .2s,background .2s}
  .pick:active{border-color:#5b87eb;background:rgba(91,135,235,.06)}
  /* 文件选择控件铺满整个 pick 区域、透明可见，用户点击即触发原生选择器。
     不用 display:none——iOS Safari 对 display:none 的 file input 不响应点击。 */
  .fileInput{position:absolute;top:0;left:0;width:100%;height:100%;opacity:0;cursor:pointer;font-size:0}
  .pickIcon{font-size:40px;line-height:1}
  .pickText{font-size:16px;font-weight:700;color:#e6e9f2;margin-top:4px}
  .pickHint{font-size:12.5px;color:#5c6478;margin-top:2px}
  .preview{display:none}
  .preview.show{display:block}
  .preview img{width:100%;max-height:360px;object-fit:contain;border-radius:12px;background:#0b0d14}
  .filename{font-size:13px;color:#9aa3b5;margin-top:10px;text-align:center;word-break:break-all}
  .repick{display:block;margin:12px auto 0;background:none;border:0;color:#5c6478;font-size:13px;padding:4px 8px;cursor:pointer}
  footer{position:fixed;left:0;right:0;bottom:0;padding:14px 16px calc(14px + env(safe-area-inset-bottom));
         background:linear-gradient(180deg,rgba(11,13,20,0),#0b0d14 34%)}
  .send{display:block;width:100%;max-width:520px;margin:0 auto;font-size:16.5px;font-weight:700;
        padding:15px 0;border:0;border-radius:14px;color:#fff;cursor:pointer;
        background:linear-gradient(135deg,#5b87eb,#3f68e2);box-shadow:0 10px 26px rgba(91,135,235,.28)}
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
      <div class="title">上传背景图</div>
      <div class="sub">手机选一张图，立刻设为电视背景</div>
    </div>
  </header>

  <div class="card">
    <div class="pick" id="pick">
      <div class="pickIcon">🖼️</div>
      <div class="pickText">选择一张本地图片</div>
      <div class="pickHint">支持 JPG / PNG / WebP，8MB 以内</div>
      <input type="file" id="file" accept="image/*" class="fileInput">
    </div>

    <div class="preview" id="previewBox">
      <img id="preview" alt="预览">
      <div class="filename" id="filename"></div>
      <button class="repick" id="repick">重新选择</button>
    </div>
  </div>
</div>

<footer><button class="send" id="send" disabled>上传到电视</button></footer>
<div class="toast" id="toast"></div>

<script>
(function(){
  var fileInput = document.getElementById('file');
  var pick = document.getElementById('pick');
  var previewBox = document.getElementById('previewBox');
  var preview = document.getElementById('preview');
  var filename = document.getElementById('filename');
  var sendBtn = document.getElementById('send');
  var toastEl = document.getElementById('toast');
  var fileData = null;
  var fileName = '';

  var toastTimer;
  function toast(msg){
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function(){ toastEl.classList.remove('show'); }, 2600);
  }

  function reset(){
    fileData = null;
    fileName = '';
    fileInput.value = '';
    previewBox.classList.remove('show');
    pick.style.display = 'flex';
    sendBtn.disabled = true;
  }

  fileInput.addEventListener('change', function(){
    var file = fileInput.files && fileInput.files[0];
    if (!file) return;
    if (file.size > 8 * 1024 * 1024){
      toast('图片过大，请选择 8MB 以内的图片');
      fileInput.value = '';
      return;
    }
    fileName = file.name || 'image.jpg';
    var reader = new FileReader();
    reader.onload = function(){
      var result = String(reader.result);
      var comma = result.indexOf(',');
      fileData = comma >= 0 ? result.slice(comma + 1) : result;
      preview.src = result;
      filename.textContent = fileName;
      pick.style.display = 'none';
      previewBox.classList.add('show');
      sendBtn.disabled = false;
    };
    reader.onerror = function(){
      toast('读取图片失败，请重试');
    };
    reader.readAsDataURL(file);
  });

  // 文件选择控件已铺满 pick 区域（透明覆盖），点击 pick 即直接打开原生选择器，
  // 无需再手动 fileInput.click()——那会和覆盖控件叠加触发，导致选择器打开又
  // 关闭（选择后无反馈）。
  document.getElementById('repick').addEventListener('click', function(){
    reset();
    fileInput.click();
  });

  var sending = false;
  function send(){
    if (!fileData || sending) return;
    sending = true;
    sendBtn.disabled = true;
    sendBtn.textContent = '上传中…';
    fetch('/api/upload', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name: fileName, data: fileData})
    })
      .then(function(r){ return r.json(); })
      .then(function(data){
        if (data && data.ok){
          toast('已上传到电视，请看电视屏幕');
        } else {
          toast((data && data.error) || '上传失败，请重试');
        }
      })
      .catch(function(){ toast('连接失败，请确认手机和电视在同一 Wi-Fi'); })
      .then(function(){
        sending = false;
        sendBtn.disabled = !fileData;
        sendBtn.textContent = '上传到电视';
      });
  }
  sendBtn.addEventListener('click', send);
})();
</script>
</body>
</html>
''';
}
