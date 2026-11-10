cmake_minimum_required(VERSION 3.5.0)
project(mottynapi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# 交叉编译出来的 libssh2 + mbedTLS（harmonyos/native/third_party/ohos/<arch>）
# 由 build-profile.json5 的 externalNativeOptions.arguments 传入
if(NOT DEFINED OHOS_SSH_ROOT)
  message(FATAL_ERROR "OHOS_SSH_ROOT 未定义：需要在 externalNativeOptions.arguments 里传入 -DOHOS_SSH_ROOT=<.../third_party/ohos>")
endif()

# hvigor 为每个 ABI 各跑一次 CMake，并注入 OHOS_ARCH（x86_64 / arm64-v8a）。
# 第三方库按目录分架构存放，所以这里必须按 ABI 选，不能写死。
if(DEFINED OHOS_ARCH AND OHOS_ARCH STREQUAL "arm64-v8a")
  set(OHOS_SSH_ARCH arm64)
else()
  set(OHOS_SSH_ARCH x86_64)
endif()
set(OHOS_SSH_PREFIX ${OHOS_SSH_ROOT}/${OHOS_SSH_ARCH})
message(STATUS "OHOS_ARCH=${OHOS_ARCH} -> OHOS_SSH_PREFIX=${OHOS_SSH_PREFIX}")

add_library(mottynapi SHARED ssh_napi.cpp vt_core.cpp)

target_include_directories(mottynapi PRIVATE
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${OHOS_SSH_PREFIX}/include)

target_link_libraries(mottynapi PUBLIC libace_napi.z.so)

# 静态链 libssh2 与 mbedTLS：避免额外 .so 进包，也避免运行时找不到依赖
target_link_libraries(mottynapi PRIVATE
    ${OHOS_SSH_PREFIX}/lib/libssh2.a
    ${OHOS_SSH_PREFIX}/lib/libmbedtls.a
    ${OHOS_SSH_PREFIX}/lib/libmbedx509.a
    ${OHOS_SSH_PREFIX}/lib/libmbedcrypto.a
    ${OHOS_SSH_PREFIX}/lib/libeverest.a
    ${OHOS_SSH_PREFIX}/lib/libp256m.a)

target_link_libraries(mottynapi PRIVATE z)
