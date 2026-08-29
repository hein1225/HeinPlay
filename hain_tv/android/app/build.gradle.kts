import java.util.Properties
import java.io.FileInputStream
import tvlegacy.FlutterEmbeddingPatcher

plugins {
    id("com.android.application")
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

val tvlegacyKeystorePropertiesFile = rootProject.file("key-tvlegacy.properties")
val tvlegacyKeystoreProperties = Properties()
if (tvlegacyKeystorePropertiesFile.exists()) {
    tvlegacyKeystoreProperties.load(FileInputStream(tvlegacyKeystorePropertiesFile))
}

android {
    namespace = "com.heinplay.hain_tv"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.heinplay.hain_tv"
        // tvlegacy 需要支持到 Android 5.0（API 21），默认值设 21；
        // tv/mobile flavor 再各自覆盖为 24。
        // 必须写死数字，避免 Flutter 插件把 flutter.minSdkVersion 解析为 24 或 current。
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // tvlegacy 支持低版本真机及常见模拟器；Flutter 3.44.8 release 未提供 x86 engine，
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
        create("tvlegacy") {
            applicationId = "com.heinplay.hain_tv_legacy"
            versionNameSuffix = "-tvlegacy"
            minSdk = flutter.minSdkVersion
        }
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

    // 为各 flavor 单独指定签名配置
    productFlavors.all {
        signingConfig = when (name) {
            "tv" -> signingConfigs.getByName("tv")
            "mobile" -> signingConfigs.getByName("mobile")
            "tvlegacy" -> signingConfigs.getByName("tvlegacy")
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


