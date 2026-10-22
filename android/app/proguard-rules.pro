# ProGuard / R8 rules for Vanity Tracker release build
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-dontwarn com.google.android.play.core.**

# Flutter and Firebase keep rules
-keep class io.flutter.** { *; }
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
