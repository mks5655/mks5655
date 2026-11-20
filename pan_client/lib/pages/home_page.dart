import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/file_response.dart';
import '../utils/event_bus.dart';
import 'file_page.dart';
import 'transfer_page.dart';
import 'user_detail_page.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/user_api.dart';

class HomePage extends StatefulWidget {
  final int cardId;
  final String cardCode;
  final FileResponse response;

  const HomePage({
    super.key,
    required this.cardId,
    required this.cardCode,
    required this.response,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  final PageController _pageController = PageController();
  late final List<Widget> _pages;

  // 定义 _filePageKey 用于跟文件页内部通信
  final GlobalKey<FilePageState> _filePageKey = GlobalKey<FilePageState>();

  // 事件总线监听订阅对象
  StreamSubscription<String>? _eventSubscription;

  @override
  void initState() {
    super.initState();

    // 初始化底部导航的 3 个页面
    _pages = [
      FilePage(
        key: _filePageKey,
        cardId: widget.cardId,
        cardCode: widget.cardCode,
        response: widget.response,
      ),
      TransferPage(cardCode: widget.cardCode),
      UserDetailPage(cardId: widget.cardId, cardCode: widget.cardCode),
    ];

    // 💥 关键修复：监听转存成功事件，切页 + 显式触发 FilePage 强制刷新
    _eventSubscription = globalEventBus.stream.listen((event) {
      if (event == 'refresh_file_list') {
        if (mounted) {
          // 1. 切换回文件页面 (Tab 0)
          _onBottomTabTapped(0);

          // 2. 延迟到下一帧，确保 PageView 页面切回后直接通过 GlobalKey 驱动 FilePage 强制刷新
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final filePageState = _filePageKey.currentState;
            if (filePageState != null) {
              final currentPath = filePageState.response.path;
              // 强制向服务端请求最新文件列表
              filePageState.loadPath(currentPath, forceRefresh: true);
            }
          });
        }
      }
    });

    // 页面首帧渲染完成后自动执行检查与初始切换
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 1. 如果登录后默认文件列表为空，自动切换到转存页面 (Tab 1)
      if (widget.response.files.isEmpty) {
        _onBottomTabTapped(1);
      }

      // 2. 只有安卓才检查电池优化
      if (Platform.isAndroid) {
        _checkAndRequestBatteryOptimization();
      }

      // 3. 检查 App 版本更新（所有平台通用）
      _checkAppVersion();
    });
  }

  /// 检查并请求忽略电池优化
  Future<void> _checkAndRequestBatteryOptimization() async {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("开启后台保持"),
        content: const Text("为了保证文件在息屏或切到后台时能持续下载，建议允许应用忽略电池优化。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                const platform = MethodChannel('com.mksha.pan_client/battery');
                await platform.invokeMethod('openBatteryOptimizationSettings');
              } catch (_) {}
            },
            child: const Text("去设置"),
          ),
        ],
      ),
    );
  }

  /// 检查 App 版本与强制更新逻辑
  Future<void> _checkAppVersion() async {
    if (!mounted) return;
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version;

      final remoteData = await UserApi().getSystemVersion();

      String latestVersion = remoteData['latest_version'] ?? '1.0.0';
      String minSupportVersion = remoteData['min_support_version'] ?? '1.0.0';
      String updateUrl = remoteData['update_url'] ?? '';
      String updateLog = remoteData['update_log'] ?? '';
      bool forceUpdate = remoteData['force_update'] ?? false;

      if (_isVersionOlder(currentVersion, minSupportVersion) || forceUpdate) {
        _showUpdateDialog(latestVersion, updateLog, updateUrl, isForce: true);
      } else if (_isVersionOlder(currentVersion, latestVersion)) {
        _showUpdateDialog(latestVersion, updateLog, updateUrl, isForce: false);
      }
    } catch (e) {
      debugPrint("检查更新出错: $e");
    }
  }

  /// 辅助方法：比较版本号大小
  bool _isVersionOlder(String current, String target) {
    List<int> cParts = current
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    List<int> tParts = target
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    while (cParts.length < 3) cParts.add(0);
    while (tParts.length < 3) tParts.add(0);

    for (int i = 0; i < 3; i++) {
      if (cParts[i] < tParts[i]) return true;
      if (cParts[i] > tParts[i]) return false;
    }
    return false;
  }

  /// 展示更新弹窗
  void _showUpdateDialog(
    String version,
    String log,
    String url, {
    required bool isForce,
  }) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: !isForce,
      builder: (BuildContext context) {
        return PopScope(
          canPop: !isForce,
          child: AlertDialog(
            title: Text(isForce ? '发现重要安全更新' : '发现新版本 ($version)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '更新日志：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(log),
              ],
            ),
            actions: [
              if (!isForce)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '以后再说',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  final Uri uri = Uri.parse(url);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: const Text('立即下载更新'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _onBottomTabTapped(int index) {
    setState(() => _currentIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (_currentIndex == 0) {
          final filePageState = _filePageKey.currentState;
          if (filePageState != null && filePageState.canGoBack()) {
            filePageState.goBack();
            return;
          }
        }

        try {
          const platform = MethodChannel('com.mksha.pan_client/battery');
          await platform.invokeMethod('moveTaskToBack');
        } catch (_) {
          SystemChannels.platform.invokeMethod('SystemNavigator.pop');
        }
      },
      child: Scaffold(
        body: PageView(
          controller: _pageController,
          onPageChanged: (index) => setState(() => _currentIndex = index),
          physics: const BouncingScrollPhysics(),
          children: _pages,
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _onBottomTabTapped,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
          unselectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.folder_outlined),
              activeIcon: Icon(Icons.folder),
              label: '文件',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.swap_horiz_outlined),
              activeIcon: Icon(Icons.swap_horiz),
              label: '转存',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
