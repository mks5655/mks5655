import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/download_task.dart';
import '../api/dio_client.dart';
import '../services/traffic_reporter.dart';

class DownloadEngine {
  final Dio _dio = DioClient().downloadDio;
  final TrafficReporter? reporter;

  // 核心防线：全局静态文件排他锁，防止新旧任务并发写同一个文件
  static final Map<String, Completer<void>> _fileLocks = {};

  DownloadEngine({this.reporter});

  Future<void> download(
    DownloadTask task,
    void Function(int current, int total) onProgress,
  ) async {
    final savePath = task.savePath;
    if (savePath == null || savePath.isEmpty) {
      throw Exception("未指定保存路径");
    }

    // 1. 排队等待针对该文件的旧句柄彻底释放
    while (_fileLocks.containsKey(savePath)) {
      await _fileLocks[savePath]!.future;
    }

    final lockCompleter = Completer<void>();
    _fileLocks[savePath] = lockCompleter;

    try {
      await _doDownload(task, onProgress);
    } finally {
      // 2. 确保任务结束（无论成功、报错还是被取消）后释放锁
      _fileLocks.remove(savePath);
      if (!lockCompleter.isCompleted) {
        lockCompleter.complete();
      }
    }
  }

  Future<void> _doDownload(
    DownloadTask task,
    void Function(int current, int total) onProgress,
  ) async {
    final savePath = task.savePath!;
    final file = File(savePath);
    int downloadedBytes = 0;

    if (file.existsSync()) {
      downloadedBytes = file.lengthSync();
      task.downloaded = downloadedBytes;
    }

    print(
      "--- [Engine] 开始执行下载任务: ${task.filename} | 已下载: $downloadedBytes | Status: ${task.status} ---",
    );

    if (task.size > 0 && downloadedBytes >= task.size) {
      print("--- [Engine] 文件已完整存在，无需重复下载 ---");
      if (downloadedBytes > task.size) {
        final raf = file.openSync(mode: FileMode.writeOnlyAppend);
        raf.truncateSync(task.size);
        raf.closeSync();
        downloadedBytes = task.size;
        task.downloaded = task.size;
      }
      onProgress(task.size, task.size);
      return;
    }

    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.cancelled ||
        task.cancelToken.isCancelled) {
      print("--- [Engine 防线0] 检测到任务已被暂停/取消，退出下载 ---");
      return;
    }

    final parentDir = file.parent;
    if (!await parentDir.exists()) {
      print("--- [Engine] 父目录不存在，自动递归创建目录: ${parentDir.path} ---");
      await parentDir.create(recursive: true);
    }

    int retryCount = 0;
    const int maxSocketRetries = 5;

    while (retryCount <= maxSocketRetries) {
      final options = Options(
        headers: {
          if (downloadedBytes > 0) 'Range': 'bytes=$downloadedBytes-',
          'User-Agent': 'pan.baidu.com',
          'Connection': 'keep-alive',
        },
        responseType: ResponseType.stream,
        validateStatus: (status) => status != null && status < 500,
        receiveTimeout: const Duration(seconds: 30),
      );

      IOSink? sink;
      StreamSubscription<List<int>>? subscription;

      try {
        print(
          "--- [Engine] 发起 Dio GET 请求 (尝试第 ${retryCount + 1} 次)... 已下载: $downloadedBytes ---",
        );

        final response = await _dio.get<ResponseBody>(
          task.dlink!,
          options: options,
          cancelToken: task.cancelToken,
        );

        final statusCode = response.statusCode ?? 0;
        print("--- [Engine] 收到响应状态码: $statusCode ---");

        if (statusCode == 403 || statusCode == 410) {
          throw DioException(
            requestOptions: response.requestOptions,
            response: response,
            type: DioExceptionType.badResponse,
            error: "Http status $statusCode",
          );
        }

        if (statusCode == 416) {
          if (task.size > 0) {
            task.downloaded = task.size;
            onProgress(task.size, task.size);
          }
          return;
        }

        bool isPartial = (statusCode == 206);

        if (statusCode == 200) {
          isPartial = false;
          downloadedBytes = 0;
          task.downloaded = 0;
        } else if (statusCode != 206) {
          throw Exception("服务器响应异常: $statusCode");
        }

        int totalBytes = task.size;
        final contentRangeStr = response.headers.value('content-range');
        final contentLengthStr = response.headers.value('content-length');

        if (contentRangeStr != null) {
          final match = RegExp(
            r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
          ).firstMatch(contentRangeStr);
          if (match != null) {
            final serverStartByte = int.tryParse(match.group(1) ?? '') ?? 0;
            final serverTotal = int.tryParse(match.group(3) ?? '') ?? 0;

            if (isPartial && serverStartByte != downloadedBytes) {
              downloadedBytes = serverStartByte;
              task.downloaded = downloadedBytes;
            }

            if (serverTotal > 0) {
              totalBytes = serverTotal;
            }
          }
        } else if (contentLengthStr != null) {
          final contentLength = int.tryParse(contentLengthStr) ?? 0;
          if (contentLength > 0) {
            totalBytes = isPartial
                ? (downloadedBytes + contentLength)
                : contentLength;
          }
        }

        sink = file.openWrite(
          mode: isPartial ? FileMode.append : FileMode.write,
        );

        final completer = Completer<void>();
        int lastProgressUpdateTime = 0;

        const int bytesPerSecondLimit = 11 * 1024 * 1024;
        final Stopwatch rateLimitStopwatch = Stopwatch()..start();
        int totalDownloadedInSession = 0;

        Future<void> cleanupAndCancel() async {
          if (!completer.isCompleted) {
            await subscription?.cancel();
            if (sink != null) {
              try {
                await sink!.flush();
                await sink!.close();
              } catch (_) {}
              sink = null;
            }
            completer.completeError(
              DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.cancel,
                error: "用户暂停/取消下载",
              ),
            );
          }
        }

        if (task.cancelToken.isCancelled) {
          await cleanupAndCancel();
        } else {
          task.cancelToken.whenCancel
              .then((_) async => await cleanupAndCancel())
              .catchError((_) {}); // 🛡️ 增加防崩保护
        }

        subscription = response.data!.stream.listen(
          (chunk) async {
            if (task.status == DownloadStatus.paused ||
                task.status == DownloadStatus.cancelled ||
                task.cancelToken.isCancelled) {
              await cleanupAndCancel();
              return;
            }

            try {
              subscription?.pause();

              sink?.add(chunk);

              totalDownloadedInSession += chunk.length;
              downloadedBytes += chunk.length;
              task.downloaded = downloadedBytes;

              final expectedMs = (totalDownloadedInSession / bytesPerSecondLimit * 1000).round();
              final actualMs = rateLimitStopwatch.elapsedMilliseconds;
              final sleepMs = expectedMs - actualMs;
              if (sleepMs > 5) {
                await Future.delayed(Duration(milliseconds: sleepMs));
              }

              reporter?.addBytes(chunk.length);

              final now = DateTime.now().millisecondsSinceEpoch;
              if (now - lastProgressUpdateTime > 300 || downloadedBytes >= totalBytes) {
                lastProgressUpdateTime = now;
                onProgress(downloadedBytes, totalBytes);
              }

              subscription?.resume();
            } catch (e) {
              print("--- [Engine 文件写入错误]: $e ---");
              if (!completer.isCompleted) {
                completer.completeError(e);
              }
            }
          },
          onDone: () {
            print("--- [Engine Stream 完成] onDone 触发 ---");
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (e) {
            print("--- [Engine Stream 异常] onError 触发: $e ---");
            if (!completer.isCompleted) {
              completer.completeError(e);
            }
          },
          cancelOnError: true,
        );

        await completer.future;

        await subscription.cancel();
        if (sink != null) {
          await sink?.flush();
          await sink?.close();
          sink = null;
        }

        await reporter?.flushAndCheck();

        final finalLength = file.lengthSync();
        if (totalBytes > 0 && finalLength < totalBytes) {
          throw Exception("文件大小不匹配：期望 $totalBytes 字节，实际下载 $finalLength 字节");
        }

        return;

      } catch (e) {
        await subscription?.cancel();
        if (sink != null) {
          try {
            await sink?.flush();
            await sink?.close();
          } catch (_) {}
          sink = null;
        }

        if ((e is DioException && CancelToken.isCancel(e)) ||
            (e is DioException && e.type == DioExceptionType.cancel)) {
          rethrow;
        }

        bool isSocketOrNetworkError = e is SocketException ||
            e is HttpException ||
            (e is DioException &&
                (e.error is SocketException ||
                    e.error is HttpException ||
                    e.type == DioExceptionType.connectionError ||
                    e.type == DioExceptionType.receiveTimeout));

        if (isSocketOrNetworkError &&
            retryCount < maxSocketRetries &&
            !task.cancelToken.isCancelled &&
            task.status != DownloadStatus.paused &&
            task.status != DownloadStatus.cancelled) {
          retryCount++;
          print(
            "⚠️ [Engine 捕获网络中断] 详细错误: $e \n 正在进行第 $retryCount/$maxSocketRetries 次重试...",
          );
          if (file.existsSync()) {
            downloadedBytes = file.lengthSync();
            task.downloaded = downloadedBytes;
          }
          await Future.delayed(Duration(seconds: retryCount * 2));
          continue;
        }

        print("--- [Engine 捕获不可恢复的异常/已达最大重试上限]: $e ---");
        rethrow;
      }
    }
  }
}