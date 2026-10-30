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

# 🔴 HeinPlay mpv（自写壳）：JNI 按**类名与方法名**查找，R8 混淆后必然崩。
#   · JNI_OnLoad 里 FindClass("com/heinplay/hain_tv/MpvPlayerView") —— 类名不能改；
#   · 事件线程 CallVoidMethod(view, onMpvEvent, ...) —— 方法名与签名不能改；
#   · MpvCore 的 external fun 与 libheinplay_mpv_jni.so 的 Java_com_heinplay_*
#     符号一一对应，同样不能改。
-keep class com.heinplay.hain_tv.MpvPlayerView { *; }
-keep class com.heinplay.hain_tv.MpvCore { *; }
-keep class com.heinplay.hain_tv.MpvViewFactory { *; }
-keep class com.heinplay.hain_tv.MpvPlugin { *; }
-keepclassmembers class com.heinplay.hain_tv.MpvPlayerView {
    public void onMpvEvent(java.lang.String, double, boolean);
}
# native 方法由 System.loadLibrary 动态解析，R8 不要因「找不到实现」而报错。
-dontwarn com.heinplay.hain_tv.MpvCore

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
