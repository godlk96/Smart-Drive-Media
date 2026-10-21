// 与正式引擎处于同一翻译单元，直接验证实际生成的滤镜串，而非手工重写的近似版本。
#include "../../entry/src/main/cpp/export_engine.cpp"
#include <iostream>

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    resetNativeExportProgress();
    cancelNativeExport();
    const std::string cancelled = runExportEnginePipeline({"missing"}, {"missing"}, {}, {}, "T1", 1, "missing.mp4", 0, 1, {});
    if (cancelled.find("cancelled") == std::string::npos) {
        std::cerr << "queued cancellation was lost: " << cancelled << '\n';
        return 3;
    }
    resetNativeExportProgress();
    const std::string source = argv[1];
    const std::string joined = argv[2];
    struct stat inputStat {};
    if (stat(source.c_str(), &inputStat) != 0) return 4;
    int64_t completed = 0;
    const int64_t total = inputStat.st_size * 2;
    std::string error;
    if (!concatTrackToMp4({source, source}, true, joined, error, completed, total)) {
        std::cerr << "concat failed: " << error << '\n';
        return 5;
    }
    const auto progress = getNativeExportProgress();
    if (progress.stage != 4 || progress.completedUnits != total || progress.totalUnits != total) return 6;
    const auto emit = [&](const std::string &name, const std::string &kind, const std::string &graph) {
        std::cout << name << '\t' << kind << '\t' << graph << '\n';
    };
    for (const double speed : {0.75, 1.0, 1.5, 2.0}) {
        const std::vector<NativeExportSegment> segments = {{40125, 41625, speed, false}};
        const std::string name = "speed_" + std::to_string(speed);
        emit(name, "video", buildSegmentsVideoDesc("T1", source, source, source, source, segments, {20, 1}));
        emit(name, "audio", buildSegmentsAudioDesc(source, segments));
    }
    const std::vector<NativeExportSegment> multi = {
        {125, 1625, 0.75, false}, {40125, 41625, 2.0, true}, {50125, 51625, 1.5, false}
    };
    emit("multi", "video", buildSegmentsVideoDesc("T1", source, source, source, source, multi, {20, 1}));
    emit("multi", "audio", buildSegmentsAudioDesc(source, multi));
    const std::vector<NativeExportSegment> crossing = {{58125, 61125, 1.5, false}};
    emit("file_boundary", "video", buildSegmentsVideoDesc("T1", joined, joined, joined, joined, crossing, {20, 1}));
    emit("file_boundary", "audio", buildSegmentsAudioDesc(joined, crossing));
    for (const std::string &id : {"T2", "T3", "T5", "T6", "T1", "T4"}) {
        emit(id, "video", buildSegmentsVideoDesc(id, source, source, source, source,
            {{45125, 45625, 1.0, false}}, {20, 1}));
    }
    // 相同函数生成基线，只移除本次新增的 seek；线程、画质和其余滤镜完全一致。
    return 0;
}
