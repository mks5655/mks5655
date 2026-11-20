import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import '../download/download_manager.dart';
import '../models/download_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({Key? key}) : super(key: key);

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> with SingleTickerProviderStateMixin {
  final DownloadManager _manager = DownloadManager.instance;
  late TabController _tabController;

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);

    _tabController.addListener(() {
      if (mounted) setState(() {});
    });

    if (Platform.isAndroid || Platform.isIOS) {
      FlutterBackgroundService().on('update_progress').listen((event) {
        if (event != null && mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }
  Future<String> _getLocalFilePath(DownloadTask task) async {
    // ✅ 优先使用任务创建时记录的本地绝对保存路径
    final sp = task.savePath;
    if (sp != null && sp.isNotEmpty) {
      return p.normalize(sp);
    }

    // —— 以下为 savePath 为空时的兜底逻辑（旧数据/异常数据）——
    Directory? baseDir;
    if (Platform.isAndroid) {
      baseDir = Directory('/storage/emulated/0/Download');
    } else {
      baseDir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    }
    final String baseDownloadDir = baseDir.path;
    String taskPath = task.path;

    if (!taskPath.endsWith(task.filename)) {
      final parentDir = p.dirname(taskPath);
      taskPath = (parentDir == '.' || parentDir == '/')
          ? p.join(taskPath, task.filename)
          : p.join(parentDir, task.filename);
    }

    String relativePath = taskPath;

    if (taskPath.contains('/我的文件/')) {
      relativePath = taskPath.substring(taskPath.indexOf('我的文件'));
    } else if (taskPath.contains(RegExp(r'/share_\d+/'))) {
      final parts = taskPath.split(RegExp(r'/share_\d+/'));
      if (parts.length > 1) {
        relativePath = p.join('我的文件', parts[1]);
      }
    } else if (taskPath.startsWith('/转存/')) {
      final pathSegments = p.split(taskPath);
      int index = pathSegments.indexWhere((s) => s.startsWith('《') || s == task.filename);
      if (index != -1) {
        relativePath = p.joinAll(['我的文件', ...pathSegments.sublist(index)]);
      }
    }

    return p.normalize(p.join(baseDownloadDir, relativePath));
  }

  Future<void> _openFile(DownloadTask task) async {
    final fullPath = await _getLocalFilePath(task);
    final file = File(fullPath);

    if (!await file.exists()) {
      _showSnackBar('文件不存在：$fullPath');
      return;
    }

    if (Platform.isAndroid && fullPath.toLowerCase().endsWith('.apk')) {
      var status = await Permission.requestInstallPackages.status;
      if (!status.isGranted) {
        _showSnackBar('请授予“允许安装未知应用”权限以继续安装');
        status = await Permission.requestInstallPackages.request();
        if (!status.isGranted) {
          _showSnackBar('未授予安装权限，无法安装 APK');
          return;
        }
      }

      final result = await OpenFilex.open(
        fullPath,
        type: 'application/vnd.android.package-archive',
      );

      if (result.type != ResultType.done) {
        _showSnackBar('调起安装失败: ${result.message}');
      }
      return;
    }

    final result = await OpenFilex.open(fullPath);
    if (result.type != ResultType.done) {
      _showSnackBar('打开文件失败: ${result.message}');
    }
  }

  Future<void> _openFolder(DownloadTask task) async {
    final fullPath = await _getLocalFilePath(task);
    final file = File(fullPath);
    final parentDir = file.parent;

    if (!await parentDir.exists()) {
      _showSnackBar('文件夹不存在：${parentDir.path}');
      return;
    }

    try {
      if (Platform.isWindows) {
        final winFullPath = fullPath.replaceAll('/', '\\');
        final winFolderPath = parentDir.path.replaceAll('/', '\\');
        
        if (await file.exists()) {
          await Process.run('explorer.exe', ['/select,', winFullPath]);
        } else {
          await Process.run('explorer.exe', [winFolderPath]);
        }
      } else if (Platform.isMacOS) {
        if (await file.exists()) {
          await Process.run('open', ['-R', fullPath]);
        } else {
          await Process.run('open', [parentDir.path]);
        }
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [parentDir.path]);
      } else {
        await _openFile(task);
      }
    } catch (e) {
      _showSnackBar('打开路径失败: $e');
    }
  }

  Future<bool?> _showConfirmDialog({
    required BuildContext context,
    required String title,
    required String content,
    String confirmText = '确定',
    bool isDangerous = false,
    bool allowPopGesture = true,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: allowPopGesture,
      builder: (BuildContext context) {
        return PopScope(
          canPop: allowPopGesture,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
          },
          child: AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: isDangerous ? Colors.red : Colors.blue,
                ),
                child: Text(confirmText),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Color.fromARGB(255, 0, 0, 0)),
                cursorColor: const Color.fromARGB(255, 0, 0, 0),
                decoration: const InputDecoration(
                  hintText: '搜索文件名...',
                  hintStyle: TextStyle(color: Color.fromARGB(179, 0, 0, 0)),
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value.trim().toLowerCase();
                  });
                },
              )
            : const Text('下载管理'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: false,
          labelPadding: EdgeInsets.zero,
          tabs: const [
            Tab(text: '正在下载'),
            Tab(text: '已暂停'),
            Tab(text: '下载失败'),
            Tab(text: '已完成'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            tooltip: _isSearching ? '关闭搜索' : '搜索任务',
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchController.clear();
                  _searchQuery = '';
                } else {
                  _isSearching = true;
                }
              });
            },
          ),
          if (!_isSearching) ...[
            if (_tabController.index == 0)
              IconButton(
                icon: const Icon(Icons.pause_circle_filled),
                tooltip: '全部暂停',
                onPressed: () => _manager.pauseAll(),
              ),
            if (_tabController.index == 0 || _tabController.index == 1)
              IconButton(
                icon: Icon(
                  _tabController.index == 1 ? Icons.play_arrow : Icons.play_circle_filled,
                ),
                tooltip: '全部继续',
                onPressed: () async {
                  if (_tabController.index == 1) {
                    await _manager.resumeTasksByStatus([DownloadStatus.paused]);
                  } else if (_tabController.index == 0) {
                    await _manager.resumeAll();
                  }
                },
              ),
            if (_tabController.index == 2)
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '全部重试',
                onPressed: () async {
                  await _manager.resumeTasksByStatus([DownloadStatus.error, DownloadStatus.failed]);
                },
              ),
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              tooltip: _getClearTooltip(),
              onPressed: () async {
                final tabIndex = _tabController.index;
                String title = '确认清空';
                String content = '确定要清空操作吗？';

                if (tabIndex == 0) {
                  title = '清空正在下载任务和文件';
                  content = '确定要取消并删除所有正在下载的任务及文件吗？';
                } else if (tabIndex == 1) {
                  title = '清空已暂停任务和文件';
                  content = '确定要删除所有已暂停的任务及文件吗？';
                } else if (tabIndex == 2) {
                  title = '清空下载失败任务和文件';
                  content = '确定要清除所有失败的下载任务记录和文件吗？';
                } else if (tabIndex == 3) {
                  title = '清空已完成记录和文件';
                  content = '确定要清空所有已完成的下载记录和文件吗？';
                }

                final confirmed = await _showConfirmDialog(
                  context: context,
                  title: title,
                  content: content,
                  confirmText: '清空',
                  isDangerous: true,
                );

                if (confirmed == true) {
                  if (tabIndex == 0) {
                    final activeStatuses = _manager.tasks
                        .where((t) => t.status != DownloadStatus.completed &&
                            t.status != DownloadStatus.error &&
                            t.status != DownloadStatus.failed &&
                            t.status != DownloadStatus.paused)
                        .map((t) => t.status)
                        .toSet()
                        .toList();
                    if (activeStatuses.isNotEmpty) {
                      await _manager.clearTasksByStatus(activeStatuses);
                    }
                  } else if (tabIndex == 1) {
                    await _manager.clearTasksByStatus([DownloadStatus.paused]);
                  } else if (tabIndex == 2) {
                    await _manager.clearTasksByStatus([DownloadStatus.error, DownloadStatus.failed]);
                  } else if (tabIndex == 3) {
                    await _manager.clearTasksByStatus([DownloadStatus.completed]);
                  }
                }
              },
            ),
          ],
        ],
      ),
      body: StreamBuilder<List<DownloadTask>>(
        stream: _manager.stream,
        initialData: _manager.tasks,
        builder: (context, snapshot) {
          final rawTasks = snapshot.data ?? [];

          final allTasks = _searchQuery.isEmpty
              ? rawTasks
              : rawTasks.where((task) => task.filename.toLowerCase().contains(_searchQuery)).toList();

          final downloadingTasks = allTasks.where((task) =>
            task.status != DownloadStatus.completed &&
            task.status != DownloadStatus.error &&
            task.status != DownloadStatus.failed &&
            task.status != DownloadStatus.paused
          ).toList();

          final pausedTasks = allTasks.where((task) => task.status == DownloadStatus.paused).toList();

          final failedTasks = allTasks.where((task) =>
            task.status == DownloadStatus.error || task.status == DownloadStatus.failed
          ).toList();

          final completedTasks = allTasks.where((task) => task.status == DownloadStatus.completed).toList();

          return TabBarView(
            controller: _tabController,
            children: [
              _buildTaskList(downloadingTasks, tabType: _TabType.downloading),
              _buildTaskList(pausedTasks, tabType: _TabType.paused),
              _buildTaskList(failedTasks, tabType: _TabType.failed),
              _buildTaskList(completedTasks, tabType: _TabType.completed),
            ],
          );
        },
      ),
    );
  }

  String _getClearTooltip() {
    if (_tabController.index == 0) return '清空正在下载';
    if (_tabController.index == 1) return '清空已暂停';
    if (_tabController.index == 2) return '清空失败任务';
    return '清空已完成';
  }

  Widget _buildTaskList(List<DownloadTask> tasks, {required _TabType tabType}) {
    if (tasks.isEmpty) {
      String emptyText = '暂无任务';
      if (_searchQuery.isNotEmpty) {
        emptyText = '未搜索到匹配任务';
      } else {
        if (tabType == _TabType.downloading) emptyText = '暂无正在下载任务';
        if (tabType == _TabType.paused) emptyText = '暂无已暂停任务';
        if (tabType == _TabType.failed) emptyText = '没有下载失败的任务';
        if (tabType == _TabType.completed) emptyText = '暂无已完成任务';
      }

      return Center(
        child: Text(emptyText),
      );
    }

    // 关键优化点：使用 ListView.builder 配合 fixed itemExtent 避免布局动态测量计算
    return ListView.builder(
      itemCount: tasks.length,
      itemExtent: 76.0, // 固定的 List Item 高度，极大提高成千上万条记录时的滑动流畅度
      itemBuilder: (context, index) {
        final task = tasks[index];

        return Column(
          key: ValueKey(task.id), // 使用持久唯一的 ID 提高列表复用性能
          children: [
            Expanded(
              child: ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                onTap: () {
                  if (tabType == _TabType.completed) {
                    _openFile(task);
                  } else {
                    _openFolder(task);
                  }
                },
                title: Text(
                  task.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: task.progress,
                      backgroundColor: Colors.grey[200],
                      valueColor: AlwaysStoppedAnimation<Color>(
                        tabType == _TabType.failed
                            ? Colors.red
                            : tabType == _TabType.completed
                                ? Colors.green
                                : tabType == _TabType.paused
                                    ? Colors.grey
                                    : Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildStatusWidget(task),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tabType == _TabType.downloading) ...[
                      if (task.status == DownloadStatus.downloading ||
                          task.status == DownloadStatus.waiting ||
                          task.status == DownloadStatus.gettingUrl)
                        IconButton(
                          icon: const Icon(Icons.pause_circle_outline, color: Colors.orange),
                          tooltip: '暂停',
                          onPressed: () => _manager.pause(task),
                        ),
                    ] else if (tabType == _TabType.paused) ...[
                      IconButton(
                        icon: const Icon(Icons.play_circle_outline, color: Colors.blue),
                        tooltip: '继续下载',
                        onPressed: () => _manager.resume(task),
                      ),
                    ] else if (tabType == _TabType.failed) ...[
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.blue),
                        tooltip: '点击重试',
                        onPressed: () => _manager.resume(task),
                      ),
                    ] else ...[
                      IconButton(
                        icon: const Icon(Icons.folder_open, color: Colors.blueAccent),
                        tooltip: '打开所在文件夹',
                        onPressed: () => _openFolder(task),
                      ),
                      IconButton(
                        icon: const Icon(Icons.insert_drive_file_outlined, color: Colors.green),
                        tooltip: '打开文件',
                        onPressed: () => _openFile(task),
                      ),
                    ],
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      tooltip: tabType == _TabType.completed ? '删除记录' : '取消并删除文件',
                      onPressed: () async {
                        final confirmed = await _showConfirmDialog(
                          context: context,
                          title: tabType == _TabType.completed ? '确认删除记录和文件' : '确认取消下载和删除文件',
                          content: tabType == _TabType.completed
                              ? '确定要删除 "${task.filename}" 的完成记录和文件吗？'
                              : '确定要取消任务并删除已下载的文件 "${task.filename}" 吗？',
                          confirmText: '删除',
                          isDangerous: true,
                        );
                        if (confirmed == true) {
                          await _manager.cancel(task);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }

  Widget _buildStatusWidget(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.pending:
      case DownloadStatus.waiting:
        return const Text('排队中...', style: TextStyle(fontSize: 12, color: Colors.orange));

      case DownloadStatus.gettingUrl:
        return const Text('获取解析地址中...', style: TextStyle(fontSize: 12, color: Colors.blue));

      case DownloadStatus.downloading:
        final progressStr = (task.progress * 100).toStringAsFixed(1);
        return Row(
          children: [
            Text('下载中 $progressStr%', style: const TextStyle(fontSize: 12, color: Colors.blue)),
            const SizedBox(width: 12),
            Text(
              task.speedText,
              style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.bold),
            ),
          ],
        );

      case DownloadStatus.paused:
        final progressStr = (task.progress * 100).toStringAsFixed(1);
        return Text('已暂停 $progressStr%', style: const TextStyle(fontSize: 12, color: Colors.grey));

      case DownloadStatus.completed:
        return const Text('已完成 (点击打开)', style: TextStyle(fontSize: 12, color: Colors.green));

      case DownloadStatus.error:
      case DownloadStatus.failed:
        return const Text('下载失败, 点击重试', style: TextStyle(fontSize: 12, color: Colors.red));

      case DownloadStatus.cancelled:
        return const Text('已取消', style: TextStyle(fontSize: 12, color: Colors.grey));
    }
  }
}

enum _TabType { downloading, paused, failed, completed }
