import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1. 本地流量离线存储器（防闪退/离线积攒）
class TrafficStorage {
  static const String _keyUnreportedBytes = 'pending_unreported_bytes';

  /// 获取本地尚未上报的累积字节数
  static Future<int> getUnreportedBytes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyUnreportedBytes) ?? 0;
  }

  /// 追加未上报流量到本地缓存
  static Future<void> addUnreportedBytes(int bytes) async {
    if (bytes <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(_keyUnreportedBytes) ?? 0;
    await prefs.setInt(_keyUnreportedBytes, current + bytes);
  }

  /// 上报成功后，扣减/清空本地已上报的字节数
  static Future<void> clearUnreportedBytes(int reportedBytes) async {
    if (reportedBytes <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(_keyUnreportedBytes) ?? 0;
    final remaining = (current - reportedBytes) < 0
        ? 0
        : (current - reportedBytes);
    await prefs.setInt(_keyUnreportedBytes, remaining);
  }
}

class TrafficReporter {
  final String serverUrl;
  final String cardCode;
  final Dio _dio;

  // 内存缓冲累加量
  int _memBytesBuffer = 0;

  // 上报门槛：302MB
  static const int reportThreshold = 302 * 1024 * 1024;

  // 用于签名验证的客户端密钥
  static const String _appSecret = "f831d102e2c8491bb40e69a039d54a2b";

  // 全局上报互斥锁，防止并发重复上报
  static bool _isReporting = false;

  // -------------------【速度与有效时间统计变量】-------------------
  DateTime? _segmentStartTime; // 当前有效下载片段的开始时间
  int _activeDurationMs = 0; // 处于下载状态下的累积有效毫秒数
  int _sessionAccumulatedBytes = 0; // 上报周期内的累积字节数
  bool _isDownloading = false; // 当前是否处于下载传输状态
  // -------------------------------------------------------------

  TrafficReporter({required this.serverUrl, required this.cardCode, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  /// 供 DownloadEngine 在分块流下载时调用的流量接收接口
  void addBytes(int bytes) {
    if (bytes <= 0) return;
    _memBytesBuffer += bytes;

    // 开启当前片段的计时器
    if (!_isDownloading) {
      _isDownloading = true;
      _segmentStartTime = DateTime.now();
    }

    _sessionAccumulatedBytes += bytes;

    // 当内存缓冲区积攒达到 2MB 时，批量刷入磁盘并尝试判断上报
    if (_memBytesBuffer >= 2 * 1024 * 1024) {
      flushAndCheck();
    }
  }

  /// 当任务暂停、取消或失败时由 DownloadManager 显式调用，冻结计时器
  void pauseTimer() {
    if (_isDownloading && _segmentStartTime != null) {
      _activeDurationMs += DateTime.now()
          .difference(_segmentStartTime!)
          .inMilliseconds;
      _isDownloading = false;
      _segmentStartTime = null;
      print(
        "=== [TrafficReporter] 暂停/中断计时器，当前累积有效耗时: ${(_activeDurationMs / 1000).toStringAsFixed(1)} 秒 ===",
      );
    }

    // 【新增】：暂停时立即刷新内存残余流量至本地磁盘
    flushAndCheck();
  }

  /// 将内存流量写入持久化存储并检测是否触发上报
  Future<void> flushAndCheck({double? avgSpeedKbps, String? fatalError}) async {
    if (_memBytesBuffer > 0) {
      final bytesToFlush = _memBytesBuffer;
      _memBytesBuffer = 0;
      await TrafficStorage.addUnreportedBytes(bytesToFlush);
    }
    await checkAndReport(avgSpeedKbps: avgSpeedKbps, fatalError: fatalError);
  }

  /// 检查并执行上报
  Future<void> checkAndReport({
    double? avgSpeedKbps,
    String? fatalError,
  }) async {
    // 拦截 1：如果当前已经在上报中，直接返回
    if (_isReporting) {
      return;
    }

    // 先确保内存中的流量已刷新至本地
    if (_memBytesBuffer > 0) {
      final bytesToFlush = _memBytesBuffer;
      _memBytesBuffer = 0;
      await TrafficStorage.addUnreportedBytes(bytesToFlush);
    }

    // 1. 读取本地累积未上报流量
    final pendingBytes = await TrafficStorage.getUnreportedBytes();

    // 2. 核心拦截判定：未满门槛 且 没有致命错误 -> 直接返回
    if (pendingBytes < reportThreshold && fatalError == null) {
      return;
    }

    // 如果没有任何未上报字节且没有错误，退出
    if (pendingBytes <= 0 && fatalError == null) {
      return;
    }

    // -------------------【计算平均速度 (KB/s)】-------------------
    double calculatedSpeedKbps = avgSpeedKbps ?? 0.0;
    int totalActiveMs = _activeDurationMs;

    if (_isDownloading && _segmentStartTime != null) {
      totalActiveMs += DateTime.now()
          .difference(_segmentStartTime!)
          .inMilliseconds;
    }

    if (calculatedSpeedKbps <= 0 &&
        _sessionAccumulatedBytes > 0 &&
        totalActiveMs > 0) {
      // 平均速度 (KB/s) = (传输总字节 / 1024) / (总有效耗时秒数)
      calculatedSpeedKbps =
          (_sessionAccumulatedBytes / 1024.0) / (totalActiveMs / 1000.0);
    }
    // -----------------------------------------------------------

    // 加锁：标记开始上报
    _isReporting = true;

    try {
      print("=== [TrafficReporter] 触发上报机制 ===");
      print(
        "    -> 待上报流量: ${(pendingBytes / (1024 * 1024)).toStringAsFixed(2)} MB",
      );
      print("    -> 有效下载耗时: ${(totalActiveMs / 1000).toStringAsFixed(1)} 秒");
      print("    -> 计算的平均速度: ${calculatedSpeedKbps.toStringAsFixed(2)} KB/s");
      print("    -> 触发原因: ${fatalError != null ? '存在致命错误' : '流量已满'}");

      // 3. 执行实际网络请求
      final success = await _sendReportApi(
        bytes: pendingBytes,
        avgSpeedKbps: calculatedSpeedKbps,
        errorMsg: fatalError,
      );

      if (success) {
        // 上报成功，清空/扣减本地缓存
        await TrafficStorage.clearUnreportedBytes(pendingBytes);

        // 重置速度与计时状态
        _activeDurationMs = 0;
        _sessionAccumulatedBytes = 0;
        _segmentStartTime = _isDownloading ? DateTime.now() : null;

        print("=== [TrafficReporter] 上报成功，本地缓存与速度统计已重置 ===");
      }
    } catch (e) {
      print("=== [TrafficReporter] 网络上报失败，流量继续保存在本地等待下一次触发: $e ===");
    } finally {
      // 无论成功还是失败，解锁
      _isReporting = false;
    }
  }

  /// 提交网络请求
  Future<bool> _sendReportApi({
    required int bytes,
    double? avgSpeedKbps,
    String? errorMsg,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = 'flutter_${DateTime.now().microsecondsSinceEpoch}';

    final rawStr =
        'bytes_used=$bytes&card_code=$cardCode&nonce=$nonce&timestamp=$timestamp';
    final sign = _generateSignature(rawStr);

    final payload = <String, dynamic>{
      'card_code': cardCode,
      'bytes_used': bytes,
      'nonce': nonce,
      'timestamp': timestamp,
      'signature': sign,
    };

    if (avgSpeedKbps != null && avgSpeedKbps > 0) {
      payload['avg_speed_kbps'] = double.parse(avgSpeedKbps.toStringAsFixed(2));
    } else {
      payload['avg_speed_kbps'] = 0.0;
    }

    if (errorMsg != null && errorMsg.isNotEmpty) {
      payload['recent_error'] = errorMsg;
    }

    final response = await _dio.post(
      '$serverUrl/api/user/card/report_traffic',
      data: payload,
    );

    if (response.statusCode == 200 && response.data != null) {
      final resData = response.data;
      if (resData is Map &&
          (resData['success'] == true || resData['code'] == 0)) {
        return true;
      }
    }
    return false;
  }

  /// 计算 HMAC-SHA256 签名
  String _generateSignature(String rawStr) {
    final key = utf8.encode(_appSecret);
    final bytesToSign = utf8.encode(rawStr);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytesToSign);
    return digest.toString();
  }
}
