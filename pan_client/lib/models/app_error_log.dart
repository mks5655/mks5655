class AppErrorLog {
  final String errorType;
  final String message;
  final String? stackTrace;
  final String timestamp;
  final Map<String, dynamic>? extraInfo;

  AppErrorLog({
    required this.errorType,
    required this.message,
    this.stackTrace,
    required this.timestamp,
    this.extraInfo,
  });

  Map<String, dynamic> toJson() => {
        'error_type': errorType,
        'message': message,
        'stack_trace': stackTrace,
        'timestamp': timestamp,
        'extra_info': extraInfo,
      };
}