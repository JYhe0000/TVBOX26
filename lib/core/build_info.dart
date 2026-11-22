// 构建期注入信息：编译日期经 `--dart-define=APP_BUILD_DATE=...` 传入。
//
// 发布 / 真机构建示例：
//   flutter build apk --dart-define=APP_BUILD_DATE="$(date +%F)"
// IDE 日常 run 不带该 define 时，展示层落到「开发构建」兜底文案，
// 不会把空串或未知值误当成真实日期展示。
library;

/// 编译日期（构建时注入；未注入为空串）。
const String kAppBuildDate = String.fromEnvironment('APP_BUILD_DATE');

/// 设置页展示文案：未注入时明确标注为开发构建。
String get appBuildDateDisplay =>
    kAppBuildDate.isEmpty ? '—（开发构建）' : kAppBuildDate;
