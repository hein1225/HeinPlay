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
            // 🔴 HeinPlay mpv：libmpv 内核已就位 arm64-v8a 与 armeabi-v7a 两套
            // （来源 .mpv-android/src/mpv-android/buildscripts/prefix/，NDK r27 编译）。
            // 两 ABI 都要：v8a 覆盖主流 64 位设备，v7a 覆盖老旧 32 位电视盒子。
            // 不收 x86/x86_64：Flutter release 引擎无对应产物，mpv 也未编该架构。
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }

        // 🔴 HeinPlay mpv：用 NDK 编译自写 JNI 壳（libheinplay_mpv_jni.so），
        // 它直接调官方 mpv 内核（jniLibs 内的 libmpv.so）。
        externalNativeBuild {
            cmake {
                // 🔴 HeinPlay mpv：libmpv 内核两 ABI 均已就位，原生壳同样编两个。
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
                arguments += listOf("-DANDROID_STL=c++_shared")
                // mpv 头文件必须与 libmpv.so 二进制同源。
                // 🔴 曾指向 .mpv-build/src/mpv（鸿蒙源码树），二者不同源、版本可能漂移。
                // 现在优先用本机 mpv-android 源码树（与 prefix/ 下的 .so 同一次构建产出）；
                // CI / 干净环境没有该树，改用 HeinPlayMPV 发布的头文件
                // （third_party/include/mpv/client.h，由 CI 从 Release 资产解出）。
                val mpvIncludeSrc = rootProject.file("../../.mpv-android/src/mpv")
                val mpvInclude = if (mpvIncludeSrc.resolve("include/mpv/client.h").exists()) {
                    mpvIncludeSrc
                } else {
                    rootProject.file("../third_party")
                }
                // 🔴 防漂移断言（2026-10-30 加固）：
                //    mpv 内核的**唯一权威来源是独立仓 HeinPlayMPV**（固定 tag mpv-v1.4.1），
                //    契约见 docs/mpv-dependency-contract.md 与 HeinPlayMPV/docs/heinplay-integration.md。
                //    本机 .mpv-android/ 只是该仓资产的本地构建树；.mpv-build/ 是**鸿蒙交叉编译树**
                //    （mpv master），与 Android 的 0.41.0 不同源 —— 历史上曾误指这里导致头/二进制漂移。
                require(!mpvInclude.absolutePath.replace('\\', '/').contains("/.mpv-build/")) {
                    "mpv 头文件来源非法（指向 .mpv-build 鸿蒙源码树，与 Android 0.41.0 不同源）: ${mpvInclude.absolutePath}\n" +
                        "请改用 HeinPlayMPV（tag mpv-v1.4.1）的资产；契约见 docs/mpv-dependency-contract.md"
                }
                require(mpvInclude.resolve("include/mpv/client.h").exists()) {
                    "找不到 mpv 头文件: ${mpvInclude.absolutePath}/include/mpv/client.h\n" +
                        "本地请先构建 .mpv-android（mpv 0.41.0），或从 HeinPlayMPV Release 资产解包到 third_party/；" +
                        "契约见 docs/mpv-dependency-contract.md"
                }
                println("[HeinPlay mpv] 头文件来源 = ${mpvInclude.absolutePath}（契约: docs/mpv-dependency-contract.md）")
                arguments += listOf("-DMPV_INCLUDE_DIR=${mpvInclude.absolutePath}")
                cppFlags += listOf("-std=c++17")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
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
    // 另：fvp / vlc(mdk) 等第三方插件自带 x86_64 预编译产物，不受 defaultConfig
    // 的 abiFilters 约束，会白白塞进包里约 19MB。本项目只发 arm 真机包，
    // 故显式排除 x86/x86_64 —— 排除后这些 ABI 上 mpv 也不存在，
    // 避免出现"能装上但 mpv 后端加载失败"的迷惑现象。
    packaging {
        jniLibs {
            pickFirsts += listOf(
                "lib/arm64-v8a/libc++_shared.so",
                "lib/armeabi-v7a/libc++_shared.so",
            )
            excludes += listOf(
                "lib/x86_64/**",
                "lib/x86/**",
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

