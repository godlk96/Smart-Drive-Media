#ifndef SMARTDRIVE_EXPORT_ENGINE_H
#define SMARTDRIVE_EXPORT_ENGINE_H

#include <string>
#include <vector>

bool isSupportedTemplateId(const std::string &templateId);
std::string normalizeTemplateId(const std::string &templateId);

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
                                    const std::string &templateId,
                                    double expectedDurationSec,
                                    const std::string &outputPath,
                                    double startMs = 0.0,
                                    double endMs = 0.0,
                                    const std::vector<NativeExportSegment> &segments = {});

#endif
