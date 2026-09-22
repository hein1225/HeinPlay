package com.heinplay.hain_tv

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "hain_tv/exo_buffer_config"
        private const val APP_CHANNEL = "hain_tv/app"
        private const val SPLASH_CHANNEL = "hain_tv/splash"

        /// 最近一次通过 MethodChannel 下发的 ExoPlayer 缓冲配置。
        /// 当前 video_player_android 插件在内部自行创建 ExoPlayer 实例，
        /// 若要真正生效，需要后续通过 fork video_player_android 或自定义插件
        /// 在创建 ExoPlayer.Builder 时读取此处配置并调用 setLoadControl。
        @JvmStatic
        var bufferConfig: Map<String, Any>? = null
            private set
    }

    // 原生启动封面覆盖层。Activity 创建后立刻叠加在 FlutterView 之上，显示真正的满屏封面；
    // Flutter 首帧解码完成封面后通过 SPLASH_CHANNEL 通知移除，实现“点开即满屏封面、无黑屏
    // 空窗期”。主题切换触发 Activity 重建时会一并重建该覆盖层。
    private var splashCoverView: View? = null
    private var coverReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        attachSplashCover()
        // 兜底：最多 4 秒后强制移除，避免极端情况下封面一直停留。
        Handler(Looper.getMainLooper()).postDelayed({ detachSplashCover() }, 4000)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBufferConfig" -> {
                        bufferConfig = call.arguments<Map<String, Any>?>()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Flutter 封面解码完成，通知原生启动封面可以移除。
        MethodChannel(messenger, SPLASH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "coverReady" -> {
                        coverReady = true
                        detachSplashCover()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // 主题切换：重建 Activity，原生启动封面再次显示，Flutter 以新主题重启。
        MethodChannel(messenger, APP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "restart" -> {
                        recreate()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 在 FlutterView 之上附加一个全屏 ImageView 显示启动封面。
    /// 使用 @drawable/splash，系统会根据当前方向自动选择 drawable 或 drawable-land 资源，
    /// 并用 CENTER_CROP 裁剪铺满屏幕，从而绕过 core-splashscreen 仅支持居中图标、无法满屏
    /// 的平台限制。
    private fun attachSplashCover() {
        if (splashCoverView != null) return
        val content = findViewById<ViewGroup>(android.R.id.content) ?: return
        val cover = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setImageResource(R.drawable.splash)
            isClickable = false
            isFocusable = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        content.addView(
            cover,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        splashCoverView = cover
    }

    private fun detachSplashCover() {
        splashCoverView?.let { cover ->
            val content = findViewById<ViewGroup>(android.R.id.content)
            content?.removeView(cover)
            splashCoverView = null
        }
    }
}
