import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../settings/settings_manager.dart';
import '../download/download_manager.dart';
import 'login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settings = SettingsManager.instance;

  Future<void> _pickDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      await _settings.setDownloadPath(selectedDirectory);
      setState(() {});
    }
  }

  /// 退出登录逻辑
  Future<void> _logout() async {
    // 1. 弹出二次确认弹窗
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提示'),
        content: const Text('确定要退出当前登录并清除卡密吗？退出后将暂停所有下载任务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // 2. 核心修复：退出前暂停所有正在下载和等待中的任务
    await DownloadManager.instance.pauseAll();

    // 3. 清除本地卡密缓存
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_card_code');

    if (!mounted) return;

    // 4. 清空页面栈并返回登录页
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('下载设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
    ListTile(
      title: const Text('默认保存路径'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            p.join(_settings.downloadPath, "我的文件"),
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          if (Platform.isAndroid || Platform.isIOS) ...[
            const SizedBox(height: 2),
            Text(
              'Download/我的文件',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ],
      ),
      trailing: (Platform.isAndroid || Platform.isIOS)
          ? const Icon(Icons.lock_outline, color: Colors.grey)
          : const Icon(Icons.folder_open),
      // 点击逻辑处理：移动端弹窗/提示，桌面端选择路径
      onTap: () {
        if (Platform.isAndroid || Platform.isIOS) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('下载文件保存在路径  Download/我的文件'),
              duration: Duration(seconds: 2),
            ),
          );
        } else {
          _pickDirectory();
        }
      },
    ),
          const Divider(),
          ListTile(
            title: const Text('同时下载任务数'),
            subtitle: Text('${_settings.maxConcurrent} 个任务'),
            trailing: DropdownButton<int>(
              value: _settings.maxConcurrent,
              items: [1, 2, 3]
                  .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                  .toList(),
              onChanged: (val) async {
                if (val != null) {
                  await _settings.setMaxConcurrent(val);
                  setState(() {});
                }
              },
            ),
          ),
          ListTile(
            title: const Text('单任务分段线程数'),
            subtitle: Text('${_settings.threadsPerTask} 线程'),
            trailing: DropdownButton<int>(
              value: _settings.threadsPerTask,
              items: [1, 2, 3]
                  .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                  .toList(),
              onChanged: (val) async {
                if (val != null) {
                  await _settings.setThreadsPerTask(val);
                  setState(() {});
                }
              },
            ),
          ),

          const SizedBox(height: 40),

          // 退出登录按钮
          SizedBox(
            width: double.infinity,
            height: 45,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade50,
                foregroundColor: Colors.red,
                elevation: 0,
                side: BorderSide(color: Colors.red.shade200),
              ),
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text(
                '退出登录',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
