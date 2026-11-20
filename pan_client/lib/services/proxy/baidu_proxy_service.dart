// lib/services/proxy/baidu_proxy_service.dart
import 'dart:async';
import 'dart:io';

// 引入统一错误日志模型与上报服务
import '../../models/app_error_log.dart';
import '../global_error_reporter.dart';
import 'baidu_proxy_engine.dart';

class BaiduProxyService {
  static final BaiduProxyService _instance = BaiduProxyService._internal();
  factory BaiduProxyService() => _instance;
  BaiduProxyService._internal();

  ServerSocket? _server;
  int _activePort = 0;

  /// 当前代理服务绑定的本地端口
  int get activePort => _activePort;

  /// 代理服务运行状态
  bool get isRunning => _server != null;

  // 日志辅助方法，带 ANSI 颜色区分
  static void _logInfo(String tag, String msg) =>
      print('\x1B[32m[$tag]\x1B[0m $msg');
  static void _logWarn(String tag, String msg) =>
      print('\x1B[33m[$tag]\x1B[0m $msg');
  static void _logError(String tag, String msg) =>
      print('\x1B[31m[$tag]\x1B[0m $msg');

  /// 辅助方法：统一上报异常
  static void _reportException(
    String errorType,
    String message,
    dynamic stackTrace,
  ) {
    GlobalErrorReporter().reportError(
      AppErrorLog(
        errorType: errorType,
        message: message,
        stackTrace: stackTrace?.toString() ?? StackTrace.current.toString(),
        timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      ),
    );
  }

  /// 启动代理服务
  /// [preferredPort] 优先使用的端口，如果被占用会自动递增寻找空闲端口，若传 0 则由操作系统随机分配
  Future<int> start({int preferredPort = 56558}) async {
    if (_server != null) {
      _logWarn('PROXY_SVC', '服务已在运行中，当前端口: $_activePort');
      return _activePort;
    }

    int port = preferredPort;
    int maxTries = 10; // 最多尝试递增查找 10 个端口

    _logInfo('PROXY_SVC', '正在启动百度直连代理服务，首选端口: $preferredPort ...');

    while (maxTries > 0) {
      try {
        // 绑定到 loopbackIPv4 (127.0.0.1) 保证仅限 App 本机安全访问
        _server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
          shared: false,
        );
        _activePort = _server!.port;
        _logInfo('PROXY_SVC', '成功绑定端口: $_activePort');
        break;
      } catch (e, stackTrace) {
        _logWarn('PROXY_SVC', '端口 $port 被占用或绑定失败, 尝试寻找可用端口...');
        if (preferredPort == 0) {
          _logError('PROXY_SVC', '随机端口绑定失败: $e');
          _reportException('BaiduProxyBindError', '随机端口绑定失败: $e', stackTrace);
          rethrow;
        }
        port++;
        maxTries--;
        if (maxTries == 0) {
          _logWarn('PROXY_SVC', '尝试多次依然失败，回退到由 OS 动态分配空闲端口 (port=0)');
          try {
            _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
            _activePort = _server!.port;
          } catch (bindErr, bindStack) {
            _reportException(
              'BaiduProxyBindError',
              '回退动态端口绑定失败: $bindErr',
              bindStack,
            );
            rethrow;
          }
        }
      }
    }

    print('[+] [BaiduProxyService] 服务启动成功: 127.0.0.1:$_activePort');

    _server!.listen(
      (Socket clientSocket) {
        _logInfo(
          'PROXY_SVC',
          '接收到本地 Socket 接入 Request: ${clientSocket.remoteAddress.address}:${clientSocket.remotePort}',
        );
        BaiduProxyEngine.handleClient(clientSocket).catchError((e, stackTrace) {
          _logError('PROXY_SVC', '处理客户端连接时抛出未捕获异常: $e');
          _reportException(
            'BaiduProxyUnhandledError',
            '处理客户端连接未捕获异常: $e',
            stackTrace,
          );
        });
      },
      onError: (e, stackTrace) {
        _logError('PROXY_SVC', 'ServerSocket 发生错误: $e');
        _reportException(
          'BaiduProxyServerError',
          'ServerSocket 服务端发生错误: $e',
          stackTrace,
        );
      },
      onDone: () {
        _logWarn('PROXY_SVC', 'ServerSocket 已关闭');
      },
    );

    return _activePort;
  }

  /// 停止服务
  Future<void> stop() async {
    if (_server == null) {
      _logWarn('PROXY_SVC', '服务未运行，无需停止');
      return;
    }
    _logInfo('PROXY_SVC', '正在关闭代理服务 (Port: $_activePort) ...');
    try {
      await _server?.close();
    } catch (e, stackTrace) {
      _reportException(
        'BaiduProxyStopError',
        '停止 BaiduProxyService 时发生异常: $e',
        stackTrace,
      );
    } finally {
      _server = null;
      _activePort = 0;
      print('[+] [BaiduProxyService] 服务已停止');
    }
  }
}
