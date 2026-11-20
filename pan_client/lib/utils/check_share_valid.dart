import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 校验状态枚举
enum BaiduLinkCheckResult {
  valid,          // 链接与提取码完全有效
  invalidPwd,     // 链接存在，但输入的提取码错误
  linkExpired,    // 链接不存在/已失效/取消分享/已被封禁
  networkError,   // 网络错误
}

class BaiduLinkChecker {
  // 本地代理 Host 与端口（与 DioClient 统一）
  static const String _proxyHost = '127.0.0.1';
  static const int _proxyPort = 56558;

  static final Dio _dio = () {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      // 允许跟着 301/302 重定向
      followRedirects: true,
      maxRedirects: 5,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://pan.baidu.com/disk/home',
      },
    ));

    // 🛡️ 配置网络路由策略：代理优先 + 直连自动回退 + 跳过证书拦截
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();

        // 优先尝试走本地代理，若代理断开/未启动，自动降级为 DIRECT 直连
        client.findProxy = (uri) => 'PROXY $_proxyHost:$_proxyPort; DIRECT';

        // 允许百度网盘的 CDN 证书校验，防止因为抓包或中间人拦截导致请求中断
        client.badCertificateCallback = (cert, host, port) => true;

        return client;
      },
    );

    return dio;
  }();

  /// [linkInput] 输入框填写的链接
  /// [pwdInput]  输入框填写的提取码（可为空）
  static Future<BaiduLinkCheckResult> check({
    required String linkInput,
    required String pwdInput,
  }) async {
    final cleanPwd = pwdInput.trim();
    final cleanLink = linkInput.trim();

    // 1. 如果填写了提取码，走 /share/verify 接口校验
    if (cleanPwd.isNotEmpty) {
      return await _checkWithPwd(cleanLink, cleanPwd);
    } else {
      // 2. 如果未填写提取码，走无密公开链接 GET 探测校验
      return await _checkWithoutPwd(cleanLink);
    }
  }

  /// 有提取码的校验逻辑
  static Future<BaiduLinkCheckResult> _checkWithPwd(
      String linkInput, String pwd) async {
    final surl = _parseSurl(linkInput);
    if (surl.isEmpty) {
      return BaiduLinkCheckResult.linkExpired;
    }

    try {
      final url =
          'https://pan.baidu.com/share/verify?surl=$surl&clienttype=1&web=1';

      final response = await _dio.post(
        url,
        data: FormData.fromMap({
          'pwd': pwd,
          'vcode': '',
          'vcode_str': '',
        }),
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final int errno = response.data['errno'] ?? -1;

        switch (errno) {
          case 0:
            return BaiduLinkCheckResult.valid;
          case -12:
            return BaiduLinkCheckResult.invalidPwd; // 提取码错误
          case -6:
          case -9:
          case 110:
          case 116:
            return BaiduLinkCheckResult.linkExpired; // 链接失效
          default:
            return BaiduLinkCheckResult.linkExpired;
        }
      }
      return BaiduLinkCheckResult.networkError;
    } on DioException {
      return BaiduLinkCheckResult.networkError;
    } catch (_) {
      return BaiduLinkCheckResult.networkError;
    }
  }

  /// 无提取码（公开链接）的校验逻辑
  static Future<BaiduLinkCheckResult> _checkWithoutPwd(String linkInput) async {
    try {
      // 直接请求分享页面
      final response = await _dio.get(
        linkInput,
        options: Options(
          responseType: ResponseType.plain, // 拿到 HTML 页面源码
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final String html = response.data.toString();

        // 百度网盘失效页面的常见关键特征词
        if (html.contains('链接不存在') ||
            html.contains('链接已失效') ||
            html.contains('分享已被取消') ||
            html.contains('此链接已取消分享') ||
            html.contains('页面不存在')) {
          return BaiduLinkCheckResult.linkExpired;
        }

        // 如果页面包含请输入提取码的标志，说明此链接其实是有密链接，但用户没填提取码
        if (html.contains('请输入提取码') || html.contains('access-code')) {
          return BaiduLinkCheckResult.invalidPwd; // 提示用户需要提取码
        }

        // 正常包含文件列表或分享标题
        return BaiduLinkCheckResult.valid;
      }

      return BaiduLinkCheckResult.linkExpired;
    } on DioException {
      return BaiduLinkCheckResult.networkError;
    } catch (_) {
      return BaiduLinkCheckResult.networkError;
    }
  }

  /// 提取 surl 的辅助方法
  static String _parseSurl(String urlStr) {
    try {
      final uri = Uri.parse(urlStr.trim());
      String path = uri.path;

      String rawSurl = '';
      if (path.contains('/s/1')) {
        rawSurl = path.split('/s/1').last;
      } else if (path.contains('/s/')) {
        rawSurl = path.split('/s/').last;
      }

      if (rawSurl.contains('/')) {
        rawSurl = rawSurl.split('/').first;
      }

      return rawSurl;
    } catch (e) {
      return '';
    }
  }
}