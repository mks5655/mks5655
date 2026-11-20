// lib/pages/user_detail_page.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/file_response.dart';
import 'login_page.dart';
import '../download/download_manager.dart';

/// 卡片主题配色数据结构
class CardThemeConfig {
  final List<Color> backgroundGradient;
  final Color tagDotColor;
  final Color percentTextColor;
  final List<Color> progressGradient;

  const CardThemeConfig({
    required this.backgroundGradient,
    required this.tagDotColor,
    required this.percentTextColor,
    required this.progressGradient,
  });
}

/// 预设配色方案：科技蓝、优雅紫、活力橙、碧绿
final List<CardThemeConfig> kCardThemes = [
  // 2. 优雅紫
  const CardThemeConfig(
    backgroundGradient: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
    tagDotColor: Color(0xFFC084FC),
    percentTextColor: Color(0xFFDDD6FE),
    progressGradient: [Color(0xFFC084FC), Color(0xFFA855F7)],
  ),

  // 1. 科技蓝 (默认)
  const CardThemeConfig(
    backgroundGradient: [Color(0xFF2A73EE), Color(0xFF3B82F6)],
    tagDotColor: Color(0xFF60A5FA),
    percentTextColor: Color(0xFF7DD3FC),
    progressGradient: [Color(0xFF38BDF8), Color(0xFF818CF8)],
  ),

  // 3. 活力橙/珊瑚红
  const CardThemeConfig(
    backgroundGradient: [Color(0xFFFF5733), Color(0xFFC70039)],
    tagDotColor: Color(0xFFFCA5A5),
    percentTextColor: Color(0xFFFECACA),
    progressGradient: [Color(0xFFFDE047), Color(0xFFF97316)],
  ),
  // 4. 碧绿/青色
  const CardThemeConfig(
    backgroundGradient: [Color(0xFF0D9488), Color(0xFF115E59)],
    tagDotColor: Color(0xFF5EEAD4),
    percentTextColor: Color(0xFF99F6E4),
    progressGradient: [Color(0xFF2DD4BF), Color(0xFF14B8A6)],
  ),
];

class UserDetailPage extends StatefulWidget {
  final int cardId;
  final String cardCode;
  final FileResponse? response;

  const UserDetailPage({
    super.key,
    required this.cardId,
    required this.cardCode,
    this.response,
  });

  @override
  State<UserDetailPage> createState() => _UserDetailPageState();
}

class _UserDetailPageState extends State<UserDetailPage> {
  // 静态变量做内存缓存
  static String? _cachedExpireTime;
  static String? _cachedCardCode;
  static int? _cachedUsedSize;
  static int? _cachedMaxSize;

  // SharedPreferences Key
  static const String _themePrefKey = 'selected_card_theme_index';

  // 卡片主题索引状态
  int _cardThemeIndex = 0;

  bool _isLoading = false;
  String _expireTimeStr = '未知';

  int? _usedSize;
  int? _maxSize;

  static const String _baseUrl = 'https://baidu-pan.mtd.dpdns.org';

  @override
  void initState() {
    super.initState();
    _loadSavedTheme();
    _initData();
  }

  /// 读取本地保存的主题设置
  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIndex = prefs.getInt(_themePrefKey) ?? 0;
    if (mounted && savedIndex < kCardThemes.length) {
      setState(() {
        _cardThemeIndex = savedIndex;
      });
    }
  }

  /// 切换卡片主题配色并保存到 SharedPreferences
  Future<void> _switchCardTheme() async {
    final nextIndex = (_cardThemeIndex + 1) % kCardThemes.length;
    setState(() {
      _cardThemeIndex = nextIndex;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themePrefKey, nextIndex);
  }

  void _initData() {
    final rawTime = widget.response?.card.expireTime;
    final rawUsed = widget.response?.card.usedSize;
    final rawMax = widget.response?.card.maxSize;

    if (rawTime != null && rawTime.isNotEmpty) {
      _cachedExpireTime = _formatTimeString(rawTime);
      _cachedCardCode = widget.cardCode;
      _cachedUsedSize = rawUsed;
      _cachedMaxSize = rawMax;

      setState(() {
        _expireTimeStr = _cachedExpireTime!;
        _usedSize = _cachedUsedSize;
        _maxSize = _cachedMaxSize;
        _isLoading = false;
      });
      return;
    }

    if (_cachedCardCode == widget.cardCode && _cachedExpireTime != null) {
      setState(() {
        _expireTimeStr = _cachedExpireTime!;
        _usedSize = _cachedUsedSize;
        _maxSize = _cachedMaxSize;
        _isLoading = false;
      });
      return;
    }

    // 直接调用 fetch，由内部处理 loading 状态
    _fetchLatestCardInfo();
  }

  /// 获取卡密状态对应的颜色与文案
  ({Color bgColor, Color textColor, String text}) _getCardStatusInfo() {
    if (_expireTimeStr == '已过期' ||
        _expireTimeStr == '卡密不存在' ||
        _expireTimeStr == '未设置/无效' ||
        _expireTimeStr.contains('过期')) {
      return (
        bgColor: const Color(0x33EF4444),
        textColor: const Color(0xFFFCA5A5),
        text: '已失效',
      );
    }

    if (_expireTimeStr == '获取失败' || _expireTimeStr == '未连接到服务') {
      return (
        bgColor: const Color(0x33F59E0B),
        textColor: const Color(0xFFFCD34D),
        text: '状态未知',
      );
    }

    final currentTheme = kCardThemes[_cardThemeIndex];
    return (
      bgColor: Colors.white.withOpacity(0.18),
      textColor: currentTheme.tagDotColor,
      text: '生效中',
    );
  }

  Future<void> _fetchLatestCardInfo() async {
    // 防重拦截：如果正在加载中，跳过
    if (_isLoading) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    } else {
      _isLoading = true;
    }

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/user/card?code=${widget.cardCode}'),
        headers: {'Content-Type': 'application/json'},
      );

      Map<String, dynamic>? data;
      try {
        if (response.body.isNotEmpty) {
          data = json.decode(response.body) as Map<String, dynamic>?;
        }
      } catch (_) {}

      if (response.statusCode == 200 && (data?['success'] ?? true) != false) {
        final cardData = data?['card'] ?? data ?? {};
        final rawExpireTime = cardData['expire_time'] ?? cardData['expireTime'];

        final int? netUsedSize = cardData['used_size'] ?? cardData['usedSize'];
        final int? netMaxSize = cardData['max_size'] ?? cardData['maxSize'];

        if (mounted) {
          String formattedTime;

          if (rawExpireTime != null &&
              rawExpireTime.toString().trim().isNotEmpty) {
            final timeStr = rawExpireTime.toString().trim();

            if (timeStr == '0' || timeStr.contains('9999')) {
              formattedTime = '永久有效';
            } else {
              try {
                final parsedDate = DateTime.parse(timeStr);
                if (parsedDate.isBefore(DateTime.now())) {
                  formattedTime = '已过期';
                } else {
                  formattedTime = _formatTimeString(timeStr);
                }
              } catch (_) {
                formattedTime = _formatTimeString(timeStr);
              }
            }
          } else {
            formattedTime = '未设置/无效';
          }

          _cachedExpireTime = formattedTime;
          _cachedCardCode = widget.cardCode;
          _cachedUsedSize = netUsedSize;
          _cachedMaxSize = netMaxSize;

          setState(() {
            _expireTimeStr = formattedTime;
            _usedSize = netUsedSize;
            _maxSize = netMaxSize;
          });
        }
      } else {
        if (mounted) {
          String errorMsg = '获取失败';
          final serverError = data?['error'] ?? data?['message'];

          if (serverError != null && serverError.toString().isNotEmpty) {
            errorMsg = serverError.toString();
          } else if (response.statusCode == 404) {
            errorMsg = '卡密不存在';
          }

          _cachedExpireTime = errorMsg;
          _cachedCardCode = widget.cardCode;

          setState(() {
            _expireTimeStr = errorMsg;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _expireTimeStr = '未连接到服务';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _formatTimeString(String rawTime) {
    try {
      String cleaned = rawTime.replaceAll('T', ' ');
      if (cleaned.contains('.')) {
        cleaned = cleaned.split('.')[0];
      }
      return cleaned;
    } catch (_) {
      return rawTime;
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double dBytes = bytes.toDouble();
    while (dBytes >= 1024 && i < suffixes.length - 1) {
      dBytes /= 1024;
      i++;
    }
    return '${dBytes.toStringAsFixed(2)} ${suffixes[i]}';
  }

  void _copyCardCode() {
    Clipboard.setData(ClipboardData(text: widget.cardCode));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('卡密已复制到剪贴板'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _logout() async {
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

    await DownloadManager.instance.pauseAll();

    _cachedExpireTime = null;
    _cachedCardCode = null;
    _cachedUsedSize = null;
    _cachedMaxSize = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_card_code');

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardTheme = kCardThemes[_cardThemeIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('个人中心'),
        elevation: 0,
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
                : const Icon(Icons.refresh_outlined),
            tooltip: '刷新信息',
            onPressed: _isLoading ? null : _fetchLatestCardInfo,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '下载设置',
            onPressed: () {
              Navigator.pushNamed(context, '/settings');
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _isLoading ? () async {} : _fetchLatestCardInfo,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // 1. 卡密大卡片 (点击自动切换颜色、持久化存储并平滑过渡)
            GestureDetector(
              onTap: _switchCardTheme,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    colors: cardTheme.backgroundGradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: cardTheme.backgroundGradient.first.withOpacity(
                        0.35,
                      ),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // 背景芯片纹理水印
                    Positioned(
                      right: -15,
                      top: -15,
                      child: Icon(
                        Icons.credit_card_sharp,
                        size: 150,
                        color: Colors.white.withOpacity(0.03),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(22.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 头部：标题与状态标签
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.12),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.vpn_key_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Text(
                                    '当前卡密账号',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                              Builder(
                                builder: (context) {
                                  final status = _getCardStatusInfo();
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: status.bgColor,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: status.textColor,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          status.text,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // 中间：卡密字符与复制按钮
                          Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  widget.cardCode,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(30),
                                  onTap: _copyCardCode,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.18),
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    child: const Row(
                                      children: [
                                        Icon(
                                          Icons.copy_rounded,
                                          color: Colors.white,
                                          size: 14,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          '复制',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 22),
                          Divider(
                            color: Colors.white.withOpacity(0.12),
                            height: 1,
                          ),
                          const SizedBox(height: 16),

                          // 底部：用量指示与加厚高对比度进度条
                          Builder(
                            builder: (context) {
                              final double progress =
                                  (_maxSize != null &&
                                      _maxSize! > 0 &&
                                      _usedSize != null)
                                  ? (_usedSize! / _maxSize!).clamp(0.0, 1.0)
                                  : 0.0;
                              final String usedText = _formatBytes(_usedSize);
                              final String maxText = _maxSize != null
                                  ? _formatBytes(_maxSize)
                                  : '未限定';

                              return Column(
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '用量指示: $usedText / $maxText',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '${(progress * 100).toStringAsFixed(1)}%',
                                        style: TextStyle(
                                          color: progress > 0.9
                                              ? const Color(0xFFEF4444)
                                              : (progress > 0.8
                                                    ? const Color(0xFFF59E0B)
                                                    : cardTheme
                                                          .percentTextColor),
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),

                                  // 高对比度发光进度条
                                  LayoutBuilder(
                                    builder: (context, constraints) {
                                      final double currentProgressWidth =
                                          constraints.maxWidth * progress;
                                      final progressColors = progress > 0.9
                                          ? [
                                              const Color(0xFFEF4444),
                                              Colors.red,
                                            ]
                                          : (progress > 0.8
                                                ? [
                                                    const Color(0xFFF59E0B),
                                                    Colors.orange,
                                                  ]
                                                : cardTheme.progressGradient);

                                      return Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          // 轨道
                                          Container(
                                            height: 10,
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(
                                                0.25,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              border: Border.all(
                                                color: Colors.white.withOpacity(
                                                  0.15,
                                                ),
                                                width: 1,
                                              ),
                                            ),
                                          ),
                                          // 填充条
                                          AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            height: 10,
                                            width: currentProgressWidth,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              gradient: LinearGradient(
                                                colors: progressColors,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: progressColors.first
                                                      .withOpacity(0.6),
                                                  blurRadius: 8,
                                                  spreadRadius: 1,
                                                ),
                                              ],
                                            ),
                                          ),
                                          // 末端提示白点
                                          if (progress > 0.02)
                                            Positioned(
                                              left: (currentProgressWidth - 8)
                                                  .clamp(
                                                    0.0,
                                                    constraints.maxWidth - 8,
                                                  ),
                                              top: 1,
                                              child: Container(
                                                width: 8,
                                                height: 8,
                                                decoration: const BoxDecoration(
                                                  color: Color.fromARGB(
                                                    255,
                                                    255,
                                                    249,
                                                    249,
                                                  ),
                                                  shape: BoxShape.circle,
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black38,
                                                      blurRadius: 3,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // 2. 卡密属性详情
            Text(
              '卡密账户详情',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),

            Card(
              elevation: 0.5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.badge_outlined,
                      color: Colors.blue,
                    ),
                    title: const Text('卡密 ID'),
                    trailing: Text(
                      '#${widget.cardId}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),

                  ListTile(
                    leading: const Icon(
                      Icons.access_time_outlined,
                      color: Colors.purple,
                    ),
                    title: const Text('到期时间'),
                    trailing: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _expireTimeStr,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),

                  ListTile(
                    leading: const Icon(
                      Icons.data_usage_outlined,
                      color: Colors.orange,
                    ),
                    title: const Text('流量使用情况'),
                    trailing: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            '${_formatBytes(_usedSize)} / ${_maxSize != null ? _formatBytes(_maxSize) : '请重新刷新'}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),

                  ListTile(
                    leading: const Icon(
                      Icons.cloud_done_outlined,
                      color: Colors.green,
                    ),
                    title: const Text('服务状态'),
                    trailing: const Text('正常', style: TextStyle(fontSize: 14)),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // 3. 应用设置与退出
            Card(
              elevation: 0.5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(Icons.folder_open, color: Colors.indigo),
                title: const Text('下载与并发设置'),
                subtitle: const Text('修改文件保存路径与下载线程'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pushNamed(context, '/settings');
                },
              ),
            ),

            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade50,
                  foregroundColor: Colors.red,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  side: BorderSide(color: Colors.red.shade200),
                ),
                onPressed: _logout,
                icon: const Icon(Icons.logout),
                label: const Text(
                  '退出当前卡密',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}