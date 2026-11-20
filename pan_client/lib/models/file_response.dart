import 'file_model.dart';
import 'card_model.dart';

/// 文件列表接口返回模型
///
/// 对应后端:
/// /api/user/card
class FileResponse {
  final CardModel card;

  /// 当前文件列表
  final List<FileModel> files;

  /// 当前路径
  final String path;

  /// 上一级路径
  final String? parentPath;

  /// 面包屑
  final List<Breadcrumb> breadcrumbs;

  FileResponse({
    required this.card,
    required this.files,
    required this.path,
    required this.parentPath,
    required this.breadcrumbs,
  });

  factory FileResponse.fromJson(Map<String, dynamic> json) {
    return FileResponse(
      card: CardModel.fromJson(json["card"] as Map<String, dynamic>? ?? {}),
      files: (json["files"] as List<dynamic>?)
              ?.map((e) => FileModel.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      path: json["path"] as String? ?? "",
      parentPath: json["parent_path"] as String?,
      breadcrumbs: (json["breadcrumbs"] as List<dynamic>?)
              ?.map((e) => Breadcrumb.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// 序列化：转换为 JSON Map
  Map<String, dynamic> toJson() {
    return {
      "card": card.toJson(),
      "files": files.map((e) => e.toJson()).toList(),
      "path": path,
      "parent_path": parentPath,
      "breadcrumbs": breadcrumbs.map((e) => e.toJson()).toList(),
    };
  }
}

/// 面包屑节点
class Breadcrumb {
  final String name;
  final String path;

  Breadcrumb({
    required this.name,
    required this.path,
  });

  factory Breadcrumb.fromJson(Map<String, dynamic> json) {
    return Breadcrumb(
      name: json["name"] as String? ?? "",
      path: json["path"] as String? ?? "",
    );
  }

  /// 序列化：转换为 JSON Map
  Map<String, dynamic> toJson() {
    return {
      "name": name,
      "path": path,
    };
  }
}