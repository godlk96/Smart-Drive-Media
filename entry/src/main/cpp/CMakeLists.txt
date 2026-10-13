cmake_minimum_required(VERSION 3.5.0)
project(smart_drive_exporter)

add_compile_options(-Wno-unused-command-line-argument)
add_link_options(-Wno-unused-command-line-argument)

set(NATIVE_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(FFMPEG_LIBS_PATH ${NATIVE_ROOT_PATH}/.ffmpeg-install/arm64-v8a/lib)
set(FFMPEG_INCLUDE_PATH ${NATIVE_ROOT_PATH}/.ffmpeg-install/arm64-v8a/include)

include_directories(${NATIVE_ROOT_PATH}
                    ${NATIVE_ROOT_PATH}/include
                    ${FFMPEG_INCLUDE_PATH})

set(FFMPEG_AVUTIL_LIB "${FFMPEG_LIBS_PATH}/libavutil.so.60.8.100")
set(FFMPEG_SWRESAMPLE_LIB "${FFMPEG_LIBS_PATH}/libswresample.so.6.1.100")
set(FFMPEG_SWSCALE_LIB "${FFMPEG_LIBS_PATH}/libswscale.so.9.1.100")
set(FFMPEG_AVCODEC_LIB "${FFMPEG_LIBS_PATH}/libavcodec.so.62.11.100")
set(FFMPEG_AVFORMAT_LIB "${FFMPEG_LIBS_PATH}/libavformat.so.62.3.100")
set(FFMPEG_AVFILTER_LIB "${FFMPEG_LIBS_PATH}/libavfilter.so.11.4.100")

add_library(smartdrive_exporter SHARED
            napi_init.cpp
            export_engine.cpp)

target_link_libraries(smartdrive_exporter PUBLIC
                      ${FFMPEG_AVUTIL_LIB}
                      ${FFMPEG_SWRESAMPLE_LIB}
                      ${FFMPEG_SWSCALE_LIB}
                      ${FFMPEG_AVCODEC_LIB}
                      ${FFMPEG_AVFORMAT_LIB}
                      ${FFMPEG_AVFILTER_LIB}
                      libnative_media_venc.so
                      libnative_media_avmuxer.so
                      libnative_media_codecbase.so
                      libnative_media_core.so
                      libace_napi.z.so
                      libdl.so)
