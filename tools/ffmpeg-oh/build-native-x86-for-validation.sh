#!/bin/bash
# 在 WSL 里编一份「原生 x86_64」ffmpeg，只为了离线跑 validate-filter-graph.sh。
# 原生版用软件编码器替代 h264_oh，滤镜图与设备上完全一致，因此能提前发现滤镜描述串的语法错误。
# 用法：bash build-native-x86-for-validation.sh
set -e
TARBALL="$HOME/ffbuild/ffmpeg-8.0.tar.xz"
SRC="$HOME/ffx86-src"
if [ ! -d "$SRC" ]; then
  mkdir -p "$SRC"
  tar -xf "$TARBALL" -C "$SRC" --strip-components=1
fi
cd "$SRC"
if [ ! -f config.h ]; then
  ./configure \
    --prefix="$HOME/ffx86-inst" \
    --disable-x86asm \
    --disable-doc \
    --disable-network \
    --disable-autodetect \
    --enable-protocol=file \
    --disable-debug \
    > configure.log 2>&1 || { echo "CONFIGURE FAILED"; tail -30 configure.log; exit 1; }
fi
echo "=== 开始编译 ffmpeg CLI（几分钟）==="
make -j4 ffmpeg > build.log 2>&1 || { echo "MAKE FAILED"; tail -40 build.log; exit 1; }
echo "=== 完成：$SRC/ffmpeg ==="
ls -la "$SRC/ffmpeg"
