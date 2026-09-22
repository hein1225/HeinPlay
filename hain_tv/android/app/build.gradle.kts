import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // Kotlin Gradle Plugin 必须显式声明，否则下文的 kotlin { compilerOptions { jvmTarget } }
    // 顶层扩展块无法解析（报 Unresolved reference 'kotlin' / 'compilerOptions' / 'jvmTarget'）。
    // 版本由根 settings.gradle.kts 以 apply false 形式统一管理（当前 2.2.20）。
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val mobileKeystorePropertiesFile = rootProject.file("key-mobile.properties")
val mobileKeystoreProperties = Properties()
if (mobileKeystorePropertiesFile.exists()) {
    mobileKeystoreProperties.load(FileInputStream(mobileKeystorePropertiesFile))
}

android {
    namespace = "com.heinplay.hain_tv"
    compileSdk = 36
    // 显式钉 build-tools 版本。本机 Windows SDK 的 build-tools/35.0.0 已被 WSL 侧误装成
    // Linux 二进制而损坏；这里改用已安装且完好的 36.1.0，避免构建报
    // "Installed Build Tools revision 35.0.0 is corrupted"。
    buildToolsVersion = "36.1.0"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.heinplay.hain_tv"
        // tv / mobile 两个 flavor 的 minSdk 均为 24（见下方 productFlavors 的显式覆盖）。
        // 必须写死数字，避免 Flutter 插件把 flutter.minSdkVersion 解析为 current。
        // 注：Android 5.0+（API 21）的 tvlegacy 已迁出为独立工程 hain_tv_legacy/。
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // 低版本真机及常见模拟器都要能装；Flutter 的 release 引擎未提供 x86 产物，
            // 因此不包含 x86，避免在 x86 设备上触发 libflutter.so 缺失闪退。
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
    }

    flavorDimensions += "platform"

    productFlavors {
        create("tv") {
            applicationId = "com.heinplay.hain_tv"
            versionNameSuffix = "-tv"
            minSdk = 24
        }
        // tvlegacy flavor 已移除 —— Android 5.0+（API 21）版本由独立工程
        // hain_tv_legacy/ 构建（其 applicationId 保持 com.heinplay.hain_tv_legacy，
        // 签名与已发布版一致，确保老用户可覆盖升级）。
        create("mobile") {
            applicationId = "com.heinplay.mobile"
            versionNameSuffix = "-mobile"
            minSdk = 24
        }
    }

    signingConfigs {
        create("tv") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
        create("mobile") {
            keyAlias = mobileKeystoreProperties["keyAlias"] as String?
            keyPassword = mobileKeystoreProperties["keyPassword"] as String?
            storeFile = mobileKeystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = mobileKeystoreProperties["storePassword"] as String?
        }
        // tvlegacy 签名配置已随 flavor 移除；独立工程 hain_tv_legacy/ 使用
        // android/app/heinplay-tvlegacy.jks（与已发布版同一密钥，保证可升级）。
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // 为各 flavor 单独指定签名配置
    productFlavors.all {
        signingConfig = when (name) {
            "tv" -> signingConfigs.getByName("tv")
            "mobile" -> signingConfigs.getByName("mobile")
            else -> signingConfigs.getByName("tv")
        }
    }

    // 多个依赖可能同时携带 libc++_shared.so，打包时只保留一份避免冲突。
    packaging {
        jniLibs {
            pickFirsts += listOf(
                "lib/armeabi-v7a/libc++_shared.so",
                "lib/arm64-v8a/libc++_shared.so",
                "lib/x86/libc++_shared.so",
                "lib/x86_64/libc++_shared.so",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

