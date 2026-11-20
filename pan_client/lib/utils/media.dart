import 'dart:io';
import 'package:flutter/services.dart';

class MediaScanner {
  static const MethodChannel _channel = MethodChannel('com.mksha.pan_client/media_scan');

  /// 触发系统媒体库扫描
  static Future<void> scanFile(String filePath) async {
    if (!Platform.isAndroid) return;
    if (filePath.isEmpty) return;

    try {
      await _channel.invokeMethod('scanFile', {'path': filePath});
    } on PlatformException catch (e) {
      print('扫描媒体文件异常: ${e.message}');
    }
  }

  /// 判断文件扩展名是否属于图片或视频
  static bool isMediaFile(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'mkv', 'mov', 'avi', 'flv'].contains(ext);
  }
}