#ifndef SMARTDRIVE_EXPORT_ENGINE_H
#define SMARTDRIVE_EXPORT_ENGINE_H

#include <string>
#include <vector>

/**
 * 原生只认这六种**版式原语**：它不认识任何模版 id、名字或目录顺序。
 * 「哪个模版用哪种版式、画布多大」全在 ArkTS 侧翻译好，作为 ComposeSpec 传进来。
 */
enum class ComposeLayout {
    Single = 0,       // 单路
    StackV = 1,       // 上下两格
    StackH = 2,       // 左右两格
    Top1Bottom2 = 3,  // 上一下二（上面整宽，下面两格）
    Grid2x2 = 4,      // 四宫格
    ThreeUpCrop = 5   // 三分屏（左右两路各裁一半）
};

struct ComposeSpec {
    int canvasWidth = 1920;
    int canvasHeight = 1080;
    ComposeLayout layout = ComposeLayout::Single;
    /** 常规音频来自第 1 路；左右盲区没有前视机位，这一路不带声音。 */
    bool muteFrontAudio = false;
};

/** 把 "single" / "stack-v" / … 解析成枚举；未知值返回 false（调用方报参数错误）。 */
bool parseComposeLayout(const std::string &value, ComposeLayout &out);
std::string composeLayoutName(ComposeLayout layout);

/**
 * 一段要保留的区间。speed 已经是从 '1.5X' 解析并钳到 [0.75, 2.0] 的因子，
 * muted 为真时该段音量归零。定义放在这个头文件里，因为它是引擎签名的一部分，
 * napi_init.cpp 通过 include 复用它（两处各定义一次会重复定义）。
 */
struct NativeExportSegment {
    double startMs = 0.0;
    double endMs = 0.0;
    double speed = 1.0;
    bool muted = false;
};

struct NativeExportProgressInfo {
    int percent = 0;
    int64_t currentFrame = 0;
    int64_t totalFrames = 0;
    int stage = 0;
    int64_t completedUnits = 0;
    int64_t totalUnits = 0;
};

NativeExportProgressInfo getNativeExportProgress();
void setNativeExportProgress(int percent, int64_t currentFrame, int64_t totalFrames, int stage,
                             int64_t completedUnits = 0, int64_t totalUnits = 0);
// 在任务入队前调用一次；工作线程不能清掉排队期间收到的取消。
void resetNativeExportProgress();
void cancelNativeExport();
bool isNativeExportCancelled();

std::string runExportEnginePipeline(const std::vector<std::string> &frontUris,
                                    const std::vector<std::string> &backUris,
                                    const std::vector<std::string> &sideUris,
                                    const std::vector<std::string> &side2Uris,
                                    const ComposeSpec &spec,
                                    double expectedDurationSec,
                                    const std::string &outputPath,
                                    double startMs = 0.0,
                                    double endMs = 0.0,
                                    const std::vector<NativeExportSegment> &segments = {});

#endif
