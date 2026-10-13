#!/bin/bash
# 在 WSL 里交叉编译 OpenHarmony(aarch64-linux-ohos) 版 ffmpeg。
# 实际编译器是 OH SDK 自带的 Windows 版 clang.exe，通过包装脚本转换路径后调用。
#
# 用法：
#   bash build-ffmpeg.sh configure   # 只跑 configure
#   bash build-ffmpeg.sh make        # 跑 make
#   bash build-ffmpeg.sh all         # 两步都跑
#
# 前置：WSL 里能访问 /mnt/c，且 $HOME/ffbuild/ffmpeg-8.0 存在（源码）。
set -e

STAGE="${1:-all}"

# ---- 路径配置（按需修改）----
SDK_WIN="C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
SDK_WSL="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
LLVM_WIN="$SDK_WIN/llvm/bin"
LLVM_WSL="$SDK_WSL/llvm/bin"
SYSROOT_WIN="$SDK_WIN/sysroot"

WORK="/mnt/c/Users/gzr/ffbuild-oh"          # 构建目录必须放在 /mnt/c 下，Windows 版 clang 才读写得到
SRC="$WORK/ffmpeg-8.0"                      # 源码也必须放在 /mnt/c 下（clang.exe 读不到 WSL 的 ext4）
TARBALL="$HOME/ffbuild/ffmpeg-8.0.tar.xz"   # 源码包放在 WSL 家目录即可
TOOLS="$WORK/tools"
PREFIX="$WORK/install"

mkdir -p "$TOOLS" "$WORK"

# 源码必须位于 /mnt/c（Windows 版 clang 无法访问 WSL ext4）
if [ ! -d "$SRC" ]; then
  echo "=== 解压源码到 $WORK ==="
  tar xf "$TARBALL" -C "$WORK"
fi

# ---- 生成工具链包装器 ----
gen_cc_wrapper() {
  cat > "$TOOLS/cc.sh" <<'WRAP'
#!/bin/bash
CLANG="__LLVM__/clang.exe"
SYSROOT_WIN="__SYSROOT__"
conv() {
  case "$1" in
    /mnt/*) wslpath -w "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
args=()
for a in "$@"; do
  case "$a" in
    -I/*|-L/*|-isystem/*|-iquote/*|-idirafter/*|-include/*|-imacros/*)
      flag="${a%%/*}"; p="/${a#*/}"
      args+=("${flag}$(conv "$p")") ;;
    -o/*) args+=("-o$(conv "${a#-o}")") ;;
    -Wl,*)
      out="-Wl,"; first=1
      IFS=',' read -ra parts <<< "${a#-Wl,}"
      for p in "${parts[@]}"; do
        [ $first -eq 0 ] && out="$out,"
        first=0
        case "$p" in /*) out="$out$(conv "$p")" ;; *) out="$out$p" ;; esac
      done
      args+=("$out") ;;
    /*) args+=("$(conv "$a")") ;;
    *) args+=("$a") ;;
  esac
done
exec "$CLANG" -target aarch64-linux-ohos --sysroot="$SYSROOT_WIN" -D__MUSL__ "${args[@]}"
WRAP
  sed -i "s|__LLVM__|$LLVM_WSL|g; s|__SYSROOT__|$SYSROOT_WIN|g" "$TOOLS/cc.sh"
  cp "$TOOLS/cc.sh" "$TOOLS/cxx.sh"
  chmod +x "$TOOLS/cc.sh" "$TOOLS/cxx.sh"
}

gen_bin_wrapper() {
  local name="$1" exe="$2"
  cat > "$TOOLS/$name" <<'WRAP'
#!/bin/bash
EXE="__EXE__"
args=()
for a in "$@"; do
  case "$a" in
    /mnt/*) args+=("$(wslpath -w "$a" 2>/dev/null || printf '%s' "$a")") ;;
    *) args+=("$a") ;;
  esac
done
exec "$EXE" "${args[@]}"
WRAP
  sed -i "s|__EXE__|$LLVM_WSL/$exe|g" "$TOOLS/$name"
  chmod +x "$TOOLS/$name"
}

gen_cc_wrapper
gen_bin_wrapper ar.sh      llvm-ar.exe
gen_bin_wrapper nm.sh      llvm-nm.exe
gen_bin_wrapper ranlib.sh  llvm-ranlib.exe
gen_bin_wrapper strip.sh   llvm-strip.exe

echo "=== 包装器已生成于 $TOOLS ==="
ls -1 "$TOOLS"

# ---- configure ----
if [ "$STAGE" = "configure" ] || [ "$STAGE" = "all" ]; then
  cd "$SRC"
  # configure 会在 TMPDIR 下生成探测文件；必须是 /mnt/c 路径，Windows 版 clang 才写得进去
  mkdir -p "$WORK/tmp"
  export TMPDIR="$WORK/tmp"
  echo "=== configure (TMPDIR=$TMPDIR) ==="
  ./configure \
    --prefix="$PREFIX" \
    --target-os=linux \
    --arch=aarch64 \
    --enable-cross-compile \
    --host-cc=gcc \
    --cc="$TOOLS/cc.sh" \
    --cxx="$TOOLS/cxx.sh" \
    --ar="$TOOLS/ar.sh" \
    --nm="$TOOLS/nm.sh" \
    --ranlib="$TOOLS/ranlib.sh" \
    --strip="$TOOLS/strip.sh" \
    --disable-autodetect \
    --enable-shared \
    --disable-static \
    --enable-avfilter \
    --disable-encoders \
    --enable-encoder=mpeg4,h264_oh,hevc_oh,aac \
    --enable-ohcodec \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-gpl \
    --disable-nonfree \
    --disable-avdevice \
    --disable-symver \
    --enable-small \
    --ln_s="cp -rf --remove-destination" \
    2>&1 | tail -40
  echo "=== configure 结束，检查 config.h ==="
  grep -E 'CONFIG_OHCODEC|CONFIG_H264_OH_ENCODER|CONFIG_HEVC_OH_ENCODER|CONFIG_AAC_ENCODER|CONFIG_MPEG4_ENCODER' config.h || true
fi

# ---- make ----
if [ "$STAGE" = "make" ] || [ "$STAGE" = "all" ]; then
  cd "$SRC"
  # 并发别开太大：Windows 版 clang.exe 在多进程并发下会因内存压力崩溃（frontend signal）
  JOBS="${JOBS:-4}"
  echo "=== make -j$JOBS ==="
  make -j"$JOBS" 2>&1 | tail -60
  echo "=== make install ==="
  make install 2>&1 | tail -20
  echo "=== 产物 ==="
  ls -la "$PREFIX/lib" 2>/dev/null | head -20
fi
echo "=== done ==="
