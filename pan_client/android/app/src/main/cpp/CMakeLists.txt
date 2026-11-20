cmake_minimum_required(VERSION 3.18.1)

project("security_check")

# 编译动态链接库 libsecurity_check.so
add_library(
    security_check
    SHARED
    native-lib.cpp
)

# 引入 Android Log 库
find_library(
    log-lib
    log
)

target_link_libraries(
    security_check
    ${log-lib}
)