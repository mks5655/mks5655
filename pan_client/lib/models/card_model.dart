/// 卡密模型 (匹配 FastAPI /api/user/card 响应数据)
class CardModel {
  final int id;
  final String code;
  final String expireTime;
  final int maxSize;
  final int usedSize;
  final int maxFiles;
  final int usedFiles;

  CardModel({
    required this.id,
    required this.code,
    required this.expireTime,
    required this.maxSize,
    required this.usedSize,
    required this.maxFiles,
    required this.usedFiles,
  });

  factory CardModel.fromJson(Map<String, dynamic> json) {
    return CardModel(
      id: json['id'] ?? 0,
      code: json['code'] ?? '',
      expireTime: json['expire_time']?.toString() ?? '',
      maxSize: json['max_size'] ?? 0,
      usedSize: json['used_size'] ?? 0,
      maxFiles: json['max_files'] ?? 0,
      usedFiles: json['used_files'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'expire_time': expireTime,
      'max_size': maxSize,
      'used_size': usedSize,
      'max_files': maxFiles,
      'used_files': usedFiles,
    };
  }
}