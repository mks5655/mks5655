import 'dart:async';
import 'package:dio/dio.dart';
import '../models/download_task.dart';
import '../models/file_item.dart';

class DownloadController {
  final Dio dio;

  DownloadController({required this.dio});

  /// 1. 下载单个文件
  Future<void> downloadSingleFile(FileItem file) async {
    final task = DownloadTask(
      fid: file.fid,
      filename: file.filename,
      size: file.size,
      path: file.path,
      // 保存到本地相对路径，保持目录结构
      savePath: "/sdcard/Download/Netdisk${_getRelativeDir(file.path)}",
    );

    // 将任务推入下载队列/管理器开始下载
    // DownloadManager.instance.addTask(task);
    print("已添加单文件下载任务: ${file.filename}");
  }

  /// 2. 下载整个文件夹
  Future<void> downloadFolder(FileItem folder) async {
    print("正在扫描文件夹内容: ${folder.filename}...");

    try {
      // 递归获取文件夹下的所有文件
      List<FileItem> allFiles = await _fetchAllFilesFromFolder(folder.path);

      if (allFiles.isEmpty) {
        print("文件夹为空或无有效文件");
        return;
      }

      print("扫描完成，共获取到 ${allFiles.length} 个文件，准备批量添加任务...");

      for (var file in allFiles) {
        await downloadSingleFile(file);
      }
    } catch (e) {
      print("遍历文件夹失败: $e");
    }
  }

  /// 递归向 FastAPI 服务端请求获取文件夹下所有文件列表
  Future<List<FileItem>> _fetchAllFilesFromFolder(String folderPath) async {
    List<FileItem> fileList = [];

    // 请求后端接口获取当前目录下的子项
    final response = await dio.get(
      "https://baidu-pan.mtd.dpdns.org/files/list",
      queryParameters: {"path": folderPath},
    );

    if (response.statusCode == 200 && response.data['success'] == true) {
      List items = response.data['data'] ?? [];

      for (var item in items) {
        final fileItem = FileItem(
          fid: item['fid'].toString(),
          filename: item['filename'],
          size: item['size'] ?? 0,
          path: item['path'],
          isFolder: item['is_dir'] == 1 || item['is_folder'] == true,
        );

        if (fileItem.isFolder) {
          // 如果是子文件夹，继续递归调用获取深层文件
          List<FileItem> subFiles = await _fetchAllFilesFromFolder(fileItem.path);
          fileList.addAll(subFiles);
        } else {
          // 如果是文件，推入文件列表
          fileList.add(fileItem);
        }
      }
    }

    return fileList;
  }

  /// 从完整网盘路径提取保存子目录（保持文件夹层级）
  String _getRelativeDir(String fullPath) {
    int lastSlash = fullPath.lastIndexOf('/');
    if (lastSlash > 0) {
      return fullPath.substring(0, lastSlash);
    }
    return '';
  }
}