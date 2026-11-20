import 'package:dio/dio.dart';


class DioClient {


  /*
   * Dio 单例
   *
   * 整个 APP 共用一个 Dio
   * 方便统一管理：
   *
   * - baseUrl
   * - token
   * - 超时
   * - 请求日志
   * - 错误处理
   *
   */

  static final DioClient _instance =
      DioClient._internal();


  factory DioClient(){
    return _instance;
  }


  late Dio dio;



  DioClient._internal(){

    dio = Dio(

      BaseOptions(

        // 后端地址
        baseUrl:
            "https://baidu-pan.mtd.dpdns.org",


        // 连接超时

        connectTimeout:
            const Duration(seconds:10),


        // 接收超时

        receiveTimeout:
            const Duration(seconds:30),



        headers:{


          "Accept":
              "application/json",


        },


      )

    );



    _initInterceptor();


  }





  void _initInterceptor(){


    dio.interceptors.add(

      InterceptorsWrapper(



        // 请求之前

        onRequest:(options,handler){


          print(
              "请求:"
              "${options.method}"
              " ${options.uri}"
          );


          handler.next(options);

        },



        // 返回数据

        onResponse:(response,handler){


          print(
              "响应:"
              "${response.statusCode}"
          );


          handler.next(response);

        },



        // 错误

        onError:(error,handler){


          print(
              "请求错误:"
              "${error.message}"
          );


          handler.next(error);

        }


      )

    );


  }



}