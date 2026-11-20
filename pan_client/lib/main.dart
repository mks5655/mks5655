import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'pages/login_page.dart';
import 'pages/download_page.dart';
import 'pages/settings_page.dart';
import 'settings/settings_manager.dart';
import 'services/mihomo_service.dart';
import 'download/download_manager.dart';
import 'services/traffic_reporter.dart';
import 'services/global_error_handler.dart';
import 'pages/file_page.dart';

import 'services/proxy/baidu_proxy_service.dart';

// 定义全局 Navigator Key，供非 Widget 节点（如全局回调）触发路由跳转与弹窗
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 全局处理卡密异常强退与清除本地缓存的函数
/// 全局处理卡密异常强退与清除本地缓存的函数
void handleAuthErrorAndLogout(String errorMessage) async {
  print("=== [Auth] 触发全局强退逻辑，原因: $errorMessage ===");

  // 1. 清理本地存储的卡密信息
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_card_code');

  // 2. 暂停所有当前正在进行的下载任务，防止后台继续消耗流量/请求
  await DownloadManager.instance.pauseAll();

  // 3. 获取当前全局 Context 弹出强制提示框并返回登录界面
  final context = navigatorKey.currentContext;
  if (context != null && context.mounted) {
    showDialog(
      context: context,
      barrierDismissible: false, // 阻止点击外部灰色遮罩层关闭
      builder: (dialogContext) => PopScope(
        canPop: false, // 核心修复：彻底阻止侧滑手势返回和物理 Back 键关闭弹窗
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          // 用户尝试划退时可在此处提示或静默忽略
        },
        child: AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red),
              SizedBox(width: 8),
              Text('账号凭证异常'),
            ],
          ),
          content: Text(
            errorMessage.isNotEmpty ? errorMessage : '您的卡密已被禁用或过期，请重新登录。',
            style: const TextStyle(fontSize: 15),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                // 点击确认后，关闭弹窗并跳转回登录页，同时清空路由历史
                Navigator.of(dialogContext).pop();
                navigatorKey.currentState?.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                  (route) => false,
                );
              },
              child: const Text('确定并重新登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class AppHttpOverrides extends HttpOverrides {
  final String host;
  final int port;

  static const String proxyHost = '127.0.0.1';
  static const int proxyPort = 56558;

  AppHttpOverrides({this.host = '127.0.0.1', required this.port});

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);

    client.findProxy = (uri) {
      if (uri.host.contains('mtd.dpdns.org')) {
        return 'PROXY $proxyHost:$proxyPort; DIRECT';
      }
      return 'SOCKS5 $host:$port; SOCKS $host:$port';
    };

    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (cert, host, port) => true;

    return client;
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 重启软件时自动清空本地目录缓存
  await clearAllDirCache();
  // 直接启动，占用 7890 端口，完美接管原本指向 Mihomo 的流量
  await BaiduProxyService().start();

  // 绑定制定的卡密错误回调
  onAuthError = handleAuthErrorAndLogout;

  // 1. 检查是否是由后台服务 Isolate 触发的启动（仅安卓/苹果生效）
  if (Platform.isAndroid || Platform.isIOS) {
    if (args.contains('_flutter_background_service_')) {
      await SettingsManager.instance.init();
      await DownloadManager.instance.loadTasksFromLocal();
      return;
    }
  }

  // 2. 将整个主 App 的初始化与启动包裹在 GlobalErrorHandler 中
  GlobalErrorHandler.init(
    builder: () async {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await windowManager.ensureInitialized();
        windowManager.waitUntilReadyToShow(null, () async {
          await windowManager.setPreventClose(true);
        });
      }

      if (Platform.isAndroid) {
        await initializeBackgroundService();
      }

      HttpOverrides.global = AppHttpOverrides(host: '127.0.0.1', port: 56558);

      await SettingsManager.instance.init();
      await MihomoService.start();
      await DownloadManager.instance.loadTasksFromLocal();

      final prefs = await SharedPreferences.getInstance();
      final String currentCardCode = prefs.getString('saved_card_code') ?? '';

      if (currentCardCode.isNotEmpty) {
        print("=== [main] 成功读取本地卡密，初始化流量统计服务 ===");

        final reporter = TrafficReporter(
          serverUrl: "https://baidu-pan.mtd.dpdns.org",
          cardCode: currentCardCode,
        );
        reporter.checkAndReport();

        DownloadManager.instance.updateTrafficReporter(
          serverUrl: "https://baidu-pan.mtd.dpdns.org",
          cardCode: currentCardCode,
        );
      } else {
        print("=== [main] 本地无缓存卡密，跳过流量统计初始化，等待用户登录 ===");
      }

      return const MyApp();
    },
  );
}

Future<void> initializeBackgroundService() async {
  if (!Platform.isAndroid) return;

  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'download_service_channel',
    '后台下载服务',
    description: '用于保持网盘客户端后台下载任务正常运行',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundService,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'download_service_channel',
      initialNotificationTitle: '网盘客户端',
      initialNotificationContent: '后台下载服务运行中...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartBackgroundService,
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  PlatformDispatcher.instance.onError = (error, stack) {
    print("=== [后台 Isolate 错误] $error ===");
    return true;
  };

  await SettingsManager.instance.init();
  await DownloadManager.instance.loadTasksFromLocal();

  service.on('start_download').listen((event) {
    if (event != null) {
      final String? taskId = event['taskId'];
      print("=== [后台服务] 收到 UI 指令，开始下载任务: $taskId ===");
    }
  });

  service.on('stop_service').listen((event) {
    service.stopSelf();
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp>
    with WidgetsBindingObserver, WindowListener {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }

    super.dispose();
  }

  @override
  void onWindowClose() {
    MihomoService.stop();
    exit(0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      MihomoService.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey, // 挂载全局 Navigator Key 供弹窗和路由跳转使用
      debugShowCheckedModeBanner: false,
      title: "Pan Client",
      routes: {
        "/download": (context) => const DownloadPage(),
        "/settings": (context) => const SettingsPage(),
      },
      home: const LoginPage(),
    );
  }
}
