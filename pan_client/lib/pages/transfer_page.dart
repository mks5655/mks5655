import 'package:flutter/material.dart';
import '../api/user_api.dart'; 
import '../utils/check_share_valid.dart'; 
import '../utils/event_bus.dart';

class TransferPage extends StatefulWidget {
  final String cardCode;

  const TransferPage({super.key, required this.cardCode});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with AutomaticKeepAliveClientMixin {
  final UserApi _userApi = UserApi();

  bool _isLoading = false;
  Map<String, dynamic>? _cardInfo;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  /// 获取卡密状态及配额信息
  Future<void> _loadData({bool isRefresh = false}) async {
    if (widget.cardCode.isEmpty) return;

    if (_isLoading) return;
    if (_cardInfo != null && !isRefresh) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await _userApi.getCardFiles(widget.cardCode);
      final data = response.data;

      if (data is Map<String, dynamic> && data['success'] == true) {
        setState(() {
          _cardInfo = data['card'];
        });
      } else {
        final String errorMsg = data is Map<String, dynamic>
            ? (data['error'] ?? '获取卡密信息失败')
            : '获取卡密信息失败';

        if (errorMsg.contains('过期') ||
            errorMsg.contains('失效') ||
            errorMsg.contains('禁用') ||
            errorMsg.contains('无效')) {
          setState(() {
            _cardInfo = {
              'is_valid': false,
              'status': 'expired',
              'error_msg': errorMsg,
            };
          });
        } else {
          _showSnackBar(errorMsg, isError: true);
        }
      }
    } catch (e) {
      _showSnackBar('网络请求异常: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 判断当前卡密是否有效
  bool _checkCardValid() {
    if (_cardInfo == null) return false;

    if (_cardInfo!['is_valid'] == false) return false;
    if (_cardInfo!['status'] == 'expired' ||
        _cardInfo!['status'] == 'disabled' ||
        _cardInfo!['status'] == 0) {
      return false;
    }

    final rawExpireTime = _cardInfo!['expire_time'];
    if (rawExpireTime != null) {
      final expireStr = rawExpireTime.toString().trim();
      if (expireStr.isNotEmpty &&
          expireStr != '0' &&
          !expireStr.contains('9999')) {
        try {
          final expireDate = DateTime.parse(expireStr);
          if (expireDate.isBefore(DateTime.now())) {
            return false;
          }
        } catch (_) {}
      }
    }

    return true;
  }

  void _showErrorDialog(String errorMsg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.redAccent),
            SizedBox(width: 8),
            Text('添加失败'),
          ],
        ),
        content: Text(errorMsg, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  void _showAddShareBottomSheet() {
    if (!_checkCardValid()) {
      _showErrorDialog('当前卡密已失效或已过期，无法继续添加');
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (modalContext) {
        return AddShareBottomSheet(
          cardCode: widget.cardCode,
          onSubmit: (url, pwd) async {
            final res = await _userApi.addShare(
              code: widget.cardCode,
              shareUrl: url,
              pwd: pwd,
            );

            final isSuccess = res is Map<String, dynamic> && res['success'] == true;

            if (isSuccess) {
              final String msg = res['message'] ?? '添加成功！';
              
              _loadData(isRefresh: true);
              globalEventBus.emit('refresh_file_list');

              WidgetsBinding.instance.addPostFrameCallback((_) {
                _showSuccessDialog(msg);
              });
            } else {
              final String errorMsg = res is Map<String, dynamic>
                  ? (res['error'] ?? res['message'] ?? res['detail']?.toString() ?? '添加失败，未知错误')
                  : '转存失败，返回格式异常';

              throw Exception(errorMsg);
            }
          },
        );
      },
    );
  }

  void _showSuccessDialog(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 28),
            SizedBox(width: 8),
            Text('添加成功，请在文件页面选择文件下载'),
          ],
        ),
        content: Text(
          msg.isNotEmpty ? msg : '分享链接添加成功！文件已保存到文件列表。',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('添加分享链接'),
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                    ),
                  )
                : const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _isLoading ? null : () => _loadData(isRefresh: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _isLoading
            ? () async {}
            : () => _loadData(isRefresh: true),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              if (_cardInfo != null) _buildCardInfoBanner(),
              if (_isLoading && _cardInfo == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16.0),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              const SizedBox(height: 16),
              _buildInstructionsCard(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isLoading ? null : _showAddShareBottomSheet,
        icon: const Icon(Icons.add_link),
        label: const Text('添加新链接'),
      ),
    );
  }

  Widget _buildCardInfoBanner() {
    final isValid = _checkCardValid();

    String expireTimeDisplay = '未返回/已过期';
    final rawExpireTime = _cardInfo!['expire_time'];

    if (rawExpireTime != null && rawExpireTime.toString().isNotEmpty) {
      expireTimeDisplay = rawExpireTime.toString().split('.')[0];
    } else if (_cardInfo!['error_msg'] != null) {
      expireTimeDisplay = _cardInfo!['error_msg'].toString();
    } else if (!isValid) {
      expireTimeDisplay = '已过期';
    }

    final Color bgColor = isValid ? Colors.green.shade50 : Colors.red.shade50;
    final Color borderColor = isValid
        ? Colors.green.shade300
        : Colors.red.shade300;
    final Color primaryColor = isValid
        ? Colors.green.shade800
        : Colors.red.shade800;
    final Color badgeBgColor = isValid
        ? Colors.green.shade100
        : Colors.red.shade100;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isValid
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: primaryColor,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '卡密: ${widget.cardCode}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: primaryColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '到期时间: $expireTimeDisplay',
                  style: TextStyle(
                    fontSize: 12,
                    color: primaryColor.withOpacity(0.85),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: badgeBgColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: primaryColor.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isValid ? Icons.verified : Icons.warning_amber_rounded,
                  size: 14,
                  color: primaryColor,
                ),
                const SizedBox(width: 4),
                Text(
                  isValid ? '有效' : '已失效',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionsCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue),
                SizedBox(width: 8),
                Text(
                  '使用指南与说明',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 24),
            _buildInstructionStep(
              number: '1',
              title: '添加分享链接，如：https://pan...../s/.....?pwd=5688，提取码为：5688（填你实际的提取码）',
              content: '粘贴任意包含链接与提取码的完整文案，提交时会自动去除杂质。',
            ),
            const SizedBox(height: 16),
            _buildInstructionStep(
              number: '2',
              title: '添加成功后，去文件页面刷新，选择文件下载',
              content: '点击首页右上角刷新文件列表，选择文件下载',
            ),
            const SizedBox(height: 16),
            _buildInstructionStep(
              number: '3',
              title: '点击右上角可查看下载任务，网速慢可暂停再重试',
              content: '点击右上角下载图标可查看下载任务',
            ),
            const SizedBox(height: 16),
            _buildInstructionStep(
              number: '4',
              title: '文件下载说明',
              content: '已经添加的下载任务无法重复添加，在软件内删除该下载任务才能添加下载任务',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionStep({
    required String number,
    required String title,
    required String content,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: Colors.blue.shade100,
          child: Text(
            number,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                content,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AddShareBottomSheet extends StatefulWidget {
  final String cardCode;
  final Future<void> Function(String url, String pwd) onSubmit;

  const AddShareBottomSheet({
    super.key,
    required this.cardCode,
    required this.onSubmit,
  });

  @override
  State<AddShareBottomSheet> createState() => _AddShareBottomSheetState();
}

class _AddShareBottomSheetState extends State<AddShareBottomSheet> {
  late final TextEditingController _urlController;
  late final TextEditingController _pwdController;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _pwdController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _pwdController.dispose();
    super.dispose();
  }

  /// 提取和清理杂文的核心方法（支持全自动提取链接与密码）
  void _cleanAndParseInput() {
    final rawText = _urlController.text.trim();
    if (rawText.isEmpty) return;

    // 1. 从一整段中文杂文里提取出干净的 https://pan.baidu.com/s/xxx 链接
    final urlRegExp = RegExp(
      r'https?://(?:pan|yun)\.baidu\.com/s/[a-zA-Z0-9_-]+[^\s]*',
    );
    final urlMatch = urlRegExp.firstMatch(rawText);

    if (urlMatch != null) {
      String cleanUrl = urlMatch.group(0)!;
      // 抹掉链接末尾可能附带的中文或英文标点
      cleanUrl = cleanUrl.replaceAll(RegExp(r'[，。！？；:：,]+$'), '');

      String extractedPwd = _pwdController.text.trim();

      // 2. 尝试解析提取码
      if (extractedPwd.isEmpty) {
        // 方案 A：从 url 参数 ?pwd=xxxx 或 &pwd=xxxx 中提取
        final pwdInUrlReg = RegExp(r'[?&]pwd=([a-zA-Z0-9]{4})');
        final matchInUrl = pwdInUrlReg.firstMatch(cleanUrl);

        if (matchInUrl != null) {
          extractedPwd = matchInUrl.group(1)!;
        } else {
          // 方案 B：正则匹配“提取码: xxxx”或“密码: xxxx”
          final pwdTextReg = RegExp(
            r'(?:提取码|密码|pwd|码)\s*[:：]?\s*([a-zA-Z0-9]{4})',
            caseSensitive: false,
          );
          final matchInText = pwdTextReg.firstMatch(rawText);
          if (matchInText != null) {
            extractedPwd = matchInText.group(1)!;
          }
        }
      }

      // 回填清洗后的结果
      _urlController.text = cleanUrl;
      if (extractedPwd.isNotEmpty) {
        _pwdController.text = extractedPwd;
      }
    }
  }

  Future<void> _handleSubmit() async {
    if (_isSubmitting) return;

    // 💥 提交前自动清洗文案，去掉前后的中文杂质并自动提取密码
    _cleanAndParseInput();

    final url = _urlController.text.trim();
    final pwd = _pwdController.text.trim();

    if (url.isEmpty) {
      setState(() => _errorMessage = '请输入正确的分享链接');
      return;
    }

    final isBaiduUrl = url.contains('pan.baidu.com') || url.contains('yun.baidu.com');
    if (!isBaiduUrl) {
      setState(() => _errorMessage = '请输入正确的百度网盘分享链接，如：https://pan...../s/.....');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final checkResult = await BaiduLinkChecker.check(
        linkInput: url,
        pwdInput: pwd,
      );

      // 💥 关键修复点：如果链路检测失败，设置错误提示，并跳出程序（由于有 finally 保证，不会卡死状态）
      bool isCheckPassed = false;
      switch (checkResult) {
        case BaiduLinkCheckResult.invalidPwd:
          setState(
            () => _errorMessage = pwd.isEmpty
                ? '该链接需要提取码，请填写提取码'
                : '提取码错误，请检查后重新输入',
          );
          break;

        case BaiduLinkCheckResult.linkExpired:
          setState(() => _errorMessage = '链接不存在、已失效或分享已被取消');
          break;

        case BaiduLinkCheckResult.networkError:
          setState(() => _errorMessage = '网络连接异常，无法校验链接');
          break;

        case BaiduLinkCheckResult.valid:
          isCheckPassed = true;
          break;
      }

      // 只有通过检测才触发后端保存操作
      if (isCheckPassed) {
        await widget.onSubmit(url, pwd);
        if (mounted) {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    } finally {
      // 💥 无论成功失败，都保证解锁提交状态
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        top: 20,
        left: 20,
        right: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '添加分享链接',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: _isSubmitting ? null : () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_errorMessage != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _urlController,
            enabled: !_isSubmitting,
            onChanged: (_) {
              if (_errorMessage != null) setState(() => _errorMessage = null);
            },
            decoration: const InputDecoration(
              labelText: '分享链接',
              hintText: 'https://pan...../s/.....',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwdController,
            enabled: !_isSubmitting,
            onChanged: (_) {
              if (_errorMessage != null) setState(() => _errorMessage = null);
            },
            decoration: const InputDecoration(
              labelText: '提取码',
              hintText: '例如: t53g（若粘贴文本中已包含可留空）',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _handleSubmit,
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(_isSubmitting ? '正在校验并添加...' : '开始添加'),
            ),
          ),
        ],
      ),
    );
  }
}
