# TVBOX26 Flutter

将 `主软件参考Box`（TVBox Android 版）的核心流程重制为 Flutter 版本，**只面向 Android TV / Google TV / 电视盒子横屏使用**，以遥控器方向键和确认键为主，不提供手机竖屏布局。应用沿用 TVBox 的配置生态，读取 `sites`、`lives`、`parses` 等配置。

> 本项目只提供客户端与接口解析能力，不内置、不托管任何影视资源。内置演示配置仅引用公开第三方接口，内容版权归原站点所有。



## 已集成功能

| 模块 | 当前能力 |
| --- | --- |
| 浏览与片库 | 站点切换、最新上线轮播、推荐行、豆瓣推荐、分类与条件筛选、自动分页、海报网格／横版行；详情、多线路选集、相关推荐、收藏、播放历史、继续观看。 |
| 搜索 | 遥控器 T9 九宫格、热词与联想、搜索历史、手机扫码输入；单站或多站聚合、搜索源勾选、按来源筛选、列表／海报视图切换。 |
| 点播播放器 | 默认 `video_player`（Android ExoPlayer），可启用 `media_kit` 增强内核；倍速、画面比例、快进快退、进度记忆、自动下一集、选集与换线路／解析、片头片尾标记。增强内核提供内嵌／外挂字幕与多音轨；另支持弹幕导入与配置后的自动匹配、画中画、后台音频和外部播放器入口。 |
| 电视直播 | M3U、TXT 和兼容 JSON，分组、同组同名多源合并、九宫格搜台、数字键选台、跨组换台、频道密码、上次频道记忆、可选 `media_kit` 内核。EPG 支持 JSON／XMLTV，回看取决于直播源是否提供兼容的回看地址。 |
| 配置与网络 | TVBox 配置导入、`urls.json` 配置目录、多配置点播聚合、配置缓存与离线回退、接口历史、站点启用／排序／测速；支持 HTTP 代理、DoH，覆盖范围因播放内核和网络请求类型而异。 |
| 网盘与局域网 | WebDAV／OpenList 浏览播放；阿里／夸克／百度原生网盘已接入目录浏览、播放及扫码登录，失败可手动输入凭据。手机可扫码把视频地址发给本机；点播还可以投送到局域网 DLNA 渲染器，**本机不是 DLNA 接收器**。 |
| 设置与数据 | 自定义壁纸（手机扫码上传）、背景模糊开关、主题色；同一局域网内用手机扫码导出／恢复支持的设置项、收藏和播放历史，提供电视应用启动与系统管理入口。 |
| 电视界面 | 左侧导航、遥控器焦点与返回恢复；三套皮肤为「默认」（Netflix 风格，新安装默认）、「Smartisan OS」和「Smartisan OS 暗色」。主题色默认跟随皮肤，可独立更换。固定 1280×720 画布：720p／1080p／4K 的 16:9 屏幕等比缩放，16:10／21:9 按当前皮肤底色留边，不拉伸、不裁切。 |



## 快速开始

```bash
cd TVBOX26
flutter pub get
flutter run -d <android-tv-device>
```

需要出包时可构建 APK（公开发布前须换正式签名）：

```bash
flutter build apk --release
```

将 APK 通过 U 盘、adb 或电视助手安装到 Android TV 即可。Manifest 已声明：

- `android.software.leanback`
- `android.hardware.touchscreen`（非必需）
- `LEANBACK_LAUNCHER` 启动入口
- 电视 Banner 与自适应图标

## 默认配置

首次启动使用 `assets/default_config.json`，包含：

- 3 个公开 MacCMS JSON 接口（百度资源 / 量子资源 / 电影天堂）
- 1 个国内 IPTV M3U 直播源

在「设置 → 配置接口」中粘贴自己的 TVBox 配置地址即可替换。配置会缓存到本地，网络失败时自动使用上次缓存。

## 配置支持范围

支持标准 TVBox JSON（包括 Base64 配置、`;pk;` 后缀清洗与相对路径补全）。点播站点按 `type` 的兼容范围如下：

| type | 说明 | 状态 |
| --- | --- | --- |
| `0` | XML 接口（MacCMS） | ✅ |
| `1` | JSON 接口（MacCMS / 常见影视 API） | ✅ |
| `2` | Web / 特殊接口 | ⚠️ 仅按 JSON 尝试 |
| `3` | Spider（JAR / JS） | Android 上已接入兼容的 HTTPS JAR 与部分 HTTPS JS 站点；不保证所有插件可用 |
| `4` | JSON 扩展接口 | 按专用接口处理首页、筛选、搜索、详情和播放换址 |

播放解析：

- `m3u8` / `mp4` / `flv` / `mkv` / `ts` 等地址可走直连；最终能否播放取决于设备、内核和编码格式。
- 普通网页播放地址会尝试调用配置中的 `parses`（JSON 解析接口）。
- Android 点播支持区分直连、WebView 嗅探和配置解析。JAR `type:2/3` 解析器使用其原配置的根 JAR；`proxy://` 播放代理仅监听本机，按站点绑定。
- 点播配置支持通过远端 Box 文件服务读取 `clan://主机[:端口]/路径`，并基于返回的配置地址解析相对资源。不提供本机 `/file/` 服务，也不发布聚合订阅。

直播：

- 支持 M3U、`频道,#genre#` 格式 TXT 及兼容 JSON。
- 支持 `group-title` 分组，自动把常见英文分组名翻译为中文。
- 支持同组同名频道的多 URL 合并。
- EPG 可跟随直播源或在设置中覆盖；兼容地址可看当前、下一档节目，源额外提供兼容的回看模板才能回看。

## 项目结构

```text
lib/
├── main.dart                 # 入口、启动 Bootstrap、Provider
├── core/
│   ├── app_controller.dart   # 配置、站点、直播源、设置状态
│   ├── library_store.dart    # 收藏 / 历史 / 搜索历史
│   └── player_backend.dart   # ExoPlayer / media_kit 播放后端
├── data/
│   ├── models.dart           # AppConfig / SiteConfig / VodItem / LiveChannel ...
│   ├── config_service.dart   # TVBox 配置拉取与解析
│   ├── site_api.dart         # JSON / XML 站点协议、搜索、详情
│   ├── live_parser.dart      # M3U / TXT 直播解析
│   ├── play_resolver.dart    # 直接播放地址识别与 parses 解析
│   └── storage.dart          # SharedPreferences 封装
├── theme/                    # 三套皮肤、主题色、排版和动效
└── ui/
    ├── splash_page.dart      # 启动页 / 配置错误恢复
    ├── shell_page.dart       # 可展开左侧导航栏
    ├── tv_canvas.dart        # 固定 1280×720 画布与等比缩放
    ├── pages/                # 首页、详情、播放、搜索、直播、设置...
    └── widgets/              # 皮肤化面板、焦点组件、海报、轮播
```

## 遥控器操作

- 方向键：移动焦点 / 滚动列表。
- OK / 确认：打开影片、播放、暂停。
- 返回键：先关弹层或退出侧栏焦点；子页返回上一页，主导航其他页返回首页，首页内容区返回退出。
- 播放页：通过方向键切换控制项，可快退／快进（默认 10 秒）、切上一集／下一集、打开选集侧栏和换线路。

## 开发命令

```bash
flutter analyze --no-pub
flutter test --no-pub test/home_hero_title_test.dart test/home_direction_test.dart test/home_hero_background_test.dart
flutter test --no-pub test/tv_canvas_test.dart test/theme_accent_test.dart
```



## 致谢

- 配置协议与交互参考：[TVBox](https://github.com/o0HalfLife0o/TVBoxOSC) 开源项目。
- 视觉与交互参考：Apple tvOS HIG、Smartisan OS、[izuko-tv 布局参考](../docs/izuko-layout-spec.md)。
