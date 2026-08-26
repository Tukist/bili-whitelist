import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取签名配置：android/key.properties（由 M3b 生成，含 keystore 密码）。
// 文件不存在（如 CI 或他人 clone）时跳过签名，release 退化为 debug 签名，保证能构建。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) {
        f.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.biliwhitelist.bili_whitelist_app"
    compileSdk = flutter.compileSdkVersion
    // 对齐插件要求（flutter_secure_storage / path_provider / shared_preferences / video_player
    // 均声明需 NDK 27），避免 Gradle 版本冲突警告
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.biliwhitelist.bili_whitelist_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // M2：白名单点播 App 需要 Android 8.0+（Api 26）以获得稳定 MediaCodec/ExoPlayer 行为
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // M3b：release 签名。keystore 存在才配置；否则沿用 debug 签名兜底。
    signingConfigs {
        if (rootProject.file("key.properties").exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // storeFile 相对本文件目录（android/app/），key.properties 里写文件名即可
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // M3b：优先用 release 签名；key.properties 缺失时回退 debug 签名保证可构建
            val releaseSigning = signingConfigs.findByName("release")
            signingConfig = releaseSigning ?: signingConfigs.getByName("debug")

            // M4b：R8 修复。Flutter 插件对 release 默认启用 minify（R8），会误删
            // ffmpeg-kit 的 native 方法声明（如 AbiDetect.getNativeCpuAbi），导致
            // libffmpegkit_abidetect.so 的 JNI RegisterNatives 失败、插件注册中断
            // （其后的 secure_storage/webview/path_provider 全部未注册 → 真机三故障）。
            // proguard-rules.pro 保留 native 方法；此处显式声明，避免依赖插件默认行为。
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // B 站 DASH 双流播放：与 video_player_android 2.8.15 传递的 Media3 版本对齐（1.5.1），
    // 避免 APK 里出现两份 media3（Gradle 按同版本合并成一份）。
    implementation("androidx.media3:media3-exoplayer:1.5.1")
}
