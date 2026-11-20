#include <jni.h>
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <cstring>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>

// 💡 已预置你的 keytool SHA-256 指纹
static const char* OFFICIAL_SHA256 = "8492EE8F19FDB72D90E3FC626703E9DEA50ECE092777D135FA22BD1C2726364B";

// 致命退出：拒绝 JVM 捕获，直接向内核发送 kill 信号（SIGKILL = 9）
void force_crash() {
    kill(getpid(), SIGKILL);
    exit(0);
}

// 提取 JNI 签名字节数组并格式化为 Hex 字符串
std::string bytesToHex(JNIEnv* env, jbyteArray byteArray) {
    if (!byteArray) return "";
    
    // 使用 Java 的 MessageDigest 计算 SHA-256
    jclass digestClass = env->FindClass("java/security/MessageDigest");
    if (!digestClass) return "";
    
    jmethodID getInstanceMethod = env->GetStaticMethodID(digestClass, "getInstance", "(Ljava/lang/String;)Ljava/security/MessageDigest;");
    jstring algorithm = env->NewStringUTF("SHA-256");
    jobject digestObj = env->CallStaticObjectMethod(digestClass, getInstanceMethod, algorithm);
    
    jmethodID digestMethod = env->GetMethodID(digestClass, "digest", "([B)[B");
    jbyteArray hashArray = (jbyteArray)env->CallObjectMethod(digestObj, digestMethod, byteArray);
    
    if (!hashArray) return "";

    jsize hashLen = env->GetArrayLength(hashArray);
    jbyte* hashBytes = env->GetByteArrayElements(hashArray, NULL);
    
    std::stringstream ss;
    for (int i = 0; i < hashLen; i++) {
        ss << std::hex << std::uppercase << std::setw(2) << std::setfill('0') << (int)(hashBytes[i] & 0xFF);
    }
    
    env->ReleaseByteArrayElements(hashArray, hashBytes, JNI_ABORT);
    return ss.str();
}

extern "C" JNIEXPORT void JNICALL
// ⚠️ 核心修复：Java 包名 com.mksha.pan_client 中的下划线必须转义为 pan_1client
Java_com_mksha_pan_1client_MainActivity_verifySignatureOrExit(JNIEnv* env, jobject thiz, jobject context) {
    if (context == NULL) {
        force_crash();
    }

    try {
        // 1. 获取 Context & PackageManager
        jclass contextClass = env->GetObjectClass(context);
        jmethodID getPM = env->GetMethodID(contextClass, "getPackageManager", "()Landroid/content/pm/PackageManager;");
        jobject pm = env->CallObjectMethod(context, getPM);

        // 2. 获取 PackageName
        jmethodID getPN = env->GetMethodID(contextClass, "getPackageName", "()Ljava/lang/String;");
        jstring packageName = (jstring)env->CallObjectMethod(context, getPN);

        // 3. 反射获取 PackageInfo (兼容 Android 9+ 的 GET_SIGNING_CERTIFICATES)
        jclass pmClass = env->GetObjectClass(pm);
        jmethodID getPI = env->GetMethodID(pmClass, "getPackageInfo", "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;");
        
        // 0x08000000 即 GET_SIGNING_CERTIFICATES 标志位
        jobject packageInfo = env->CallObjectMethod(pm, getPI, packageName, 0x08000000);
        
        if (env->ExceptionCheck() || !packageInfo) {
            env->ExceptionClear();
            force_crash();
        }

        jclass piClass = env->GetObjectClass(packageInfo);
        jfieldID signingInfoField = env->GetFieldID(piClass, "signingInfo", "Landroid/content/pm/SigningInfo;");
        jobject signingInfo = env->GetObjectField(packageInfo, signingInfoField);

        if (!signingInfo) {
            force_crash();
        }

        jclass signingInfoClass = env->GetObjectClass(signingInfo);
        jmethodID getApkCerts = env->GetMethodID(signingInfoClass, "getApkContentsSigners", "()[Landroid/content/pm/Signature;");
        jobjectArray signatures = (jobjectArray)env->CallObjectMethod(signingInfo, getApkCerts);

        if (signatures == NULL || env->GetArrayLength(signatures) == 0) {
            force_crash(); // 获取不到签名，直接崩溃
        }

        // 4. 提取首个签名的 byte 数组
        jobject firstSignature = env->GetObjectArrayElement(signatures, 0);
        jclass signatureClass = env->GetObjectClass(firstSignature);
        jmethodID toByteArray = env->GetMethodID(signatureClass, "toByteArray", "()[B");
        jbyteArray certBytes = (jbyteArray)env->CallObjectMethod(firstSignature, toByteArray);

        // 5. 计算当前包的 SHA-256 并比对
        std::string currentSha256 = bytesToHex(env, certBytes);

        if (currentSha256 != OFFICIAL_SHA256) {
            // ❌ SHA-256 不匹配！说明重签名过，强行退出！
            force_crash();
        }
    } catch (...) {
        // 异常直接退出
        force_crash();
    }
}