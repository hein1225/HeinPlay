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

// tvlegacy 强制使用低版本 Media3，避免 1.9.2 在 Android 5.x（API 21/22）上因
// AudioDeviceCallback（API 23+）类缺失而闪退。该 property 由 video_player_android
// 插件读取并覆盖默认的 Media3 版本号。
subprojects {
    val isTvlegacyBuild = gradle.startParameter.taskNames.any { it.contains("tvlegacy", ignoreCase = true) }
    if (isTvlegacyBuild && project.name == "video_player_android") {
        project.extra["heinplay.media3.version"] = "1.1.0"
        println("[tvlegacy] 强制 video_player_android 使用 Media3 1.1.0")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
