# Google ML Kit Text Recognition Proguard Rules
-keep class com.google.mlkit.vision.text.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }

# Specifically keep the options builders mentioned in the build error
-keep class com.google.mlkit.vision.text.chinese.** { *; }
-keep class com.google.mlkit.vision.text.devanagari.** { *; }
-keep class com.google.mlkit.vision.text.japanese.** { *; }
-keep class com.google.mlkit.vision.text.korean.** { *; }

# Suppress warnings for optional ML Kit modules (Chinese, Korean, Japanese, Devanagari) 
# if they are not explicitly included as dependencies.
-dontwarn com.google.mlkit.**
