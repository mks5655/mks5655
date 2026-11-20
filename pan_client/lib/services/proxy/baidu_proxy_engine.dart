// lib/services/proxy/baidu_proxy_engine.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class BaiduProxyEngine {
  static const String baiduProxyHost = 'cloudnproxy.baidu.com';
  static const int baiduProxyPort = 443;

  // 1. 预置百度代理备用 IP 池（可根据需要自行扩充）
  static final List<String> _baiduIpPool = [
    '153.3.237.117',
    '180.101.50.249',
    '180.101.50.208',
    '220.181.7.1',
    '220.181.33.174',
    "220.181.111.189",
    "183.240.98.84",
    "36.155.169.188",
    "36.155.169.188",
    "163.177.17.6",
    "163.177.17.189",
    "110.242.70.68",
    "110.242.70.69",
    "153.3.237.117",
    "157.0.146.158",

  ];

  // 2. 内存锁定的有效 IP（只要 App 不重启，此变量锁定后绝不重置或更换）
  static String? _lockedIp;

  static void _logInfo(String tag, String msg) =>
      print('\x1B[32m[$tag]\x1B[0m $msg');
  static void _logWarn(String tag, String msg) =>
      print('\x1B[33m[$tag]\x1B[0m $msg');
  static void _logError(String tag, String msg) =>
      print('\x1B[31m[$tag]\x1B[0m $msg');

  /// 处理接入的客户端连接
  static Future<void> handleClient(Socket client) async {
    final clientTag =
        'Client:${client.remoteAddress.address}:${client.remotePort}';
    _logInfo('CONNECT', '收到新的客户端连接 $clientTag');

    final completer = Completer<Uint8List>();
    late StreamSubscription clientSub;

    // 创建 client 监听
    clientSub = client.listen(
      (data) {
        if (!completer.isCompleted) {
          completer.complete(data);
        }
      },
      onError: (e) {
        _logError('CLIENT_ERR', '$clientTag 发生错误: $e');
        _closeSocket(client);
      },
      onDone: () {
        _logWarn('CLIENT_CLOSE', '$clientTag 断开连接');
        _closeSocket(client);
      },
    );

    Uint8List initialData;
    try {
      initialData = await completer.future;
    } catch (e) {
      _logError('NO_DATA', '$clientTag 首包读取失败: $e');
      await clientSub.cancel();
      _closeSocket(client);
      return;
    }

    clientSub.pause();

    if (initialData.isEmpty) {
      _logWarn('EMPTY', '$clientTag 发送了空数据');
      await clientSub.cancel();
      _closeSocket(client);
      return;
    }

    String targetHost = '';
    int targetPort = 80;
    bool isSocks5 = false;
    bool isConnectMethod = false;
    Uint8List? leftoverData;

    // 协议解析
    if (initialData[0] == 0x05) {
      isSocks5 = true;
      _logInfo('PARSE', '$clientTag 识别为 SOCKS5 协议');
      final parseResult = await _handshakeSocks5(
        client,
        clientSub,
        initialData,
        clientTag,
      );
      if (parseResult == null) {
        _logError('PARSE_ERR', '$clientTag SOCKS5 握手失败');
        await clientSub.cancel();
        _closeSocket(client);
        return;
      }
      targetHost = parseResult.host;
      targetPort = parseResult.port;
    } else {
      _logInfo('PARSE', '$clientTag 识别为 HTTP 代理协议');
      final parseResult = _parseHttpProxyHeader(initialData);
      if (parseResult == null) {
        _logError('PARSE_ERR', '$clientTag HTTP Header 解析失败');
        await clientSub.cancel();
        _closeSocket(client);
        return;
      }
      targetHost = parseResult.host;
      targetPort = parseResult.port;
      isConnectMethod = parseResult.isConnect;

      leftoverData = _extractLeftoverData(initialData, isConnectMethod);
      if (leftoverData != null) {
        _logInfo('STICKY', '$clientTag 提取出首包粘包数据: ${leftoverData.length} 字节');
      }
    }

    _logInfo(
      'TARGET',
      '$clientTag 目标地址: $targetHost:$targetPort (isConnect: $isConnectMethod)',
    );

    // 建立百度直连隧道
    Socket? baiduSocket;
    StreamSubscription? baiduSub;
    try {
      final baiduRes = await connectViaBaiduProxy(
        targetHost,
        targetPort,
        clientTag,
      );
      baiduSocket = baiduRes.socket;
      baiduSub = baiduRes.subscription;
    } catch (e) {
      _logError('BAIDU_ERR', '$clientTag 建立百度隧道失败: $e');
      if (isSocks5) {
        _sendSocks5Response(client, 0x05);
      } else if (isConnectMethod) {
        try {
          client.add(utf8.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
          await client.flush();
        } catch (_) {}
      }
      await clientSub.cancel();
      _closeSocket(client);
      return;
    }

    // 回复客户端成功响应
    if (isSocks5) {
      _logInfo('RESPONSE', '向 $clientTag 响应 SOCKS5 成功握手');
      _sendSocks5Response(client, 0x00);
    } else if (isConnectMethod) {
      _logInfo('RESPONSE', '向 $clientTag 响应 200 Connection Established');
      try {
        client.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        await client.flush();
      } catch (e) {
        _logError('RESPONSE_ERR', '$clientTag 写入 200 响应失败: $e');
        await clientSub.cancel();
        await baiduSub.cancel();
        _closeSocket(client);
        _closeSocket(baiduSocket);
        return;
      }
    }

    // 将首包解出的黏包/剩余数据写入百度隧道
    if (leftoverData != null && leftoverData.isNotEmpty) {
      _logInfo('FORWARD', '向百度隧道写入粘包数据 ${leftoverData.length} 字节');
      baiduSocket.add(leftoverData);
    }

    // 双向透传
    _logInfo('PIPE', '开始为 $clientTag 构建双向透传管道');
    _pipeSockets(client, clientSub, baiduSocket, baiduSub, clientTag);
  }

  /// 建立百度隧道（锁定生效后死磕锁定 IP，只有重启 App 才能重选 IP）
  static Future<({Socket socket, StreamSubscription subscription})>
  connectViaBaiduProxy(
    String targetHost,
    int targetPort,
    String clientTag,
  ) async {
    // 场景 A：如果已经成功锁定过 IP，本次 App 生命周期内直接使用该 IP
    if (_lockedIp != null) {
      _logInfo('BAIDU_CONN', '使用本次运行已锁定的百度代理 IP: $_lockedIp');
      return await _tryConnectSingleIp(_lockedIp!, targetHost, targetPort, clientTag);
    }

    // 场景 B：App 启动后的首次请求，遍历探活并锁定 IP
    List<String> candidateIps = [];

    // 1. 优先获取系统的 DNS IPv4 地址（排除 198.18.x.x 等 Fake IP）
    try {
      final addresses = await InternetAddress.lookup(
        baiduProxyHost,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 3));
      
      for (var addr in addresses) {
        final ipStr = addr.address;
        // 💥 过滤 Clash / Mihomo 等代理软件生成的 Fake IP (198.18.0.0/15)
        if (ipStr.startsWith('198.18.') || ipStr.startsWith('198.19.')) {
          _logWarn('DNS_SKIP', '检测到代理软件 Fake IP: $ipStr，自动跳过');
          continue;
        }
        candidateIps.add(ipStr);
      }
    } catch (e) {
      _logWarn('DNS_ERR', '解析域名 $baiduProxyHost 失败，使用硬编码备用 IP 池');
    }

    // 2. 追加备用硬编码 IP 池（去重）
    for (var ip in _baiduIpPool) {
      if (!candidateIps.contains(ip)) {
        candidateIps.add(ip);
      }
    }

    if (candidateIps.isEmpty) {
      throw SocketException('无可用的百度代理节点 IP');
    }

    _logInfo('IP_POOL', '首次连接，开始寻找可用 IP: $candidateIps');

    // 3. 依次尝试连接与握手，找到第一个可用 IP 并永久锁定
    Object? lastError;
    for (String currentIp in candidateIps) {
      try {
        _logInfo('TRY_IP', '正在测试节点 IP: $currentIp ...');
        final res = await _tryConnectSingleIp(currentIp, targetHost, targetPort, clientTag);

        // 成功！写入静态变量锁定，进程退出前不再更改
        _lockedIp = currentIp;
        _logInfo('LOCK_IP', '已成功锁定 IP: $_lockedIp (本次 App 进程退出前将不再更换)');
        return res;
      } catch (e) {
        _logWarn('IP_FAIL', '节点 IP $currentIp 连不上: $e，尝试下一个...');
        lastError = e;
      }
    }

    throw SocketException('所有百度节点均不可用，最后一次报错: $lastError');
  }

/// 针对单个 IP 执行 TCP 连接与 CONNECT 伪装头握手
  static Future<({Socket socket, StreamSubscription subscription})>
  _tryConnectSingleIp(
    String ip,
    String targetHost,
    int targetPort,
    String clientTag,
  ) async {
    // 💥 1. 尝试强转 IPv4，但严格过滤 Clash/Mihomo 等生成的 Fake IP (198.18.x.x)
    String resolvedTargetHost = targetHost;
    final isIpAddress = InternetAddress.tryParse(targetHost) != null;

    if (!isIpAddress) {
      try {
        final ips = await InternetAddress.lookup(
          targetHost,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 3));

        for (var addr in ips) {
          final ipStr = addr.address;
          // 如果解析结果是 Fake IP，跳过，不拿 Fake IP 去请求百度
          if (ipStr.startsWith('198.18.') || ipStr.startsWith('198.19.')) {
            continue;
          }
          resolvedTargetHost = ipStr;
          _logInfo('IPV4_RESOLVE', '直链域名 $targetHost 已强转锁定公网 IPv4: $resolvedTargetHost');
          break;
        }
      } catch (e) {
        _logWarn('DNS_WARN', '直链域名 $targetHost 解析 IPv4 失败，退回原始域名: $e');
      }
    }

    final socket = await Socket.connect(
      ip,
      baiduProxyPort,
      timeout: const Duration(seconds: 4),
    );

    // 💥 2. 发送伪装 CONNECT 报文
    final handshakePayload =
        'CONNECT $resolvedTargetHost:$targetPort HTTP/1.1\r\n'
        'Host: 153.3.236.22:443\r\n'
        '$resolvedTargetHost:$targetPort\r\n'
        'Proxy-Connection: Keep-Alive\r\n'
        'X-T5-Auth: 683556433\r\n'
        'User-Agent: baiduboxapp\r\n\r\n';

    socket.add(utf8.encode(handshakePayload));

    final responseBuffer = BytesBuilder();
    final completer = Completer<Uint8List?>();

    late StreamSubscription baiduSub;
    baiduSub = socket.listen(
      (chunk) {
        responseBuffer.add(chunk);
        final bytes = responseBuffer.toBytes();

        // 寻找响应头结束符 \r\n\r\n
        for (int i = 0; i < bytes.length - 3; i++) {
          if (bytes[i] == 13 &&
              bytes[i + 1] == 10 &&
              bytes[i + 2] == 13 &&
              bytes[i + 3] == 10) {
            
            final headerStr = utf8.decode(bytes, allowMalformed: true);
            if (!headerStr.startsWith('HTTP/1.1 200') &&
                !headerStr.startsWith('HTTP/1.0 200')) {
              if (!completer.isCompleted) {
                completer.completeError('代理响应非 200: ${headerStr.split('\r\n')[0]}');
              }
              return;
            }

            baiduSub.pause();
            Uint8List? extra;
            if (i + 4 < bytes.length) {
              extra = bytes.sublist(i + 4);
            }
            if (!completer.isCompleted) completer.complete(extra);
            return;
          }
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.completeError('百度代理提前断开');
      },
    );

    try {
      await completer.future.timeout(const Duration(seconds: 5));
      return (socket: socket, subscription: baiduSub);
    } catch (e) {
      await baiduSub.cancel();
      _closeSocket(socket);
      rethrow;
    }
  }

  static Future<({String host, int port})?> _handshakeSocks5(
    Socket client,
    StreamSubscription clientSub,
    Uint8List firstChunk,
    String clientTag,
  ) async {
    client.add(Uint8List.fromList([0x05, 0x00]));

    final completer = Completer<Uint8List>();
    clientSub.onData((data) {
      if (!completer.isCompleted) completer.complete(data);
    });
    clientSub.resume();

    Uint8List req;
    try {
      req = await completer.future.timeout(const Duration(seconds: 5));
      clientSub.pause();
    } catch (_) {
      _logError('SOCKS_ERR', '$clientTag 接收 SOCKS5 请求超时');
      return null;
    }

    if (req.length < 7 || req[1] != 0x01) {
      _logError('SOCKS_ERR', '$clientTag 不支持的 SOCKS5 命令');
      return null;
    }

    String host = '';
    int port = 0;
    int addressType = req[3];

    if (addressType == 0x01) {
      host = '${req[4]}.${req[5]}.${req[6]}.${req[7]}';
      port = (req[8] << 8) | req[9];
    } else if (addressType == 0x03) {
      int domainLen = req[4];
      if (req.length < 5 + domainLen + 2) return null;
      host = utf8.decode(req.sublist(5, 5 + domainLen));
      port = (req[5 + domainLen] << 8) | req[5 + domainLen + 1];
    } else if (addressType == 0x04) {
      if (req.length < 22) return null;
      List<String> segments = [];
      for (int i = 4; i < 20; i += 2) {
        segments.add(((req[i] << 8) | req[i + 1]).toRadixString(16));
      }
      host = segments.join(':');
      port = (req[20] << 8) | req[21];
    } else {
      _logError('SOCKS_ERR', '$clientTag 未知的 SOCKS5 地址类型: $addressType');
      return null;
    }

    return (host: host, port: port);
  }

  static void _sendSocks5Response(Socket client, int rep) {
    client.add(Uint8List.fromList([0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
  }

  static ({String host, int port, bool isConnect})? _parseHttpProxyHeader(
    Uint8List data,
  ) {
    try {
      String header = utf8.decode(data, allowMalformed: true);
      final lines = header.split('\r\n');
      if (lines.isEmpty) return null;

      final firstLine = lines[0].split(' ');
      if (firstLine.length < 2) return null;

      final method = firstLine[0].toUpperCase();
      final url = firstLine[1];

      if (method == 'CONNECT') {
        final parts = url.split(':');
        return (
          host: parts[0],
          port: parts.length > 1 ? int.parse(parts[1]) : 443,
          isConnect: true,
        );
      } else {
        final uri = Uri.parse(url);
        if (uri.hasAuthority) {
          return (host: uri.host, port: uri.port, isConnect: false);
        }
        for (var line in lines) {
          if (line.toLowerCase().startsWith('host:')) {
            final hostPort = line.substring(5).trim().split(':');
            return (
              host: hostPort[0],
              port: hostPort.length > 1 ? int.parse(hostPort[1]) : 80,
              isConnect: false,
            );
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Uint8List? _extractLeftoverData(
    Uint8List initialData,
    bool isConnect,
  ) {
    if (!isConnect) {
      return _rewriteHttpRequestHeader(initialData);
    }

    for (int i = 0; i < initialData.length - 3; i++) {
      if (initialData[i] == 13 &&
          initialData[i + 1] == 10 &&
          initialData[i + 2] == 13 &&
          initialData[i + 3] == 10) {
        final headerEndIndex = i + 4;
        if (headerEndIndex < initialData.length) {
          return initialData.sublist(headerEndIndex);
        }
        break;
      }
    }
    return null;
  }

  static Uint8List _rewriteHttpRequestHeader(Uint8List data) {
    try {
      String header = utf8.decode(data, allowMalformed: true);
      final lines = header.split('\r\n');
      if (lines.isNotEmpty) {
        final firstLine = lines[0].split(' ');
        if (firstLine.length >= 3) {
          final uri = Uri.parse(firstLine[1]);
          if (uri.hasScheme) {
            final path =
                (uri.path.isEmpty ? '/' : uri.path) +
                (uri.hasQuery ? '?${uri.query}' : '');
            lines[0] = '${firstLine[0]} $path ${firstLine[2]}';
            return utf8.encode(lines.join('\r\n'));
          }
        }
      }
    } catch (_) {}
    return data;
  }

  static void _pipeSockets(
    Socket client,
    StreamSubscription clientSub,
    Socket baiduSocket,
    StreamSubscription baiduSub,
    String clientTag,
  ) {
    bool isClosed = false;

    Future<void> closeAll() async {
      if (isClosed) return;
      isClosed = true;

      _logWarn('CLOSE', '销毁双向 Socket 连接 ($clientTag)');
      await clientSub.cancel();
      await baiduSub.cancel();
      _closeSocket(client);
      _closeSocket(baiduSocket);
    }

    // 1. 客户端 -> 百度
    clientSub.onData((data) {
      if (isClosed) return;
      try {
        baiduSocket.add(data);
      } catch (e) {
        _logError('PIPE_ERR', '$clientTag 写入百度失败: $e');
        closeAll();
      }
    });

    clientSub.onError((e) {
      _logError('PIPE_ERR', '$clientTag 客户端流错误: $e');
      closeAll();
    });

    clientSub.onDone(() {
      _logWarn('PIPE_DONE', '$clientTag 客户端关闭流');
      closeAll();
    });

    // 2. 百度 -> 客户端
    baiduSub.onData((data) {
      if (isClosed) return;
      try {
        client.add(data);
      } catch (e) {
        _logError('PIPE_ERR', '写入 $clientTag 失败: $e');
        closeAll();
      }
    });

    baiduSub.onError((e) {
      _logError('PIPE_ERR', '百度流错误: $e');
      closeAll();
    });

    baiduSub.onDone(() {
      _logWarn('PIPE_DONE', '百度断开流');
      closeAll();
    });

    // 恢复数据流传输
    clientSub.resume();
    baiduSub.resume();
  }

  static void _closeSocket(Socket? s) {
    if (s == null) return;
    try {
      s.destroy();
    } catch (_) {}
  }
}