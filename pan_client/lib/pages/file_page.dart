import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/user_api.dart';
import '../download/download_manager.dart';
import '../models/download_task.dart';
import '../models/file_model.dart';
import '../models/file_response.dart';
import '../utils/download_helper.dart';
import '../utils/event_bus.dart';
import 'settings_page.dart';

/// ============================================================
/// 全局目录缓存
/// ============================================================

/// L1 内存缓存
/// 使用 cardCode + path 隔离不同卡券的目录数据。
final Map<String, FileResponse> _globalDirCache = {};

/// 当前全局缓存所属卡券
String? _globalLastCardCode;

/// 清理全部目录缓存
Future<void> clearAllDirCache() async {
  _globalDirCache.clear();
  _globalLastCardCode = null;

  try {
    final prefs = await SharedPreferences.getInstance();

    for (final key in prefs.getKeys()) {
      if (key.startsWith('dir_cache_')) {
        await prefs.remove(key);
      }
    }

    debugPrint('已清理所有目录缓存');
  } catch (e) {
    debugPrint('清理目录缓存失败: $e');
  }
}


/// ============================================================
/// 文件列表页面
/// ============================================================

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


class FilePageState extends State<FilePage>
    with AutomaticKeepAliveClientMixin {

  final UserApi api = UserApi();

  late FileResponse response;

  /// 页面加载状态
  bool loading = false;

  /// 是否正在执行批量下载
  bool _batchDownloading = false;

  /// 已选中的文件 ID
  final Set<String> selectedIds = {};

  /// ============================================================
  /// 目录导航请求控制
  /// ============================================================

  /// 每次导航请求都会递增。
  ///
  /// 如果用户连续点击不同文件夹：
  /// A 请求编号 = 1
  /// B 请求编号 = 2
  ///
  /// 即使 A 最后才返回，也不能覆盖 B 的结果。
  int _navigationRequestId = 0;

  /// ============================================================
  /// 搜索状态
  /// ============================================================

  bool _isSearching = false;

  String _searchQuery = '';

  final TextEditingController _searchController =
      TextEditingController();

  StreamSubscription<String>? _eventSubscription;


  /// 搜索过滤后的文件
  List<FileModel> get filteredFiles {
    if (_searchQuery.trim().isEmpty) {
      return response.files;
    }

    final query = _searchQuery.trim().toLowerCase();

    return response.files.where((file) {
      return file.name.toLowerCase().contains(query);
    }).toList();
  }


  @override
  bool get wantKeepAlive => true;


  /// ============================================================
  /// 缓存管理
  /// ============================================================

  String _getCacheKey(String path) {
    return 'dir_cache_${widget.cardCode}_$path';
  }


  @override
  void initState() {
    super.initState();

    /// 切换卡券时清空其他卡券的内存缓存
    if (_globalLastCardCode != widget.cardCode) {
      _globalDirCache.clear();
      _globalLastCardCode = widget.cardCode;
    }

    response = widget.response;

    /// 保存初始目录缓存
    final initialKey = _getCacheKey(response.path);

    _globalDirCache[initialKey] = response;

    _saveToPersistentCache(initialKey, response);

    /// 异步读取磁盘缓存，只填充缓存，不允许覆盖当前页面数据
    _restoreFromPersistentCache(initialKey);

    /// 监听全局刷新事件
    _eventSubscription = globalEventBus.stream.listen((event) {
      if (event == 'refresh_file_list') {
        if (mounted && !_batchDownloading) {
          loadPath(
            response.path,
            forceRefresh: true,
          );
        }
      }
    });
  }


  @override
  void dispose() {
    /// 使所有尚未返回的导航请求失效
    _navigationRequestId++;

    _eventSubscription?.cancel();

    _searchController.dispose();

    super.dispose();
  }


  /// 保存目录到磁盘缓存
  Future<void> _saveToPersistentCache(
    String cacheKey,
    FileResponse data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final jsonString = jsonEncode(data.toJson());

      await prefs.setString(cacheKey, jsonString);

    } catch (e) {
      debugPrint('写入目录缓存失败 [$cacheKey]: $e');
    }
  }


  /// 恢复磁盘缓存
  ///
  /// 注意：
  /// 这里只恢复到 L1 内存缓存。
  /// 不直接修改 response，避免异步缓存覆盖当前页面。
  Future<void> _restoreFromPersistentCache(
    String cacheKey,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final jsonString = prefs.getString(cacheKey);

      if (jsonString == null || jsonString.isEmpty) {
        return;
      }

      final Map<String, dynamic> jsonMap =
          jsonDecode(jsonString);

      final cachedResponse =
          FileResponse.fromJson(jsonMap);

      if (mounted && widget.cardCode == _globalLastCardCode) {
        _globalDirCache[cacheKey] = cachedResponse;
      }

    } catch (e) {
      debugPrint('读取目录缓存失败 [$cacheKey]: $e');

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(cacheKey);
      } catch (_) {}
    }
  }


  /// ============================================================
  /// 面包屑
  /// ============================================================

  List<String> get currentBreadcrumbNames {
    return response.breadcrumbs
        .map((b) => b.name)
        .toList();
  }


  List<String> _getBreadcrumbsForFile(
    FileModel file, {
    List<String>? baseBreadcrumbs,
  }) {
    final base = baseBreadcrumbs ?? currentBreadcrumbNames;

    return List<String>.from(base);
  }


  /// ============================================================
  /// 多选功能
  /// ============================================================

  void toggleSelect(FileModel file) {
    if (response.breadcrumbs.length <= 1) {
      return;
    }

    setState(() {
      if (selectedIds.contains(file.fsId)) {
        selectedIds.remove(file.fsId);
      } else {
        selectedIds.add(file.fsId);
      }
    });
  }


  void toggleSelectAll() {
    if (response.breadcrumbs.length <= 1) {
      return;
    }

    final currentList = filteredFiles;

    final allCurrentSelected = currentList.every(
      (e) => selectedIds.contains(e.fsId),
    );

    setState(() {
      if (allCurrentSelected) {
        for (final file in currentList) {
          selectedIds.remove(file.fsId);
        }
      } else {
        for (final file in currentList) {
          selectedIds.add(file.fsId);
        }
      }
    });
  }


  /// ============================================================
  /// 搜索功能
  /// ============================================================

  void _clearSearch() {
    if (!mounted) return;

    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
  }


  /// ============================================================
  /// 进入文件夹
  /// ============================================================

  Future<void> openDir(FileModel file) async {

    debugPrint('========== 文件夹导航 ==========');

    debugPrint('文件夹名称: ${file.name}');
    debugPrint('文件夹路径: ${file.path}');
    debugPrint('是否文件夹: ${file.isDir}');
    debugPrint('当前目录: ${response.path}');
    debugPrint('当前加载状态: $loading');

    if (!file.isDir) {
      debugPrint('目标不是文件夹');
      return;
    }

    /// 批量下载期间禁止切换目录
    if (_batchDownloading) {
      debugPrint('批量下载期间禁止导航');
      return;
    }

    _clearSearch();

    /// 不在这里判断 loading。
    ///
    /// 允许用户连续点击不同目录，
    /// 由 loadPath 的请求序号保证最终结果正确。
    await loadPath(file.path);
  }


  /// ============================================================
  /// 核心目录加载方法
  /// ============================================================

  Future<void> loadPath(
    String path, {
    bool forceRefresh = false,
  }) async {

    if (!mounted) return;

    if (_batchDownloading) {
      return;
    }

    /// 每次请求生成独立编号
    final requestId = ++_navigationRequestId;

    final cacheKey = _getCacheKey(path);

    debugPrint('========== loadPath ==========');
    debugPrint('目标目录: $path');
    debugPrint('强制刷新: $forceRefresh');
    debugPrint('请求编号: $requestId');

    /// ------------------------------------------------------------
    /// 1. 普通进入目录，优先读取内存缓存
    /// ------------------------------------------------------------

    if (!forceRefresh) {

      final memoryCache = _globalDirCache[cacheKey];

      if (memoryCache != null) {

        if (!mounted || requestId != _navigationRequestId) {
          return;
        }

        debugPrint('命中 L1 内存缓存: $path');

        setState(() {
          response = memoryCache;
          loading = false;
          selectedIds.clear();
        });

        return;
      }
    }


    /// ------------------------------------------------------------
    /// 2. 普通进入目录，尝试读取磁盘缓存
    /// ------------------------------------------------------------

    if (!forceRefresh) {

      try {
        final prefs = await SharedPreferences.getInstance();

        /// 等待磁盘缓存时，用户可能已经点击了其他目录
        if (!mounted || requestId != _navigationRequestId) {
          return;
        }

        final jsonString = prefs.getString(cacheKey);

        if (jsonString != null && jsonString.isNotEmpty) {

          try {
            final Map<String, dynamic> jsonMap =
                jsonDecode(jsonString);

            final cachedResponse =
                FileResponse.fromJson(jsonMap);

            _globalDirCache[cacheKey] = cachedResponse;

            debugPrint('命中 L2 磁盘缓存: $path');

            setState(() {
              response = cachedResponse;
              loading = false;
              selectedIds.clear();
            });

            return;

          } catch (e) {
            debugPrint('磁盘缓存解析失败: $e');

            await prefs.remove(cacheKey);
          }
        }

      } catch (e) {
        debugPrint('读取磁盘缓存异常: $e');
      }
    }


    /// ------------------------------------------------------------
    /// 3. 检查当前请求是否仍然有效
    /// ------------------------------------------------------------

    if (!mounted || requestId != _navigationRequestId) {
      return;
    }


    /// ------------------------------------------------------------
    /// 4. 开始请求服务器
    /// ------------------------------------------------------------

    setState(() {
      loading = true;
    });

    try {

      debugPrint('开始请求服务器: $path');

      final result = await api.getFiles(
        widget.cardCode,
        path: path,
      );


      /// ----------------------------------------------------------
      /// 核心：防止旧请求覆盖新请求
      /// ----------------------------------------------------------

      if (!mounted || requestId != _navigationRequestId) {

        debugPrint('旧请求已失效，不更新页面');

        return;
      }


      /// ----------------------------------------------------------
      /// 5. 保存缓存
      /// ----------------------------------------------------------

      _globalDirCache[cacheKey] = result;

      _saveToPersistentCache(cacheKey, result);


      /// ----------------------------------------------------------
      /// 6. 更新页面
      /// ----------------------------------------------------------

      setState(() {
        response = result;
        selectedIds.clear();
      });

      debugPrint('目录加载成功: ${result.path}');

    } catch (e) {

      /// 只有最新请求才显示错误
      if (mounted && requestId == _navigationRequestId) {

        debugPrint('目录加载失败: $e');

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载目录失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }

    } finally {

      /// 旧请求不能修改新请求的 loading 状态
      if (mounted && requestId == _navigationRequestId) {

        setState(() {
          loading = false;
        });

      }
    }
  }


  /// ============================================================
  /// 下拉刷新
  /// ============================================================

  Future<void> _onRefresh() async {

    if (_batchDownloading) return;

    await loadPath(
      response.path,
      forceRefresh: true,
    );
  }


  /// ============================================================
  /// 递归获取目录文件
  /// ============================================================

  Future<List<Map<String, dynamic>>> _getAllFilesWithRelPath(
    String dirPath,
    List<String> parentBreadcrumbs, {
    List<Map<String, dynamic>>? buffer,
    Future<void> Function(List<Map<String, dynamic>> chunk)? onChunk,
  }) async {

    final List<Map<String, dynamic>> resultList = [];

    final currentBuffer = buffer ?? [];

    try {

      final res = await api.getFiles(
        widget.cardCode,
        path: dirPath,
      );

      for (final item in res.files) {

        if (item.isDir) {

          final subBreadcrumbs = [
            ...parentBreadcrumbs,
            item.name,
          ];

          final subFiles = await _getAllFilesWithRelPath(
            item.path,
            subBreadcrumbs,
            buffer: currentBuffer,
            onChunk: onChunk,
          );

          resultList.addAll(subFiles);

        } else {

          final itemData = {
            'file': item,
            'breadcrumbs': parentBreadcrumbs,
          };

          resultList.add(itemData);

          if (onChunk != null) {

            currentBuffer.add(itemData);

            /// 每 20 个文件批量写入一次
            if (currentBuffer.length >= 20) {

              final chunkToFlush =
                  List<Map<String, dynamic>>.from(currentBuffer);

              currentBuffer.clear();

              await onChunk(chunkToFlush);
            }
          }
        }
      }

    } catch (e) {

      debugPrint('递归获取目录文件失败 [$dirPath]: $e');

    }

    return resultList;
  }


  /// ============================================================
  /// 单文件下载
  /// ============================================================

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


  /// ============================================================
  /// 批量下载
  /// ============================================================

  Future<void> _downloadSelected() async {

    if (selectedIds.isEmpty || loading || _batchDownloading) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认批量下载'),
        content: Text(
          '确定要下载选中的 ${selectedIds.length} 项（包含文件夹及其所有子文件）吗？',
        ),
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

    if (confirmed != true || !mounted) {
      return;
    }


    /// 固定当前选中项，避免后续状态变化影响任务
    final selectedSnapshot = Set<String>.from(selectedIds);

    setState(() {
      loading = true;
      _batchDownloading = true;
    });


    int totalAdded = 0;

    final List<String> allSkippedFiles = [];

    final List<Map<String, dynamic>> pendingBuffer = [];


    /// 分批写入任务
    Future<void> flushChunk(
      List<Map<String, dynamic>> chunkItems,
    ) async {

      if (chunkItems.isEmpty) return;

      final batchItems = chunkItems.map((item) {

        final FileModel fileModel = item['file'];

        final List<String> relBreadcrumbs =
            List<String>.from(item['breadcrumbs']);

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

      for (final fsId in selectedSnapshot) {

        final file = response.files.firstWhere(
          (e) => e.fsId == fsId,
        );


        if (file.isDir) {

          final folderBreadcrumbs = [
            ...currentBreadcrumbNames,
            file.name,
          ];

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

            final chunk =
                List<Map<String, dynamic>>.from(pendingBuffer);

            pendingBuffer.clear();

            await flushChunk(chunk);
          }
        }
      }


      /// 写入剩余任务
      if (pendingBuffer.isNotEmpty) {

        await flushChunk(
          List<Map<String, dynamic>>.from(pendingBuffer),
        );

        pendingBuffer.clear();
      }


      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已成功添加 $totalAdded 个下载任务，'
              '已忽略 ${allSkippedFiles.length} 个重复文件',
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
          _batchDownloading = false;
          selectedIds.clear();
        });
      }
    }
  }


  /// ============================================================
  /// 文件信息
  /// ============================================================

  String _formatSize(int bytes) {

    if (bytes <= 0) return '0 B';

    const suffixes = [
      'B',
      'KB',
      'MB',
      'GB',
      'TB',
    ];

    final i = (log(bytes) / log(1024)).floor();

    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }


  IconData _getFileIcon(FileModel file) {

    if (file.isDir) {
      return Icons.folder_rounded;
    }

    final ext = file.name.split('.').last.toLowerCase();

    if ([
      'mp4',
      'mkv',
      'mov',
      'avi',
      'flv',
      'wmv',
    ].contains(ext)) {
      return Icons.video_file_rounded;
    }

    if ([
      'mp3',
      'flac',
      'wav',
      'aac',
      'm4a',
    ].contains(ext)) {
      return Icons.audio_file_rounded;
    }

    if ([
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
    ].contains(ext)) {
      return Icons.image_rounded;
    }

    if ([
      'zip',
      'rar',
      '7z',
      'tar',
      'gz',
    ].contains(ext)) {
      return Icons.folder_zip_rounded;
    }

    if ([
      'pdf',
      'doc',
      'docx',
      'txt',
      'md',
    ].contains(ext)) {
      return Icons.description_rounded;
    }

    return Icons.insert_drive_file_rounded;
  }


  Color _getFileIconColor(
    FileModel file,
    ThemeData theme,
  ) {

    if (file.isDir) {
      return Colors.amber.shade700;
    }

    final ext = file.name.split('.').last.toLowerCase();

    if ([
      'mp4',
      'mkv',
      'mov',
      'avi',
    ].contains(ext)) {
      return Colors.deepOrange;
    }

    if ([
      'mp3',
      'flac',
      'wav',
    ].contains(ext)) {
      return Colors.purple;
    }

    if ([
      'jpg',
      'jpeg',
      'png',
      'gif',
    ].contains(ext)) {
      return Colors.green;
    }

    if ([
      'zip',
      'rar',
      '7z',
    ].contains(ext)) {
      return Colors.indigo;
    }

    return theme.colorScheme.primary;
  }


  /// ============================================================
  /// 返回上一级
  /// ============================================================

  bool canGoBack() {
    return response.breadcrumbs.length > 1;
  }


  void goBack() {

    if (!canGoBack() || _batchDownloading) {
      return;
    }

    _clearSearch();

    final parentCr = response.breadcrumbs[
      response.breadcrumbs.length - 2
    ];

    loadPath(parentCr.path);
  }


  /// ============================================================
  /// 页面 UI
  /// ============================================================

  @override
  Widget build(BuildContext context) {

    super.build(context);

    final theme = Theme.of(context);

    final isSelecting = selectedIds.isNotEmpty;

    final displayFiles = filteredFiles;

    /// 根目录判断
    final bool isRootDir =
        response.breadcrumbs.length <= 1;

    final isAllSelectedInCurrent =
        displayFiles.isNotEmpty &&
        displayFiles.every(
          (e) => selectedIds.contains(e.fsId),
        );


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

        /// ======================================================
        /// AppBar
        /// ======================================================

        appBar: AppBar(

          leading: canGoBack()

              ? IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_rounded,
                  ),
                  tooltip: '返回上一级',
                  onPressed: loading || _batchDownloading
                      ? null
                      : goBack,
                )

              : null,


          title: _isSearching

              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索当前目录下的文件...',
                    border: InputBorder.none,
                  ),
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                )

              : Text(
                  isSelecting
                      ? '已选择 ${selectedIds.length} 项'
                      : '我的文件',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),


          actions: [

            if (_isSearching)

              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭搜索',
                onPressed: _clearSearch,
              )

            else ...[

              /// 搜索
              IconButton(
                icon: const Icon(Icons.search_rounded),
                tooltip: '搜索当前目录',
                onPressed: () {
                  setState(() {
                    _isSearching = true;
                  });
                },
              ),


              /// 全选
              if (isSelecting && !isRootDir)

                IconButton(
                  icon: Icon(
                    isAllSelectedInCurrent
                        ? Icons.deselect
                        : Icons.select_all,
                  ),
                  tooltip: isAllSelectedInCurrent
                      ? '取消全选'
                      : '全选',
                  onPressed: toggleSelectAll,
                ),


              /// 刷新
              IconButton(
                icon: loading

                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(
                            Colors.grey,
                          ),
                        ),
                      )

                    : const Icon(Icons.refresh_rounded),

                tooltip: '刷新目录',

                onPressed: loading || _batchDownloading
                    ? null
                    : _onRefresh,
              ),


              /// 下载管理
              IconButton(
                icon: const Icon(Icons.download_rounded),
                tooltip: '下载管理',
                onPressed: () {
                  Navigator.pushNamed(
                    context,
                    '/download',
                  );
                },
              ),


              /// 设置
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '设置',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
                },
              ),
            ],
          ],
        ),


        /// ======================================================
        /// 底部批量下载栏
        /// ======================================================

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
                          '已选中 ${selectedIds.length} 个文件/文件夹',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      ElevatedButton.icon(

                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              theme.colorScheme.primary,
                          foregroundColor:
                              theme.colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),

                        icon: const Icon(
                          Icons.download_rounded,
                        ),

                        label: const Text('立即下载'),

                        onPressed: loading || _batchDownloading
                            ? null
                            : _downloadSelected,
                      ),
                    ],
                  ),
                ),
              )

            : null,


        /// ======================================================
        /// 页面主体
        /// ======================================================

        body: Column(
          children: [

            /// 面包屑
            _buildBreadcrumbsBar(theme),


            /// 加载进度条
            if (loading)
              const LinearProgressIndicator(
                minHeight: 2,
              ),


            Expanded(

              child: RefreshIndicator(

                onRefresh: loading || _batchDownloading
                    ? () async {}
                    : _onRefresh,

                child: displayFiles.isEmpty && !loading

                    ? ListView(
                        physics:
                            const AlwaysScrollableScrollPhysics(),

                        children: [

                          const SizedBox(height: 120),

                          Center(
                            child: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,

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
                                      ? '未找到匹配的文件'
                                      : '文件夹为空',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )


                    : ListView.builder(

                        physics:
                            const AlwaysScrollableScrollPhysics(),

                        padding: const EdgeInsets.only(
                          bottom: 24,
                        ),

                        itemCount: displayFiles.length,

                        itemBuilder: (context, index) {

                          final file = displayFiles[index];

                          final selected =
                              selectedIds.contains(file.fsId);


                          return Padding(

                            padding:
                                const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),

                            child: Material(

                              color: selected
                                  ? theme.colorScheme
                                      .primaryContainer
                                      .withOpacity(0.4)
                                  : theme.cardColor,

                              borderRadius:
                                  BorderRadius.circular(12),

                              clipBehavior: Clip.antiAlias,


                              child: ListTile(

                                shape:
                                    RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: selected
                                        ? theme.colorScheme.primary
                                        : Colors.transparent,
                                    width: 1.5,
                                  ),
                                ),


                                contentPadding:
                                    const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),


                                /// 左侧图标和复选框
                                leading: Row(

                                  mainAxisSize: MainAxisSize.min,

                                  children: [

                                    if (!isRootDir) ...[

                                      Checkbox(

                                        value: selected,

                                        activeColor:
                                            theme.colorScheme.primary,

                                        shape:
                                            RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),

                                        onChanged: _batchDownloading
                                            ? null
                                            : (_) => toggleSelect(file),
                                      ),
                                    ],


                                    Container(

                                      padding:
                                          const EdgeInsets.all(8),

                                      decoration: BoxDecoration(
                                        color: _getFileIconColor(
                                          file,
                                          theme,
                                        ).withOpacity(0.12),

                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),

                                      child: Icon(
                                        _getFileIcon(file),
                                        color: _getFileIconColor(
                                          file,
                                          theme,
                                        ),
                                        size: 26,
                                      ),
                                    ),
                                  ],
                                ),


                                /// 文件名
                                title: Text(
                                  file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),


                                /// 文件大小
                                subtitle: Text(
                                  file.isDir
                                      ? '文件夹'
                                      : _formatSize(file.size),

                                  style: TextStyle(
                                    fontSize: 13,
                                    color: theme.textTheme
                                        .bodySmall?.color,
                                  ),
                                ),


                                /// ==================================================
                                /// 核心修复：点击事件
                                /// ==================================================

                                onTap: _batchDownloading
                                    ? null
                                    : () {

                                        /// 1. 文件夹始终优先进入目录
                                        ///
                                        /// 不再受多选状态影响
                                        if (file.isDir) {
                                          openDir(file);
                                          return;
                                        }


                                        /// 2. 非根目录下的多选状态
                                        if (isSelecting &&
                                            !isRootDir) {
                                          toggleSelect(file);
                                          return;
                                        }


                                        /// 3. 根目录文件保护
                                        if (isRootDir) {

                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                '根目录文件暂不支持直接下载，请进入下一级目录操作',
                                              ),
                                              duration:
                                                  Duration(seconds: 2),
                                            ),
                                          );

                                          return;
                                        }


                                        /// 4. 下载文件
                                        _downloadSingleFile(file);
                                      },


                                /// 长按选择
                                onLongPress: isRootDir ||
                                        _batchDownloading
                                    ? null
                                    : () => toggleSelect(file),


                                /// 右侧按钮
                                trailing: file.isDir

                                    ? IconButton(
                                        icon: const Icon(
                                          Icons.chevron_right_rounded,
                                        ),
                                        onPressed: _batchDownloading
                                            ? null
                                            : () => openDir(file),
                                      )

                                    : (isRootDir

                                        ? null

                                        : IconButton(
                                            icon: const Icon(
                                              Icons.file_download_outlined,
                                            ),
                                            color:
                                                theme.colorScheme.primary,
                                            onPressed: _batchDownloading
                                                ? null
                                                : () => _downloadSingleFile(
                                                    file,
                                                  ),
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


  /// ============================================================
  /// 面包屑导航栏
  /// ============================================================

  Widget _buildBreadcrumbsBar(ThemeData theme) {

    return Container(

      height: 48,

      width: double.infinity,

      color: theme.colorScheme
          .surfaceContainerHighest
          .withOpacity(0.3),

      child: ListView.builder(

        scrollDirection: Axis.horizontal,

        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),

        itemCount: response.breadcrumbs.length,

        itemBuilder: (context, index) {

          final b = response.breadcrumbs[index];

          final isLast =
              index == response.breadcrumbs.length - 1;


          return Row(
            children: [

              InkWell(

                borderRadius:
                    BorderRadius.circular(8),

                onTap: isLast || _batchDownloading
                    ? null
                    : () {

                        _clearSearch();

                        /// 面包屑导航同样使用请求序号控制
                        loadPath(b.path);
                      },


                child: Padding(

                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),

                  child: Text(

                    b.name,

                    style: TextStyle(
                      fontSize: 14,

                      fontWeight: isLast
                          ? FontWeight.bold
                          : FontWeight.normal,

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