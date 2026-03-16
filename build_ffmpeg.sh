#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
TARGET_ABI="${TARGET_ABI:-arm64-v8a}"
DEFAULT_NDK_PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
NDK_PATH="${1:-${OHOS_NDK_HOME:-${DEVECO_NDK_HOME:-${ANDROID_NDK_HOME:-${ANDROID_NDK:-${DEFAULT_NDK_PATH}}}}}}"
NDK_DIR="${NDK_PATH}"

if [[ ! -d "${NDK_PATH}" ]]; then
  echo "NDK路径不存在: ${NDK_PATH}"
  exit 1
fi

TOOLCHAIN_BIN=""
SYSROOT=""
if [[ -d "${NDK_PATH}/toolchains/llvm/prebuilt" ]]; then
  UNAME_S="$(uname -s)"
  UNAME_M="$(uname -m)"
  HOST_TAG_CANDIDATES=()
  if [[ "${UNAME_S}" == "Darwin" && "${UNAME_M}" == "arm64" ]]; then
    HOST_TAG_CANDIDATES=("darwin-arm64" "darwin-x86_64")
  elif [[ "${UNAME_S}" == "Darwin" ]]; then
    HOST_TAG_CANDIDATES=("darwin-x86_64")
  elif [[ "${UNAME_S}" == "Linux" && "${UNAME_M}" == "x86_64" ]]; then
    HOST_TAG_CANDIDATES=("linux-x86_64")
  else
    echo "不支持的主机平台: ${UNAME_S} ${UNAME_M}"
    exit 1
  fi
  for candidate in "${HOST_TAG_CANDIDATES[@]}"; do
    if [[ -d "${NDK_PATH}/toolchains/llvm/prebuilt/${candidate}" ]]; then
      TOOLCHAIN_BIN="${NDK_PATH}/toolchains/llvm/prebuilt/${candidate}/bin"
      SYSROOT="${NDK_PATH}/toolchains/llvm/prebuilt/${candidate}/sysroot"
      break
    fi
  done
elif [[ -d "${NDK_PATH}/llvm/bin" && -d "${NDK_PATH}/sysroot" ]]; then
  TOOLCHAIN_BIN="${NDK_PATH}/llvm/bin"
  SYSROOT="${NDK_PATH}/sysroot"
fi

if [[ -z "${TOOLCHAIN_BIN}" || -z "${SYSROOT}" ]]; then
  echo "未找到可用工具链: ${NDK_PATH}"
  exit 1
fi

if [[ "${TARGET_ABI}" != "arm64-v8a" ]]; then
  echo "当前脚本仅支持arm64-v8a，收到: ${TARGET_ABI}"
  exit 1
fi

SRC_PARENT="${ROOT_DIR}/entry/src/main/cpp/.ffmpeg-src"
BUILD_DIR="${ROOT_DIR}/entry/src/main/cpp/.ffmpeg-build/${TARGET_ABI}"
INSTALL_DIR="${ROOT_DIR}/entry/src/main/cpp/.ffmpeg-install/${TARGET_ABI}"
OUTPUT_LIB_DIR="${ROOT_DIR}/entry/src/main/cpp/libs"
FFMPEG_SRC_DIR="${SRC_PARENT}/ffmpeg-${FFMPEG_VERSION}"
TARBALL="${SRC_PARENT}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

CC="${NDK_DIR}/llvm/bin/clang"
if [[ ! -x "${CC}" ]]; then
  echo "未找到 clang 编译器: ${CC}"
  exit 1
fi

CXX="${NDK_DIR}/llvm/bin/clang++"
if [[ ! -x "${CXX}" ]]; then
  echo "未找到 clang++ 编译器: ${CXX}"
  exit 1
fi

AR="${TOOLCHAIN_BIN}/llvm-ar"
AS="${CC}"
NM="${TOOLCHAIN_BIN}/llvm-nm"
RANLIB="${TOOLCHAIN_BIN}/llvm-ranlib"
STRIP="${TOOLCHAIN_BIN}/llvm-strip"
CROSS_PREFIX="${TOOLCHAIN_BIN}/aarch64-linux-ohos-"

mkdir -p "${SRC_PARENT}" "${BUILD_DIR}" "${INSTALL_DIR}" "${OUTPUT_LIB_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  curl -L "${FFMPEG_URL}" -o "${TARBALL}"
fi

if [[ ! -d "${FFMPEG_SRC_DIR}" ]]; then
  tar -xf "${TARBALL}" -C "${SRC_PARENT}"
fi

cd "${FFMPEG_SRC_DIR}"
make distclean >/dev/null 2>&1 || true

./configure \
  --prefix="${INSTALL_DIR}" \
  --target-os=linux \
  --arch=aarch64 \
  --cross-prefix="${CROSS_PREFIX}" \
  --cpu=armv8-a \
  --cc="${CC}" \
  --cxx="${CXX}" \
  --nm="${NM}" \
  --ar="${AR}" \
  --as="${AS}" \
  --ranlib="${RANLIB}" \
  --strip="${STRIP}" \
  --sysroot="${SYSROOT}" \
  --enable-cross-compile \
  --disable-autodetect \
  --enable-shared \
  --disable-static \
  --enable-avfilter \
  --disable-encoders \
  --enable-encoder=mpeg4 \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-gpl \
  --disable-nonfree \
  --disable-avdevice \
  --disable-symver \
  --enable-small \
  --extra-cflags="-fPIC -target aarch64-linux-ohos" \
  --extra-cxxflags="-fPIC -target aarch64-linux-ohos" \
  --extra-ldflags="-Wl,--gc-sections -target aarch64-linux-ohos"

make -j8
make install

rm -f "${OUTPUT_LIB_DIR}"/libav*.so*
rm -f "${OUTPUT_LIB_DIR}"/libsw*.so*
cp -f "${INSTALL_DIR}/lib/"*.so "${OUTPUT_LIB_DIR}/"

READELF_BIN="${TOOLCHAIN_BIN}/llvm-readelf"
for lib in "${OUTPUT_LIB_DIR}"/libav*.so "${OUTPUT_LIB_DIR}"/libsw*.so; do
  if [[ ! -f "${lib}" ]]; then
    continue
  fi
  soname="$("${READELF_BIN}" -d "${lib}" | awk -F'[][]' '/SONAME/ {print $2}')"
  if [[ -n "${soname}" ]]; then
    cp -f "${lib}" "${OUTPUT_LIB_DIR}/${soname}"
  fi
done

echo "FFmpeg ${FFMPEG_VERSION} 构建完成"
echo "输出目录: ${OUTPUT_LIB_DIR}"
ls -1 "${OUTPUT_LIB_DIR}"/libav*.so* "${OUTPUT_LIB_DIR}"/libsw*.so*
