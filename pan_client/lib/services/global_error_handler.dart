// lib/utils/global_error_handler.dart

import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/app_error_log.dart';
import 'global_error_reporter.dart';

class GlobalErrorHandler {
  static void init({required Future<Widget> Function() builder}) {
    // 1. Flutter UI 框架渲染异常捕获
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _logAndReport(
        'FlutterFrameworkError',
        details.exceptionAsString(),
        details.stack?.toString(),
      );
    };

    // 2. Dart 未捕获的异步异常
    PlatformDispatcher.instance.onError =
        (Object error, StackTrace stackTrace) {
          _logAndReport(
            'PlatformDispatcherError',
            error.toString(),
            stackTrace.toString(),
          );
          return true;
        };

    // 3. 异步启动 App
    builder()
        .then((appWidget) {
          runApp(appWidget);
        })
        .catchError((error, stackTrace) {
          _logAndReport(
            'AppStartupError',
            error.toString(),
            stackTrace.toString(),
          );
        });
  }

  // 【修复点】：实现异常上报逻辑
  static void _logAndReport(String type, String message, String? stack) {
    try {
      final log = AppErrorLog(
        errorType: type,
        message: message,
        stackTrace: stack ?? '',
        timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      );
      // 主动异步提交给全局日志收集器
      GlobalErrorReporter().reportError(log);
    } catch (e) {
      print("--- [GlobalErrorHandler] 上报捕获异常时出错: $e ---");
    }
  }
}
