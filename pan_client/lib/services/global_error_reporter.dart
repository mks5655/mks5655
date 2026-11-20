// lib/services/global_error_reporter.dart

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_error_log.dart';
import 'error_log_cache_service.dart';

class GlobalErrorReporter {
  static final GlobalErrorReporter _instance = GlobalErrorReporter._internal();
  factory GlobalErrorReporter() => _instance;
  GlobalErrorReporter._internal();

  String? _cardKey;
  final String _apiUrl = 'https://baidu-pan.mtd.dpdns.org/api/app/error_log';

  /// 用户登录成功后调用此接口更新凭证，后台异步刷盘（绝不阻塞登录跳转速度）
  Future<void> setAuthCredentials(String cardKey) async {
    _cardKey = cardKey;
    print('[GlobalErrorReporter] 凭证已设置，后台触发离线日志补发...');

    // 👈 核心改进：去除对刷盘过程的等待，完全剥离到后台微任务中执行
    unawaited(
      ErrorLogCacheService.flushLogsToServer(
        apiEndpoint: _apiUrl,
        cardKey: cardKey,
      ),
    );
  }

  /// 统一错误上报入口（非阻塞）
  Future<void> reportError(AppErrorLog log) async {
    // 状态 A：未登录 -> 异步存入本地缓存（内部自动检测去重）
    if (_cardKey == null || _cardKey!.isEmpty) {
      unawaited(ErrorLogCacheService.saveToCache(log));
      return;
    }

    // 状态 B：已登录 -> 异步实时发送
    unawaited(_sendReportAsync(log));
  }

  /// 内部后台发送逻辑
  Future<void> _sendReportAsync(AppErrorLog log) async {
    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json', 'X-Card-Key': _cardKey!},
        body: jsonEncode({
          'errorType': log.errorType,
          'message': log.message,
          'stackTrace': log.stackTrace,
          'timestamp': log.timestamp,
        }),
      );

      if (response.statusCode != 200) {
        await ErrorLogCacheService.saveToCache(log);
      }
    } catch (e) {
      // 网络失败时退回缓存
      await ErrorLogCacheService.saveToCache(log);
    }
  }
}