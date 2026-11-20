# 防止 Native JNI 方法名在 Release 构建中被混淆
-keepclasseswithmembernames class * {
    native <methods>;
}

# 明确保留 MainActivity 的 JNI 方法
-keep class com.mksha.pan_client.MainActivity {
    private external void verifySignatureOrExit(java.lang.Object);
}