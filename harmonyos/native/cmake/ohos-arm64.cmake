# OpenHarmony (OHOS) 交叉编译 toolchain：aarch64-linux-ohos (musl)
#
# 与 ohos-x86_64.cmake 的差别只有三元组与 sysroot 子目录；其余坑相同：
# NDK 的 *-ohos-clang 是 sh 脚本，Windows 上必须直接调 clang.exe。
#
# 用法：
#   cmake -S <src> -B <build> -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=harmonyos/native/cmake/ohos-arm64.cmake \
#     -DCMAKE_INSTALL_PREFIX=<prefix>
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DEFINED OHOS_NDK)
  set(OHOS_NDK "C:/ohos-ndk")
endif()
set(OHOS_TRIPLE aarch64-linux-ohos)

set(CMAKE_C_COMPILER   "${OHOS_NDK}/llvm/bin/clang.exe")
set(CMAKE_CXX_COMPILER "${OHOS_NDK}/llvm/bin/clang++.exe")
set(CMAKE_AR           "${OHOS_NDK}/llvm/bin/llvm-ar.exe")
set(CMAKE_RANLIB       "${OHOS_NDK}/llvm/bin/llvm-ranlib.exe")
set(CMAKE_STRIP        "${OHOS_NDK}/llvm/bin/llvm-strip.exe")
set(CMAKE_SYSROOT      "${OHOS_NDK}/sysroot")

set(CMAKE_C_FLAGS_INIT   "-target ${OHOS_TRIPLE} -D__MUSL__ -fPIC")
set(CMAKE_CXX_FLAGS_INIT "-target ${OHOS_TRIPLE} -D__MUSL__ -fPIC")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-target ${OHOS_TRIPLE}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-target ${OHOS_TRIPLE}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-target ${OHOS_TRIPLE}")

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH "${OHOS_NDK}/sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
