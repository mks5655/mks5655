import 'package:flutter/material.dart';
import '../download/download_manager.dart';
import '../models/download_task.dart';

class DownloadHelper {
  /// 点击下载文件时的触发函数（含确认弹窗）
  static Future<void> handleStartDownload({
    required BuildContext context,
    required String fsId,
    required String filename,
    required int size,
    required int cardId,
    required String path,
    List<String>? breadcrumbs,
  }) async {
    // 1. 智能转换文件大小格式 (MB / GB)
    final String sizeText = size >= 1024 * 1024 * 1024
        ? '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
        : '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';

    // 2. 弹出下载确认框
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认新建下载'),
        content: Text('确定要下载 "$filename" ($sizeText) 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );

    // 3. 确认后加入队列
    if (confirmed == true) {
      final task = DownloadTask(
        id: '${cardId}_$fsId',
        fsId: fsId,
        filename: filename,
        size: size,
        cardId: cardId,
        path: path,
        status: DownloadStatus.waiting,
      );

      // 采用命名参数调用
      final bool success = await DownloadManager.instance.addTask(
        taskOrUrl: task,
        breadcrumbs: breadcrumbs,
      );

      if (!context.mounted) return;

      // 💥【关键优化点】：在展示新的 SnackBar 前，立刻清除上一个提示条
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();

      if (success) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('已加入下载队列: $filename'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating, // 改为悬浮式体验更好，不卡底部
            action: SnackBarAction(
              label: '查看',
              onPressed: () {
                Navigator.pushNamed(context, '/download');
              },
            ),
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('任务已存在，请勿重复添加: $filename'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '查看',
              onPressed: () {
                Navigator.pushNamed(context, '/download');
              },
            ),
          ),
        );
      }
    }
  }
}
