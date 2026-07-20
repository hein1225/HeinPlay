package com.heinplay.hain_tv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "hain_tv/exo_buffer_config"

        /// 最近一次通过 MethodChannel 下发的 ExoPlayer 缓冲配置。
        /// 当前 video_player_android 插件在内部自行创建 ExoPlayer 实例，
        /// 若要真正生效，需要后续通过 fork video_player_android 或自定义插件
        /// 在创建 ExoPlayer.Builder 时读取此处配置并调用 setLoadControl。
        @JvmStatic
        var bufferConfig: Map<String, Any>? = null
            private set
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBufferConfig" -> {
                    bufferConfig = call.arguments<Map<String, Any>?>()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
