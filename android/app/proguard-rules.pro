# Flutter-specific ProGuard rules

# Keep Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep generic signatures (required by Gson TypeToken) and annotations
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Keep Kotlin metadata
-keep class kotlin.Metadata { *; }

# flutter_foreground_task
-keep class com.pravera.flutter_foreground_task.** { *; }

# flutter_local_notifications uses Gson + TypeToken to persist scheduled
# notifications. R8 full mode strips those generic signatures unless kept.
# See: https://pub.dev/packages/flutter_local_notifications#release-build-configuration
-keep class com.dexterous.flutterlocalnotifications.** { *; }

-dontwarn sun.misc.**
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Suppress warnings for Google Play Core classes (used by Flutter deferred components)
# These are optional dependencies not needed for standard APK builds
-dontwarn com.google.android.play.core.**
