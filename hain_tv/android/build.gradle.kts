allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 注：tvlegacy 专属的「强制低版本 Media3」逻辑已移除 ——
// 该逻辑是为 Android 5.x（API 21/22）规避 AudioDeviceCallback（API 23+）类缺失而设，
// 现已随 tvlegacy 迁出到独立工程 hain_tv_legacy/（其 android/build.gradle.kts 内保留对应实现）。
// 主工程 tv / mobile 均为 API 24+，使用默认 Media3 版本即可。

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// 统一钉所有 Android 子模块的 build-tools 版本为 36.1.0。
// 根因：本机 Windows SDK 的 build-tools/35.0.0 被 WSL 侧误装成 Linux 二进制而损坏，
// 而 AGP 8.11.1 默认 build-tools 为 35.0.0，导致 flutter_js 等未显式声明的子模块报
// "Installed Build Tools revision 35.0.0 is corrupted"。这里统一覆盖，彻底绕开损坏的 35.0.0。
// 用 plugins.withId 懒回调（插件 apply 时即设置），避免 afterEvaluate 的时序问题；
// setBuildToolsVersion 用反射设置，避免根脚本未引入 AGP 类型导致编译失败。
subprojects {
    val subProj = this
    listOf("com.android.application", "com.android.library").forEach { pluginId ->
        plugins.withId(pluginId) {
            val androidExt = subProj.extensions.findByName("android") ?: return@withId
            try {
                androidExt.javaClass
                    .getMethod("setBuildToolsVersion", String::class.java)
                    .invoke(androidExt, "36.1.0")
            } catch (_: Throwable) {
                // 非 Android 模块或属性不可写，忽略
            }
        }
    }
}
