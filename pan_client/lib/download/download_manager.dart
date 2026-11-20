import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/user_api.dart';
import '../models/download_task.dart';
import '../services/traffic_reporter.dart';
import '../settings/settings_manager.dart';
import 'download_engine.dart';
import '../services/global_error_reporter.dart';
import '../models/app_error_log.dart';
import '../utils/media.dart';

/// 全局身份验证/卡密异常回调（例如卡密过期、流量耗尽时触发弹窗或强退）
void Function(String message)? onAuthError;


/// 定义批量添加结果模型
class AddBatchResult {
  final int addedCount;
  final List<String> skippedFiles;

  AddBatchResult({required this.addedCount, required this.skippedFiles});
}

/// 下载管理器类：负责下载任务的生命周期管理、状态调度、本地持久化与流量上报
class DownloadManager {
  // ===========================================================================
  // 单例模式配置
  // ===========================================================================
  static final DownloadManager instance = DownloadManager._internal();
  DownloadManager._internal();

  /// 计数器/调试标记
  int num = 1;

  /// 底层下载引擎实例
  late DownloadEngine _engine = DownloadEngine();

  /// 流量上报服务组件
  TrafficReporter? _reporter;

  /// 用户 API 交互接口
  final UserApi _api = UserApi();

  /// 当前激活的卡密/卡片 ID（用于实现不同卡密下的下载任务环境隔离）
  String? currentCardId;

  /// 内存中维护的所有下载任务列表
  final List<DownloadTask> tasks = [];

  /// 当前正在运行/执行中的任务 ID 集合（防止并发竞争和重复启动）
  final Set<String> _runningTaskIds = {};

  /// 任务状态广播流控制器（用于通知 UI 界面更新下载进度和状态）
  final StreamController<List<DownloadTask>> _streamController =
      StreamController<List<DownloadTask>>.broadcast();

  /// 获取任务变化的广播流
  Stream<List<DownloadTask>> get stream => _streamController.stream;


/// 自动重试失败任务的定时器
  Timer? _autoRetryTimer;

  /// 启动每 10 分钟自动重试失败任务的定时器
  void _startAutoRetryTimer() {
    _autoRetryTimer?.cancel(); // 确保不重复启动
    _autoRetryTimer = Timer.periodic(const Duration(minutes: 10), (timer) {
      retryFailedTasks();
    });
    print("=== [Manager] 已启动每 10 分钟自动重试失败任务的定时器 ===");
  }

  /// 停止自动重试定时器
  void _stopAutoRetryTimer() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    print("=== [Manager] 已停止自动重试定时器 ===");
  }

  /// 执行自动重试所有失败/错误任务的逻辑
  Future<void> retryFailedTasks() async {
    final failedTasks = tasks.where((t) =>
        t.status == DownloadStatus.error || t.status == DownloadStatus.failed
    ).toList();

    if (failedTasks.isEmpty) return;

    print("=== [Manager.AutoRetry] 检测到 ${failedTasks.length} 个失败任务，准备自动重试... ===");

    for (var task in failedTasks) {
      task.resetCancelToken();
      task.status = DownloadStatus.waiting;
      task.needsRefreshDlink = true; // 重试时建议重新刷新直链，防止链接过期
    }

    await saveTasksToLocal();
    _notifyListeners();
    _scheduleTasks();
  }

  // ===========================================================================
  // 初始化与卡密环境切换
  // ===========================================================================

  /// 更新流量上报器与下载引擎
  ///
  /// [serverUrl] 上报服务器地址
  /// [cardCode] 卡密 Code
  /// [cardId] 卡片 ID（可选，若不传则默认使用 cardCode）
  void updateTrafficReporter({
    required String serverUrl,
    required String cardCode,
    String? cardId,
  }) {
    _reporter = TrafficReporter(serverUrl: serverUrl, cardCode: cardCode);
    _engine = DownloadEngine(reporter: _reporter);
    print("=== [Manager] 成功初始化/更新 TrafficReporter 与 DownloadEngine ===");

    final targetCardId = cardId ?? cardCode;
    if (targetCardId.isNotEmpty) {
      switchCard(targetCardId);
    }
  }

  /// 切换卡密隔离环境：暂停现有任务，加载新卡密绑定的本地任务
/// 切换卡密隔离环境：暂停现有任务，加载新卡密绑定的本地任务
  Future<void> switchCard(String newCardId) async {
    if (newCardId.isEmpty || currentCardId == newCardId) return;

    print("=== [Manager] 开始切换卡密隔离环境: $currentCardId -> $newCardId ===");

    // 切换卡密前暂停当前所有的下载任务
    await pauseAll();

    currentCardId = newCardId;

    // 清空内存中的任务与运行状态
    tasks.clear();
    _runningTaskIds.clear();

    // 从本地存储加载新卡密对应的任务列表
    await loadTasksFromLocal();
    
    // 启动/重启定时重试服务
    _startAutoRetryTimer();
    
    _notifyListeners();
  }

  /// 广播通知 UI 监听者更新
  void _notifyListeners() {
    _streamController.add(List.from(tasks));
  }

  // ===========================================================================
  // 辅助解析与文件路径处理工具方法
  // ===========================================================================

  /// 内部工具：通过 ID 或 Task 对象在内存列表中查找匹配的 DownloadTask
  DownloadTask? _resolveTask(dynamic taskOrId) {
    String? targetId;
    if (taskOrId is DownloadTask) {
      targetId = taskOrId.id;
    } else if (taskOrId is String) {
      targetId = taskOrId;
    }

    if (targetId == null || targetId.isEmpty) {
      print("=== [Manager Error] _resolveTask 接收到的 ID 为空 ===");
      return null;
    }

    for (var t in tasks) {
      if (t.id == targetId) return t;
    }
    print(
      "=== [Manager Error] 内存中找不到 ID 为 $targetId 的任务！当前内存任务数: ${tasks.length} ===",
    );
    for (var t in tasks) {
      print("   -> 内存已有任务: ID=${t.id}, File=${t.filename}");
    }
    return null;
  }

  /// 过滤路径节点，剔除“转存”、分享 ID 或内部 uuid 格式的文件夹名称
  List<String> _filterPathSegments(List<String> segments) {
    return segments.where((name) {
      if (name.isEmpty) return false;
      if (name == '转存') return false;
      if (RegExp(r'^share_\d+$', caseSensitive: false).hasMatch(name)) {
        return false;
      }
      if (RegExp(
        r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}',
        caseSensitive: false,
      ).hasMatch(name)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// 获取当前平台的默认基础下载目录（iOS 使用 Documents，其他平台使用设置中的路径）
  Future<String> _getPlatformBaseDir() async {
    if (Platform.isIOS) {
      final docsDir = await getApplicationDocumentsDirectory();
      return docsDir.path;
    } else {
      return SettingsManager.instance.downloadPath;
    }
  }

  /// 生成唯一的本地文件存储路径（若存在重名文件，自动追加 "(1)", "(2)" 后缀）
  String _getUniqueFilePath(String filePath) {
    var file = File(filePath);
    if (!file.existsSync()) {
      return filePath;
    }

    final dir = file.parent.path;
    final extension = p.extension(filePath);
    final nameWithoutExt = p.basenameWithoutExtension(filePath);

    int count = 1;
    while (file.existsSync()) {
      final newName = '$nameWithoutExt ($count)$extension';
      final newPath = p.join(dir, newName);
      file = File(newPath);
      count++;
    }

    return file.path;
  }

  /// 生成微秒时间戳与随机数结合的唯一任务 ID
  String _generateUniqueTaskId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = Random().nextInt(1000000);
    return '${timestamp}_$random';
  }

  // ===========================================================================
  // 任务添加逻辑 (单任务 & 批量任务)
  // ===========================================================================

  /// 添加单个下载任务
/// 添加单个下载任务
  Future<bool> addTask({
    dynamic taskOrUrl,
    String? filename,
    String? path,
    int? size,
    String? fsId,
    dynamic cardId,
    List<String>? breadcrumbs,
  }) async {
    final baseDir = await _getPlatformBaseDir();

    // 构建层级子目录
    List<String> subFolders = [];
    if (breadcrumbs != null && breadcrumbs.isNotEmpty) {
      subFolders = _filterPathSegments(breadcrumbs);
    } else if (taskOrUrl is DownloadTask && taskOrUrl.path.isNotEmpty) {
      final rawParts = taskOrUrl.path
          .split('/')
          .where((e) => e.isNotEmpty)
          .toList();
      if (rawParts.isNotEmpty) rawParts.removeLast();
      subFolders = ['我的文件', ..._filterPathSegments(rawParts)];
    } else {
      subFolders = ['我的文件'];
    }

    final targetDir = p.joinAll([baseDir, ...subFolders]);
    final dir = Directory(targetDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // 解析字段参数
    String rawFilename = 'download_file';
    String rawPath = '';
    int rawSize = 0;
    String rawFsId = '';
    int parsedCardId = 0;
    String? rawDlink;

    if (taskOrUrl is DownloadTask) {
      rawFilename = taskOrUrl.filename;
      rawPath = taskOrUrl.path;
      rawSize = taskOrUrl.size;
      rawFsId = taskOrUrl.fsId;
      parsedCardId = taskOrUrl.cardId;
      rawDlink = taskOrUrl.dlink;
    } else {
      rawFilename = filename ?? 'download_file';
      rawPath = path ?? '';
      rawSize = size ?? 0;
      rawFsId = fsId ?? '';
      if (cardId is int) {
        parsedCardId = cardId;
      } else if (cardId is String) {
        parsedCardId = int.tryParse(cardId) ?? 0;
      }
      rawDlink = taskOrUrl?.toString();
    }

    // ================= 1. 防重校验 & 旧记录清理 =================
    final targetSavePath = p.join(targetDir, rawFilename);

    // 检查是否存在正在进行或排队中的相同任务
    final isAlreadyExist = tasks.any((t) =>
        ((rawFsId.isNotEmpty && t.fsId == rawFsId) || t.savePath == targetSavePath) &&
        (t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.waiting ||
            t.status == DownloadStatus.gettingUrl ||
            t.status == DownloadStatus.pending ||
                t.status == DownloadStatus.failed ||
                t.status == DownloadStatus.completed ||
                t.status == DownloadStatus.error ||
                t.status == DownloadStatus.paused
            ));

    if (isAlreadyExist) {
      print("=== [Manager] 任务已在下载或等待队列中，拒绝重复添加: $rawFilename ===");
      return false; // 返回 false 代表已被跳过    
    }

    // 存在已取消、失败或已完成的旧任务记录时，移除旧记录以便重新添加
    tasks.removeWhere(
      (t) =>
          ((rawFsId.isNotEmpty && t.fsId == rawFsId) || t.savePath == targetSavePath) &&
          (t.status == DownloadStatus.cancelled
              // t.status == DownloadStatus.failed ||
              // t.status == DownloadStatus.completed ||
              // t.status == DownloadStatus.error
              ),
    );
    // =========================================================

    // 确定唯一保存路径
    final rawSavePath = p.join(targetDir, rawFilename);
    final finalSavePath = _getUniqueFilePath(rawSavePath);
    final finalFilename = p.basename(finalSavePath);

    final newTaskId = _generateUniqueTaskId();

    final newTask = DownloadTask(
      id: newTaskId,
      filename: finalFilename,
      path: rawPath,
      size: rawSize,
      fsId: rawFsId,
      cardId: parsedCardId,
      dlink: rawDlink,
      savePath: finalSavePath,
      downloaded: 0,
      status: DownloadStatus.waiting,
    );

    newTask.resetCancelToken();
    tasks.add(newTask);
    print(
      "=== [Manager] 添加新任务成功 (Card: $currentCardId): ID=${newTask.id} | File=${newTask.filename} ===",
    );

    await saveTasksToLocal();
    _notifyListeners();
    _scheduleTasks();
    return true; // 返回 false 代表已被跳过
  }

  /// 批量添加下载任务
  /// 批量添加下载任务
  /// 修改批量任务添加：返回 AddBatchResult
  Future<AddBatchResult> addBatchTasks(
    List<Map<String, dynamic>> rawItems, {
    List<String>? breadcrumbs,
  }) async {

    // if (rawItems.isEmpty) return;
    if (rawItems.isEmpty) {
        return AddBatchResult(addedCount: 0, skippedFiles: []);
    }
    
    final List<String> skippedFiles = [];
    int addedCount = 0;

    final rawBaseDir = await _getPlatformBaseDir();
    final baseDir = p.join(rawBaseDir, '我的文件');

    final cleanBreadcrumbs = (breadcrumbs != null && breadcrumbs.isNotEmpty)
        ? _filterPathSegments(breadcrumbs)
        : <String>[];

    print(
      "=== [Manager] 开始批量添加 ${rawItems.length} 个任务, 当前目录层级: $cleanBreadcrumbs ===",
    );

    for (var item in rawItems) {
      final String rawFilename = item['filename'] ?? 'download_file';
      final String rawPath = item['path'] ?? '';
      final int rawSize = item['size'] ?? 0;
      final String rawFsId = item['fsId'] ?? '';
      final int parsedCardId = item['cardId'] is int
          ? item['cardId']
          : (int.tryParse(item['cardId']?.toString() ?? '0') ?? 0);
      final String? rawDlink = item['dlink'];

      List<String> fileSubFolders = List.from(cleanBreadcrumbs);

      // 根据文件的相对路径构建嵌套目录结构
      if (rawPath.isNotEmpty) {
        final pathParts = rawPath
            .split('/')
            .where((e) => e.isNotEmpty)
            .toList();
        if (pathParts.isNotEmpty) {
          pathParts.removeLast();
        }

        if (pathParts.length > cleanBreadcrumbs.length) {
          bool match = true;
          for (int i = 0; i < cleanBreadcrumbs.length; i++) {
            if (i >= pathParts.length || pathParts[i] != cleanBreadcrumbs[i]) {
              match = false;
              break;
            }
          }

          if (match) {
            final extraParts = pathParts.skip(cleanBreadcrumbs.length).toList();
            fileSubFolders.addAll(_filterPathSegments(extraParts));
          } else {
            fileSubFolders = _filterPathSegments(pathParts);
          }
        }
      }

      final targetDir = p.joinAll([baseDir, ...fileSubFolders]);
      final dir = Directory(targetDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // ================= 1. 防重校验 & 旧记录清理 =================
      final targetSavePath = p.join(targetDir, rawFilename);

      final isAlreadyExist = tasks.any((t) =>
          ((rawFsId.isNotEmpty && t.fsId == rawFsId) || t.savePath == targetSavePath) &&
          (t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.waiting ||
              t.status == DownloadStatus.gettingUrl ||
              t.status == DownloadStatus.pending ||
                t.status == DownloadStatus.failed ||
                t.status == DownloadStatus.completed ||
                t.status == DownloadStatus.error ||
                t.status == DownloadStatus.paused
              ));

      if (isAlreadyExist) {
        print("=== [Manager] 批量添加跳过正在下载或等待的任务: $rawFilename ===");
        skippedFiles.add(rawFilename); // 记录被跳过的文件名
        continue; // 跳过当前任务
      }

      tasks.removeWhere(
        (t) =>
            ((rawFsId.isNotEmpty && t.fsId == rawFsId) || t.savePath == targetSavePath) &&
            (t.status == DownloadStatus.cancelled
                // t.status == DownloadStatus.failed ||
                // t.status == DownloadStatus.completed ||
                // t.status == DownloadStatus.error
                ),
      );
      // =========================================================

      final rawSavePath = p.join(targetDir, rawFilename);
      final finalSavePath = _getUniqueFilePath(rawSavePath);
      final finalFilename = p.basename(finalSavePath);

      final newTaskId = _generateUniqueTaskId();
      final newTask = DownloadTask(
        id: newTaskId,
        filename: finalFilename,
        path: rawPath,
        size: rawSize,
        fsId: rawFsId,
        cardId: parsedCardId,
        dlink: rawDlink,
        savePath: finalSavePath,
        downloaded: 0,
        status: DownloadStatus.waiting,
      );

      newTask.resetCancelToken();
      tasks.add(newTask);
      addedCount++;
    }

    await saveTasksToLocal();
    _notifyListeners();

    // 延迟 50ms 触发调度，确保并发添加逻辑结算完毕
    Future.delayed(const Duration(milliseconds: 50), () {
      _scheduleTasks();
    });
    
    return AddBatchResult(addedCount: addedCount, skippedFiles: skippedFiles);

  }

  // ===========================================================================
  // 任务控制逻辑 (暂停、恢复、取消、清理)
  // ===========================================================================

  /// 暂停指定任务
  Future<void> pause(dynamic taskOrId) async {
    print("=== [Manager.pause] 试图暂停任务, 参数: $taskOrId ===");
    final task = _resolveTask(taskOrId);

    if (task == null) {
      print("=== [Manager.pause] 找不到对应 Task 对象，暂停中断 ===");
      return;
    }

    task.status = DownloadStatus.paused;
    task.speed = 0;

    // 取消该任务当前的 HTTP 下载 Request
    if (!task.cancelToken.isCancelled) {
      task.cancelToken.cancel("User Paused");
    }

    _reporter?.pauseTimer();

    _notifyListeners();
    await saveTasksToLocal();
  }

  /// 恢复执行指定任务
  Future<void> resume(dynamic taskOrId) async {
    print("=== [Manager.resume] 恢复任务, 参数: $taskOrId ===");
    final task = _resolveTask(taskOrId);
    if (task == null) return;

    // 若本地文件已经完整存在，直接置为完成状态
    if (_checkFileCompleted(task)) {
      task.status = DownloadStatus.completed;
      task.speed = 0;
      _notifyListeners();
      await saveTasksToLocal();
      return;
    }

    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.error ||
        task.status == DownloadStatus.failed ||
        task.status == DownloadStatus.gettingUrl ||
        task.status == DownloadStatus.waiting) {
      task.resetCancelToken();
      task.status = DownloadStatus.waiting;
      _notifyListeners();
      _scheduleTasks();
    }
  }

  /// 取消指定任务并删除关联文件
  Future<void> cancel(dynamic taskOrId) async {
    print("=== [Manager.cancel] 取消任务, 参数: $taskOrId ===");
    final task = _resolveTask(taskOrId);
    if (task == null) return;

    final targetId = task.id;

    task.status = DownloadStatus.cancelled;
    task.speed = 0;
    if (!task.cancelToken.isCancelled) {
      task.cancelToken.cancel("User Cancelled");
    }

    tasks.removeWhere((e) => e.id == targetId);

    _reporter?.pauseTimer();

    _notifyListeners();
    await saveTasksToLocal();
    _scheduleTasks();

    // 异步清理磁盘未完成的临时/目标文件
    await _deleteLocalFile(task);
  }

  /// 删除任务对应的本地物理文件（附带重试逻辑以防文件句柄被占用）
  Future<void> _deleteLocalFile(DownloadTask task) async {
    await Future.delayed(const Duration(milliseconds: 200));

    final pathsToDelete = [
      if (task.savePath != null && task.savePath!.isNotEmpty) task.savePath!,
      if (task.tempPath != null && task.tempPath!.isNotEmpty) task.tempPath!,
    ];

    for (final pathStr in pathsToDelete) {
      final file = File(pathStr);
      if (!file.existsSync()) continue;

      int retries = 5;
      while (retries > 0) {
        try {
          await file.delete();
          break;
        } catch (e) {
          retries--;
          if (retries == 0) {
            print("删除本地磁盘文件最终失败 ($pathStr): $e");
          } else {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      }
    }
  }

  /// 批量暂停所有运行中或等待中的任务
  Future<void> pauseAll() async {
    print("=== [Manager] 执行批量 pauseAll ===");

    final targets = tasks
        .where(
          (task) =>
              task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.waiting ||
              task.status == DownloadStatus.gettingUrl,
        )
        .toList();

    if (targets.isEmpty) return;

    for (var task in targets) {
      task.cancelToken.cancel('Paused by user');
      task.status = DownloadStatus.paused;
      task.speed = 0;
    }

    _reporter?.pauseTimer();

    await saveTasksToLocal();
    _notifyListeners();

    print("=== [Manager] 批量 pauseAll 完成，共处理 ${targets.length} 个任务 ===");
  }

  /// 批量恢复所有暂停或失败的任务
  Future<void> resumeAll() async {
    print("=== [Manager] 执行批量 resumeAll ===");

    final targets = tasks
        .where(
          (task) =>
              task.status == DownloadStatus.paused ||
              task.status == DownloadStatus.error ||
              task.status == DownloadStatus.failed,
        )
        .toList();

    if (targets.isEmpty) return;

    for (var task in targets) {
      task.status = DownloadStatus.waiting;
    }

    await saveTasksToLocal();
    _notifyListeners();
    _scheduleTasks();

    print("=== [Manager] 批量 resumeAll 完成，共处理 ${targets.length} 个任务 ===");
  }

  /// 批量取消并清空所有任务
  Future<void> cancelAll() async {
    print("=== [Manager] 执行批量 cancelAll ===");

    final targets = List<DownloadTask>.from(tasks);
    if (targets.isEmpty) return;

    for (var task in targets) {
      task.cancelToken.cancel('Cancelled by user');
    }

    _reporter?.pauseTimer();

    tasks.clear();
    _runningTaskIds.clear();

    await saveTasksToLocal();
    _notifyListeners();
    _scheduleTasks();

    for (var task in targets) {
      _deleteLocalFile(task);
    }

    print("=== [Manager] 批量 cancelAll 完成 ===");
  }

  /// 根据指定的状态列表批量移除任务并清理本地文件
  Future<void> clearTasksByStatus(List<DownloadStatus> statuses) async {
    print("=== [Manager] 执行批量清空状态: $statuses ===");

    final targets = tasks
        .where((task) => statuses.contains(task.status))
        .toList();
    if (targets.isEmpty) return;

    for (var task in targets) {
      task.cancelToken.cancel('Cleared by user');
      _runningTaskIds.remove(task.id);
    }

    tasks.removeWhere((task) => statuses.contains(task.status));

    await saveTasksToLocal();
    _notifyListeners();
    _scheduleTasks();

    for (var task in targets) {
      _deleteLocalFile(task);
    }

    print("=== [Manager] 批量清空完成，共处理 ${targets.length} 个任务 ===");
  }

  /// 根据指定的状态列表批量恢复任务
  Future<void> resumeTasksByStatus(List<DownloadStatus> statuses) async {
    print("=== [Manager] 执行批量恢复状态: $statuses ===");

    final targets = tasks
        .where((task) => statuses.contains(task.status))
        .toList();
    if (targets.isEmpty) return;

    for (var task in targets) {
      task.status = DownloadStatus.waiting;
    }

    await saveTasksToLocal();
    _notifyListeners();
    _scheduleTasks();

    print("=== [Manager] 批量恢复完成，共处理 ${targets.length} 个任务 ===");
  }

  // ===========================================================================
  // 核心调度与执行引擎
  // ===========================================================================

  /// 任务调度器：根据系统的最大并发数配置，拉取等待中的任务开始执行
  void _scheduleTasks() {
    final maxConcurrent = SettingsManager.instance.maxConcurrent;

    final activeCount = tasks
        .where(
          (t) =>
              t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.gettingUrl,
        )
        .length;

    print(
      "=== [Manager._scheduleTasks] 当前活动任务数: $activeCount / 最大允许: $maxConcurrent ===",
    );

    if (activeCount >= maxConcurrent) return;

    final pendingTasks = tasks
        .where(
          (t) =>
              t.status == DownloadStatus.waiting ||
              t.status == DownloadStatus.pending,
        )
        .toList();

    for (var task in pendingTasks) {
      final currentActive = tasks
          .where(
            (t) =>
                t.status == DownloadStatus.downloading ||
                t.status == DownloadStatus.gettingUrl,
          )
          .length;

      if (currentActive >= maxConcurrent) break;

      if (_runningTaskIds.contains(task.id)) {
        continue;
      }

      _startExecuteTask(task);
    }
  }

  /// 提取各种类型的错误对象中的文本消息
  String _extractErrorMessage(dynamic errorOrData) {
    if (errorOrData == null) return '';

    if (errorOrData is Map) {
      return errorOrData['error']?.toString() ??
          errorOrData['message']?.toString() ??
          errorOrData['msg']?.toString() ??
          '';
    }

    if (errorOrData is DioException) {
      final resData = errorOrData.response?.data;
      if (resData is Map) {
        return resData['error']?.toString() ??
            resData['message']?.toString() ??
            errorOrData.message ??
            '';
      }
      return resData?.toString() ?? errorOrData.message ?? '';
    }

    try {
      final dynamic model = errorOrData;
      if (model.error != null && model.error.toString().isNotEmpty) {
        return model.error.toString();
      }
    } catch (_) {}

    return errorOrData.toString();
  }

  /// 检查错误消息中是否包含敏性卡密失效词，若有则触发全局退出的 [onAuthError] 回调
  bool _checkAndTriggerAuthError(String errMsg, DownloadTask task) {
    if (errMsg.contains('卡密不存在') ||
        errMsg.contains('卡密已禁用') ||
        errMsg.contains('卡密已过期') ||
        errMsg.contains('流量已用完')) {
      print("=== [卡密异常触发] 检测到敏感关键字，触发全局强退弹窗: $errMsg ===");

      task.status = DownloadStatus.error;
      task.speed = 0;
      _notifyListeners();

      if (onAuthError != null) {
        onAuthError!(errMsg);
      } else {
        print("=== [Warning] onAuthError 未注册，无法触发全局退出逻辑 ===");
      }
      return true;
    }
    return false;
  }

  /// 启动并执行具体的单个下载任务（获取直链 -> 启动 Engine -> 处理网络重试及状态转换）
  Future<void> _startExecuteTask(DownloadTask task) async {
    print(
      "=== [Manager._startExecuteTask] 试图启动任务: ID=${task.id} | 当前 Status=${task.status} ===",
    );
    if (_runningTaskIds.contains(task.id)) {
      print("=== [Manager] 任务已经运行，禁止重复启动 ${task.id} ===");
      return;
    }

    _runningTaskIds.add(task.id);

    try {
      print("=== [Manager] 加入运行锁 ${task.id} ===");

      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        print("=== [Manager._startExecuteTask] 任务已暂停/取消，放弃执行 ===");
        return;
      }

      if (task.status != DownloadStatus.waiting &&
          task.status != DownloadStatus.pending) {
        return;
      }

      if (task.cancelToken.isCancelled) {
        task.resetCancelToken();
      }

      if (task.dlink != null && task.dlink!.isNotEmpty) {
        task.status = DownloadStatus.downloading;
      } else {
        task.status = DownloadStatus.gettingUrl;
      }
      _notifyListeners();

      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        print("=== [Manager._startExecuteTask] 执行前二次拦截成功 ===");
        return;
      }

      // 步骤 1：若缺少直链或直链已被标记为过期，请求 API 获取最新直链 (dlink)
      if (task.dlink == null || task.dlink!.isEmpty) {
        String? newDlink;

        try {
          dynamic res;
          if (task.needsRefreshDlink) {
            print(
              "=== [Manager] 监测到直链失效/过期，强制调用 refreshDlink 刷新服务器缓存... ID=${task.id} ===",
            );
            res = await _api.refreshDlink(
              fsId: task.fsId,
              cardId: task.cardId,
              path: task.path,
              filename: task.filename,
              size: task.size,
            );
          } else {
            print(
              "=== [Manager] 首次/正常获取直链，调用 createDownload... ID=${task.id} ===",
            );
            res = await _api.createDownload(
              fsId: task.fsId,
              cardId: task.cardId,
              path: task.path,
              filename: task.filename,
              size: task.size,
            );
          }

          final apiErrMsg = _extractErrorMessage(res);
          if (_checkAndTriggerAuthError(apiErrMsg, task)) {
            return;
          }

          if (res is Map) {
            newDlink = res['dlink']?.toString();
          } else {
            try {
              newDlink = (res as dynamic).dlink;
            } catch (_) {}
          }

          task.needsRefreshDlink = false;
        } catch (e) {
          final errMsg = _extractErrorMessage(e);
          print("=== [API 请求异常拦截] Msg: $errMsg ===");

          if (_checkAndTriggerAuthError(errMsg, task)) {
            return;
          }

          rethrow;
        }

        if (task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.cancelled) {
          print("=== [Manager] 直链请求返回后检测到任务被暂停/取消，终止后续下载！ ===");
          task.speed = 0;
          return;
        }

        if (newDlink == null || newDlink.isEmpty) {
          throw Exception("获取直链失败：返回地址为空");
        }
        task.dlink = newDlink;
        print("=== [Manager] 获取直链成功: ${task.dlink} ===");
      }

      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        print("=== [Manager] 进入 Engine 前第三次拦截成功 ===");
        task.speed = 0;
        return;
      }

      // 步骤 2：切换为下载中状态，调用底层 Engine 进行分块/流式下载并实时统计网速
      task.status = DownloadStatus.downloading;
      _notifyListeners();

      print("=== [Manager] 即将进入 _engine.download ... ===");
      await _runDownloadWithSpeed(task);

      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        print("=== [Manager] _engine.download 结束后检测到任务已被暂停/取消 ===");
        task.speed = 0;
        return;
      }

      // 步骤 3：下载成功，重置重试计数并记录完成
      task.retryCount = 0;
      task.needsRefreshDlink = false;
      task.status = DownloadStatus.completed;
      task.speed = 0;

      // 若为图片或视频，通知 Android 系统图库刷新
      if (task.savePath != null && MediaScanner.isMediaFile(task.savePath!)) {
        MediaScanner.scanFile(task.savePath!);
      }

      await _reporter?.flushAndCheck();

      print("=== [Manager] 任务已顺利完成: ID=${task.id} ===");
    } catch (e, stackTrace) {
      print(
        "=== [Manager.catch] 捕获到异常: $e | 当前 Task.status=${task.status} ===",
      );

      _reporter?.pauseTimer();

      // 如果属于主动暂停/取消引发的 Exception，不做报错记录
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        print("=== [Manager.catch] 该异常由暂停/取消触发，保留状态，不标记为 Error ===");
        task.speed = 0;
        return;
      }

      final catchedErrMsg = _extractErrorMessage(e);
      if (_checkAndTriggerAuthError(catchedErrMsg, task)) {
        return;
      }

      // 校验文件是否实际已下完（防止网络在最后一刻中断导致的误判错误）
      final isFinished = _checkFileCompleted(task);
      if (isFinished) {
        task.status = DownloadStatus.completed;
        task.speed = 0;
        task.retryCount = 0;
        task.needsRefreshDlink = false;
        return;
      }

      // 记录到全局错误日志中心
      GlobalErrorReporter().reportError(
        AppErrorLog(
          errorType: 'DownloadTaskError',
          message: '任务 [${task.filename}] (ID: ${task.id}) 发生错误: $e',
          stackTrace: stackTrace.toString(),
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
        ),
      );

      // 判断是否属于 HTTP 403 / 410 直链链接过期
      bool isDlinkExpired = false;
      if (e is DioException) {
        final statusCode = e.response?.statusCode;
        if (statusCode == 403 || statusCode == 410) {
          isDlinkExpired = true;
          print("===================== dlink 已失效 =====================");
          print("=== [Manager.catch] 检测到 HTTP $statusCode，dlink 已失效！ ===");
          _reporter?.flushAndCheck(
            fatalError: "HTTP $statusCode: Link Expired",
          );
        }
      }

      if (!isDlinkExpired) {
        _reporter?.flushAndCheck(fatalError: "DownloadError: ${e.toString()}");
      }

      task.dlink = null;

      // 若链接过期且未超过最大重试次数，标记需要重新获取直链并重新挂起排队
      if (isDlinkExpired && task.retryCount < task.maxRetry) {
        task.retryCount++;
        task.needsRefreshDlink = true;
        task.status = DownloadStatus.waiting;
        print(
          "=== [Manager.catch] 已标记强制刷新直链，准备重试 (${task.retryCount}/${task.maxRetry}) ===",
        );
      } else {
        task.status = DownloadStatus.error;
      }
    } finally {
      // 释放当前任务运行锁，持久化并触发下一次调度
      _runningTaskIds.remove(task.id);
      print("=== [Manager] 移除运行锁 ${task.id} ===");

      task.speed = 0;
      await saveTasksToLocal();
      _notifyListeners();

      Future.microtask(() => _scheduleTasks());
    }
  }

  /// 校验本地已存在文件的大小与任务所需大小是否完全一致
  bool _checkFileCompleted(DownloadTask task) {
    if (task.savePath == null || task.savePath!.isEmpty) return false;
    final file = File(task.savePath!);
    if (!file.existsSync()) return false;

    final localLength = file.lengthSync();

    if (task.size > 0) {
      return localLength == task.size;
    }

    return task.downloaded > 0 && localLength == task.downloaded;
  }

  /// 封装下载引擎调用，实施限流广播并计算实时下载速度
  Future<void> _runDownloadWithSpeed(DownloadTask task) async {
    DateTime lastTime = DateTime.now();
    int lastBytes = task.downloaded;
    int lastNotifyTime = 0;

    await _engine.download(task, (current, total) {
      if (task.status != DownloadStatus.downloading) {
        return;
      }

      task.downloaded = current;

      final now = DateTime.now();
      final timeDiff = now.difference(lastTime).inMilliseconds;

      // 每 500ms 统计一次速度
      if (timeDiff >= 500) {
        final bytesDiff = current - lastBytes;
        if (bytesDiff > 0) {
          task.speed = ((bytesDiff / timeDiff) * 1000).round();
        } else {
          task.speed = 0;
        }
        lastTime = now;
        lastBytes = current;
      }

      // 给 UI 广播通知设置限流（保底 250ms 触发一次，或完成时直接通知）
      final nowMs = now.millisecondsSinceEpoch;
      if (nowMs - lastNotifyTime >= 250 || current >= total) {
        lastNotifyTime = nowMs;
        _notifyListeners();
      }
    });
  }

  // ===========================================================================
  // 本地数据持久化 (SharedPreferences JSON)
  // ===========================================================================

  /// 将内存中的下载任务列表序列化并保存至本地 SharedPreferences
  Future<void> saveTasksToLocal() async {
    if (currentCardId == null || currentCardId!.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final String rawJson = jsonEncode(tasks.map((e) => e.toJson()).toList());
    await prefs.setString('download_tasks_cache_$currentCardId', rawJson);
  }

  /// 从本地 SharedPreferences 恢复对应卡密下的任务列表
/// 从本地 SharedPreferences 恢复对应卡密下的任务列表
  Future<void> loadTasksFromLocal() async {
    if (currentCardId == null || currentCardId!.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final String? rawJson =
        prefs.getString('download_tasks_cache_$currentCardId');

    tasks.clear();

    if (rawJson != null && rawJson.isNotEmpty) {
      final List list = jsonDecode(rawJson);
      tasks.addAll(list.map((e) => DownloadTask.fromJson(e)).toList());

      // 修正程序上次异常关闭时残余的中间状态（“获取直链中”、“下载中”自动转为“等待中”）
      for (var task in tasks) {
        if (task.status == DownloadStatus.gettingUrl ||
            task.status == DownloadStatus.downloading) {
          task.status = DownloadStatus.waiting;
        }
      }

      _notifyListeners();
      _scheduleTasks();
    }
    
    // 开启自动重试定时器
    _startAutoRetryTimer();
  }
}
