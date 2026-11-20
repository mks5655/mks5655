// lib/services/error_log_cache_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_error_log.dart';

class ErrorLogCacheService {
  static const String _storageKey = 'cached_app_error_logs';
  
  /// 本地已缓存日志的 Hash 记录（内存去重）
  static final Set<String> _cachedHashes = {};
  static bool _isHashLoaded = false;

  /// 计算 AppErrorLog 唯一特征 Hash (MD5)
  static String _computeLogHash(String type, String message, String stackTrace) {
    // 提取 StackTrace 的前 2 行作为特征值，避免时间戳干扰去重
    final stackKey = stackTrace.split('\n').take(2).join('\n');
    final content = '$type|$message|$stackKey';
    return md5.convert(utf8.encode(content)).toString();
  }

  /// 初始化已有的 Hash 列表
  static Future<void> _ensureHashLoaded(SharedPreferences prefs) async {
    if (_isHashLoaded) return;
    final List<String> currentList = prefs.getStringList(_storageKey) ?? [];
    for (String logJson in currentList) {
      try {
        final map = jsonDecode(logJson);
        final hash = _computeLogHash(
          map['errorType'] ?? '',
          map['message'] ?? '',
          map['stackTrace'] ?? '',
        );
        _cachedHashes.add(hash);
      } catch (_) {}
    }
    _isHashLoaded = true;
  }

  /// 1. 写入本地缓存队列（含内容重复性检测）
  static Future<void> saveToCache(AppErrorLog log) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _ensureHashLoaded(prefs);

      // 🔒 修复编译报错：为 log.stackTrace 加上 ?? '' 安全判空兜底
      final logHash = _computeLogHash(
        log.errorType,
        log.message,
        log.stackTrace ?? '',
      );

      // 🔍【内容去重】：已存在的报错直接丢弃
      if (_cachedHashes.contains(logHash)) {
        print('[ErrorLogCache] ⚠️ 命中本地去重规则，已截断重复日志: ${log.errorType}');
        return;
      }

      final List<String> currentList = prefs.getStringList(_storageKey) ?? [];

      final logMap = {
        'errorType': log.errorType,
        'message': log.message,
        'stackTrace': log.stackTrace ?? '',
        'timestamp': log.timestamp,
      };

      currentList.add(jsonEncode(logMap));
      _cachedHashes.add(logHash);

      await prefs.setStringList(_storageKey, currentList);
      print('[ErrorLogCache] 错误日志已保存至本地缓存 (当前积压: ${currentList.length} 条)');
    } catch (e) {
      print('[ErrorLogCache] 写入本地缓存失败: $e');
    }
  }

  /// 2. 登录成功后后台异步补发缓存日志
  static Future<void> flushLogsToServer({
    required String apiEndpoint,
    required String cardKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> currentList = prefs.getStringList(_storageKey) ?? [];

      if (currentList.isEmpty) return;

      print('[ErrorLogCache] 开始后台异步上报本地缓存日志，共 ${currentList.length} 条...');

      List<String> failedLogs = [];

      for (String logJson in currentList) {
        final Map<String, dynamic> bodyData = jsonDecode(logJson);

        try {
          final response = await http.post(
            Uri.parse(apiEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'X-Card-Key': cardKey,
            },
            body: jsonEncode(bodyData),
          );

          if (response.statusCode != 200) {
            failedLogs.add(logJson);
          }
        } catch (_) {
          failedLogs.add(logJson);
        }
      }

      if (failedLogs.isEmpty) {
        await prefs.remove(_storageKey);
        _cachedHashes.clear();
        print('[ErrorLogCache] 所有本地缓存日志已成功上报并清理！');
      } else {
        await prefs.setStringList(_storageKey, failedLogs);
        print('[ErrorLogCache] 上报完成，剩余 ${failedLogs.length} 条失败日志等待重试。');
      }
    } catch (e) {
      print('[ErrorLogCache] 刷新日志异常: $e');
    }
  }
}