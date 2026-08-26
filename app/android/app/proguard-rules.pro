# ============================================================
# ProGuard / R8 keep 规则（release 构建生效）
#
# 背景：Flutter Gradle 插件对 release 默认开启 R8 收缩（minifyEnabled=true）。
# R8 会删除未被引用到的 Java 成员，包括 ffmpeg-kit 的 native 方法声明
# （如 AbiDetect.getNativeCpuAbi()）——它们是 .so 库 JNI_OnLoad 里
# RegisterNatives 的注册目标，被删后加载 .so 时注册失败，插件注册流程
# 抛异常中断，其后所有插件（secure_storage/webview/path_provider）都不注册，
# 导致 release 版真机：配置保存失败 / 同步失败 / 登录页白屏。
# ============================================================

# ffmpeg-kit 原生库注册所需，防止 R8 误删导致插件注册中断
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keepclassmembers class com.antonkarpenko.ffmpegkit.** { native <methods>; }

# 加固：保留所有类中声明的 native 方法名（ProGuard 官方推荐写法）。
# App 体量小，收益明确；本 App 还有第二个 native 插件 sherpa_onnx，
# 一并防护，避免同类问题再犯。
-keepclasseswithmembernames class * { native <methods>; }
