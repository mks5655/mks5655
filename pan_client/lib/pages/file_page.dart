import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/user_api.dart';
import '../download/download_manager.dart';
import '../models/file_model.dart';
import '../models/file_response.dart';
import '../utils/download_helper.dart';
import 'settings_page.dart';
import '../utils/event_bus.dart';

/// L1 级别：内存目录缓存（按 cardCode + path 隔离）
final Map<String, FileResponse> _globalDirCache = {};
String? _globalLastCardCode;

/// 清空本地磁盘及内存中的所有目录缓存
Future<void> clearAllDirCache() async {
  // 1. 清空内存 L1 缓存
  _globalDirCache.clear();
  _globalLastCardCode = null;

  // 2. 清空 SharedPreferences 磁盘持久化缓存
  try {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    for (final key in keys) {
      if (key.startsWith('dir_cache_')) {
        await prefs.remove(key);
      }
    }
    debugPrint("已成功自动清理所有本地目录缓存");
  } catch (e) {
    debugPrint("清理本地目录缓存异常: $e");
  }
}

/// 文件列表页面
class FilePage extends StatefulWidget {
  final int cardId;
  final String cardCode;
  final FileResponse response;

  const FilePage({
    super.key,
    required this.cardId,
    required this.cardCode,
    required this.response,
  });

  @override
  State<FilePage> createState() => FilePageState();
}

class FilePageState extends State<FilePage> with AutomaticKeepAliveClientMixin {
  final UserApi api = UserApi();

  late FileResponse response;
  bool loading = false;
  final Set<String> selectedIds = {};

  /// 请求序列号，用于防止异步竞态或旧请求晚到覆盖最新状态
  int _requestSeq = 0;

  // ==================== 搜索功能状态 ====================
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  /// 获取经过搜索词过滤后的当前目录文件列表
  List<FileModel> get filteredFiles {
    if (_searchQuery.trim().isEmpty) {
      return response.files;
    }
    final query = _searchQuery.trim().toLowerCase();
    return response.files
        .where((file) => file.name.toLowerCase().contains(query))
        .toList();
  }

  @override
  bool get wantKeepAlive => true;

  String _getCacheKey(String path) {
    return "dir_cache_${widget.cardCode}_$path";
  }

  StreamSubscription<String>? _eventSubscription;

  @override
  void initState() {
    super.initState();

    if (_globalLastCardCode != widget.cardCode) {
      _globalDirCache.clear();
      _globalLastCardCode = widget.cardCode;
    }

    final initialKey = _getCacheKey(widget.response.path);
    response = widget.response;
    _globalDirCache[initialKey] = response;
    _saveToPersistentCache(initialKey, response);

    _restoreFromPersistentCache(initialKey, expectedPath: widget.response.path);

    _eventSubscription = globalEventBus.stream.listen((event) {
      if (event == 'refresh_file_list') {
        if (mounted) {
          loadPath(response.path, forceRefresh: true);
        }
      }
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _saveToPersistentCache(
    String cacheKey,
    FileResponse data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(data.toJson());
      await prefs.setString(cacheKey, jsonString);
    } catch (e) {
      debugPrint("写入持久化缓存失败 [$cacheKey]: $e");
    }
  }

  Future<void> _restoreFromPersistentCache(
    String cacheKey, {
    required String expectedPath,
  }) async {
    final int seqAtStart = _requestSeq;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(cacheKey);
      if (jsonString != null && jsonString.isNotEmpty) {
        final Map<String, dynamic> jsonMap = jsonDecode(jsonString);
        final cachedResponse = FileResponse.fromJson(jsonMap);

        _globalDirCache[cacheKey] = cachedResponse;

        // 仅当未发生新的目录切换/加载，且当前仍停留在同一路径时才更新视图
        if (mounted &&
            seqAtStart == _requestSeq &&
            !loading &&
            response.path == expectedPath) {
          setState(() {
            response = cachedResponse;
          });
        }
      }
    } catch (e) {
      debugPrint("读取本地持久化缓存失败 [$cacheKey]: $e");
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(cacheKey);
      } catch (_) {}
    }
  }

  List<String> get currentBreadcrumbNames {
    return response.breadcrumbs.map((b) => b.name).toList();
  }

  List<String> _getBreadcrumbsForFile(
    FileModel file, {
    List<String>? baseBreadcrumbs,
  }) {
    final base = baseBreadcrumbs ?? currentBreadcrumbNames;
    return List<String>.from(base);
  }

  void toggleSelect(FileModel file) {
    // 根目录下不执行多选逻辑
    if (response.breadcrumbs.length <= 1) return;

    setState(() {
      if (selectedIds.contains(file.fsId)) {
        selectedIds.remove(file.fsId);
      } else {
        selectedIds.add(file.fsId);
      }
    });
  }

  void toggleSelectAll() {
    if (response.breadcrumbs.length <= 1) return;

    final currentList = filteredFiles;
    final allCurrentSelected =
        currentList.every((e) => selectedIds.contains(e.fsId));

    setState(() {
      if (allCurrentSelected) {
        for (var file in currentList) {
          selectedIds.remove(file.fsId);
        }
      } else {
        for (var file in currentList) {
          selectedIds.add(file.fsId);
        }
      }
    });
  }

  void _clearSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  Future<void> openDir(FileModel file) async {
    debugPrint(
      "[FilePage] openDir -> name=${file.name}, isDir=${file.isDir}, path=${file.path}, currentPath=${response.path}, loading=$loading",
    );
    if (!file.isDir) return;
    _clearSearch();
    await loadPath(file.path);
  }

  Future<void> loadPath(String path, {bool forceRefresh = false}) async {
    if (loading) {
      debugPrint("[FilePage] loadPath 跳过：当前正在加载，目标路径=$path");
      return;
    }

    final int seq = ++_requestSeq;
    final cacheKey = _getCacheKey(path);
    final String rootPath = "/转存/${widget.cardCode}";
    final bool isRootDir = (path == rootPath);

    debugPrint(
      "[FilePage] loadPath开始 -> seq=$seq, path=$path, forceRefresh=$forceRefresh, isRootDir=$isRootDir",
    );

    if (!forceRefresh && _globalDirCache.containsKey(cacheKey)) {
      if (!mounted || seq != _requestSeq) return;
      debugPrint("[FilePage] seq=$seq 命中内存缓存: $cacheKey");
      setState(() {
        response = _globalDirCache[cacheKey]!;
        selectedIds.clear();
      });
      return;
    }

    if (!forceRefresh) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final jsonString = prefs.getString(cacheKey);
        if (jsonString != null && jsonString.isNotEmpty) {
          final Map<String, dynamic> jsonMap = jsonDecode(jsonString);
          final cachedResponse = FileResponse.fromJson(jsonMap);

          _globalDirCache[cacheKey] = cachedResponse;
          if (!mounted || seq != _requestSeq) return;

          debugPrint("[FilePage] seq=$seq 命中磁盘缓存: $cacheKey");
          setState(() {
            response = cachedResponse;
            selectedIds.clear();
          });
          return;
        }
      } catch (e) {
        debugPrint("[FilePage] seq=$seq 解析磁盘缓存出错: $e");
      }
    }

    if (forceRefresh && !isRootDir) {
      if (_globalDirCache.containsKey(cacheKey)) {
        if (!mounted || seq != _requestSeq) return;
        debugPrint("[FilePage] seq=$seq forceRefresh 子目录使用本地缓存: $cacheKey");
        setState(() {
          response = _globalDirCache[cacheKey]!;
          selectedIds.clear();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('子目录已优先使用本地缓存')),
          );
        }
        return;
      }
    }

    if (!mounted || seq != _requestSeq) return;
    setState(() {
      loading = true;
    });

    try {
      final result = await api.getFiles(widget.cardCode, path: path);
      if (!mounted || seq != _requestSeq) {
        debugPrint("[FilePage] seq=$seq 请求返回时已过期或页面已销毁，丢弃结果");
        return;
      }

      debugPrint(
        "[FilePage] seq=$seq 接口返回成功 -> path=${result.path}, filesCount=${result.files.length}, breadcrumbsCount=${result.breadcrumbs.length}",
      );

      _globalDirCache[cacheKey] = result;
      _saveToPersistentCache(cacheKey, result);

      setState(() {
        response = result;
        selectedIds.clear();
      });
    } catch (e, stack) {
      debugPrint("[FilePage] seq=$seq 加载目录失败 [$path]: $e\n$stack");
      if (mounted && seq == _requestSeq) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载目录失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted && seq == _requestSeq) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> _onRefresh() async {
    if (loading) return;
    await loadPath(response.path, forceRefresh: true);
  }

  /// 递归获取指定目录下的所有文件（支持满 20 条边扫描边分批写入任务）
  Future<List>> _getAllFilesWithRelPath(
    String dirPath,
    List<String> parentBreadcrumbs, {
    List>? buffer,
    Future<void> Function(List> chunk)? onChunk,
  }) async {
    List> resultList = [];
    final currentBuffer = buffer ?? [];

    try {
      final res = await api.getFiles(widget.cardCode, path: dirPath);
      for (final item in res.files) {
        if (item.isDir) {
          final subBreadcrumbs = [...parentBreadcrumbs, item.name];
          final subFiles = await _getAllFilesWithRelPath(
            item.path,
            subBreadcrumbs,
            buffer: currentBuffer,
            onChunk: onChunk,
          );
          resultList.addAll(subFiles);
        } else {
          final itemData = {'file': item, 'breadcrumbs': parentBreadcrumbs};
          resultList.add(itemData);

          if (onChunk != null) {
            currentBuffer.add(itemData);
            if (currentBuffer.length >= 20) {
              final chunkToFlush = List>.from(currentBuffer);
              currentBuffer.clear();
              await onChunk(chunkToFlush);
            }
          }
        }
      }
    } catch (e) {
      debugPrint("递归获取目录文件失败 [$dirPath]: $e");
    }
    return resultList;
  }

  void _downloadSingleFile(FileModel file) {
    DownloadHelper.handleStartDownload(
      context: context,
      fsId: file.fsId,
      filename: file.name,
      size: file.size,
      cardId: widget.cardId,
      path: file.path,
      breadcrumbs: _getBreadcrumbsForFile(file),
    );
  }

  Future<void> _downloadSelected() async {
    if (selectedIds.isEmpty || loading) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认批量下载'),
        content: Text('确定要下载选中的 ${selectedIds.length} 项（包含文件夹及其所有子文件）吗？'),
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

    if (confirmed != true) return;

    setState(() => loading = true);

    int totalAdded = 0;
    List<String> allSkippedFiles = [];
    List> pendingBuffer = [];

    // 定义分批写入的私有回调（满 20 条时自动写入并通知）
    Future<void> flushChunk(List> chunkItems) async {
      if (chunkItems.isEmpty) return;

      final batchItems = chunkItems.map((item) {
        final FileModel fileModel = item['file'];
        final List<String> relBreadcrumbs = item['breadcrumbs'];

        return {
          'filename': fileModel.name,
          'path': fileModel.path,
          'size': fileModel.size,
          'fsId': fileModel.fsId,
          'cardId': widget.cardId,
          'breadcrumbs': relBreadcrumbs,
        };
      }).toList();

      final result = await DownloadManager.instance.addBatchTasks(
        batchItems,
        breadcrumbs: currentBreadcrumbNames,
      );

      totalAdded += result.addedCount;
      allSkippedFiles.addAll(result.skippedFiles);
    }

    try {
      for (final fsId in selectedIds) {
        final file = response.files.firstWhere((e) => e.fsId == fsId);

        if (file.isDir) {
          final folderBreadcrumbs = [...currentBreadcrumbNames, file.name];
          await _getAllFilesWithRelPath(
            file.path,
            folderBreadcrumbs,
            buffer: pendingBuffer,
            onChunk: flushChunk,
          );
        } else {
          pendingBuffer.add({
            'file': file,
            'breadcrumbs': currentBreadcrumbNames,
          });

          if (pendingBuffer.length >= 20) {
            final chunk = List>.from(pendingBuffer);
            pendingBuffer.clear();
            await flushChunk(chunk);
          }
        }
      }

      if (pendingBuffer.isNotEmpty) {
        await flushChunk(pendingBuffer);
        pendingBuffer.clear();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "已成功添加 $totalAdded 个下载任务，已忽略 ${allSkippedFiles.length} 个文件重复添加",
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('创建下载任务失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          selectedIds.clear();
        });
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  IconData _getFileIcon(FileModel file) {
    if (file.isDir) return Icons.folder_rounded;
    final ext = file.name.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'mov', 'avi', 'flv', 'wmv'].contains(ext)) {
      return Icons.video_file_rounded;
    }
    if (['mp3', 'flac', 'wav', 'aac', 'm4a'].contains(ext)) {
      return Icons.audio_file_rounded;
    }
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
      return Icons.image_rounded;
    }
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return Icons.folder_zip_rounded;
    }
    if (['pdf', 'doc', 'docx', 'txt', 'md'].contains(ext)) {
      return Icons.description_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  Color _getFileIconColor(FileModel file, ThemeData theme) {
    if (file.isDir) return Colors.amber.shade700;
    final ext = file.name.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) return Colors.deepOrange;
    if (['mp3', 'flac', 'wav'].contains(ext)) return Colors.purple;
    if (['jpg', 'jpeg', 'png', 'gif'].contains(ext)) return Colors.green;
    if (['zip', 'rar', '7z'].contains(ext)) return Colors.indigo;
    return theme.colorScheme.primary;
  }

  bool canGoBack() {
    return response.breadcrumbs.length > 1;
  }

  void goBack() {
    if (canGoBack() && !loading) {
      _clearSearch();
      final parentCr = response.breadcrumbs[response.breadcrumbs.length - 2];
      loadPath(parentCr.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final theme = Theme.of(context);
    final isSelecting = selectedIds.isNotEmpty;
    final displayFiles = filteredFiles;

    // 核心断定：是否位于根目录
    final bool isRootDir = response.breadcrumbs.length <= 1;

    final isAllSelectedInCurrent = displayFiles.isNotEmpty &&
        displayFiles.every((e) => selectedIds.contains(e.fsId));

    return PopScope(
      canPop: !canGoBack() && !_isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSearching) {
          _clearSearch();
        } else if (canGoBack()) {
          goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: canGoBack()
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_ios_rounded),
                  tooltip: "返回上一级",
                  onPressed: loading ? null : goBack,
                )
              : null,
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: "搜索当前目录下的文件...",
                    border: InputBorder.none,
                  ),
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                )
              : Text(
                  isSelecting ? "已选择 ${selectedIds.length} 项" : "我的文件",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
          actions: [
            if (_isSearching)
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: "关闭搜索",
                onPressed: _clearSearch,
              )
            else ...[
              IconButton(
                icon: const Icon(Icons.search_rounded),
                tooltip: "搜索当前目录",
                onPressed: () {
                  setState(() {
                    _isSearching = true;
                  });
                },
              ),
              if (isSelecting && !isRootDir)
                IconButton(
                  icon: Icon(
                    isAllSelectedInCurrent ? Icons.deselect : Icons.select_all,
                  ),
                  tooltip: isAllSelectedInCurrent ? "取消全选" : "全选",
                  onPressed: toggleSelectAll,
                ),
              IconButton(
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                        ),
                      )
                    : const Icon(Icons.refresh_rounded),
                tooltip: "刷新目录",
                onPressed: loading ? null : _onRefresh,
              ),
              IconButton(
                icon: const Icon(Icons.download_rounded),
                tooltip: "下载管理",
                onPressed: () {
                  Navigator.pushNamed(context, "/download");
                },
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: "设置",
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsPage()),
                  );
                },
              ),
            ],
          ],
        ),

        bottomNavigationBar: isSelecting
            ? AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 10,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "已选中 ${selectedIds.length} 个文件/文件夹",
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text("立即下载"),
                        onPressed: loading ? null : _downloadSelected,
                      ),
                    ],
                  ),
                ),
              )
            : null,

        body: Column(
          children: [
            _buildBreadcrumbsBar(theme),

            if (loading) const LinearProgressIndicator(minHeight: 2),

            Expanded(
              child: RefreshIndicator(
                onRefresh: loading ? () async {} : _onRefresh,
                child: displayFiles.isEmpty && !loading
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _searchQuery.isNotEmpty
                                      ? Icons.search_off_rounded
                                      : Icons.folder_open_rounded,
                                  size: 64,
                                  color: Colors.grey,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _searchQuery.isNotEmpty
                                      ? "未找到匹配的文件"
                                      : "文件夹为空",
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: displayFiles.length,
                        itemBuilder: (context, index) {
                          final file = displayFiles[index];
                          final selected = selectedIds.contains(file.fsId);

                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: Material(
                              color: selected
                                  ? theme.colorScheme.primaryContainer
                                      .withOpacity(0.4)
                                  : theme.cardColor,
                              borderRadius: BorderRadius.circular(12),
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: selected
                                        ? theme.colorScheme.primary
                                        : Colors.transparent,
                                    width: 1.5,
                                  ),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!isRootDir) ...[
                                      Checkbox(
                                        value: selected,
                                        activeColor: theme.colorScheme.primary,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        onChanged: (_) => toggleSelect(file),
                                      ),
                                    ],
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: _getFileIconColor(
                                          file,
                                          theme,
                                        ).withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        _getFileIcon(file),
                                        color: _getFileIconColor(file, theme),
                                        size: 26,
                                      ),
                                    ),
                                  ],
                                ),
                                title: Text(
                                  file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                                subtitle: Text(
                                  file.isDir ? "文件夹" : _formatSize(file.size),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: theme.textTheme.bodySmall?.color,
                                  ),
                                ),
                                onTap: () {
                                  if (isSelecting && !isRootDir) {
                                    toggleSelect(file);
                                  } else if (file.isDir) {
                                    openDir(file);
                                  } else {
                                    if (isRootDir) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('根目录文件暂不支持直接下载，请进入下一级目录操作'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    } else {
                                      _downloadSingleFile(file);
                                    }
                                  }
                                },
                                onLongPress: isRootDir ? null : () => toggleSelect(file),
                                trailing: file.isDir
                                    ? IconButton(
                                        icon: const Icon(
                                          Icons.chevron_right_rounded,
                                        ),
                                        onPressed:
                                            loading ? null : () => openDir(file),
                                      )
                                    : (isRootDir
                                        ? null
                                        : IconButton(
                                            icon: const Icon(
                                              Icons.file_download_outlined,
                                            ),
                                            color: theme.colorScheme.primary,
                                            onPressed: () =>
                                                _downloadSingleFile(file),
                                          )),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumbsBar(ThemeData theme) {
    return Container(
      height: 48,
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: response.breadcrumbs.length,
        itemBuilder: (context, index) {
          final b = response.breadcrumbs[index];
          final isLast = index == response.breadcrumbs.length - 1;

          return Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: (isLast || loading)
                    ? null
                    : () {
                        _clearSearch();
                        loadPath(b.path);
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    b.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                      color: isLast
                          ? theme.colorScheme.primary
                          : theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                ),
              ),
              if (!isLast)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Colors.grey.shade400,
                ),
            ],
          );
        },
      ),
    );
  }
}