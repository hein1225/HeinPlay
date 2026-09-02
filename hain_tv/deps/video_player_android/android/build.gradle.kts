group = "io.flutter.plugins.videoplayer"
version = "1.0-SNAPSHOT"

plugins {
    id("com.android.library")
    // 复用根 settings.gradle.kts 以 apply false 管理的 2.2.20。必须显式在 plugins {} 中声明，
    // 才能使 Kotlin DSL 生成 kotlin {} 类型安全访问器，并正确建立 src/main/kotlin 源集与
    // compileReleaseKotlin 任务（否则 Java 编译找不到 Messages.kt 中的 Pigeon 类）。
    id("org.jetbrains.kotlin.android")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "io.flutter.plugins.videoplayer"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    lint {
        checkAllWarnings = true
        warningsAsErrors = true
        disable.addAll(setOf("AndroidGradlePluginVersion", "InvalidPackage", "GradleDependency", "NewerVersionAvailable"))
        baseline = file("lint-baseline.xml")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    dependencies {
        // tvlegacy 通过 project property 强制使用较低版本 Media3，避免 1.9.2 在 API 21/22
        // 上引用 AudioDeviceCallback（API 23+）导致 NoClassDefFoundError 闪退。
        val exoplayerVersion = project.findProperty("heinplay.media3.version") as? String ?: "1.9.2"
        implementation("androidx.media3:media3-exoplayer:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-hls:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-dash:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-rtsp:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-smoothstreaming:${exoplayerVersion}")
        implementation("androidx.media3:media3-datasource-okhttp:${exoplayerVersion}")
        implementation("com.squareup.okhttp3:okhttp:4.12.0")
        testImplementation("junit:junit:4.13.2")
        testImplementation("androidx.test:core:1.7.0")
        testImplementation("org.mockito:mockito-core:5.23.0")
        testImplementation("org.robolectric:robolectric:4.16")
        testImplementation("androidx.media3:media3-test-utils:${exoplayerVersion}")
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
            all {
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
                // The org.gradle.jvmargs property that may be set in gradle.properties does not impact
                // the Java heap size when running the Android unit tests. The following property here
                // sets the heap size to a size large enough to run the robolectric tests across
                // multiple SDK levels.
                it.jvmArgs("-Xmx4G")
            }
        }
    }
}
