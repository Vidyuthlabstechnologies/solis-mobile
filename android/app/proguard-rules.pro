# Aggressive Code Obfuscation & Hardening for SOLIS Clinical OS

# 1. Repackage all classes into a single obscure root package to destroy original package architecture
-repackageclasses 'o'

# 2. Obfuscate class names, field names, and method names with short characters
-overloadaggressively
-allowaccessmodification

# 3. Strip all debugging and log output
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
}

# 4. Strip source file names and line number tables from stacktraces
-renamesourcefileattribute 'SourceFile'
-keepattributes !SourceFile,!LineNumberTable

# 5. Suppress warnings for optional Play Store deferred components not bundled
-dontwarn com.google.android.play.core.**

# 6. Flutter Engine and Plugin preservation
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# 7. Preserve MainActivity entrypoint
-keep public class com.solis.clinical.solis_mobile.MainActivity {
    public *;
}

# 8. Google ML Kit (on-device card scanning). Only the Latin text model is
# bundled; the plugin references the optional script recognizers by name.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
# ML Kit loads its model components by reflection; keep them unobfuscated.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_barcode_scanning.** { *; }

# 9. On-device speech engine (k2-fsa sherpa-onnx). The JNI library looks up
# these Kotlin classes, their fields and their native methods by name, so
# none of them may be renamed or removed.
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
# commons-compress: only the bzip2 decoder is used; its optional codecs
# (xz, zstd, brotli, lzma, osgi) are not on the classpath.
-dontwarn org.apache.commons.compress.**
-dontwarn org.tukaani.xz.**
-dontwarn com.github.luben.zstd.**
-dontwarn org.brotli.dec.**
-dontwarn org.objectweb.asm.**
-dontwarn org.osgi.**
# The diarization JNI calls back into this object by method name and
# signature (invoke(IIJ)Ljava/lang/Integer;), so keep it unrenamed.
-keepclassmembers class com.solis.clinical.solis_mobile.speech.DiarizationProgress {
    public java.lang.Integer invoke(int, int, long);
    public java.lang.Object invoke(java.lang.Object, java.lang.Object, java.lang.Object);
}
-keep class com.solis.clinical.solis_mobile.speech.DiarizationProgress
