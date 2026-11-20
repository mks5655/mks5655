// lib/services/mihomo_service.dart

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// 引入错误日志模型与上报器
import '../models/app_error_log.dart';
import '../services/global_error_reporter.dart';

class MihomoService {
  static Process? _process;
  static const int proxyPort = 56558;

  static Pointer? _hJobHandle;
  static const _channel = MethodChannel('com.mksha.pan_client/native');

  /// 启动代理
  static Future<void> start() async {
    if (true) {
      print('=== [Mihomo] 手动关闭，已跳过启动 ===');
      return;
    }

    // 1. 明确拦截 iOS 平台
    if (Platform.isIOS) {
      print('=== [Mihomo] iOS 平台不受支持，已跳过 ===');
      return;
    }

    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final mihomoDir = Directory(p.join(appSupportDir.path, 'mihomo'));
      if (!await mihomoDir.exists()) {
        await mihomoDir.create(recursive: true);
      }

      final configPath = p.join(mihomoDir.path, 'config.yaml');
      String exePath;

      // 2. 判定平台：Android 走 so 库，桌面端（Windows/macOS/Linux）走 assets 提取
      if (Platform.isAndroid) {
        final String nativeDir = await _channel.invokeMethod(
          'getNativeLibraryDir',
        );
        exePath = p.join(nativeDir, 'libmihomo.so');
      } else {
        exePath = p.join(mihomoDir.path, _getDesktopExeName());

        // 提取 Asset 二进制二进制文件
        await _copyAssetToFile(_getDesktopAssetPath(), exePath);

        // 💡 针对 macOS / Linux 赋予权限与解封隔离
        if (!Platform.isWindows) {
          // 1) 赋予可执行权限（chmod +x）
          final chmodRes = await Process.run('chmod', ['+x', exePath]);
          if (chmodRes.exitCode != 0) {
            print('[Mihomo Err] chmod +x 失败: ${chmodRes.stderr}');
            throw Exception('chmod +x 失败: ${chmodRes.stderr}');
          }

          // 2) macOS 特有：解除 com.apple.quarantine 隔离标记
          if (Platform.isMacOS) {
            try {
              await Process.run('xattr', [
                '-d',
                'com.apple.quarantine',
                exePath,
              ]);
              print('[Mihomo] 已成功清除 macOS 隔离属性');
            } catch (e) {
              // 若文件本就无隔离标记，xattr 会报错，可静默忽略
              print('[Mihomo] 清理 xattr 提示: $e');
            }
          }
        }
      }

      // 3. 覆盖配置文件
      await _copyAssetToFile('assets/mihomo/config.yaml', configPath);

      // 4. 清理旧进程（防止端口被占用）
      await _cleanExistingProcessSync();

      // 5. 启动子进程
      _process = await Process.start(exePath, [
        '-d',
        mihomoDir.path,
        '-f',
        configPath,
      ], runInShell: false);

      _process?.stdout
          .transform(SystemEncoding().decoder)
          .listen((data) => print('[Mihomo Log]: $data'));
      _process?.stderr
          .transform(SystemEncoding().decoder)
          .listen((data) => print('[Mihomo Err]: $data'));

      _registerProcessAutoKill();

      // 6. 设置全局代理
      HttpOverrides.global = _AppHttpOverrides('127.0.0.1', proxyPort);

      print('Mihomo 启动成功 [${Platform.operatingSystem}], 路径: $exePath');
    } catch (e, stackTrace) {
      print('Mihomo 启动失败: $e');

      // 统一错误上报
      GlobalErrorReporter().reportError(
        AppErrorLog(
          errorType: 'MihomoStartError',
          message: 'Mihomo 启动失败: $e',
          stackTrace: stackTrace.toString(),
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
        ),
      );
    }
  }

  static void _registerProcessAutoKill() {
    SystemChannels.lifecycle.setMessageHandler((msg) async {
      if (msg == AppLifecycleState.detached.toString()) {
        await stop();
      }
      return null;
    });

    if (!Platform.isWindows && !Platform.isAndroid) {
      ProcessSignal.sigterm.watch().listen((_) async {
        await stop();
        exit(0);
      });
      ProcessSignal.sigint.watch().listen((_) async {
        await stop();
        exit(0);
      });
    }

    if (Platform.isWindows && _process != null) {
      _bindWindowsJobObject(_process!.pid);
    }
  }

  static void _bindWindowsJobObject(int childPid) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');

      final createJobObject = kernel32
          .lookupFunction<
            Pointer Function(Pointer, Pointer),
            Pointer Function(Pointer, Pointer)
          >('CreateJobObjectW');

      final setInformationJobObject = kernel32
          .lookupFunction<
            Int32 Function(Pointer, Int32, Pointer, Int32),
            int Function(Pointer, int, Pointer, int)
          >('SetInformationJobObject');

      final assignProcessToJobObject = kernel32
          .lookupFunction<
            Int32 Function(Pointer, Pointer),
            int Function(Pointer, Pointer)
          >('AssignProcessToJobObject');

      final openProcess = kernel32
          .lookupFunction<
            Pointer Function(Uint32, Int32, Uint32),
            Pointer Function(int, int, int)
          >('OpenProcess');

      final closeHandle = kernel32
          .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
            'CloseHandle',
          );

      _hJobHandle = createJobObject(nullptr, nullptr);
      if (_hJobHandle == nullptr || _hJobHandle == Pointer.fromAddress(0)) {
        return;
      }

      final infoLength = 112;
      final pInfo = calloc<Uint8>(infoLength);

      final limitFlagsPtr = Pointer<Uint32>.fromAddress(
        pInfo.address + (sizeOf<IntPtr>() == 8 ? 16 : 16),
      );
      limitFlagsPtr.value = 0x2000;

      final setRes = setInformationJobObject(
        _hJobHandle!,
        9,
        pInfo,
        infoLength,
      );
      calloc.free(pInfo);

      if (setRes != 0) {
        final hProcess = openProcess(0x0101, 0, childPid);
        if (hProcess != nullptr && hProcess != Pointer.fromAddress(0)) {
          assignProcessToJobObject(_hJobHandle!, hProcess);
          closeHandle(hProcess);
        }
      }
    } catch (e, stackTrace) {
      print('Win32 Job Object 绑定失败: $e');

      GlobalErrorReporter().reportError(
        AppErrorLog(
          errorType: 'MihomoWin32JobError',
          message: 'Win32 Job Object 绑定失败: $e',
          stackTrace: stackTrace.toString(),
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
        ),
      );
    }
  }

  /// 获取桌面端 Asset 路径
  static String _getDesktopAssetPath() {
    final abi = Abi.current();
    switch (abi) {
      case Abi.windowsX64:
        return 'assets/mihomo/windows/amd64/mihomo.exe';
      case Abi.macosArm64:
        return 'assets/mihomo/macos/arm64/mihomo';
      case Abi.macosX64:
        return 'assets/mihomo/macos/amd64/mihomo';
      case Abi.linuxX64:
        return 'assets/mihomo/linux/amd64/mihomo';
      default:
        throw UnsupportedError('Unsupported Abi: $abi');
    }
  }

  static String _getDesktopExeName() =>
      Platform.isWindows ? 'mihomo.exe' : 'mihomo';

  static Future<void> stop() async {
    try {
      HttpOverrides.global = null;

      if (_process != null) {
        _process!.kill(ProcessSignal.sigkill);
        _process = null;
      }

      _killExistingProcessAsync();
      print('Mihomo 进程清理完毕');
    } catch (e, stackTrace) {
      print('关闭 Mihomo 时发生异常: $e');

      GlobalErrorReporter().reportError(
        AppErrorLog(
          errorType: 'MihomoStopError',
          message: '关闭 Mihomo 时发生异常: $e',
          stackTrace: stackTrace.toString(),
          timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
        ),
      );
    }
  }

  static Future<void> _cleanExistingProcessSync() async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/IM', 'mihomo.exe']);
      } else {
        // macOS / Linux 结合 killall 和 pkill 保证清理干净
        await Process.run('killall', ['-9', 'mihomo']);
        await Process.run('pkill', ['-9', '-f', 'libmihomo.so']);
        await Process.run('pkill', ['-9', '-f', 'mihomo']);
      }
    } catch (_) {}
  }

  static void _killExistingProcessAsync() {
    try {
      if (Platform.isWindows) {
        Process.start('taskkill', [
          '/F',
          '/T',
          '/IM',
          'mihomo.exe',
        ], runInShell: true);
      } else {
        Process.start('killall', ['-9', 'mihomo']);
        Process.start('pkill', ['-9', '-f', 'libmihomo.so']);
        Process.start('pkill', ['-9', '-f', 'mihomo']);
      }
    } catch (_) {}
  }

  static Future<void> _copyAssetToFile(
    String assetPath,
    String filePath,
  ) async {
    final file = File(filePath);
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await file.writeAsBytes(bytes, flush: true);
  }
}

class _AppHttpOverrides extends HttpOverrides {
  final String host;
  final int port;

  _AppHttpOverrides(this.host, this.port);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => 'PROXY $host:$port';
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}
