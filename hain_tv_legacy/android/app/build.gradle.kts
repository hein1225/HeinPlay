import java.util.Properties
import java.io.FileInputStream
import tvlegacy.FlutterEmbeddingPatcher

plugins {
    id("com.android.application")
    // Kotlin Gradle Plugin 必须显式声明，否则下文的 kotlin { compilerOptions { jvmTarget } }
    // 顶层扩展块无法解析（报 Unresolved reference 'kotlin' / 'compilerOptions' / 'jvmTarget'）。
    // 版本由根 settings.gradle.kts 以 apply false 形式统一管理（当前 2.2.20）。
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 【tvLegacy 独立工程】只保留 tvlegacy 一个 flavor。
// tv / mobile 的签名材料与 flavor 定义已于 2026-09-27 随「非本工程目标」清理移除
// （它们由主工程 hain_tv/ 构建）。
val tvlegacyKeystorePropertiesFile = rootProject.file("key-tvlegacy.properties")
val tvlegacyKeystoreProperties = Properties()
if (tvlegacyKeystorePropertiesFile.exists()) {
    tvlegacyKeystoreProperties.load(FileInputStream(tvlegacyKeystorePropertiesFile))
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
        applicationId = "com.heinplay.hain_tv_legacy"
        // 本工程只构建 tvlegacy：支持到 Android 5.0（API 21）。
        // 必须写死数字，避免 Flutter 插件把 flutter.minSdkVersion 解析为 24 或 current。
        minSdk = 21
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // tvlegacy 支持低版本真机及常见模拟器。
            // 🔴 HeinPlay mpv：播放内核换成本工程自编译的 libmpv.so（API 21，OpenGL
            // 路线），只编了 armeabi-v7a / arm64-v8a 两个 ABI，故此处必须同步收窄 ——
            // 若保留 x86_64，该 ABI 会缺 libmpv.so 而拿不到 mpv 后端。
            // Flutter 3.44.8 release 未提供 x86 engine，本来也不含 x86。
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }

        // 🔴 HeinPlay mpv：用 NDK 编译自写 JNI 壳（libheinplay_mpv_jni.so），
        // 它直接调 jniLibs 内的 libmpv.so / libavcodec.so（av_jni_set_java_vm）。
        externalNativeBuild {
            cmake {
                abiFilters += listOf("armeabi-v7a", "arm64-v8a")
                arguments += listOf("-DANDROID_STL=c++_shared")
                // mpv 头文件优先取本机 mpv-android 源码树；
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
                //    .mpv-build/ 是鸿蒙交叉编译树（mpv master），与本工程 Android 的 0.41.0 不同源，
                //    历史上曾误指这里导致头文件与 libmpv.so 漂移 → 明确禁止。
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
        // 仅保留 tvlegacy —— 本独立工程的唯一构建目标。
        // tv / mobile flavor 已移除（由主工程 hain_tv/ 构建）。
        create("tvlegacy") {
            applicationId = "com.heinplay.hain_tv_legacy"
            versionNameSuffix = "-tvlegacy"
            minSdk = 21
        }
    }

    signingConfigs {
        create("tvlegacy") {
            keyAlias = tvlegacyKeystoreProperties["keyAlias"] as String?
            keyPassword = tvlegacyKeystoreProperties["keyPassword"] as String?
            storeFile = tvlegacyKeystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = tvlegacyKeystoreProperties["storePassword"] as String?
        }
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

    // 签名配置：本工程只有 tvlegacy 一个 flavor。
    productFlavors.all {
        signingConfig = signingConfigs.getByName("tvlegacy")
    }

    // 多个依赖可能同时携带 libc++_shared.so，打包时只保留一份避免冲突。
    // 🔴 HeinPlay mpv：libmpv.so 依赖 libc++_shared.so（C++ 运行时），而本工程
    // 已不再编 x86/x86_64，故 pickFirsts 也相应收窄到两个 ARM ABI。
    packaging {
        jniLibs {
            pickFirsts += listOf(
                "lib/armeabi-v7a/libc++_shared.so",
                "lib/arm64-v8a/libc++_shared.so",
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

// tvlegacy 专属本地 Maven 仓库：存放修补后的 flutter_embedding_release。
// 该仓库只在 tvlegacy 构建时通过 dependencySubstitution 使用，tv/mobile 不受影响。
repositories {
    maven {
        name = "tvlegacyFlutterEmbeddingPatch"
        url = uri(layout.buildDirectory.dir("intermediates/tvlegacy_flutter_patch/repo"))
        content {
            // 该仓库只存放 flutter_embedding_release 的 tvlegacy 修补版本，
            // 避免影响其他依赖的解析。
            includeGroup("io.flutter")
            includeModule("io.flutter", "flutter_embedding_release")
        }
    }
}

// ============================================================================
// tvlegacy 专属补丁：替换 Flutter LocalizationPlugin.class
// ============================================================================
// 原版 Flutter LocalizationPlugin 只有 "API 26+" 和 "API < 26" 两个分支，
// 后一分支直接调用 Configuration.getLocales() / LocaleList，这在 Android 5.1（API 22）
// 上不存在，导致启动即闪退。该补丁显式区分 API 26+ / API 24-25 / API 23 及以下，
// 低版本回退到 Configuration.locale，从而支持 Android 5.0+。
//
// 以下逻辑仅在构建 tvlegacy flavor 时生效，tv/mobile 不受影响。
// ============================================================================

/** 读取当前 Flutter SDK 对应的 engine 版本号（来自 engine.stamp）。 */
val flutterEngineVersion: String by lazy {
    val flutterSdkPath = project.properties["flutter.sdk"] as? String
        ?: rootProject.file("local.properties").inputStream().use {
            Properties().apply { load(it) }.getProperty("flutter.sdk")
        }
        ?: throw GradleException("无法获取 flutter.sdk，无法为 tvlegacy 生成 LocalizationPlugin 补丁")
    File(flutterSdkPath, "bin/cache/engine.stamp").readText().trim()
}

/** tvlegacy 修补后的 flutter_embedding_release 版本号。 */
val patchedFlutterEmbeddingVersion: String by lazy { "1.0.0-$flutterEngineVersion-tvlegacy" }

/** 读取 Android SDK 路径。 */
val androidSdkDir: String by lazy {
    project.properties["sdk.dir"] as? String
        ?: rootProject.file("local.properties").inputStream().use {
            Properties().apply { load(it) }.getProperty("sdk.dir")
        }
        ?: throw GradleException("sdk.dir 未设置")
}

/** tvlegacy 补丁源文件路径。 */
val tvlegacyLocalizationPatchSource = project.layout.projectDirectory.file(
    "src/tvlegacy/patch/java/io/flutter/plugin/localization/LocalizationPlugin.java"
)

/**
 * 用于先解析原始 flutter_embedding_release jar 的独立 configuration。
 * 该 configuration 名称不含 "tvlegacy"，因此不会被上面的 dependencySubstitution 替换，
 * 确保补丁任务能拿到原始 jar。
 */
val originalFlutterEmbeddingRelease by configurations.creating {
    isTransitive = false
    isCanBeConsumed = false
    isCanBeResolved = true
}

/**
 * 用于解析原始 flutter_embedding_release POM 的独立 configuration。
 * POM 中声明了 lifecycle、fragment 等传递依赖，需要复制到 tvlegacy 本地仓库的 POM 中。
 */
val originalFlutterEmbeddingPom by configurations.creating {
    isTransitive = false
    isCanBeConsumed = false
    isCanBeResolved = true
}

dependencies {
    originalFlutterEmbeddingRelease(
        "io.flutter:flutter_embedding_release:1.0.0-$flutterEngineVersion"
    )
    originalFlutterEmbeddingPom(
        "io.flutter:flutter_embedding_release:1.0.0-$flutterEngineVersion@pom"
    )
    // 原生启动封面不再使用 androidx.core:core-splashscreen：该库在 Android 12+ 仅支持
    // 居中图标，无法满屏铺满自定义封面。现改为 MainActivity 在 FlutterView 之上手动附加
    // 全屏 ImageView（@drawable/splash，CENTER_CROP），实现真正的满屏启动封面。
    // implementation("androidx.core:core-splashscreen:1.2.0")
}

/**
 * 仅在构建 tvlegacy flavor 时，在配置阶段预先生成修补后的 flutter_embedding_release jar
 * 并发布到本地 Maven 仓库。dependencySubstitution 会在后续依赖解析时使用该产物。
 *
 * 必须在配置阶段完成，因为 Gradle 会在任务执行前就先解析 tvlegacy 的编译/运行依赖。
 */
val isTvlegacyBuild = gradle.startParameter.taskNames.any { it.contains("tvlegacy", ignoreCase = true) }
if (isTvlegacyBuild) {
    val originalJar = originalFlutterEmbeddingRelease.resolve().single()
    val originalPom = originalFlutterEmbeddingPom.resolve().single()
    val version = patchedFlutterEmbeddingVersion
    // outputJar 与本地 Maven 仓库目录分开，patch() 内部会复制到仓库。
    val outputJar = project.layout.buildDirectory.file(
        "intermediates/tvlegacy_flutter_patch/patched/flutter_embedding_release-$version.jar"
    ).get().asFile
    val repoDir = project.layout.buildDirectory.dir("intermediates/tvlegacy_flutter_patch/repo").get().asFile

    FlutterEmbeddingPatcher.patch(
        originalJar = originalJar,
        originalPom = originalPom,
        patchSourceFile = tvlegacyLocalizationPatchSource.asFile,
        androidJar = project.file("$androidSdkDir/platforms/android-36/android.jar"),
        outputJar = outputJar,
        repoDir = repoDir,
        originalVersion = "1.0.0-$flutterEngineVersion",
        patchedVersion = version
    )
}

// 以下 tvlegacy 专属依赖策略，仅在名称包含 "tvlegacy" 的可解析 configuration 上生效，
// 避免影响 tv/mobile 版本。
configurations.all {
    if (name.contains("tvlegacy", ignoreCase = true)
        && isCanBeResolved
        && !name.contains("WearApp", ignoreCase = true)
        && (name.contains("CompileClasspath", ignoreCase = true) || name.contains("RuntimeClasspath", ignoreCase = true))
    ) {
        resolutionStrategy {
            // tvlegacy 需要支持 Android 5.0（API 21）。Flutter 3.44.8 引擎编译时依赖
            // androidx.core:core:1.13.1，若强制使用更低版本（如 1.12.0），高版本安卓上
            // Flutter TextInputPlugin 调用 setStylusHandwritingEnabled 等方法会出现
            // NoSuchMethodError 闪退；若放任解析到 1.17.0+ 又会调用 API 24 方法导致低版本
            // 闪退。因此强制使用与引擎匹配的 1.13.1。
            force("androidx.core:core:1.13.1")
            force("androidx.core:core-ktx:1.13.1")

            // 将原版 flutter_embedding_release 替换为 tvlegacy 本地仓库中的修补版本，
            // 保留原始 POM 中的传递依赖（lifecycle、fragment 等）。
            dependencySubstitution {
                substitute(module("io.flutter:flutter_embedding_release:1.0.0-$flutterEngineVersion"))
                    .using(module("io.flutter:flutter_embedding_release:$patchedFlutterEmbeddingVersion"))
            }
        }
    }
}


