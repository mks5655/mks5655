import 'package:dio/dio.dart';

enum DownloadStatus {
  pending,
  waiting,
  gettingUrl,
  downloading,
  paused,
  completed,
  failed,
  error,
  cancelled,
}

class DownloadTask {
  final String id;
  final String filename;
  final String path;
  final int size;
  final String fsId;
  final int cardId; // 统一为 int 类型
  String? dlink;
  String? savePath;
  String? tempPath;

  int downloaded;
  int speed; // 单位: bytes/s
  DownloadStatus status;

  int retryCount;
  final int maxRetry;

  // Dio 取消令牌
  CancelToken cancelToken;

  bool needsRefreshDlink = false;

  DownloadTask({
    required this.id,
    required this.filename,
    required this.path,
    required this.size,
    required this.fsId,
    required this.cardId,
    this.dlink,
    this.savePath,
    this.tempPath,
    this.downloaded = 0,
    this.speed = 0,
    this.status = DownloadStatus.waiting,
    this.retryCount = 0,
    this.maxRetry = 3,
    CancelToken? cancelToken,
  }) : cancelToken = cancelToken ?? CancelToken();

  /// 计算下载进度百分比 (0.0 ~ 1.0)
  double get progress {
    if (size <= 0) return 0.0;
    final p = downloaded / size;
    return p.clamp(0.0, 1.0);
  }

  /// 格式化网速文本 (例: 1.5 MB/s)
  String get speedText {
    if (speed <= 0) return '0 B/s';
    if (speed < 1024) return '$speed B/s';
    if (speed < 1024 * 1024) return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    return '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// 实例化空对象辅助函数
  factory DownloadTask.empty() {
    return DownloadTask(
      id: '',
      filename: '',
      path: '',
      size: 0,
      fsId: '',
      cardId: 0,
    );
  }

  /// 重置 CancelToken
  void resetCancelToken() {
    print("==================================");
    print(this.id);
    print(this.cancelToken.hashCode);
    if (cancelToken.isCancelled) {
      cancelToken = CancelToken();
          print("==================================");
    print(this.id);
    print(this.cancelToken.hashCode);
    }
    print(this.cancelToken.hashCode);
    print("======================================");
  }

  /// 序列化转 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'filename': filename,
      'path': path,
      'size': size,
      'fsId': fsId,
      'cardId': cardId,
      'dlink': dlink,
      'savePath': savePath,
      'tempPath': tempPath,
      'downloaded': downloaded,
      'status': status.index,
    };
  }

  /// 反序列化从 JSON 加载
  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    int parseCardId(dynamic raw) {
      if (raw is int) return raw;
      if (raw is String) return int.tryParse(raw) ?? 0;
      return 0;
    }

    return DownloadTask(
      id: json['id'] ?? '',
      filename: json['filename'] ?? '',
      path: json['path'] ?? '',
      size: json['size'] ?? 0,
      fsId: json['fsId'] ?? '',
      cardId: parseCardId(json['cardId']),
      dlink: json['dlink'],
      savePath: json['savePath'],
      tempPath: json['tempPath'],
      downloaded: json['downloaded'] ?? 0,
      status: DownloadStatus.values[json['status'] ?? 1],
    );
  }
}