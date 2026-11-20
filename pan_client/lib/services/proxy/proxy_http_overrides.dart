// lib/services/proxy/proxy_http_overrides.dart
import 'dart:io';

class ProxyHttpOverrides extends HttpOverrides {
  final String host;
  final int port;

  ProxyHttpOverrides({required this.host, required this.port});

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // 拦截全局 HTTP/HTTPS 请求走本地代理
    client.findProxy = (uri) {
      return 'PROXY $host:$port';
    };
    // 信任代理隧道中的证书（防止某些 HTTPS 校验失败）
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return client;
  }
}
