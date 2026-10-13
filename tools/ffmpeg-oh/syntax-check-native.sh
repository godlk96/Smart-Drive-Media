#!/bin/bash
# 用 OH SDK 自带的 clang.exe 对 native 源码做语法检查（不产出目标文件）。
# 好处：不需要跑完整 DevEco 构建就能发现语法/头文件错误。
# 用法：bash syntax-check-native.sh
CLANG="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin/clang++.exe"
SDK_WIN="C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
REPO_WIN="C:/Users/gzr/Desktop/Smart-Drive-Media"
FF="$REPO_WIN/entry/src/main/cpp/.ffmpeg-install/arm64-v8a/include"
SRC="$REPO_WIN/entry/src/main/cpp"

echo "=== 语法检查 export_engine.cpp ==="
"$CLANG" --target=aarch64-linux-ohos --sysroot="$SDK_WIN/sysroot" \
  -std=c++17 -fsyntax-only -Wall -Wextra \
  -I"$FF" "$SRC/export_engine.cpp" 2>&1 | head -80
echo "---- export_engine.cpp 结束 ----"

echo "=== 语法检查 napi_init.cpp ==="
"$CLANG" --target=aarch64-linux-ohos --sysroot="$SDK_WIN/sysroot" \
  -std=c++17 -fsyntax-only \
  -I"$FF" "$SRC/napi_init.cpp" 2>&1 | head -40
echo "---- napi_init.cpp 结束 ----"
