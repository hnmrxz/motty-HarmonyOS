# OpenHarmony (OHOS) 交叉编译 toolchain：x86_64-linux-ohos (musl)
#
# 为什么要手写而不是用 NDK 的 *-ohos-clang 包装脚本：那些是 sh 脚本，Windows 上
# 不可执行（实测 170–250 字节的 #!/bin/sh），必须直接调 clang.exe 并显式给
# -target 与 --sysroot。
#
# 用法：
#   cmake -S <src> -B <build> -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=harmonyos/native/cmake/ohos-x86_64.cmake \
#     -DCMAKE_INSTALL_PREFIX=<prefix>
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

if(NOT DEFINED OHOS_NDK)
  set(OHOS_NDK "C:/ohos-ndk")
endif()
set(OHOS_TRIPLE x86_64-linux-ohos)

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

# 交叉编译时不能运行目标程序做能力探测，否则 configure 阶段会失败
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH "${OHOS_NDK}/sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
