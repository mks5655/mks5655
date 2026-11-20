import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsManager {
  SettingsManager._internal();
  static final SettingsManager instance = SettingsManager._internal();

  late SharedPreferences _prefs;

  String downloadPath = '';
  int maxConcurrent = 2;
  int threadsPerTask = 2;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    // 1. 如果用户曾经在设置中手动选择过路径，优先使用保存的路径
    String? savedPath = _prefs.getString('download_path');

    if (savedPath != null && savedPath.isNotEmpty) {
      downloadPath = savedPath;
    } else {
      // 2. 如果没有保存过，根据不同平台获取默认系统下载目录
      downloadPath = await _getDefaultDownloadDirectory();
    }

    maxConcurrent = _prefs.getInt('max_concurrent') ?? 2;
    threadsPerTask = _prefs.getInt('threads_per_task') ?? 2;
  }

  /// 跨平台获取默认下载目录
  Future<String> _getDefaultDownloadDirectory() async {
    try {
      if (Platform.isAndroid) {
        // 安卓内置标准路径
        return '/storage/emulated/0/Download';
      } else {
        // macOS, Windows, Linux 自动获取系统的 Downloads 目录
        final directory = await getDownloadsDirectory();
        if (directory != null) {
          return directory.path;
        }
        // 兜底：如果 getDownloadsDirectory 返回 null，获取应用文档目录
        final appDocDir = await getApplicationDocumentsDirectory();
        return appDocDir.path;
      }
    } catch (e) {
      // 容错兜底
      return '/storage/emulated/0/Download';
    }
  }

  Future<void> setDownloadPath(String path) async {
    downloadPath = path;
    await _prefs.setString('download_path', path);
  }

  Future<void> setMaxConcurrent(int count) async {
    maxConcurrent = count;
    await _prefs.setInt('max_concurrent', count);
  }

  Future<void> setThreadsPerTask(int count) async {
    threadsPerTask = count;
    await _prefs.setInt('threads_per_task', count);
  }
}
