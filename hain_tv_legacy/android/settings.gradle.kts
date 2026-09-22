pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 以下是 Flutter 3.32.8 官方模板配套版本（见 flutter_tools/lib/src/android/gradle_utils.dart：
    // templateAndroidGradlePluginVersion=8.7.3 / templateKotlinGradlePluginVersion=2.1.0 /
    // templateDefaultGradleVersion=8.12）。旧引擎的 flutter-gradle-plugin 源码使用了 Gradle 9
    // 已移除的 API（如 Copy.fileMode），因此必须配套 Gradle 8.x，不能跟主工程的 Gradle 9.5.1。
    id("com.android.application") version "8.7.3" apply false
    // 本地插件模块通过 plugins {} 声明 com.android.library，需在此以 apply false 统一管理版本，
    // 避免同一构建中 AGP 多版本冲突。
    id("com.android.library") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
