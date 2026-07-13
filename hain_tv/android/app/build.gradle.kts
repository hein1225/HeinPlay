import java.util.Properties
import java.io.FileInputStream

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

android {
    namespace = "com.heinplay.hain_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.heinplay.hain_tv"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
    }

    flavorDimensions += "platform"

    productFlavors {
        create("tv") {
            applicationId = "com.heinplay.hain_tv"
            versionNameSuffix = "-tv"
        }
        create("mobile") {
            applicationId = "com.heinplay.mobile"
            versionNameSuffix = "-mobile"
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
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
