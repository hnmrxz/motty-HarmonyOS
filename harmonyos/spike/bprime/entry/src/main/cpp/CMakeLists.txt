cmake_minimum_required(VERSION 3.5.0)
project(bprobe)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_library(bprobe SHARED napi_init.cpp)

target_include_directories(bprobe PRIVATE
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include)

target_link_libraries(bprobe PUBLIC libace_napi.z.so)
