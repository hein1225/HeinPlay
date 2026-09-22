# Flutter ProGuard Rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.google.firebase.** { *; }
-dontwarn io.flutter.embedding.**

# AndroidX Core：tvlegacy 强制使用 1.13.1（与 Flutter 引擎匹配），R8 full mode
# 可能过度收缩 EditorInfoCompat 的 setStylusHandwritingEnabled 等方法，导致高版本
# 安卓（Flutter TextInputPlugin 调用时）出现 NoSuchMethodError 闪退。
-keep class androidx.core.view.inputmethod.EditorInfoCompat { *; }
-keepclassmembers class androidx.core.view.inputmethod.EditorInfoCompat { *; }

# video_player / ExoPlayer / AndroidX Media3
-keep class io.flutter.plugins.videoplayer.** { *; }
-keep class com.google.android.exoplayer2.** { *; }
-keep class com.google.android.exoplayer2.ext.** { *; }
-keep class com.google.android.exoplayer2.source.** { *; }
-keep class com.google.android.exoplayer2.upstream.** { *; }
-keep class com.google.android.exoplayer2.util.** { *; }
-keep class com.google.android.exoplayer2.extractor.** { *; }
-keep class com.google.android.exoplayer2.decoder.** { *; }
-keep class com.google.android.exoplayer2.mediacodec.** { *; }
-dontwarn com.google.android.exoplayer2.**
-keep class androidx.media3.** { *; }
-keep class androidx.media3.exoplayer.** { *; }
-keep class androidx.media3.common.** { *; }
-keep class androidx.media3.datasource.** { *; }
-keep class androidx.media3.extractor.** { *; }
-keep class androidx.media3.decoder.** { *; }
-dontwarn androidx.media3.**

# flutter_vlc_player
-keep class org.videolan.libvlc.** { *; }
-keep class software.solid.fluttervlcplayer.** { *; }
-dontwarn org.videolan.libvlc.**

# SharedPreferences / JSON
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# General
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes EnclosingMethod
