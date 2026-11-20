/// 创建下载接口返回
///
/// 对应后端:
///
/// GET /download/create/{fs_id}/{card_id}
class CreateDownloadResponse {
  /// 是否成功
  final bool success;

  /// 错误信息
  final String? error;

  /// 百度直链
  final String? dlink;

  /// 文件名
  final String? filename;

  /// 文件大小
  final int? size;

  /// 百度路径
  final String? path;

  String? get url => dlink;
  

  const CreateDownloadResponse({
    required this.success,
    this.error,
    this.dlink,
    this.filename,
    this.size,
    this.path,
  });

  factory CreateDownloadResponse.fromJson(
    Map<String, dynamic> json,
  ) {
    return CreateDownloadResponse(
      success: json["success"] ?? false,
      error: json["error"],
      dlink: json["dlink"],
      filename: json["filename"],
      size: json["size"],
      path: json["path"],
    );
  }
}