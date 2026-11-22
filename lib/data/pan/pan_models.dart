/// 网盘目录项与播放直链的统一模型（三家字段差异在各自 provider 内收敛）。
library;

/// 目录项（文件/文件夹）。[id] 为平台文件 id（百度是 fs_id 字符串），
/// [path] 仅百度使用（绝对路径，其余平台为 null，目录导航靠调用方栈维护）。
class PanEntry {
  const PanEntry({
    required this.id,
    required this.name,
    required this.folder,
    this.size = 0,
    this.modifiedAt,
    this.path,
    this.extension,
  });

  final String id;
  final String name;
  final bool folder;

  /// 字节数，未知为 0。
  final int size;
  final DateTime? modifiedAt;

  /// 百度为绝对路径（`/视频/a.mp4`）；其余平台为 null。
  final String? path;

  /// 小写扩展名（不含点），无扩展名为 null（UI 据此过滤视频）。
  final String? extension;

  @override
  String toString() =>
      'PanEntry(id: $id, name: $name, folder: $folder, size: $size)';
}

/// 平台返回的播放/下载直链。[headers] 是播放请求**必须**随附的头
/// （Referer / User-Agent / Cookie 等防盗链凭据），播放器原样带上。
class PanFileUrl {
  const PanFileUrl({
    required this.url,
    this.headers = const {},
    this.expiresAt,
  });

  final String url;

  /// 播放时随请求发出的头（键值已按各厂要求拼好）。
  final Map<String, String> headers;

  /// 直链过期时间（平台返回时填写；百度 dlink 约 8 小时但接口不返回精确值）。
  final DateTime? expiresAt;
}

/// 从文件名取小写扩展名（不含点），无扩展名/异常长后缀返回 null。
String? panExtensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (ext.isEmpty || ext.length > 10) return null;
  return ext;
}
