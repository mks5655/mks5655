import 'dart:async'; // 👈 引入 unawaited 异步方法
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/user_api.dart';
import 'home_page.dart';
import '../download/download_manager.dart';
import '../services/global_error_reporter.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController controller = TextEditingController();
  final UserApi api = UserApi();

  bool loading = false;
  String error = "";

  @override
  void initState() {
    super.initState();
    // 👈 1. 页面加载时自动检查并登录
    _checkAutoLogin();
  }

  /// 读取本地保存的卡密，如果存在则自动填充并登录
  Future<void> _checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCode = prefs.getString('saved_card_code');

    if (savedCode != null && savedCode.trim().isNotEmpty) {
      controller.text = savedCode;
      // 自动发起登录校验
      login();
    }
  }

  Future<void> login() async {
    final code = controller.text.trim();

    if (code.isEmpty) {
      setState(() {
        error = "请输入卡密";
      });
      return;
    }

    setState(() {
      loading = true;
      error = "";
    });

    try {
      final response = await api.getFiles(code);

      // 登录成功，保存/更新卡密到本地
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_card_code', code);
      // 2. 关键：通知错误上报器已登录，并同步上报未登录阶段的历史日志（去除 await 改为 unawaited 后台异步执行，本地检测重复后上传，不卡顿登录）
      unawaited(GlobalErrorReporter().setAuthCredentials(code));
      // ========================== 新增 ==========================
      // 【关键修复】：登录成功后，立刻将最新卡密注入到下载引擎中，无需等待下次重启
      DownloadManager.instance.updateTrafficReporter(
        serverUrl: "https://baidu-pan.mtd.dpdns.org",
        cardCode: code,
      );
      // ==========================================================

      if (!mounted) return;

      // 替换当前页面进入主页
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => HomePage(
            cardId: response.card.id,
            cardCode: code,
            response: response,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString().replaceFirst("Exception:", "").trim();
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 350,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(25),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "请输入卡密",
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 30),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: "卡密",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => loading ? null : login(),
                  ),
                  const SizedBox(height: 20),
                  if (error.isNotEmpty) ...[
                    Text(error, style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 15),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: ElevatedButton(
                      onPressed: loading ? null : login,
                      child: loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text("进入"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}