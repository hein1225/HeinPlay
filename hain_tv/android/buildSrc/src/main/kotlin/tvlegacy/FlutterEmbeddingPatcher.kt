package tvlegacy

import org.gradle.api.GradleException
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * tvlegacy 专属辅助：将原始 flutter_embedding_release jar 中的 LocalizationPlugin.class
 * 替换为兼容 Android 5.0+（API 21）的版本，并发布到本地 Maven 仓库。
 *
 * <p>原版 LocalizationPlugin 在 API < 26 分支直接调用 Configuration.getLocales() /
 * LocaleList，而这些 API 24 才存在，导致 Android 5.1（API 22）启动闪退。补丁版本显式区分
 * API 26+ / API 24-25 / API 23 及以下，低版本回退到 Configuration.locale。
 */
object FlutterEmbeddingPatcher {
    /**
     * 执行补丁并发布到本地 Maven 仓库。
     *
     * @param originalJar 原始 flutter_embedding_release jar
     * @param patchSourceFile LocalizationPlugin.java 补丁源文件
     * @param androidJar android.jar 路径，用于编译补丁源文件
     * @param outputJar 输出的修补后 jar 路径
     * @param repoDir 本地 Maven 仓库根目录
     * @param originalVersion 原始 flutter_embedding_release 版本号
     * @param patchedVersion 修补后的版本号
     */
    fun patch(
        originalJar: File,
        originalPom: File,
        patchSourceFile: File,
        androidJar: File,
        outputJar: File,
        repoDir: File,
        originalVersion: String,
        patchedVersion: String
    ) {
        if (isUpToDate(originalJar, patchSourceFile, outputJar, repoDir, patchedVersion)) {
            println("[tvlegacy] 修补版 flutter_embedding_release 已是最新，跳过生成。")
            return
        }

        val workDir = File.createTempFile("tvlegacy-patch-work", "").apply {
            delete()
            mkdirs()
        }
        try {
            val classesDir = workDir.resolve("classes").apply { mkdirs() }
            val extractDir = workDir.resolve("extract").apply { mkdirs() }

            // 编译补丁源文件，classpath 使用原始 flutter_embedding jar + android.jar
            val javacProcess = ProcessBuilder(
                "javac",
                "-cp", "${originalJar.absolutePath};${androidJar.absolutePath}",
                "-d", classesDir.absolutePath,
                patchSourceFile.absolutePath
            ).apply {
                inheritIO()
                directory(patchSourceFile.parentFile)
            }.start()
            val exitCode = javacProcess.waitFor()
            if (exitCode != 0) {
                throw GradleException("tvlegacy LocalizationPlugin 补丁编译失败，exitCode=$exitCode")
            }

            // 解压原始 jar
            ZipFile(originalJar).use { zip ->
                zip.entries().asSequence().forEach { entry ->
                    val outFile = extractDir.resolve(entry.name)
                    if (entry.isDirectory) {
                        outFile.mkdirs()
                    } else {
                        outFile.parentFile.mkdirs()
                        zip.getInputStream(entry).use { input ->
                            outFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                    }
                }
            }

            // 替换 LocalizationPlugin.class 及其内部类
            classesDir.walkTopDown().filter { it.isFile && it.extension == "class" }.forEach { classFile ->
                val relative = classesDir.toPath().relativize(classFile.toPath()).toString().replace("\\", "/")
                val target = extractDir.resolve(relative)
                target.parentFile.mkdirs()
                classFile.copyTo(target, overwrite = true)
            }

            // 重新打包为 jar
            outputJar.parentFile.mkdirs()
            ZipOutputStream(outputJar.outputStream().buffered()).use { zos ->
                extractDir.walkTopDown().filter { it.isFile }.forEach { file ->
                    val entryName = extractDir.toPath().relativize(file.toPath()).toString().replace("\\", "/")
                    zos.putNextEntry(ZipEntry(entryName))
                    file.inputStream().use { it.copyTo(zos) }
                    zos.closeEntry()
                }
            }

            // 发布到本地 Maven 仓库：jar + POM（继承原始依赖）
            val artifactDir = repoDir.resolve("io/flutter/flutter_embedding_release/$patchedVersion").apply { mkdirs() }
            val baseName = "flutter_embedding_release-$patchedVersion"
            outputJar.copyTo(artifactDir.resolve("$baseName.jar"), overwrite = true)

            val patchedPom = artifactDir.resolve("$baseName.pom")
            val resolvedPomContent = if (originalPom.exists()) originalPom.readText() else ""
            // Gradle 解析的 POM 可能不包含依赖（例如缓存了简化文件），优先从远程 Flutter Maven 仓库获取完整 POM。
            val pomContent = if (resolvedPomContent.contains("<dependencies>")) {
                println("[tvlegacy] 使用 Gradle 解析的原始 POM: ${originalPom.absolutePath}")
                resolvedPomContent
            } else {
                println("[tvlegacy] Gradle 解析的 POM 不含依赖，尝试从远程下载: $originalVersion")
                fetchOriginalPom(originalVersion)
                    ?: throw GradleException(
                        "无法获取 flutter_embedding_release 原始 POM，版本=$originalVersion。" +
                        "请检查网络或 Gradle 仓库配置。"
                    )
            }
            patchedPom.writeText(
                pomContent.replace("<version>$originalVersion</version>", "<version>$patchedVersion</version>")
            )
            println("[tvlegacy] 已发布修补版 flutter_embedding_release 到本地仓库: ${artifactDir.absolutePath}")
        } finally {
            workDir.deleteRecursively()
        }
    }

    private fun isUpToDate(originalJar: File, patchSourceFile: File, outputJar: File, repoDir: File, patchedVersion: String): Boolean {
        if (!outputJar.exists()) return false
        // 同时检查修补后的 POM 是否存在且包含依赖声明。
        val pomFile = repoDir.resolve(
            "io/flutter/flutter_embedding_release/$patchedVersion/flutter_embedding_release-$patchedVersion.pom"
        )
        if (!pomFile.exists() || !pomFile.readText().contains("<dependencies>")) {
            println("[tvlegacy] 本地修补 POM 缺失或不含依赖，需要重新生成补丁。")
            return false
        }
        val outputTime = outputJar.lastModified()
        return originalJar.lastModified() <= outputTime && patchSourceFile.lastModified() <= outputTime
    }

    /**
     * 从 Flutter Maven 仓库下载原始 flutter_embedding_release 的 POM 内容。
     * 仅在 Gradle 没有直接解析到 POM 时作为兜底。
     */
    private fun fetchOriginalPom(originalVersion: String): String? {
        val remoteUrl =
            "https://storage.googleapis.com/download.flutter.io/io/flutter/flutter_embedding_release/$originalVersion/flutter_embedding_release-$originalVersion.pom"
        return try {
            val url = java.net.URL(remoteUrl)
            val connection = url.openConnection()
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.getInputStream().use { input ->
                input.bufferedReader().use { it.readText() }
            }
        } catch (e: Exception) {
            null
        }
    }
}
