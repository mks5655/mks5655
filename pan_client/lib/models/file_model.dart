class FileModel {
  final String fsId;
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int category;

  /// UI 层的选择状态（默认未选中）
  bool selected;

  FileModel({
    required this.fsId,
    required this.name,
    required this.path, // 已修正：将原先的 me.path 改回 this.path
    required this.isDir,
    required this.size,
    required this.category,
    this.selected = false,
  });

  factory FileModel.fromJson(Map<String, dynamic> json) {
    return FileModel(
      // 兼顾网络 API 格式 (fs_id) 和缓存中的格式 (fsId)
      fsId: (json["fs_id"] ?? json["fsId"] ?? "").toString(),
      
      // 兼顾网络 API 格式 (server_filename) 和缓存中的格式 (name)
      name: (json["server_filename"] ?? json["name"] ?? "").toString(),
      
      path: (json["path"] ?? "").toString(),
      
      // 兼顾网络 API 的 int 标志 (isdir == 1) 和缓存中的 bool 标志 (isDir)
      isDir: json["isdir"] == 1 || json["isDir"] == true,
      
      size: (json["size"] as num?)?.toInt() ?? 0,
      category: (json["category"] as num?)?.toInt() ?? 0,
    );
  }

  /// 序列化：转换为 JSON Map（与网络 API 结构及缓存全兼容）
  Map<String, dynamic> toJson() {
    return {
      "fs_id": fsId,
      "server_filename": name,
      "path": path,
      "isdir": isDir ? 1 : 0,
      "size": size,
      "category": category,
    };
  }
}

/// 简化的本地/传输文件模型
class FileItem {
  final String fid;
  final String filename;
  final int size;
  final String path;
  final bool isFolder;

  FileItem({
    required this.fid,
    required this.filename,
    required this.size,
    required this.path,
    required this.isFolder,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      fid: (json["fid"] ?? "").toString(),
      filename: (json["filename"] ?? "").toString(),
      size: (json["size"] as num?)?.toInt() ?? 0,
      path: (json["path"] ?? "").toString(),
      isFolder: json["isFolder"] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "fid": fid,
      "filename": filename,
      "size": size,
      "path": path,
      "isFolder": isFolder,
    };
  }
}