import 'package:shared_preferences/shared_preferences.dart';

class TrafficStorage {
  static const String _keyUnreportedBytes = 'unreported_bytes';

  /// 累加未上报的流量（字节）
  static Future<void> addUnreportedBytes(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    int current = prefs.getInt(_keyUnreportedBytes) ?? 0;
    await prefs.setInt(_keyUnreportedBytes, current + bytes);
  }

  /// 获取当前未上报的流量
  static Future<int> getUnreportedBytes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyUnreportedBytes) ?? 0;
  }

  /// 清空或扣减已上报的流量
  static Future<void> clearReportedBytes(int reportedBytes) async {
    final prefs = await SharedPreferences.getInstance();
    int current = prefs.getInt(_keyUnreportedBytes) ?? 0;
    int remaining = current - reportedBytes;
    await prefs.setInt(_keyUnreportedBytes, remaining < 0 ? 0 : remaining);
  }
}