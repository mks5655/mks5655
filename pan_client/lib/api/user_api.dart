import 'package:dio/dio.dart';

import 'dio_client.dart';

import '../models/file_response.dart';

import '../models/create_download_response.dart';

import 'package:dio/dio.dart';

/// 用户接口管理
///
/// 对应后端:
///
/// GET  /api/user/card
/// POST /api/user/share
///
class UserApi {
  
  
  /// 后端服务器地址
  ///
  /// Windows / Android客户端都会请求这里
  static const String baseUrl =
      "https://baidu-pan.mtd.dpdns.org";


    /// Dio请求实例
  // final Dio dio = Dio(

  //   BaseOptions(

  //     baseUrl: baseUrl,


  //     /// 连接超时时间
  //     connectTimeout:
  //         const Duration(seconds:10),


  //     /// 接收超时时间
  //     receiveTimeout:
  //         const Duration(seconds:60),

  //   ),

  // );

  final Dio dio = Dio(

    BaseOptions(

      baseUrl:baseUrl,

    )

    )..interceptors.add(

    LogInterceptor(

      requestBody:true,

      responseBody:true,

    )

  );


  /// Dio请求对象
  final Dio _dio = DioClient().dio;




  /// 获取用户文件数据
  ///
  /// code:
  /// 卡密
  ///
  /// path:
  /// 当前目录
  ///
  Future<Response> getCardFiles(

    String code,

    {
      String? path
    }

  ) async {


    return await _dio.get(

      "/api/user/card",

      queryParameters:{


        "code":code,


        if(path != null)

          "path":path,


      }

    );


  }





  /// 获取文件管理器数据
  ///
  /// 对接口结果进行模型转换
  ///
  Future<FileResponse> getFiles(

    String code,

    {

      String? path

    }

  ) async {



    final response =
    await getCardFiles(

      code,

      path:path

    );



    final data =
    response.data;



    if(data["error"] != null){

      throw Exception(
        data["error"]
      );

    }



    return FileResponse.fromJson(
      data
    );


  }






  /// 添加分享链接
  ///
  /// POST /api/user/share
  ///
  Future<Map<String,dynamic>> addShare({

    required String code,

    required String shareUrl,

    String pwd=""

  }) async {



    final response =
    await _dio.post(

      "/api/user/share",

      data:{


        "code":
        code,


        "share_url":
        shareUrl,


        "pwd":
        pwd


      }

    );


    return response.data;


  }





  /// 创建下载任务
  ///
  /// GET /download/create/{fs_id}/{card_id}
  ///
  Future<String> createDownload111({

    required String fsId,

    required int cardId,

    required String path,

    required String filename,

    required int size,
 

  }) async {



    final response =
    await _dio.get(

      "/download/create/"
      "$fsId/"
      "$cardId",


      queryParameters:{


        "path":
        path,


        "filename":
        filename,


        "size":
        size,


      }

    );



    final data =
    response.data;



    if(data["error"] != null){

      throw Exception(
        data["error"]
      );

    }



    return data["url"];


  }


/// 创建下载
///
/// 获取百度 dlink
Future<CreateDownloadResponse> createDownload({

  required String fsId,

  required int cardId,

  required String path,

  required String filename,

  required int size,

  /// 是否客户端请求
  int isApp = 1,

}) async {

  final response = await _dio.get(

    "/download/create/$fsId/$cardId",

    queryParameters: {

      "path": path,

      "filename": filename,

      "size": size,

      "is_app": 1,

    },

  );

  print(response.data);

  return CreateDownloadResponse.fromJson(

    response.data,

  );

}




/// 创建下载
///
/// 请求刷新 dlink
Future<CreateDownloadResponse> refreshDlink({

  required String fsId,

  required int cardId,

  required String path,

  required String filename,

  required int size,

  /// 是否客户端请求
  int isApp = 1,

  int refresh = 1,

}) async {

  final response = await _dio.get(

    "/download/create/$fsId/$cardId",

    queryParameters: {

      "path": path,

      "filename": filename,

      "size": size,

      "is_app": 1,

      "refresh": 1,

    },

  );

  print(response.data);

  return CreateDownloadResponse.fromJson(

    response.data,

  );

}

/// 获取系统版本及强制更新信息
  ///
  /// GET /api/system/version (请根据后端实际路径调整)
  Future<Map<String, dynamic>> getSystemVersion() async {
    final response = await _dio.get("/api/system/version");
    
    final data = response.data;
    
    // 兼容可能存在的错误结构
    if (data is Map && data["error"] != null) {
      throw Exception(data["error"]);
    }
    
    // 如果您的后端返回格式是标准 JSON，比如直接包含字段或嵌套在 data 中：
    // 如果后端直接返回 { "latest_version": "1.1.0", ... } 直接返回 data 即可
    // 如果后端返回 { "code": 200, "data": { ... } }，请改成 return data["data"];
    return data is Map<String, dynamic> ? (data["data"] ?? data) : {};
  }

}