#include "export_engine.h"

#include <hilog/log.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#include <string>
#include <thread>
#include <utility>
#include <vector>

static std::atomic<int> g_exportPercent{0};
static std::atomic<int64_t> g_exportCurrentFrame{0};
static std::atomic<int64_t> g_exportTotalFrames{0};
static std::atomic<int> g_exportStage{0};
static std::atomic<bool> g_exportCancelled{false};
static std::mutex g_exportProgressMutex;
static int64_t g_exportCompletedUnits = 0;
static int64_t g_exportTotalUnits = 0;

NativeExportProgressInfo getNativeExportProgress()
{
    const std::lock_guard<std::mutex> lock(g_exportProgressMutex);
    NativeExportProgressInfo info;
    info.percent = g_exportPercent.load();
    info.currentFrame = g_exportCurrentFrame.load();
    info.totalFrames = g_exportTotalFrames.load();
    info.stage = g_exportStage.load();
    info.completedUnits = g_exportCompletedUnits;
    info.totalUnits = g_exportTotalUnits;
    return info;
}

void setNativeExportProgress(int percent, int64_t currentFrame, int64_t totalFrames, int stage,
                             int64_t completedUnits, int64_t totalUnits)
{
    const std::lock_guard<std::mutex> lock(g_exportProgressMutex);
    g_exportPercent.store(percent);
    g_exportCurrentFrame.store(currentFrame);
    g_exportTotalFrames.store(totalFrames);
    g_exportStage.store(stage);
    g_exportCompletedUnits = completedUnits;
    g_exportTotalUnits = totalUnits;
}

void cancelNativeExport()
{
    g_exportCancelled.store(true);
}

bool isNativeExportCancelled()
{
    return g_exportCancelled.load();
}

void resetNativeExportProgress()
{
    g_exportCancelled.store(false);
    setNativeExportProgress(0, 0, 0, 0);
}

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
}

namespace {

struct ProbeResult {
    int width = 0;
    int height = 0;
    int pixFmt = AV_PIX_FMT_YUV420P;
    int codecId = AV_CODEC_ID_NONE;
    AVRational frameRate = {30, 1};
    int64_t bitRate = 0;
};

struct PacketTimestampState {
    int64_t nextPts = 0;
    int64_t nextDts = 0;
    bool initialized = false;
};

struct TemporaryTrackFiles {
    std::vector<std::string> paths;
    ~TemporaryTrackFiles()
    {
        for (const auto &path : paths) {
            if (!path.empty()) {
                std::remove(path.c_str());
            }
        }
    }
};

std::string normalizeUri(const std::string &uri);
void logPipeline(const std::string &stage, const std::string &message);
std::string avErrorText(int ret);

int resolveThreadCount()
{
    const unsigned int hardware = std::thread::hardware_concurrency();
    if (hardware == 0) {
        return 4;
    }
    return static_cast<int>(hardware > 4 ? 4 : hardware);
}

int evenValue(int value)
{
    int normalized = value > 0 ? value : 1280;
    if (normalized % 2 != 0) {
        normalized -= 1;
    }
    return normalized > 0 ? normalized : 1280;
}

/** 哪几路轨由**版式本身**决定，和是哪个模版无关。 */
bool layoutNeedsBack(const ComposeLayout layout)
{
    return layout != ComposeLayout::Single;
}

bool layoutNeedsSide(const ComposeLayout layout)
{
    return layout == ComposeLayout::Top1Bottom2 || layout == ComposeLayout::Grid2x2 ||
           layout == ComposeLayout::ThreeUpCrop;
}

bool layoutNeedsSide2(const ComposeLayout layout)
{
    return layout == ComposeLayout::Grid2x2;
}

void applyPacketTimestampFallback(int64_t &pts,
                                  int64_t &dts,
                                  int64_t duration,
                                  PacketTimestampState &state)
{
    const int64_t step = duration > 0 ? duration : 1;
    if (!state.initialized) {
        if (pts == AV_NOPTS_VALUE && dts != AV_NOPTS_VALUE) {
            pts = dts;
        } else if (dts == AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE) {
            dts = pts;
        } else if (pts == AV_NOPTS_VALUE && dts == AV_NOPTS_VALUE) {
            pts = 0;
            dts = 0;
        }
        state.nextPts = pts + step;
        state.nextDts = dts + step;
        state.initialized = true;
        return;
    }
    if (dts == AV_NOPTS_VALUE) {
        dts = (pts != AV_NOPTS_VALUE) ? pts : state.nextDts;
    }
    if (dts < state.nextDts) {
        dts = state.nextDts;
    }
    if (pts == AV_NOPTS_VALUE) {
        pts = dts;
    }
    state.nextDts = dts + step;
    if (pts + step > state.nextPts) {
        state.nextPts = pts + step;
    }
}

std::string escapeFilterPath(const std::string &path)
{
    std::string escaped;
    escaped.reserve(path.size() * 2);
    for (char ch : path) {
        if (ch == '\\' || ch == ':' || ch == '\'') {
            escaped.push_back('\\');
        }
        escaped.push_back(ch);
    }
    return escaped;
}

std::string buildMovieSourceFilter(const std::string &path,
                                   const std::string &transformChain,
                                   double startSec,
                                   double endSec,
                                   double speed,
                                   const AVRational &frameRate)
{
    std::ostringstream oss;
    oss << "movie='" << escapeFilterPath(path) << "'";
    // seek 回退到关键帧；保留后面的精确 trim 和原始时间戳，不能以 seek 代替裁剪。
    if (startSec > 1.0) {
        oss << ":seek_point=" << (startSec - 1.0);
    }
    oss << ":dec_threads=" << resolveThreadCount();
    if (endSec > startSec && startSec >= 0.0) {
        oss << ",trim=start=" << startSec << ":end=" << endSec;
    } else if (startSec > 0.0) {
        oss << ",trim=start=" << startSec;
    }
    if (speed > 0.0 && std::fabs(speed - 1.0) > 1e-6) {
        oss << ",setpts=(PTS-STARTPTS)/" << speed;
    } else {
        oss << ",setpts=PTS-STARTPTS";
    }
    // fps 把每一段都归一成同一帧率与同一时间基，倍速靠它抽帧（setpts 压缩时间戳后按源帧率重采样），
    // 多段 concat 也依赖它保证各段时间基一致。
    if (frameRate.num > 0 && frameRate.den > 0) {
        oss << ",fps=" << frameRate.num << "/" << frameRate.den;
    }
    if (!transformChain.empty()) {
        oss << "," << transformChain;
    }
    return oss.str();
}

std::string buildTemplateFilterDesc(const ComposeLayout layout,
                                    const std::string &frontPath,
                                    const std::string &backPath,
                                    const std::string &sidePath,
                                    const std::string &side2Path,
                                    double startSec,
                                    double endSec,
                                    double speed,
                                    const AVRational &frameRate,
                                    const std::string &labelPrefix,
                                    const std::string &outLabel,
                                    const std::string &pixFmt = "yuv420p")
{
    // labelPrefix 让同一张图里的多段（多段剪辑）各自拥有不冲突的内部标签。
    const std::string top = labelPrefix + "top";
    const std::string bottom = labelPrefix + "bottom";
    const std::string left = labelPrefix + "left";
    const std::string right = labelPrefix + "right";
    const std::string middle = labelPrefix + "middle";
    const std::string bottomLeft = labelPrefix + "bl";
    const std::string bottomRight = labelPrefix + "br";
    const std::string out = "[" + outLabel + "]";
    const std::string formatFilter = ",format=pix_fmts=" + (pixFmt.empty() ? "yuv420p" : pixFmt) + ",setsar=1";
    if (layout == ComposeLayout::StackV) {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << top << "];"
            << buildMovieSourceFilter(backPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << bottom << "];"
            << "[" << top << "][" << bottom << "]vstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    if (layout == ComposeLayout::StackH) {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << left << "];"
            << buildMovieSourceFilter(backPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << right << "];"
            << "[" << left << "][" << right << "]hstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    if (layout == ComposeLayout::ThreeUpCrop) {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(sidePath, "scale=1920:1080,crop=960:1080:960:0", startSec, endSec, speed, frameRate) << "[" << left << "];"
            << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << middle << "];"
            << buildMovieSourceFilter(backPath, "scale=1920:1080,crop=960:1080:0:0", startSec, endSec, speed, frameRate) << "[" << right << "];"
            << "[" << left << "][" << middle << "][" << right << "]hstack=inputs=3" << formatFilter << out;
        return oss.str();
    }
    if (layout == ComposeLayout::Top1Bottom2) {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << top << "];"
            << buildMovieSourceFilter(sidePath, "scale=960:540", startSec, endSec, speed, frameRate) << "[" << bottomLeft << "];"
            << buildMovieSourceFilter(backPath, "scale=960:540", startSec, endSec, speed, frameRate) << "[" << bottomRight << "];"
            << "[" << bottomLeft << "][" << bottomRight << "]hstack=inputs=2[" << bottom << "];"
            << "[" << top << "][" << bottom << "]vstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    if (layout == ComposeLayout::Single) {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate)
            << formatFilter << out;
        return oss.str();
    }
    if (layout == ComposeLayout::Grid2x2) {
        // 四机位 2×2：左上=前、右上=后、左下=左后、右下=右后。
        // 画布 3840×2160，每格 1920×1080 正好等于各机位原生分辨率 —— 只做等比缩放 + 居中补边，
        // 不裁剪、不拉伸，源是 1920×1080 时 scale 与 pad 都是恒等变换，零重采样损失。
        const std::string cell =
            "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2";
        const std::string rowTop = labelPrefix + "rowTop";
        const std::string rowBottom = labelPrefix + "rowBottom";
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, cell, startSec, endSec, speed, frameRate) << "[" << top << "];"
            << buildMovieSourceFilter(backPath, cell, startSec, endSec, speed, frameRate) << "[" << right << "];"
            << buildMovieSourceFilter(sidePath, cell, startSec, endSec, speed, frameRate) << "[" << bottomLeft << "];"
            << buildMovieSourceFilter(side2Path, cell, startSec, endSec, speed, frameRate) << "[" << bottomRight << "];"
            << "[" << top << "][" << right << "]hstack=inputs=2[" << rowTop << "];"
            << "[" << bottomLeft << "][" << bottomRight << "]hstack=inputs=2[" << rowBottom << "];"
            << "[" << rowTop << "][" << rowBottom << "]vstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    return "";
}

// 多段视频链：每段各自 trim/倍速抽帧，再 concat 拼接。单段时直接产出 outLabel。
std::string buildSegmentsVideoDesc(const ComposeLayout layout,
                                   const std::string &frontPath,
                                   const std::string &backPath,
                                   const std::string &sidePath,
                                   const std::string &side2Path,
                                   const std::vector<NativeExportSegment> &segments,
                                   const AVRational &frameRate,
                                   const std::string &pixFmt = "yuv420p")
{
    std::ostringstream oss;
    for (size_t i = 0; i < segments.size(); i++) {
        const std::string label = (segments.size() == 1) ? std::string("outv") : ("seg" + std::to_string(i));
        const std::string one = buildTemplateFilterDesc(layout,
                                                        frontPath,
                                                        backPath,
                                                        sidePath,
                                                        side2Path,
                                                        segments[i].startMs / 1000.0,
                                                        segments[i].endMs / 1000.0,
                                                        segments[i].speed,
                                                        frameRate,
                                                        "s" + std::to_string(i) + "_",
                                                        label,
                                                        pixFmt);
        if (one.empty()) {
            return "";
        }
        oss << one;
        if (i + 1 < segments.size()) {
            oss << ";";
        }
    }
    if (segments.size() > 1) {
        oss << ";";
        for (size_t i = 0; i < segments.size(); i++) {
            oss << "[seg" << i << "]";
        }
        oss << "concat=n=" << segments.size() << ":v=1:a=0[outv]";
    }
    return oss.str();
}

// 多段音频链：每段各自 atrim/atempo/volume，再 concat 拼接。静音段用 volume=0 保留时长。
std::string buildSegmentsAudioDesc(const std::string &audioPath,
                                   const std::vector<NativeExportSegment> &segments)
{
    std::ostringstream oss;
    for (size_t i = 0; i < segments.size(); i++) {
        double speed = segments[i].speed;
        if (!(speed >= 0.5 && speed <= 2.0)) {
            speed = 1.0;
        }
        oss << "amovie='" << escapeFilterPath(audioPath) << "'";
        const double startSec = segments[i].startMs / 1000.0;
        // AAC 的感知噪声替代依赖先前解码状态；音频保持从头解码，保证样本一致。
        oss << ":dec_threads=1,atrim=start=" << startSec << ":end=" << (segments[i].endMs / 1000.0)
            << ",asetpts=PTS-STARTPTS";
        if (std::fabs(speed - 1.0) > 1e-6) {
            oss << ",atempo=" << speed;
        }
        oss << ",volume=" << (segments[i].muted ? 0.0 : 1.0)
            << ",aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo";
        if (segments.size() == 1) {
            oss << "[outa]";
        } else {
            oss << "[a" << i << "]";
            if (i + 1 < segments.size()) {
                oss << ";";
            }
        }
    }
    if (segments.size() > 1) {
        oss << ";";
        for (size_t i = 0; i < segments.size(); i++) {
            oss << "[a" << i << "]";
        }
        oss << "concat=n=" << segments.size() << ":v=0:a=1[outa]";
    }
    return oss.str();
}

bool composeTemplateToMp4(const ComposeSpec &spec,
                          const std::string &frontPath,
                          const std::string &backPath,
                          const std::string &sidePath,
                          const std::string &side2Path,
                          const bool includeFrontAudio,
                          const std::string &frontAudioPath,
                          double expectedDurationSec,
                          double startSec,
                          double endSec,
                          const std::vector<NativeExportSegment> &segments,
                          const ProbeResult &probe,
                          const std::string &outputPath,
                          std::string &error)
{
    const int width = evenValue(spec.canvasWidth);
    const int height = evenValue(spec.canvasHeight);
    AVRational frameRate = probe.frameRate.num > 0 && probe.frameRate.den > 0 ? probe.frameRate : AVRational{30, 1};
    AVFormatContext *outputFmt = nullptr;
    if (avformat_alloc_output_context2(&outputFmt, nullptr, "mp4", outputPath.c_str()) < 0 || outputFmt == nullptr) {
        error = "compose_alloc_output_context_failed";
        return false;
    }

    struct EncoderCandidate {
        std::string lookupName;
        AVCodecID codecId;
        bool isOhCodec;
    };
    // 鸿蒙原生平台导出专供：只使用 OpenHarmony 系统编码体系（h264_ohcodec / hevc_ohcodec），
    // 绝不静默降级为旧版 mpeg4（mp4v 兼容性差且不被相册索引）。
    const std::vector<EncoderCandidate> candidates = {
        {"h264_ohcodec", AV_CODEC_ID_H264, true},
        {"hevc_ohcodec", AV_CODEC_ID_HEVC, true},
        {"h264_oh", AV_CODEC_ID_H264, true},
        {"hevc_oh", AV_CODEC_ID_HEVC, true}
    };

    const AVCodec *selectedEncoder = nullptr;
    AVCodecContext *encoderCtx = nullptr;
    const int threadCount = resolveThreadCount();
    const int64_t sourceBitRate = probe.bitRate > 0 ? probe.bitRate : (12LL * 1000LL * 1000LL);
    const int64_t targetBitRate = sourceBitRate > (10LL * 1000LL * 1000LL) ? sourceBitRate : (10LL * 1000LL * 1000LL);
    std::vector<const AVCodec *> triedEncoders;
    std::string lastOpenError;

    for (const auto &candidate : candidates) {
        const AVCodec *enc = nullptr;
        if (!candidate.lookupName.empty()) {
            enc = avcodec_find_encoder_by_name(candidate.lookupName.c_str());
        }
        if (enc == nullptr) {
            enc = avcodec_find_encoder(candidate.codecId);
        }
        if (enc == nullptr) {
            continue;
        }
        bool alreadyTried = false;
        for (const AVCodec *tried : triedEncoders) {
            if (tried == enc) {
                alreadyTried = true;
                break;
            }
        }
        if (alreadyTried) {
            continue;
        }
        triedEncoders.push_back(enc);

        enum AVPixelFormat targetPixFmt = AV_PIX_FMT_YUV420P;
        const enum AVPixelFormat *pixFmts = nullptr;
        int numPixFmts = 0;
        avcodec_get_supported_config(nullptr, enc, AV_CODEC_CONFIG_PIX_FORMAT, 0,
                                     reinterpret_cast<const void **>(&pixFmts), &numPixFmts);
        if (pixFmts != nullptr) {
            bool hasNv12 = false;
            bool hasYuv420p = false;
            for (int p = 0; p < numPixFmts && pixFmts[p] != AV_PIX_FMT_NONE; ++p) {
                if (pixFmts[p] == AV_PIX_FMT_NV12) {
                    hasNv12 = true;
                }
                if (pixFmts[p] == AV_PIX_FMT_YUV420P) {
                    hasYuv420p = true;
                }
            }
            if (hasNv12 && !hasYuv420p) {
                targetPixFmt = AV_PIX_FMT_NV12;
            } else if (hasYuv420p) {
                targetPixFmt = AV_PIX_FMT_YUV420P;
            } else if (numPixFmts > 0) {
                targetPixFmt = pixFmts[0];
            }
        }

        AVCodecContext *ctx = avcodec_alloc_context3(enc);
        if (ctx == nullptr) {
            continue;
        }
        ctx->codec_id = enc->id;
        ctx->codec_type = AVMEDIA_TYPE_VIDEO;
        ctx->pix_fmt = targetPixFmt;
        ctx->width = width;
        ctx->height = height;
        ctx->time_base = av_inv_q(frameRate);
        // The OHCodec hardware encoders convert frame->pts to microseconds through
        // avctx->pkt_timebase (libavcodec/ohenc.c), whose default is {0,1}. Left unset,
        // av_rescale_q() collapses every frame timestamp to 0, which freezes the whole
        // video track onto a single DTS while the audio keeps playing.
        ctx->pkt_timebase = ctx->time_base;
        ctx->framerate = frameRate;
        ctx->thread_count = threadCount;
        ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
        ctx->slices = threadCount;
        ctx->bit_rate = targetBitRate;
        ctx->gop_size = 30;
        ctx->max_b_frames = 0;
        ctx->flags2 |= AV_CODEC_FLAG2_FAST;
        if (outputFmt->oformat->flags & AVFMT_GLOBALHEADER) {
            ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        AVDictionary *opts = nullptr;
        if (candidate.isOhCodec) {
            av_dict_set(&opts, "allow_sw", "1", 0);
            av_dict_set(&opts, "bitrate_mode", "vbr", 0);
        } else if (enc->id == AV_CODEC_ID_HEVC || enc->id == AV_CODEC_ID_H264) {
            av_dict_set(&opts, "preset", "veryfast", 0);
            av_dict_set(&opts, "crf", "24", 0);
        }

        const int openRet = avcodec_open2(ctx, enc, &opts);
        av_dict_free(&opts);
        if (openRet < 0) {
            const char *encName = enc->name != nullptr ? enc->name : "unknown";
            lastOpenError = std::string(encName) + ":" + avErrorText(openRet) + " (ret=" + std::to_string(openRet) + ")";
            logPipeline("mux", "encoder candidate " + std::string(encName) + " open failed: " +
                               avErrorText(openRet) + " (ret=" + std::to_string(openRet) + "), trying next");
            avcodec_free_context(&ctx);
            continue;
        }

        selectedEncoder = enc;
        encoderCtx = ctx;
        break;
    }

    if (encoderCtx == nullptr || selectedEncoder == nullptr) {
        avformat_free_context(outputFmt);
        error = "compose_open_encoder_failed:ohcodec_failed:" + (lastOpenError.empty() ? "encoder_not_found" : lastOpenError);
        return false;
    }

    const char *encoderName = selectedEncoder->name != nullptr ? selectedEncoder->name : "unknown";
    std::ostringstream encoderLog;
    encoderLog << "selected encoder=" << encoderName << " codec_id=" << static_cast<int>(selectedEncoder->id)
               << " pix_fmt=" << av_get_pix_fmt_name(encoderCtx->pix_fmt)
               << " hevc_encoder_available=" << (avcodec_find_encoder(AV_CODEC_ID_HEVC) != nullptr ? 1 : 0)
               << " h264_encoder_available=" << (avcodec_find_encoder(AV_CODEC_ID_H264) != nullptr ? 1 : 0);
    logPipeline("mux", encoderLog.str());

    {
        std::ostringstream encoderDetail;
        encoderDetail << "resolution=" << width << "x" << height << " fps=" << frameRate.num << "/"
                      << frameRate.den << " time_base=" << encoderCtx->time_base.num << "/"
                      << encoderCtx->time_base.den << " bitrate=" << targetBitRate
                      << " threads=" << threadCount;
        logPipeline("mux.encoder", encoderDetail.str());
    }
    AVStream *outVideoStream = avformat_new_stream(outputFmt, nullptr);
    if (outVideoStream == nullptr) {
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_new_stream_failed";
        return false;
    }
    outVideoStream->time_base = encoderCtx->time_base;
    if (avcodec_parameters_from_context(outVideoStream->codecpar, encoderCtx) < 0) {
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_copy_codecpar_failed";
        return false;
    }
    AVStream *outAudioStream = nullptr;
    AVCodecContext *audioEncoderCtx = nullptr;
    AVFilterGraph *audioGraph = nullptr;
    AVFilterContext *audioSinkCtx = nullptr;
    AVFrame *audioFrame = nullptr;
    auto releaseComposePartial = [&]() {
        if (audioFrame != nullptr) {
            av_frame_free(&audioFrame);
        }
        if (audioGraph != nullptr) {
            avfilter_graph_free(&audioGraph);
        }
        if (audioEncoderCtx != nullptr) {
            avcodec_free_context(&audioEncoderCtx);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
    };
    if (includeFrontAudio) {
        // 音频必须重编码：倍速要走 atempo、静音要走 volume=0，包直通做不到。
        const AVCodec *audioEncoder = avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (audioEncoder == nullptr) {
            releaseComposePartial();
            error = "compose_aac_encoder_not_found";
            return false;
        }
        audioEncoderCtx = avcodec_alloc_context3(audioEncoder);
        if (audioEncoderCtx == nullptr) {
            releaseComposePartial();
            error = "compose_alloc_audio_encoder_failed";
            return false;
        }
        audioEncoderCtx->sample_fmt = AV_SAMPLE_FMT_FLTP;
        audioEncoderCtx->sample_rate = 48000;
        av_channel_layout_default(&audioEncoderCtx->ch_layout, 2);
        audioEncoderCtx->bit_rate = 128000;
        audioEncoderCtx->time_base = AVRational{1, 48000};
        audioEncoderCtx->pkt_timebase = audioEncoderCtx->time_base;
        if (outputFmt->oformat->flags & AVFMT_GLOBALHEADER) {
            audioEncoderCtx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        const int openAudioRet = avcodec_open2(audioEncoderCtx, audioEncoder, nullptr);
        if (openAudioRet < 0) {
            releaseComposePartial();
            error = "compose_open_aac_encoder_failed:" + avErrorText(openAudioRet);
            return false;
        }
        outAudioStream = avformat_new_stream(outputFmt, nullptr);
        if (outAudioStream == nullptr ||
            avcodec_parameters_from_context(outAudioStream->codecpar, audioEncoderCtx) < 0) {
            releaseComposePartial();
            error = "compose_create_audio_stream_failed";
            return false;
        }
        outAudioStream->time_base = audioEncoderCtx->time_base;
        const std::string audioDesc = buildSegmentsAudioDesc(frontAudioPath, segments);
        audioGraph = avfilter_graph_alloc();
        if (audioGraph != nullptr) {
            audioGraph->nb_threads = 1;
        }
        const AVFilter *aBuffersinkFilter = avfilter_get_by_name("abuffersink");
        if (audioGraph == nullptr || aBuffersinkFilter == nullptr ||
            avfilter_graph_create_filter(&audioSinkCtx, aBuffersinkFilter, "asink", nullptr, nullptr, audioGraph) < 0) {
            releaseComposePartial();
            error = "compose_create_abuffersink_failed";
            return false;
        }
        AVFilterInOut *audioInputs = avfilter_inout_alloc();
        if (audioInputs == nullptr) {
            releaseComposePartial();
            error = "compose_audio_inout_alloc_failed";
            return false;
        }
        audioInputs->name = av_strdup("outa");
        audioInputs->filter_ctx = audioSinkCtx;
        audioInputs->pad_idx = 0;
        audioInputs->next = nullptr;
        {
            std::ostringstream audioInfo;
            audioInfo << "segments=" << segments.size() << " desc=" << audioDesc;
            logPipeline("filter.audio", audioInfo.str());
        }
        const int audioParseRet = avfilter_graph_parse_ptr(audioGraph, audioDesc.c_str(), &audioInputs, nullptr, nullptr);
        avfilter_inout_free(&audioInputs);
        if (audioParseRet < 0) {
            releaseComposePartial();
            error = "compose_audio_graph_parse_failed:" + avErrorText(audioParseRet);
            return false;
        }
        const int audioConfigRet = avfilter_graph_config(audioGraph, nullptr);
        if (audioConfigRet < 0) {
            releaseComposePartial();
            error = "compose_audio_graph_config_failed:" + avErrorText(audioConfigRet);
            return false;
        }
        if (audioEncoderCtx->frame_size > 0) {
            av_buffersink_set_frame_size(audioSinkCtx, static_cast<unsigned>(audioEncoderCtx->frame_size));
        }
        audioFrame = av_frame_alloc();
        if (audioFrame == nullptr) {
            releaseComposePartial();
            error = "compose_alloc_audio_frame_failed";
            return false;
        }
    }
    if (!(outputFmt->oformat->flags & AVFMT_NOFILE)) {
        const int openOutputRet = avio_open(&outputFmt->pb, outputPath.c_str(), AVIO_FLAG_WRITE);
        if (openOutputRet < 0) {
            avcodec_free_context(&encoderCtx);
            avformat_free_context(outputFmt);
            error = "compose_open_output_failed:" + avErrorText(openOutputRet) + ":" + outputPath;
            return false;
        }
    }
    const int headerRet = avformat_write_header(outputFmt, nullptr);
    if (headerRet < 0) {
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_write_header_failed:" + avErrorText(headerRet);
        return false;
    }
    AVFilterGraph *graph = avfilter_graph_alloc();
    if (graph != nullptr) {
        graph->nb_threads = threadCount;
    }
    AVFilterContext *bufferSink = nullptr;
    if (graph == nullptr) {
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_filter_graph_alloc_failed";
        return false;
    }
    const AVFilter *bufferSinkFilter = avfilter_get_by_name("buffersink");
    if (bufferSinkFilter == nullptr) {
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_buffersink_not_found";
        return false;
    }
    if (avfilter_graph_create_filter(&bufferSink, bufferSinkFilter, "sink", nullptr, nullptr, graph) < 0) {
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_create_buffersink_failed";
        return false;
    }
    AVFilterInOut *inputs = avfilter_inout_alloc();
    if (inputs == nullptr) {
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_inout_alloc_failed";
        return false;
    }
    inputs->name = av_strdup("outv");
    inputs->filter_ctx = bufferSink;
    inputs->pad_idx = 0;
    inputs->next = nullptr;
    const char *outPixFmt = av_get_pix_fmt_name(encoderCtx->pix_fmt);
    const std::string filterDesc = buildSegmentsVideoDesc(
        spec.layout, frontPath, backPath, sidePath, side2Path, segments, frameRate,
        outPixFmt != nullptr ? outPixFmt : "yuv420p");
    {
        std::ostringstream filterInfo;
        filterInfo << "layout=" << composeLayoutName(spec.layout) << " " << width << "x" << height
                   << " startSec=" << startSec << " endSec=" << endSec << " desc=" << filterDesc;
        logPipeline("filter", filterInfo.str());
    }
    if (filterDesc.empty()) {
        avfilter_inout_free(&inputs);
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_invalid_template_filter";
        return false;
    }
    const int parseRet = avfilter_graph_parse_ptr(graph, filterDesc.c_str(), &inputs, nullptr, nullptr);
    if (parseRet < 0) {
        avfilter_inout_free(&inputs);
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_graph_parse_failed:" + avErrorText(parseRet);
        return false;
    }
    avfilter_inout_free(&inputs);
    const int configRet = avfilter_graph_config(graph, nullptr);
    if (configRet < 0) {
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_graph_config_failed:" + avErrorText(configRet);
        return false;
    }
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    if (frame == nullptr || packet == nullptr) {
        if (frame != nullptr) {
            av_frame_free(&frame);
        }
        if (packet != nullptr) {
            av_packet_free(&packet);
        }
        avfilter_graph_free(&graph);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avcodec_free_context(&encoderCtx);
        avformat_free_context(outputFmt);
        error = "compose_alloc_frame_or_packet_failed";
        return false;
    }

    auto cleanupComposeResources = [&]() {
        if (frame != nullptr) {
            av_frame_free(&frame);
        }
        if (packet != nullptr) {
            av_packet_free(&packet);
        }
        if (graph != nullptr) {
            avfilter_graph_free(&graph);
        }
        if (audioGraph != nullptr) {
            avfilter_graph_free(&audioGraph);
        }
        if (audioEncoderCtx != nullptr) {
            avcodec_free_context(&audioEncoderCtx);
        }
        if (audioFrame != nullptr) {
            av_frame_free(&audioFrame);
        }
        if (outputFmt != nullptr) {
            if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                avio_closep(&outputFmt->pb);
            }
            avformat_free_context(outputFmt);
            outputFmt = nullptr;
        }
        if (encoderCtx != nullptr) {
            avcodec_free_context(&encoderCtx);
        }
    };

    int64_t nextPts = 0;
    int64_t videoEndPts = 0;
    double effectiveDurationSec = 0.0;
    for (size_t segmentIndex = 0; segmentIndex < segments.size(); segmentIndex++) {
        double oneSpeed = segments[segmentIndex].speed;
        if (!(oneSpeed >= 0.5 && oneSpeed <= 2.0)) {
            oneSpeed = 1.0;
        }
        effectiveDurationSec += (segments[segmentIndex].endMs - segments[segmentIndex].startMs) / 1000.0 / oneSpeed;
    }
    if (effectiveDurationSec <= 0.0) {
        effectiveDurationSec = (endSec > startSec) ? (endSec - startSec) : expectedDurationSec;
    }
    // segments 存在时由滤镜链各个 trim/concat 严格自然终止并触发 EOF；
    // 仅在无 segments 且指定时长时作为安全保护上限，并留 1.0 秒容差避免浮点舍入误伤尾帧。
    const int64_t videoCutoffPts = (segments.empty() && effectiveDurationSec > 0.0)
        ? static_cast<int64_t>(std::ceil((effectiveDurationSec + 1.0) * static_cast<double>(outVideoStream->time_base.den) /
                                         static_cast<double>(outVideoStream->time_base.num)))
        : 0;

    int64_t audioNextPts = 0;
    AVPacket *audioPkt = av_packet_alloc();

    // 音频从滤镜图里抽帧、按 48kHz 重打时间戳、交给 AAC 编码器。
    // 倍速/静音已经在滤镜链（atempo / volume）里生效，这里只负责编码与封装。
    auto writeEncodedAudio = [&]() -> bool {
        while (avcodec_receive_packet(audioEncoderCtx, audioPkt) == 0) {
            audioPkt->stream_index = outAudioStream->index;
            av_packet_rescale_ts(audioPkt, audioEncoderCtx->time_base, outAudioStream->time_base);
            const int writeRet = av_interleaved_write_frame(outputFmt, audioPkt);
            av_packet_unref(audioPkt);
            if (writeRet < 0) {
                return false;
            }
        }
        return true;
    };
    auto pumpAudioUntil = [&](double targetTimeSec) -> bool {
        if (audioSinkCtx == nullptr || audioEncoderCtx == nullptr || audioFrame == nullptr) {
            return true;
        }
        const int sampleRate = audioEncoderCtx->sample_rate > 0 ? audioEncoderCtx->sample_rate : 48000;
        while (true) {
            const double currentAudioSec = static_cast<double>(audioNextPts) / static_cast<double>(sampleRate);
            if (currentAudioSec >= targetTimeSec) {
                return true;
            }
            av_frame_unref(audioFrame);
            const int sinkAudioRet = av_buffersink_get_frame(audioSinkCtx, audioFrame);
            if (sinkAudioRet == AVERROR_EOF || sinkAudioRet == AVERROR(EAGAIN)) {
                return true;
            }
            if (sinkAudioRet < 0) {
                return false;
            }
            audioFrame->pts = audioNextPts;
            audioNextPts += audioFrame->nb_samples;
            if (avcodec_send_frame(audioEncoderCtx, audioFrame) < 0) {
                return false;
            }
            if (!writeEncodedAudio()) {
                return false;
            }
        }
    };

    int64_t encodedFrameCount = 0;
    int sinkBreakRet = 0;
    const int64_t totalExpectedFrames = (frameRate.den > 0 && frameRate.num > 0 && effectiveDurationSec > 0.0)
        ? static_cast<int64_t>(std::ceil(effectiveDurationSec * static_cast<double>(frameRate.num) / static_cast<double>(frameRate.den)))
        : (effectiveDurationSec > 0.0 ? static_cast<int64_t>(effectiveDurationSec * 30.0) : 1800);
    {
        std::ostringstream encodeBegin;
        encodeBegin << "begin cutoffPts=" << videoCutoffPts << " fps=" << frameRate.num << "/" << frameRate.den
                    << " expectFrames=" << totalExpectedFrames;
        logPipeline("encode", encodeBegin.str());
    }
    while (true) {
        if (isNativeExportCancelled()) {
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "export_cancelled";
            setNativeExportProgress(-1, encodedFrameCount, totalExpectedFrames, -1);
            return false;
        }
        int sinkRet = av_buffersink_get_frame(bufferSink, frame);
        if (sinkRet == AVERROR_EOF || sinkRet == AVERROR(EAGAIN)) {
            sinkBreakRet = sinkRet;
            break;
        }
        if (sinkRet < 0) {
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_buffersink_get_frame_failed";
            setNativeExportProgress(-1, encodedFrameCount, totalExpectedFrames, -1);
            return false;
        }
        frame->pts = nextPts++;
        ++encodedFrameCount;
        if (totalExpectedFrames > 0) {
            double ratio = static_cast<double>(encodedFrameCount) / static_cast<double>(totalExpectedFrames);
            if (ratio > 0.99) {
                ratio = 0.99;
            }
            if (ratio < 0.0) {
                ratio = 0.0;
            }
            int currentPct = 25 + static_cast<int>(ratio * 60.0);
            if (currentPct > 84) {
                currentPct = 84;
            }
            setNativeExportProgress(currentPct, encodedFrameCount, totalExpectedFrames, 2);
        }
        if (encodedFrameCount % 100 == 0) {
            std::ostringstream encodeProgress;
            encodeProgress << "progress frames=" << encodedFrameCount << " pts=" << frame->pts
                           << " pct=" << g_exportPercent.load();
            logPipeline("encode", encodeProgress.str());
        }
        if (avcodec_send_frame(encoderCtx, frame) < 0) {
            av_frame_unref(frame);
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_send_frame_failed";
            return false;
        }
        av_frame_unref(frame);
        while (avcodec_receive_packet(encoderCtx, packet) == 0) {
            packet->stream_index = outVideoStream->index;
            av_packet_rescale_ts(packet, encoderCtx->time_base, outVideoStream->time_base);
            if (packet->dts == AV_NOPTS_VALUE) {
                packet->dts = packet->pts;
            }
            if (packet->duration <= 0) {
                packet->duration = av_rescale_q(1, encoderCtx->time_base, outVideoStream->time_base);
            }
            if (videoCutoffPts > 0 && packet->pts != AV_NOPTS_VALUE && packet->pts >= videoCutoffPts) {
                av_packet_unref(packet);
                break;
            }
            const double videoTimeSec = (packet->pts != AV_NOPTS_VALUE)
                ? (static_cast<double>(packet->pts) * av_q2d(outVideoStream->time_base))
                : 0.0;
            if (!pumpAudioUntil(videoTimeSec)) {
                av_packet_unref(packet);
                av_packet_free(&audioPkt);
                cleanupComposeResources();
                error = "compose_write_interleaved_audio_failed";
                return false;
            }
            if (packet->pts != AV_NOPTS_VALUE) {
                const int64_t endPts = packet->pts + (packet->duration > 0 ? packet->duration : 1);
                if (endPts > videoEndPts) {
                    videoEndPts = endPts;
                }
            }
            const int writeRet = av_interleaved_write_frame(outputFmt, packet);
            av_packet_unref(packet);
            if (writeRet < 0) {
                av_packet_free(&audioPkt);
                cleanupComposeResources();
                error = "compose_write_packet_failed:" + avErrorText(writeRet);
                return false;
            }
        }
    }
    {
        std::ostringstream encodeLoopEnd;
        encodeLoopEnd << "loop end frames=" << encodedFrameCount << " breakRet="
                      << (sinkBreakRet == AVERROR_EOF ? "eof" : (sinkBreakRet == AVERROR(EAGAIN) ? "eagain" : "other"))
                      << " videoEndPts=" << videoEndPts
                      << " bytesWritten=" << (outputFmt->pb != nullptr ? avio_tell(outputFmt->pb) : -1);
        logPipeline("encode", encodeLoopEnd.str());
    }
    setNativeExportProgress(85, encodedFrameCount, totalExpectedFrames, 3);
    avcodec_send_frame(encoderCtx, nullptr);
    while (avcodec_receive_packet(encoderCtx, packet) == 0) {
        packet->stream_index = outVideoStream->index;
        av_packet_rescale_ts(packet, encoderCtx->time_base, outVideoStream->time_base);
        if (packet->dts == AV_NOPTS_VALUE) {
            packet->dts = packet->pts;
        }
        if (packet->duration <= 0) {
            packet->duration = av_rescale_q(1, encoderCtx->time_base, outVideoStream->time_base);
        }
        if (videoCutoffPts > 0 && packet->pts != AV_NOPTS_VALUE && packet->pts >= videoCutoffPts) {
            av_packet_unref(packet);
            break;
        }
        const double videoTimeSec = (packet->pts != AV_NOPTS_VALUE)
            ? (static_cast<double>(packet->pts) * av_q2d(outVideoStream->time_base))
            : 0.0;
        if (!pumpAudioUntil(videoTimeSec)) {
            av_packet_unref(packet);
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_write_interleaved_audio_failed";
            return false;
        }
        if (packet->pts != AV_NOPTS_VALUE) {
            const int64_t endPts = packet->pts + (packet->duration > 0 ? packet->duration : 1);
            if (endPts > videoEndPts) {
                videoEndPts = endPts;
            }
        }
        const int flushRet = av_interleaved_write_frame(outputFmt, packet);
        av_packet_unref(packet);
        if (flushRet < 0) {
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_flush_packet_failed:" + avErrorText(flushRet);
            return false;
        }
    }
    pumpAudioUntil(1e9);
    if (audioEncoderCtx != nullptr) {
        avcodec_send_frame(audioEncoderCtx, nullptr);
        writeEncodedAudio();
    }
    if (audioFrame != nullptr) {
        av_frame_free(&audioFrame);
    }
    av_packet_free(&audioPkt);
    {
        std::ostringstream composeFinish;
        composeFinish << "finish frames=" << encodedFrameCount << " videoEndPts=" << videoEndPts
                      << " bytesWritten=" << (outputFmt->pb != nullptr ? avio_tell(outputFmt->pb) : -1);
        logPipeline("encode", composeFinish.str());
    }
    const int trailerRet = av_write_trailer(outputFmt);
    if (trailerRet < 0) {
        error = "compose_write_trailer_failed:" + avErrorText(trailerRet);
        cleanupComposeResources();
        return false;
    }
    setNativeExportProgress(85, encodedFrameCount, totalExpectedFrames, 3);
    cleanupComposeResources();
    return true;
}

bool concatTrackToMp4(const std::vector<std::string> &inputs,
                      bool includeAudio,
                      const std::string &outputPath,
                      std::string &error,
                      int64_t &completedBytes,
                      int64_t totalBytes)
{
    if (inputs.empty()) {
        error = "concat_inputs_empty";
        return false;
    }
    AVFormatContext *outputFmt = nullptr;
    AVStream *outVideo = nullptr;
    AVStream *outAudio = nullptr;
    AVRational inVideoTb = {1, 1000};
    AVRational inAudioTb = {1, 1000};
    int64_t videoPtsOffset = 0;
    int64_t audioPtsOffset = 0;
    PacketTimestampState videoTsState;
    PacketTimestampState audioTsState;
    bool outputReady = false;
    for (const std::string &rawInput : inputs) {
        const std::string inputPath = normalizeUri(rawInput);
        struct stat inputStat {};
        const int64_t inputBytes = stat(inputPath.c_str(), &inputStat) == 0 ? inputStat.st_size : 0;
        int64_t processedInputBytes = 0;
        AVFormatContext *inputFmt = nullptr;
        if (avformat_open_input(&inputFmt, inputPath.c_str(), nullptr, nullptr) < 0) {
            if (outputFmt != nullptr) {
                if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                    avio_closep(&outputFmt->pb);
                }
                avformat_free_context(outputFmt);
            }
            error = "concat_open_input_failed";
            return false;
        }
        if (avformat_find_stream_info(inputFmt, nullptr) < 0) {
            avformat_close_input(&inputFmt);
            if (outputFmt != nullptr) {
                if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                    avio_closep(&outputFmt->pb);
                }
                avformat_free_context(outputFmt);
            }
            error = "concat_find_stream_info_failed";
            return false;
        }
        int videoIndex = av_find_best_stream(inputFmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (videoIndex < 0) {
            avformat_close_input(&inputFmt);
            if (outputFmt != nullptr) {
                if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                    avio_closep(&outputFmt->pb);
                }
                avformat_free_context(outputFmt);
            }
            error = "concat_video_stream_not_found";
            return false;
        }
        int audioIndex = includeAudio ? av_find_best_stream(inputFmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0) : -1;
        if (!outputReady) {
            if (avformat_alloc_output_context2(&outputFmt, nullptr, "mp4", outputPath.c_str()) < 0 || outputFmt == nullptr) {
                avformat_close_input(&inputFmt);
                error = "concat_alloc_output_context_failed";
                return false;
            }
            AVStream *inVideo = inputFmt->streams[videoIndex];
            outVideo = avformat_new_stream(outputFmt, nullptr);
            if (outVideo == nullptr || avcodec_parameters_copy(outVideo->codecpar, inVideo->codecpar) < 0) {
                avformat_close_input(&inputFmt);
                avformat_free_context(outputFmt);
                error = "concat_create_video_stream_failed";
                return false;
            }
            outVideo->codecpar->codec_tag = 0;
            inVideoTb = inVideo->time_base;
            if (audioIndex >= 0) {
                AVStream *inAudio = inputFmt->streams[audioIndex];
                outAudio = avformat_new_stream(outputFmt, nullptr);
                if (outAudio == nullptr || avcodec_parameters_copy(outAudio->codecpar, inAudio->codecpar) < 0) {
                    avformat_close_input(&inputFmt);
                    if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                        avio_closep(&outputFmt->pb);
                    }
                    avformat_free_context(outputFmt);
                    error = "concat_create_audio_stream_failed";
                    return false;
                }
                outAudio->codecpar->codec_tag = 0;
                inAudioTb = inAudio->time_base;
            }
            if (!(outputFmt->oformat->flags & AVFMT_NOFILE)) {
                if (avio_open(&outputFmt->pb, outputPath.c_str(), AVIO_FLAG_WRITE) < 0) {
                    avformat_close_input(&inputFmt);
                    avformat_free_context(outputFmt);
                    error = "concat_open_output_failed";
                    return false;
                }
            }
            if (avformat_write_header(outputFmt, nullptr) < 0) {
                avformat_close_input(&inputFmt);
                if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                    avio_closep(&outputFmt->pb);
                }
                avformat_free_context(outputFmt);
                error = "concat_write_header_failed";
                return false;
            }
            outputReady = true;
        }
        AVPacket *packet = av_packet_alloc();
        if (packet == nullptr) {
            avformat_close_input(&inputFmt);
            if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                avio_closep(&outputFmt->pb);
            }
            avformat_free_context(outputFmt);
            error = "concat_alloc_packet_failed";
            return false;
        }
        int64_t maxVideoPts = videoPtsOffset;
        int64_t maxAudioPts = audioPtsOffset;
        int64_t firstVideoDts = AV_NOPTS_VALUE;
        int64_t firstAudioDts = AV_NOPTS_VALUE;
        while (av_read_frame(inputFmt, packet) >= 0) {
            if (isNativeExportCancelled()) {
                av_packet_free(&packet);
                avformat_close_input(&inputFmt);
                if (outputFmt->pb != nullptr) {
                    avio_closep(&outputFmt->pb);
                }
                avformat_free_context(outputFmt);
                error = "export_cancelled";
                return false;
            }
            if (inputBytes > 0 && packet->pos >= 0) {
                processedInputBytes = std::min(inputBytes, std::max(processedInputBytes, packet->pos + packet->size));
                setNativeExportProgress(22, 0, 0, 4, completedBytes + processedInputBytes, totalBytes);
            }
            if (packet->stream_index == videoIndex) {
                AVStream *inStream = inputFmt->streams[videoIndex];
                packet->stream_index = outVideo->index;
                if (firstVideoDts == AV_NOPTS_VALUE) {
                    firstVideoDts = (packet->dts != AV_NOPTS_VALUE) ? packet->dts : ((packet->pts != AV_NOPTS_VALUE) ? packet->pts : 0);
                }
                int64_t relPts = (packet->pts != AV_NOPTS_VALUE) ? (packet->pts - firstVideoDts) : AV_NOPTS_VALUE;
                int64_t relDts = (packet->dts != AV_NOPTS_VALUE) ? (packet->dts - firstVideoDts) : AV_NOPTS_VALUE;
                int64_t mappedPts = (relPts != AV_NOPTS_VALUE) ? av_rescale_q(relPts, inStream->time_base, outVideo->time_base) : AV_NOPTS_VALUE;
                int64_t mappedDts = (relDts != AV_NOPTS_VALUE) ? av_rescale_q(relDts, inStream->time_base, outVideo->time_base) : AV_NOPTS_VALUE;
                packet->pts = (mappedPts != AV_NOPTS_VALUE) ? (mappedPts + videoPtsOffset) : AV_NOPTS_VALUE;
                packet->dts = (mappedDts != AV_NOPTS_VALUE) ? (mappedDts + videoPtsOffset) : AV_NOPTS_VALUE;
                packet->duration = av_rescale_q(packet->duration, inStream->time_base, outVideo->time_base);
                applyPacketTimestampFallback(packet->pts, packet->dts, packet->duration, videoTsState);
                if (packet->pts != AV_NOPTS_VALUE) {
                    int64_t endPts = packet->pts + (packet->duration > 0 ? packet->duration : 1);
                    if (endPts > maxVideoPts) {
                        maxVideoPts = endPts;
                    }
                }
                if (av_interleaved_write_frame(outputFmt, packet) < 0) {
                    av_packet_unref(packet);
                    av_packet_free(&packet);
                    avformat_close_input(&inputFmt);
                    if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                        avio_closep(&outputFmt->pb);
                    }
                    avformat_free_context(outputFmt);
                    error = "concat_write_video_packet_failed";
                    return false;
                }
            } else if (audioIndex >= 0 && outAudio != nullptr && packet->stream_index == audioIndex) {
                AVStream *inStream = inputFmt->streams[audioIndex];
                packet->stream_index = outAudio->index;
                if (firstAudioDts == AV_NOPTS_VALUE) {
                    firstAudioDts = (packet->dts != AV_NOPTS_VALUE) ? packet->dts : ((packet->pts != AV_NOPTS_VALUE) ? packet->pts : 0);
                }
                int64_t relPts = (packet->pts != AV_NOPTS_VALUE) ? (packet->pts - firstAudioDts) : AV_NOPTS_VALUE;
                int64_t relDts = (packet->dts != AV_NOPTS_VALUE) ? (packet->dts - firstAudioDts) : AV_NOPTS_VALUE;
                int64_t mappedPts = (relPts != AV_NOPTS_VALUE) ? av_rescale_q(relPts, inStream->time_base, outAudio->time_base) : AV_NOPTS_VALUE;
                int64_t mappedDts = (relDts != AV_NOPTS_VALUE) ? av_rescale_q(relDts, inStream->time_base, outAudio->time_base) : AV_NOPTS_VALUE;
                packet->pts = (mappedPts != AV_NOPTS_VALUE) ? (mappedPts + audioPtsOffset) : AV_NOPTS_VALUE;
                packet->dts = (mappedDts != AV_NOPTS_VALUE) ? (mappedDts + audioPtsOffset) : AV_NOPTS_VALUE;
                packet->duration = av_rescale_q(packet->duration, inStream->time_base, outAudio->time_base);
                applyPacketTimestampFallback(packet->pts, packet->dts, packet->duration, audioTsState);
                if (packet->pts != AV_NOPTS_VALUE) {
                    int64_t endPts = packet->pts + (packet->duration > 0 ? packet->duration : 1);
                    if (endPts > maxAudioPts) {
                        maxAudioPts = endPts;
                    }
                }
                if (av_interleaved_write_frame(outputFmt, packet) < 0) {
                    av_packet_unref(packet);
                    av_packet_free(&packet);
                    avformat_close_input(&inputFmt);
                    if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                        avio_closep(&outputFmt->pb);
                    }
                    avformat_free_context(outputFmt);
                    error = "concat_write_audio_packet_failed";
                    return false;
                }
            }
            av_packet_unref(packet);
        }
        av_packet_free(&packet);
        videoPtsOffset = videoTsState.nextDts > maxVideoPts ? videoTsState.nextDts : maxVideoPts;
        if (audioIndex >= 0 && outAudio != nullptr) {
            audioPtsOffset = audioTsState.nextDts > maxAudioPts ? audioTsState.nextDts : maxAudioPts;
        }
        avformat_close_input(&inputFmt);
        completedBytes += inputBytes;
        setNativeExportProgress(22, 0, 0, 4, completedBytes, totalBytes);
    }
    if (!outputReady) {
        error = "concat_output_not_ready";
        return false;
    }
    av_write_trailer(outputFmt);
    if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
        avio_closep(&outputFmt->pb);
    }
    avformat_free_context(outputFmt);
    return true;
}

std::string normalizeUri(const std::string &uri)
{
    static const std::string prefix = "file://";
    if (uri.rfind(prefix, 0) == 0) {
        return uri.substr(prefix.size());
    }
    return uri;
}

/**
 * 统一日志出口。hilog 给设备排查用（HarmonyOS 上应用进程的 stderr 不进 hilog），
 * stderr 留给宿主侧工具。tag 固定 export_engine，设备上用 `hdc shell hilog | grep export_engine` 抓。
 */
void logPipeline(const std::string &stage, const std::string &message)
{
    std::fprintf(stderr, "[export_engine][%s] %s\n", stage.c_str(), message.c_str());
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x3200, "智驾影音", "【Native】【%{public}s】%{public}s",
                 stage.c_str(), message.c_str());
}

/** 把 ffmpeg 的负返回值翻成可读文本，拼进错误串，避免设备上只看到 compose_xxx_failed。 */
std::string avErrorText(int ret)
{
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (av_strerror(ret, buffer, sizeof(buffer)) < 0) {
        return "ret=" + std::to_string(ret);
    }
    return std::string(buffer) + " (ret=" + std::to_string(ret) + ")";
}

bool probeVideoStream(const std::string &uri, ProbeResult &result, std::string &error)
{
    AVFormatContext *fmt = nullptr;
    if (avformat_open_input(&fmt, uri.c_str(), nullptr, nullptr) < 0) {
        error = "avformat_open_input_failed";
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        error = "avformat_find_stream_info_failed";
        avformat_close_input(&fmt);
        return false;
    }
    int streamIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (streamIndex < 0) {
        error = "video_stream_not_found";
        avformat_close_input(&fmt);
        return false;
    }
    AVStream *stream = fmt->streams[streamIndex];
    AVCodecParameters *codecPar = stream->codecpar;
    result.width = codecPar->width;
    result.height = codecPar->height;
    result.codecId = codecPar->codec_id;
    if (codecPar->format >= 0) {
        result.pixFmt = codecPar->format;
    }
    if (codecPar->bit_rate > 0) {
        result.bitRate = codecPar->bit_rate;
    }
    AVRational frameRate = av_guess_frame_rate(fmt, stream, nullptr);
    if (frameRate.num > 0 && frameRate.den > 0) {
        result.frameRate = frameRate;
    }
    avformat_close_input(&fmt);
    return true;
}

bool isVideoSpecCompatible(const ProbeResult &probe)
{
    if (probe.width != 1920 || probe.height != 1080) {
        return false;
    }
    if (probe.codecId != AV_CODEC_ID_HEVC) {
        return false;
    }
    return probe.frameRate.num > 0 && probe.frameRate.den > 0;
}

bool isNominalThirtyFps(const ProbeResult &probe)
{
    if (probe.frameRate.num <= 0 || probe.frameRate.den <= 0) {
        return false;
    }
    const int64_t delta = std::llabs(static_cast<int64_t>(probe.frameRate.num) - static_cast<int64_t>(probe.frameRate.den) * 30LL);
    return delta <= 1;
}

bool validateTrackSpecs(const std::vector<std::string> &uris,
                        const std::string &trackName,
                        std::string &error,
                        int64_t &checkedInputs,
                        int64_t totalInputs)
{
    for (size_t index = 0; index < uris.size(); ++index) {
        if (isNativeExportCancelled()) {
            error = "export_cancelled";
            return false;
        }
        ProbeResult trackProbe;
        const std::string normalizedUri = normalizeUri(uris[index]);
        std::string probeError;
        if (!probeVideoStream(normalizedUri, trackProbe, probeError)) {
            error = trackName + "_probe_failed_" + probeError;
            return false;
        }
        if (!isVideoSpecCompatible(trackProbe)) {
            std::ostringstream oss;
            oss << trackName << "_spec_mismatch_index_" << index << "_"
                << trackProbe.width << "x" << trackProbe.height << "_"
                << trackProbe.frameRate.num << "over" << trackProbe.frameRate.den << "_codec_" << trackProbe.codecId;
            error = oss.str();
            return false;
        }
        if (!isNominalThirtyFps(trackProbe)) {
            std::ostringstream fpsInfo;
            fpsInfo << "track=" << trackName << " index=" << index
                    << " non_30fps_input=" << trackProbe.frameRate.num << "/" << trackProbe.frameRate.den
                    << " normalize_to_30fps_in_filter=1";
            logPipeline("validate", fpsInfo.str());
        }
        setNativeExportProgress(20, 0, 0, 1, ++checkedInputs, totalInputs);
    }
    return true;
}

bool detectFrontAacAudio(const std::string &uri,
                         bool &hasAac,
                         std::string &error)
{
    AVFormatContext *fmt = nullptr;
    hasAac = false;
    if (avformat_open_input(&fmt, uri.c_str(), nullptr, nullptr) < 0) {
        error = "front_audio_open_failed";
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        avformat_close_input(&fmt);
        error = "front_audio_stream_info_failed";
        return false;
    }
    const int audioIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (audioIndex < 0) {
        avformat_close_input(&fmt);
        return true;
    }
    AVStream *audioStream = fmt->streams[audioIndex];
    if (audioStream != nullptr && audioStream->codecpar != nullptr) {
        hasAac = audioStream->codecpar->codec_id == AV_CODEC_ID_AAC;
    }
    avformat_close_input(&fmt);
    return true;
}


} // namespace

bool parseComposeLayout(const std::string &value, ComposeLayout &out)
{
    if (value == "single") { out = ComposeLayout::Single; return true; }
    if (value == "stack-v") { out = ComposeLayout::StackV; return true; }
    if (value == "stack-h") { out = ComposeLayout::StackH; return true; }
    if (value == "top1-bottom2") { out = ComposeLayout::Top1Bottom2; return true; }
    if (value == "grid-2x2") { out = ComposeLayout::Grid2x2; return true; }
    if (value == "three-up-crop") { out = ComposeLayout::ThreeUpCrop; return true; }
    return false;
}

std::string composeLayoutName(const ComposeLayout layout)
{
    switch (layout) {
        case ComposeLayout::Single: return "single";
        case ComposeLayout::StackV: return "stack-v";
        case ComposeLayout::StackH: return "stack-h";
        case ComposeLayout::Top1Bottom2: return "top1-bottom2";
        case ComposeLayout::Grid2x2: return "grid-2x2";
        case ComposeLayout::ThreeUpCrop: return "three-up-crop";
    }
    return "single";
}


std::string runExportEnginePipeline(const std::vector<std::string> &frontUris,
                                    const std::vector<std::string> &backUris,
                                    const std::vector<std::string> &sideUris,
                                    const std::vector<std::string> &side2Uris,
                                    const ComposeSpec &spec,
                                    double expectedDurationSec,
                                    const std::string &outputPath,
                                    double startMs,
                                    double endMs,
                                    const std::vector<NativeExportSegment> &segments)
{
    {
        std::ostringstream requestInfo;
        requestInfo << "front=" << frontUris.size() << " back=" << backUris.size()
                    << " side=" << sideUris.size() << " side2=" << side2Uris.size()
                    << " layout=" << composeLayoutName(spec.layout)
                    << " canvas=" << spec.canvasWidth << "x" << spec.canvasHeight
                    << " expectedDurationSec=" << expectedDurationSec
                    << " startMs=" << startMs << " endMs=" << endMs
                    << " segments=" << segments.size() << " output=" << outputPath;
        logPipeline("request", requestInfo.str());
        for (size_t i = 0; i < frontUris.size(); i++) {
            logPipeline("request.front", "[" + std::to_string(i) + "] " + frontUris[i]);
        }
        for (size_t i = 0; i < backUris.size(); i++) {
            logPipeline("request.back", "[" + std::to_string(i) + "] " + backUris[i]);
        }
        for (size_t i = 0; i < sideUris.size(); i++) {
            logPipeline("request.side", "[" + std::to_string(i) + "] " + sideUris[i]);
        }
        for (size_t i = 0; i < side2Uris.size(); i++) {
            logPipeline("request.side2", "[" + std::to_string(i) + "] " + side2Uris[i]);
        }
        for (size_t i = 0; i < segments.size(); i++) {
            std::ostringstream one;
            one << "#" << i << " [startMs=" << segments[i].startMs << "ms ~ endMs=" << segments[i].endMs << "ms] ("
                << (segments[i].startMs / 1000.0) << "s ~ " << (segments[i].endMs / 1000.0) << "s) speed="
                << segments[i].speed << " muted=" << (segments[i].muted ? "YES" : "NO");
            logPipeline("request.segment", one.str());
        }
    }
    if (isNativeExportCancelled()) {
        return "__ERROR__:pipeline_cancelled";
    }
    setNativeExportProgress(20, 0, 0, 1);
    if (frontUris.empty() || backUris.empty()) {
        logPipeline("validate", "invalid input: front/back uris empty");
        setNativeExportProgress(-1, 0, 0, -1);
        return "__ERROR__:pipeline_invalid_input";
    }
    if (outputPath.empty()) {
        logPipeline("validate", "invalid input: outputPath empty");
        setNativeExportProgress(-1, 0, 0, -1);
        return "__ERROR__:pipeline_output_path_empty";
    }

    const double startSec = startMs > 0.0 ? (startMs / 1000.0) : 0.0;
    double endSec = endMs > startMs ? (endMs / 1000.0) : 0.0;
    if (endSec <= startSec && expectedDurationSec > 0.0) {
        endSec = startSec + expectedDurationSec;
    }

    ProbeResult probe;
    std::string error;
    const std::string frontPrimary = normalizeUri(frontUris[0]);
    logPipeline("probe", "start probing front primary source");
    if (!probeVideoStream(frontPrimary, probe, error)) {
        logPipeline("probe", "failed probing front source: " + error);
        setNativeExportProgress(-1, 0, 0, -1);
        return "__ERROR__:pipeline_probe_front_" + error;
    }
    setNativeExportProgress(20, 0, 0, 1);
    std::ostringstream probeInfo;
    probeInfo << "probe success width=" << probe.width << " height=" << probe.height
              << " pixFmt=" << probe.pixFmt << " fps=" << probe.frameRate.num << "/" << probe.frameRate.den;
    logPipeline("probe", probeInfo.str());

    const bool needBackTrack = layoutNeedsBack(spec.layout);
    logPipeline("layout", "apply " + composeLayoutName(spec.layout) + " target=" +
        std::to_string(spec.canvasWidth) + "x" + std::to_string(spec.canvasHeight));
    const bool needSideTrack = layoutNeedsSide(spec.layout);
    const bool needSide2Track = layoutNeedsSide2(spec.layout);
    const std::vector<std::string> sideSource = !sideUris.empty() ? sideUris : backUris;
    // 第 4 路刻意**不做回退**：T4 右下格是「右后」，拿别的机位顶替只会静默产出一段机位错误的画面，
    // 宁可让导出明确失败，也不要"看起来成功但内容是错的"。
    const std::vector<std::string> side2Source = side2Uris;
    int64_t checkedInputs = 0;
    const int64_t totalInputs = static_cast<int64_t>(frontUris.size() + (needBackTrack ? backUris.size() : 0) +
        (needSideTrack ? sideSource.size() : 0) + (needSide2Track ? side2Source.size() : 0));
    if (!validateTrackSpecs(frontUris, "front", error, checkedInputs, totalInputs)) {
        logPipeline("validate", "front track spec invalid: " + error);
        return "__ERROR__:pipeline_spec_" + error;
    }
    if (needBackTrack && !validateTrackSpecs(backUris, "back", error, checkedInputs, totalInputs)) {
        logPipeline("validate", "back track spec invalid: " + error);
        return "__ERROR__:pipeline_spec_" + error;
    }
    if (needSideTrack && !validateTrackSpecs(sideSource, "side", error, checkedInputs, totalInputs)) {
        logPipeline("validate", "side track spec invalid: " + error);
        return "__ERROR__:pipeline_spec_" + error;
    }
    if (needSide2Track) {
        if (side2Source.empty()) {
            logPipeline("validate", "side2 track required but side2Uris empty");
            return "__ERROR__:pipeline_spec_side2_empty";
        }
        if (!validateTrackSpecs(side2Source, "side2", error, checkedInputs, totalInputs)) {
            logPipeline("validate", "side2 track spec invalid: " + error);
            return "__ERROR__:pipeline_spec_" + error;
        }
    }
    setNativeExportProgress(22, 0, 0, 1, totalInputs, totalInputs);

    std::string frontTrackPath;
    std::string backTrackPath;
    std::string sideTrackPath;
    std::string side2TrackPath;
    std::string frontConcatPath;
    std::string backConcatPath;
    std::string sideConcatPath;
    std::string side2ConcatPath;

    if (frontUris.size() == 1) {
        frontTrackPath = normalizeUri(frontUris[0]);
    } else {
        frontConcatPath = outputPath + ".front.concat.mp4";
        frontTrackPath = frontConcatPath;
    }

    if (!needBackTrack) {
        backTrackPath = frontTrackPath;
    } else if (backUris.size() == 1) {
        backTrackPath = normalizeUri(backUris[0]);
    } else {
        backConcatPath = outputPath + ".back.concat.mp4";
        backTrackPath = backConcatPath;
    }

    if (needSideTrack) {
        if (sideSource.size() == 1) {
            sideTrackPath = normalizeUri(sideSource[0]);
        } else {
            sideConcatPath = outputPath + ".side.concat.mp4";
            sideTrackPath = sideConcatPath;
        }
    } else {
        sideTrackPath = frontTrackPath;
    }

    if (needSide2Track) {
        if (side2Source.size() == 1) {
            side2TrackPath = normalizeUri(side2Source[0]);
        } else {
            side2ConcatPath = outputPath + ".side2.concat.mp4";
            side2TrackPath = side2ConcatPath;
        }
    } else {
        side2TrackPath = frontTrackPath;
    }

    const int threadCount = resolveThreadCount();
    logPipeline("perf", "ffmpeg thread_count=" + std::to_string(threadCount));
    const TemporaryTrackFiles temporaryTracks{{frontConcatPath, backConcatPath, sideConcatPath, side2ConcatPath}};
    int64_t completedConcatBytes = 0;
    int64_t totalConcatBytes = 0;
    const auto countConcatBytes = [&](const std::vector<std::string> &uris, const std::string &concatPath) {
        if (!concatPath.empty()) {
            for (const auto &uri : uris) {
                struct stat inputStat {};
                if (stat(normalizeUri(uri).c_str(), &inputStat) == 0) {
                    totalConcatBytes += inputStat.st_size;
                }
            }
        }
    };
    countConcatBytes(frontUris, frontConcatPath);
    countConcatBytes(backUris, backConcatPath);
    countConcatBytes(sideSource, sideConcatPath);
    countConcatBytes(side2Source, side2ConcatPath);
    setNativeExportProgress(22, 0, 0, 4, 0, totalConcatBytes);

    if (!frontConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(frontUris, true, frontConcatPath, localError, completedConcatBytes, totalConcatBytes)) {
            logPipeline("track", "concat front failed: " + localError);
            return "__ERROR__:pipeline_track_front_" + localError;
        }
    }

    if (!backConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(backUris, false, backConcatPath, localError, completedConcatBytes, totalConcatBytes)) {
            logPipeline("track", "concat back failed: " + localError);
            if (!frontConcatPath.empty()) {
                std::remove(frontConcatPath.c_str());
            }
            return "__ERROR__:pipeline_track_back_" + localError;
        }
    }

    if (!sideConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(sideSource, false, sideConcatPath, localError, completedConcatBytes, totalConcatBytes)) {
            logPipeline("track", "concat side failed: " + localError);
            if (!frontConcatPath.empty()) {
                std::remove(frontConcatPath.c_str());
            }
            if (!backConcatPath.empty()) {
                std::remove(backConcatPath.c_str());
            }
            return "__ERROR__:pipeline_track_side_" + localError;
        }
    }

    if (!side2ConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(side2Source, false, side2ConcatPath, localError, completedConcatBytes, totalConcatBytes)) {
            logPipeline("track", "concat side2 failed: " + localError);
            if (!frontConcatPath.empty()) {
                std::remove(frontConcatPath.c_str());
            }
            if (!backConcatPath.empty()) {
                std::remove(backConcatPath.c_str());
            }
            if (!sideConcatPath.empty()) {
                std::remove(sideConcatPath.c_str());
            }
            return "__ERROR__:pipeline_track_side2_" + localError;
        }
    }

    bool includeFrontAudio = false;
    if (!spec.muteFrontAudio) {
        std::string audioError;
        bool hasFrontAacAudio = false;
        if (!detectFrontAacAudio(frontTrackPath, hasFrontAacAudio, audioError)) {
            logPipeline("audio", "detect front audio failed: " + audioError);
        } else if (hasFrontAacAudio) {
            includeFrontAudio = true;
        } else {
            logPipeline("audio", "front audio missing aac stream, fallback to mute");
        }
    } else {
        logPipeline("audio", "layout " + composeLayoutName(spec.layout) + " disables front audio");
    }

    {
        std::ostringstream trackInfo;
        trackInfo << "frontTrack=" << frontTrackPath << " backTrack=" << backTrackPath
                  << " sideTrack=" << sideTrackPath << " side2Track=" << side2TrackPath
                  << " includeFrontAudio=" << (includeFrontAudio ? 1 : 0);
        logPipeline("track", trackInfo.str());
    }
    logPipeline("mux", "emit mp4 by ffmpeg compose, layout=" + composeLayoutName(spec.layout));
    setNativeExportProgress(25, 0, 0, 2);
    std::vector<NativeExportSegment> effectiveSegments = segments;
    if (effectiveSegments.empty()) {
        NativeExportSegment singleSegment;
        singleSegment.startMs = startSec * 1000.0;
        singleSegment.endMs = endSec * 1000.0;
        singleSegment.speed = 1.0;
        singleSegment.muted = false;
        effectiveSegments.push_back(singleSegment);
        logPipeline("mux", "no segments from caller, fallback to single range segment");
    }
    if (!composeTemplateToMp4(spec,
                              frontTrackPath,
                              backTrackPath,
                              sideTrackPath,
                              side2TrackPath,
                              includeFrontAudio,
                              frontTrackPath,
                              expectedDurationSec,
                              startSec,
                              endSec,
                              effectiveSegments,
                              probe,
                              outputPath,
                              error)) {
        logPipeline("mux", "emit failed: " + error);
        setNativeExportProgress(-1, 0, 0, -1);
        if (!outputPath.empty()) {
            std::remove(outputPath.c_str());
        }
        if (!frontConcatPath.empty()) {
            std::remove(frontConcatPath.c_str());
        }
        if (!backConcatPath.empty()) {
            std::remove(backConcatPath.c_str());
        }
        if (!sideConcatPath.empty()) {
            std::remove(sideConcatPath.c_str());
        }
        if (!side2ConcatPath.empty()) {
            std::remove(side2ConcatPath.c_str());
        }
        if (error == "export_cancelled" || isNativeExportCancelled()) {
            return "__ERROR__:pipeline_export_cancelled";
        }
        return "__ERROR__:pipeline_mux_" + error;
    }

    if (!frontConcatPath.empty()) {
        std::remove(frontConcatPath.c_str());
    }
    if (!backConcatPath.empty()) {
        std::remove(backConcatPath.c_str());
    }
    if (!sideConcatPath.empty()) {
        std::remove(sideConcatPath.c_str());
    }
    if (!side2ConcatPath.empty()) {
        std::remove(side2ConcatPath.c_str());
    }

    {
        std::ostringstream doneInfo;
        doneInfo << "output=" << outputPath;
        std::FILE *outputCheck = std::fopen(outputPath.c_str(), "rb");
        if (outputCheck != nullptr) {
            std::fseek(outputCheck, 0, SEEK_END);
            doneInfo << " bytes=" << static_cast<long long>(std::ftell(outputCheck));
            std::fclose(outputCheck);
        } else {
            doneInfo << " bytes=<open failed>";
        }
        logPipeline("complete", doneInfo.str());
    }
    return outputPath;
}
