package com.mksha.pan_client

import android.content.Intent
import android.media.MediaScannerConnection // 💥 1. 引入媒体扫描包
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

    companion object {
        init {
            // 💡 1. 在类加载时第一时间加载 C++ 原生动态链接库
            System.loadLibrary("security_check")
        }
    }

    // 声明 C++ 导出的签名校验函数
    private external fun verifySignatureOrExit(context: Any)

    // 定义 MethodChannel 通道名称
    private val CHANNEL_BATTERY = "com.mksha.pan_client/battery"
    private val CHANNEL_NATIVE = "com.mksha.pan_client/native"
    private val CHANNEL_MEDIA_SCAN = "com.mksha.pan_client/media_scan" // 💥 2. 增加相册媒体扫描通道

    override fun onCreate(savedInstanceState: Bundle?) {
        // 💡 2. 在 super.onCreate 之前强行触发 JNI 签名校验
        // 若被反编译二次签名，在此直接发送 SIGKILL 信号杀死进程退出（闪退）
        verifySignatureOrExit(this)

        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        val messageHandler = MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                // 💥 3. 增加媒体文件扫描分支

            "scanFile" -> {
                val filePath = call.argument<String>("path")
                if (filePath != null) {
                    try {
                        val file = java.io.File(filePath)
                        if (file.exists()) {
                            // 1. 获取准确的 MIME 类型
                            val extension = file.extension.lowercase()
                            val mimeType = when (extension) {
                                "jpg", "jpeg" -> "image/jpeg"
                                "png" -> "image/png"
                                "gif" -> "image/gif"
                                "webp" -> "image/webp"
                                "mp4" -> "video/mp4"
                                "mkv" -> "video/x-matroska"
                                "mov" -> "video/quicktime"
                                else -> null
                            }

                            // 2. 显式指定 MIME 类型并触发扫描
                            // 指定 MIME 后，MediaScanner 内部会自动完成 MediaStore 数据的正确插入，无需手动 ContentResolver 插入
                            val mimeTypes = if (mimeType != null) arrayOf(mimeType) else null
                            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), mimeTypes) { path, uri ->
                                println("MediaScan: Successfully scanned $path -> $uri")
                            }

                            result.success(true)
                        } else {
                            result.error("FILE_NOT_FOUND", "File does not exist at $filePath", null)
                        }
                    } catch (e: Exception) {
                        result.error("SCAN_FAILED", "Failed to scan media file: ${e.message}", e.message)
                    }
                } else {
                    result.error("INVALID_PATH", "File path cannot be null", null)
                }
            }


                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "getNativeLibraryDir" -> {
                    try {
                        result.success(applicationInfo.nativeLibraryDir)
                    } catch (e: Exception) {
                        result.error("UNAVAILABLE", "Failed to get native library dir", e.message)
                    }
                }
                "openBatteryOptimizationSettings" -> {
                    var success = false
                    
                    // 1. 优先尝试：弹出 Ignore Battery Optimization 的系统弹窗
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            context.startActivity(intent)
                            success = true
                        } catch (e: Exception) {
                            // 降级处理
                        }
                    }

                    // 2. 降级方案 A：打开系统的电池优化列表页
                    if (!success && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            context.startActivity(intent)
                            success = true
                        } catch (e: Exception) {
                            // 降级处理
                        }
                    }

                    // 3. 降级方案 B：打开当前 App 的系统设置页面
                    if (!success) {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            context.startActivity(intent)
                            success = true
                        } catch (e: Exception) {
                            // 彻底失败
                        }
                    }

                    if (success) {
                        result.success(true)
                    } else {
                        result.error("UNAVAILABLE", "无法打开任何电池或系统设置页面", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // 💥 4. 通道绑定
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_BATTERY).setMethodCallHandler(messageHandler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NATIVE).setMethodCallHandler(messageHandler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIA_SCAN).setMethodCallHandler(messageHandler)
    }
}
