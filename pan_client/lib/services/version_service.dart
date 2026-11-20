import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/version_info.dart';
// TODO: 请根据您项目中实际的 dio 实例路径进行修改
// import '../utils/request.dart'; 

class VersionService {
  /// 检查 App 版本
  static Future<void> checkVersion(BuildContext context) async {
    try {
      // 1. 获取本地当前版本
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version; // 如 "1.0.0"

      // 2. 真实请求后端版本接口
      // 假设您的后端接口返回结构如: { "code": 200, "data": { "latest_version": "1.1.0", ... } }
      // Response response = await dio.get('/system/version');
      // 
      // if (response.statusCode == 200 && response.data['data'] != null) {
      //   VersionInfo info = VersionInfo.fromJson(response.data['data']);
      //   
      //   // 3. 对比版本
      //   if (_isVersionOlder(currentVersion, info.minSupportVersion) || info.forceUpdate) {
      //     // 触发【强制更新】弹窗（不可取消）
      //     _showUpdateDialog(context, info, isForce: true);
      //   } else if (_isVersionOlder(currentVersion, info.latestVersion)) {
      //     // 触发【普通更新】弹窗（可跳过）
      //     _showUpdateDialog(context, info, isForce: false);
      //   }
      // }

    } catch (e) {
      debugPrint("检查更新失败: $e");
    }
  }

  /// 比较版本号大小 (例如 "1.0.0" < "1.1.2")
  static bool _isVersionOlder(String current, String target) {
    List<int> cParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    List<int> tParts = target.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    
    // 补齐3位
    while (cParts.length < 3) cParts.add(0);
    while (tParts.length < 3) tParts.add(0);

    for (int i = 0; i < 3; i++) {
      if (cParts[i] < tParts[i]) return true;
      if (cParts[i] > tParts[i]) return false;
    }
    return false;
  }

  /// 弹出更新提示框
  static void _showUpdateDialog(BuildContext context, VersionInfo info, {required bool isForce}) {
    if (!context.mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: !isForce, // 强制更新时点击外部无法关闭
      builder: (BuildContext context) {
        return PopScope(
          canPop: !isForce, // 拦截物理返回键（防止强更时用户直接返回）
          child: AlertDialog(
            title: Text(isForce ? '发现重要安全更新' : '发现新版本 (${info.latestVersion})'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('更新日志：', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(info.updateLog),
              ],
            ),
            actions: [
              if (!isForce)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('以后再说', style: TextStyle(color: Colors.grey)),
                ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                onPressed: () async {
                  final Uri url = Uri.parse(info.updateUrl);
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
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
}