# Flutter-specific ProGuard rules

# Keep Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep annotations
-keepattributes *Annotation*

# Keep Kotlin metadata
-keep class kotlin.Metadata { *; }

# flutter_foreground_task
-keep class com.pravera.flutter_foreground_task.** { *; }

# Suppress warnings for Google Play Core classes (used by Flutter deferred components)
# These are optional dependencies not needed for standard APK builds
-dontwarn com.google.android.play.core.**
