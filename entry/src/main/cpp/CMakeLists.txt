cmake_minimum_required(VERSION 3.5.0)
project(smart_drive_exporter)

set(NATIVE_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVE_ROOT_PATH}
                    ${NATIVE_ROOT_PATH}/include)

add_library(smartdrive_exporter SHARED napi_init.cpp)

target_link_libraries(smartdrive_exporter PUBLIC libace_napi.z.so libdl.so)
