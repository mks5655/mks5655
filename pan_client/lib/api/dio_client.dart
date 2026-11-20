import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

// 引入统一错误日志模型与上报服务
import '../models/app_error_log.dart';
import '../services/global_error_reporter.dart';

/// 全局 Dio 客户端网络管理类
///
/// 包含两个独立的 Dio 实例：
/// 1. [apiDio]: 处理后端 API 请求，支持代理优先+直连回退，并进行强硬的根证书 TLS 校验防抓包。
/// 2. [downloadDio]: 处理百度网盘直链下载，严格绑定本地代理，代理断开或节点不可用时触发安全熔断，绝不直连。
class DioClient {
  /// 本地百度直连代理服务的 IP 地址
  static const String proxyHost = '127.0.0.1';

  /// 本地百度直连代理服务的端口
  static const int proxyPort = 56558;

  /// 通道 1：后端 API 专用 Dio
  late Dio apiDio;

  /// 通道 2：百度网盘直链/dlink 专用 Dio
  late Dio downloadDio;

  /// 快捷 getter，兼容现有业务代码中使用 client.dio 发起 API 请求的场景
  Dio get dio => apiDio;

  // ===========================================================================
  // 🛡️ 预嵌入权威 Root CA 证书（Raw String 格式，严格保留原样换行与空格）
  // ===========================================================================

  /// Let's Encrypt 官方根证书 (ISRG Root X1)
  static const String _isrgRootX1Pem = r'''
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRmOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
''';

  /// Google Trust Services 官方根证书 (GTS Root R1)
  static const String _gtsRootR1Pem = r'''
-----BEGIN CERTIFICATE-----
MIIFVzCCAz+gAwIBAgINAgPlk28xsBNJiGuiFzANBgkqhkiG9w0BAQwFADBHMQsw
CQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEU
MBIGA1UEAxMLR1RTIFJvb3QgUjEwHhcNMTYwNjIyMDAwMDAwWhcNMzYwNjIyMDAw
MDAwWjBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZp
Y2VzIExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjEwggIiMA0GCSqGSIb3DQEBAQUA
A4ICDwAwggIKAoICAQC2EQKLHuOhd5s73L+UPreVp0A8of2C+X0yBoJx9vaMf/vo
27xqLpeXo4xL+Sv2sfnOhB2x+cWX3u+58qPpvBKJXqeqUqv4IyfLpLGcY9vXmX7w
Cl7raKb0xlpHDU0QM+NOsROjyBhsS+z8CZDfnWQpJSMHobTSPS5g4M/SCYe7zUjw
TcLCeoiKu7rPWRnWr4+wB7CeMfGCwcDfLqZtbBkOtdh+JhpFAz2weaSUKK0Pfybl
qAj+lug8aJRT7oM6iCsVlgmy4HqMLnXWnOunVmSPlk9orj2XwoSPwLxAwAtcvfaH
szVsrBhQf4TgTM2S0yDpM7xSma8ytSmzJSq0SPly4cpk9+aCEI3oncKKiPo4Zor8
Y/kB+Xj9e1x3+naH+uzfsQ55lVe0vSbv1gHR6xYKu44LtcXFilWr06zqkUspzBmk
MiVOKvFlRNACzqrOSbTqn3yDsEB750Orp2yjj32JgfpMpf/VjsPOS+C12LOORc92
wO1AK/1TD7Cn1TsNsYqiA94xrcx36m97PtbfkSIS5r762DL8EGMUUXLeXdYWk70p
aDPvOmbsB4om3xPXV2V4J95eSRQAogB/mqghtqmxlbCluQ0WEdrHbEg8QOB+DVrN
VjzRlwW5y0vtOUucxD/SVRNuJLDWcfr0wbrM7Rv1/oFB2ACYPTrIrnqYNxgFlQID
AQABo0IwQDAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4E
FgQU5K8rJnEaK0gnhS9SZizv8IkTcT4wDQYJKoZIhvcNAQEMBQADggIBAJ+qQibb
C5u+/x6Wki4+omVKapi6Ist9wTrYggoGxval3sBOh2Z5ofmmWJyq+bXmYOfg6LEe
QkEzCzc9zolwFcq1JKjPa7XSQCGYzyI0zzvFIoTgxQ6KfF2I5DUkzps+GlQebtuy
h6f88/qBVRRiClmpIgUxPoLW7ttXNLwzldMXG+gnoot7TiYaelpkttGsN/H9oPM4
7HLwEXWdyzRSjeZ2axfG34arJ45JK3VmgRAhpuo+9K4l/3wV3s6MJT/KYnAK9y8J
ZgfIPxz88NtFMN9iiMG1D53Dn0reWVlHxYciNuaCp+0KueIHoI17eko8cdLiA6Ef
MgfdG+RCzgwARWGAtQsgWSl4vflVy2PFPEz0tv/bal8xa5meLMFrUKTX5hgUvYU/
Z6tGn6D/Qqc6f1zLXbBwHSs09dR2CQzreExZBfMzQsNhFRAbd03OIozUhfJFfbdT
6u9AWpQKXCBfTkBdYiJ23//OYb2MI3jSNwLgjt7RETeJ9r/tSQdirpLsQBqvFAnZ
0E6yove+7u7Y/9waLd64NnHi/Hm3lCXRSHNboTXns5lndcEZOitHTtNCjv0xyBZm
2tIMPNuzjsmhDYAPexZ3FL//2wmUspO8IFgV6dtxQ/PeEMMA3KgqlbbC1j+Qa3bb
bP6MvPJwNQzcmRk13NfIRmPVNnGuV/u3gm3c
-----END CERTIFICATE-----
''';

  /// 辅助方法：参照 BaiduProxyService 的风格统一上报日志
  static void _reportException(
    String errorType,
    String message, [
    dynamic stackTrace,
  ]) {
    GlobalErrorReporter().reportError(
      AppErrorLog(
        errorType: errorType,
        message: message,
        stackTrace: stackTrace?.toString() ?? StackTrace.current.toString(),
        timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      ),
    );
  }

  DioClient() {
    // =========================================================================
    // 通道 1：后端 API (mtd.dpdns.org)
    // 策略：优先走本地代理，代理连不通（未启动/宕机）时自动透明回退到 DIRECT 直连。
    // 安全：丢弃操作系统根证书信任库，仅绑定预置的官方 Root CA 库，彻底阻断 Reqable 抓包。
    // =========================================================================
    apiDio = Dio(
      BaseOptions(
        baseUrl: "https://baidu-pan.mtd.dpdns.org",
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        headers: {"Accept": "application/json"},
      ),
    );

    apiDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        // 🔒 1. 创建独立的安全上下文，并传入 withTrustedRoots: false
        // 这会显式清空操作系统默认的根证书库，使任何在系统层安装的抓包软件 CA (如 Reqable/Fiddler/Charles) 失效！
        final securityContext = SecurityContext(withTrustedRoots: false);

        try {
          // 🔒 2. 拼接官方 Let's Encrypt + Google GTS 根证书链并转化为 UTF8 字节数组导入
          final combinedPem = "${_isrgRootX1Pem.trim()}\n\n${_gtsRootR1Pem.trim()}\n";
          final List<int> certBytes = utf8.encode(combinedPem);

          // 手动向 Isolated Context 载入唯一可信的根证书库
          securityContext.setTrustedCertificatesBytes(certBytes);
          print("✅ [SecurityContext] 成功载入 Trust Anchors（ISRG Root X1 + GTS Root R1）");
        } catch (e, stackTrace) {
          print("🚨 [TLS Fatal] 加载官方 Trust Anchors 根证书失败: $e");
          // 📢 上报证书加载异常日志
          _reportException(
            'DioClientTLSError',
            '加载官方 Trust Anchors 根证书失败: $e',
            stackTrace,
          );
        }

        final client = HttpClient(context: securityContext);

        // 🔄 3. 核心路由策略：代理优先 + 直连自动回退
        // 语法解析：使用 ';' 分隔多个连接选项。底层 Socket 会先尝试连接 PROXY 127.0.0.1:56558；
        // 如果本地代理未开启（Connection Refused）或挂掉，会自动无缝降级走 DIRECT 直连，保证 API 始终可用。
        client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort; DIRECT';

        // 🔒 4. 强硬零信任拦截回调：
        // 只要服务器返回的证书无法在 Dart 底层利用上面载入的 ISRG Root X1 / GTS Root R1 根证书进行【数学签名校验】
        // （例如 Reqable 试图用自己的 CA 现场伪造服务端证书），就会触发此回调。
        client.badCertificateCallback = (X509Certificate cert, String host, int port) {
          final msg = "🚨 [防伪装拦截成功] 检测到被抓包/证书伪造！Host: $host, Port: $port, Issuer: ${cert.issuer}";
          print(msg);

          // 📢 1. 上报【被抓包日志】/ MitM 企图
          _reportException(
            'NetworkCapturedWarning',
            '检测到中间人抓包/伪造 CA 证书: $msg (Subject: ${cert.subject})',
            StackTrace.current,
          );

          // 返回 false 意味着强行切断 TLS 握手，Dio 会抛出 DioException，绝不放行伪造流量！
          return false;
        };

        return client;
      },
    );

    // =========================================================================
    // 通道 2：网盘直链 downloadDio (baidupcs.com / pcs.baidu.com)
    // 策略：强行死锁本地代理！探针失败立刻抛异常砸断，绝对不允许任何直连！
    // =========================================================
    downloadDio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        followRedirects: false, // 禁用 Dio 自动重定向，以便手动把控每一个 HTTP 跳转步骤
      ),
    );

    downloadDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();

        // 🔒 绝对不带有 '; DIRECT' 后缀！强行锁定仅允许走本地代理
        client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';

        // 缩短连接超时时间，防止在失效的代理连接上无限等待
        client.connectionTimeout = const Duration(seconds: 4);

        // 百度网盘直链节点通常为 IP / 动态 CDN，且必须走本地代理转换，因此跳过直链证书校验
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
    );

    // 🛡️ 网盘直链安全熔断拦截器：在发包前进行“双重探针”穿透测试
    downloadDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // 发起请求前，实时检测：1. 本地代理端口是否在监听  2. Mihomo 代理节点是否能真实连通公网
          bool isNodeAlive = await _checkProxyAndNodeAlive(proxyHost, proxyPort);

          if (!isNodeAlive) {
            final errorMsg = "🔒 熔断起效：Mihomo 节点不可用，已拦截 dlink 网盘请求，绝对未直连！URL: ${options.uri}";

            // 📢 2. 上报【安全熔断/异常日志】
            _reportException(
              'ProxyFuseTriggeredError',
              errorMsg,
              StackTrace.current,
            );

            // 🚨 代理端口没开 或 Mihomo 外网节点不可用
            // 强行改写请求 Path 为无效的本地 127.0.0.1:1 地址。
            // 确保哪怕 Dart 底层发生任何不可预知的行为，也绝对无法触及真正网盘公网！
            options.path = "http://127.0.0.1:1/blocked_proxy_dead";

            // 直接拒绝请求并返回包含自定义错误信息的 DioException，激活安全熔断机制
            return handler.reject(
              DioException(
                requestOptions: options,
                error: errorMsg,
                type: DioExceptionType.connectionError,
              ),
            );
          }

          // 探针通过，代理正常，放行请求
          return handler.next(options);
        },
        onError: (DioException err, handler) {
          // 📢 3. 上报【下载网络异常日志】
          _reportException(
            'DownloadDioError',
            '直链下载网络异常: ${err.message} (Type: ${err.type})',
            err.stackTrace,
          );
          return handler.next(err);
        },
      ),
    );
  }

  /// 真实连通性测试（探针穿透测试）
  ///
  /// 先通过底层 [Socket.connect] 验证本地代理端口，
  /// 再发起一次极简的 HTTP 204 GET 握手，验证外网代理节点是否真的有能力处理流量。
  Future<bool> _checkProxyAndNodeAlive(String host, int port) async {
    try {
      // Step 1: 测试本地 127.0.0.1:56558 代理端口连通性
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy(); // 连通即销毁，释放 Socket 资源

      // Step 2: 发起一次走代理的极简 HTTP GET 请求，验证代理节点能否连通公网
      final client = HttpClient();
      client.findProxy = (uri) => 'PROXY $host:$port';
      client.connectionTimeout = const Duration(milliseconds: 1200);

      // 请求 Cloudflare 的 204 极简探针地址（响应体为空，极省流量）
      final request = await client.getUrl(
        Uri.parse('http://cp.cloudflare.com/generate_204'),
      );
      final response = await request.close();

      // 返回 204 或 200 即说明该代理节点能够成功转发外网流量
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (e, stackTrace) {
      // 只要捕捉到 Connection Refused、Timeout 或 Proxy Error，直接判定节点死亡
      // 📢 上报探针异常信息
      _reportException(
        'ProxyProbeCheckFailed',
        '代理探针连通性检测失败 ($host:$port): $e',
        stackTrace,
      );
      return false;
    }
  }
}