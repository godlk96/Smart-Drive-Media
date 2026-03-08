$sdkPath = "entry/src/main/cpp/prebuilt/arm64-v8a/libsmartdrive_ffmpeg_sdk.so"

if (Test-Path $sdkPath) {
  Write-Output "已找到 SDK: $sdkPath"
  exit 0
}

Write-Output "未找到 SDK，请把 libsmartdrive_ffmpeg_sdk.so 放到: entry/src/main/cpp/prebuilt/arm64-v8a/"
exit 1
