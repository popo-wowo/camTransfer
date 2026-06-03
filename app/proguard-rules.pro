# Keep Android entry points and app manifest-referenced classes reachable.
# The Android Gradle Plugin already contributes manifest/component keep rules;
# this file only adds app-specific safety around diagnostics and reflection.

# Keep source file and line number metadata for release crash reports.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Keep annotation metadata used by AndroidX and Kotlin tooling.
-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations,AnnotationDefault

# Do not obfuscate the diagnostic log model names. The diagnostic exporter is
# user-facing support tooling, and readable tags are more valuable than hiding
# these tiny wrappers.
-keep class com.camtransfer.service.DiagnosticLog { *; }

# Android platform reflection: CameraService calls BluetoothDevice.removeBond()
# by string on the platform class. Obfuscating app code is safe, but suppress
# warnings around hidden platform APIs.
-dontwarn android.bluetooth.BluetoothDevice

# Remove ordinary logcat noise from release builds. DiagnosticLog remains active.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
