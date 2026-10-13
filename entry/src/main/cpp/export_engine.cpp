#include "export_engine.h"

#include <hilog/log.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <dlfcn.h>
#include <future>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

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

struct FilterPipeline {
    AVFilterGraph *graph = nullptr;
    AVFilterContext *bufferSrc = nullptr;
    AVFilterContext *bufferSink = nullptr;
};

struct OhosPipeBridge {
    void *vencLib = nullptr;
    void *muxerLib = nullptr;
    bool ready = false;
    std::string error;
};

struct PacketTimestampState {
    int64_t nextPts = 0;
    int64_t nextDts = 0;
    bool initialized = false;
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

struct NativeTemplateContract {
    const char *templateId = "T2";
    int targetWidth = 1920;
    int targetHeight = 1620;
    bool needSideTrack = true;
    bool disableFrontAudio = false;
};

const std::array<NativeTemplateContract, 5> kNativeTemplateContracts = {{
    {"T1", 1920, 2160, false, false},
    {"T2", 1920, 1620, true, false},
    {"T3", 3840, 1080, false, true},
    {"T4", 3840, 1080, true, false},
    {"T5", 1920, 1080, false, false},
}};

const NativeTemplateContract *findTemplateContract(const std::string &templateId)
{
    for (const auto &contract : kNativeTemplateContracts) {
        if (templateId == contract.templateId) {
            return &contract;
        }
    }
    return nullptr;
}

const NativeTemplateContract &resolveTemplateContract(const std::string &templateId)
{
    const NativeTemplateContract *matched = findTemplateContract(templateId);
    if (matched != nullptr) {
        return *matched;
    }
    return kNativeTemplateContracts[1];
}

std::pair<int, int> resolveTemplateTargetResolution(const NativeTemplateContract &contract)
{
    return {contract.targetWidth, contract.targetHeight};
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
        }
        if (dts == AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE) {
            dts = pts;
        }
        if (pts == AV_NOPTS_VALUE) {
            pts = 0;
        }
        if (dts == AV_NOPTS_VALUE || dts > pts) {
            dts = pts;
        }
        state.nextPts = pts + step;
        state.nextDts = dts + step;
        state.initialized = true;
        return;
    }
    if (pts == AV_NOPTS_VALUE) {
        pts = dts != AV_NOPTS_VALUE ? dts : state.nextPts;
    }
    if (dts == AV_NOPTS_VALUE) {
        dts = pts;
    }
    if (pts < state.nextPts) {
        pts = state.nextPts;
    }
    if (dts < state.nextDts) {
        dts = state.nextDts;
    }
    if (dts > pts) {
        dts = pts;
    }
    state.nextPts = pts + step;
    state.nextDts = dts + step;
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

std::string buildTemplateFilterDesc(const std::string &templateId,
                                    const std::string &frontPath,
                                    const std::string &backPath,
                                    const std::string &sidePath,
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
    if (templateId == "T1") {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << top << "];"
            << buildMovieSourceFilter(backPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << bottom << "];"
            << "[" << top << "][" << bottom << "]vstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    if (templateId == "T3") {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << left << "];"
            << buildMovieSourceFilter(backPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << right << "];"
            << "[" << left << "][" << right << "]hstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    if (templateId == "T4") {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(sidePath, "crop=960:1080:960:0", startSec, endSec, speed, frameRate) << "[" << left << "];"
            << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << middle << "];"
            << buildMovieSourceFilter(backPath, "crop=960:1080:0:0", startSec, endSec, speed, frameRate) << "[" << right << "];"
            << "[" << left << "][" << middle << "][" << right << "]hstack=inputs=3" << formatFilter << out;
        return oss.str();
    }
    if (templateId == "T2") {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate) << "[" << top << "];"
            << buildMovieSourceFilter(sidePath, "scale=960:540", startSec, endSec, speed, frameRate) << "[" << bottomLeft << "];"
            << buildMovieSourceFilter(backPath, "scale=960:540", startSec, endSec, speed, frameRate) << "[" << bottomRight << "];"
            << "[" << bottomLeft << "][" << bottomRight << "]hstack=inputs=2[" << bottom << "];"
            << "[" << top << "][" << bottom << "]vstack=inputs=2" << formatFilter << out;
        return oss.str();
    }
    if (templateId == "T5") {
        std::ostringstream oss;
        oss << buildMovieSourceFilter(frontPath, "scale=1920:1080", startSec, endSec, speed, frameRate)
            << formatFilter << out;
        return oss.str();
    }
    return "";
}

// 多段视频链：每段各自 trim/倍速抽帧，再 concat 拼接。单段时直接产出 outLabel。
std::string buildSegmentsVideoDesc(const std::string &templateId,
                                   const std::string &frontPath,
                                   const std::string &backPath,
                                   const std::string &sidePath,
                                   const std::vector<NativeExportSegment> &segments,
                                   const AVRational &frameRate,
                                   const std::string &pixFmt = "yuv420p")
{
    std::ostringstream oss;
    for (size_t i = 0; i < segments.size(); i++) {
        const std::string label = (segments.size() == 1) ? std::string("outv") : ("seg" + std::to_string(i));
        const std::string one = buildTemplateFilterDesc(templateId,
                                                        frontPath,
                                                        backPath,
                                                        sidePath,
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
        oss << "amovie='" << escapeFilterPath(audioPath) << "'"
            << ",atrim=start=" << (segments[i].startMs / 1000.0) << ":end=" << (segments[i].endMs / 1000.0)
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

bool composeTemplateToMp4(const std::string &templateId,
                          const std::string &frontPath,
                          const std::string &backPath,
                          const std::string &sidePath,
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
    const NativeTemplateContract &templateContract = resolveTemplateContract(templateId);
    const std::pair<int, int> targetResolution = resolveTemplateTargetResolution(templateContract);
    const int width = evenValue(targetResolution.first);
    const int height = evenValue(targetResolution.second);
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
        templateId, frontPath, backPath, sidePath, segments, frameRate, outPixFmt != nullptr ? outPixFmt : "yuv420p");
    {
        std::ostringstream filterInfo;
        filterInfo << "template=" << templateId << " " << width << "x" << height
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
    const int64_t videoCutoffPts = effectiveDurationSec > 0.0
        ? static_cast<int64_t>(std::ceil(effectiveDurationSec * static_cast<double>(outVideoStream->time_base.den) /
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
        while (true) {
            av_frame_unref(audioFrame);
            const int sinkAudioRet = av_buffersink_get_frame(audioSinkCtx, audioFrame);
            if (sinkAudioRet == AVERROR_EOF || sinkAudioRet == AVERROR(EAGAIN)) {
                return true;
            }
            if (sinkAudioRet < 0) {
                return false;
            }
            const double audioTimeSec = audioFrame->pts != AV_NOPTS_VALUE
                ? (static_cast<double>(audioFrame->pts) * av_q2d(av_buffersink_get_time_base(audioSinkCtx)))
                : 0.0;
            audioFrame->pts = audioNextPts;
            audioNextPts += audioFrame->nb_samples;
            if (avcodec_send_frame(audioEncoderCtx, audioFrame) < 0) {
                return false;
            }
            if (!writeEncodedAudio()) {
                return false;
            }
            if (audioTimeSec > targetTimeSec) {
                return true;
            }
        }
    };

    int64_t encodedFrameCount = 0;
    int sinkBreakRet = 0;
    {
        std::ostringstream encodeBegin;
        encodeBegin << "begin cutoffPts=" << videoCutoffPts << " fps=" << frameRate.num << "/" << frameRate.den
                    << " expectFrames=" << (frameRate.den > 0 ? (effectiveDurationSec * frameRate.num / frameRate.den) : 0.0);
        logPipeline("encode", encodeBegin.str());
    }
    while (true) {
        int sinkRet = av_buffersink_get_frame(bufferSink, frame);
        if (sinkRet == AVERROR_EOF || sinkRet == AVERROR(EAGAIN)) {
            sinkBreakRet = sinkRet;
            break;
        }
        if (sinkRet < 0) {
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_buffersink_get_frame_failed";
            return false;
        }
        frame->pts = nextPts++;
        ++encodedFrameCount;
        if (encodedFrameCount % 100 == 0) {
            std::ostringstream encodeProgress;
            encodeProgress << "progress frames=" << encodedFrameCount << " pts=" << frame->pts;
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
            if (videoCutoffPts > 0 && packet->pts != AV_NOPTS_VALUE && packet->pts >= videoCutoffPts) {
                av_packet_unref(packet);
                break;
            }
            double videoTimeSec = (packet->pts != AV_NOPTS_VALUE)
                ? (static_cast<double>(packet->pts) * av_q2d(outVideoStream->time_base))
                : ((packet->dts != AV_NOPTS_VALUE) ? (static_cast<double>(packet->dts) * av_q2d(outVideoStream->time_base)) : 0.0);
            if (!pumpAudioUntil(videoTimeSec)) {
                av_packet_unref(packet);
                av_packet_free(&audioPkt);
                cleanupComposeResources();
                error = "compose_write_interleaved_audio_failed";
                return false;
            }
            const int writeRet = av_interleaved_write_frame(outputFmt, packet);
            if (writeRet < 0) {
                av_packet_unref(packet);
                av_packet_free(&audioPkt);
                cleanupComposeResources();
                error = "compose_write_packet_failed:" + avErrorText(writeRet);
                return false;
            }
            if (packet->pts != AV_NOPTS_VALUE) {
                const int64_t endPts = packet->pts + (packet->duration > 0 ? packet->duration : 1);
                if (endPts > videoEndPts) {
                    videoEndPts = endPts;
                }
            }
            av_packet_unref(packet);
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
    avcodec_send_frame(encoderCtx, nullptr);
    while (avcodec_receive_packet(encoderCtx, packet) == 0) {
        packet->stream_index = outVideoStream->index;
        av_packet_rescale_ts(packet, encoderCtx->time_base, outVideoStream->time_base);
        if (videoCutoffPts > 0 && packet->pts != AV_NOPTS_VALUE && packet->pts >= videoCutoffPts) {
            av_packet_unref(packet);
            break;
        }
        double videoTimeSec = (packet->pts != AV_NOPTS_VALUE)
            ? (static_cast<double>(packet->pts) * av_q2d(outVideoStream->time_base))
            : ((packet->dts != AV_NOPTS_VALUE) ? (static_cast<double>(packet->dts) * av_q2d(outVideoStream->time_base)) : 0.0);
        if (!pumpAudioUntil(videoTimeSec)) {
            av_packet_unref(packet);
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_write_interleaved_audio_failed";
            return false;
        }
        const int flushRet = av_interleaved_write_frame(outputFmt, packet);
        if (flushRet < 0) {
            av_packet_unref(packet);
            av_packet_free(&audioPkt);
            cleanupComposeResources();
            error = "compose_flush_packet_failed:" + avErrorText(flushRet);
            return false;
        }
        if (packet->pts != AV_NOPTS_VALUE) {
            const int64_t endPts = packet->pts + (packet->duration > 0 ? packet->duration : 1);
            if (endPts > videoEndPts) {
                videoEndPts = endPts;
            }
        }
        av_packet_unref(packet);
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
    av_write_trailer(outputFmt);
    cleanupComposeResources();
    return true;
}

bool concatTrackToMp4(const std::vector<std::string> &inputs,
                      bool includeAudio,
                      const std::string &outputPath,
                      std::string &error)
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
    bool outputReady = false;
    for (const std::string &rawInput : inputs) {
        const std::string inputPath = normalizeUri(rawInput);
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
        int64_t firstVideoPts = AV_NOPTS_VALUE;
        int64_t firstAudioPts = AV_NOPTS_VALUE;
        PacketTimestampState videoTsState;
        PacketTimestampState audioTsState;
        while (av_read_frame(inputFmt, packet) >= 0) {
            if (packet->stream_index == videoIndex) {
                AVStream *inStream = inputFmt->streams[videoIndex];
                packet->stream_index = outVideo->index;
                int64_t mappedPts = packet->pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(packet->pts, inStream->time_base, outVideo->time_base);
                int64_t mappedDts = packet->dts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(packet->dts, inStream->time_base, outVideo->time_base);
                if (mappedPts != AV_NOPTS_VALUE && firstVideoPts == AV_NOPTS_VALUE) {
                    firstVideoPts = mappedPts;
                }
                if (firstVideoPts != AV_NOPTS_VALUE) {
                    if (mappedPts != AV_NOPTS_VALUE) {
                        mappedPts -= firstVideoPts;
                    }
                    if (mappedDts != AV_NOPTS_VALUE) {
                        mappedDts -= firstVideoPts;
                    }
                }
                packet->pts = mappedPts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : mappedPts + videoPtsOffset;
                packet->dts = mappedDts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : mappedDts + videoPtsOffset;
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
                int64_t mappedPts = packet->pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(packet->pts, inStream->time_base, outAudio->time_base);
                int64_t mappedDts = packet->dts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(packet->dts, inStream->time_base, outAudio->time_base);
                if (mappedPts != AV_NOPTS_VALUE && firstAudioPts == AV_NOPTS_VALUE) {
                    firstAudioPts = mappedPts;
                }
                if (firstAudioPts != AV_NOPTS_VALUE) {
                    if (mappedPts != AV_NOPTS_VALUE) {
                        mappedPts -= firstAudioPts;
                    }
                    if (mappedDts != AV_NOPTS_VALUE) {
                        mappedDts -= firstAudioPts;
                    }
                }
                packet->pts = mappedPts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : mappedPts + audioPtsOffset;
                packet->dts = mappedDts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : mappedDts + audioPtsOffset;
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
        videoPtsOffset = maxVideoPts;
        if (audioIndex >= 0 && outAudio != nullptr) {
            audioPtsOffset = maxAudioPts;
        }
        avformat_close_input(&inputFmt);
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

bool muxVideoWithFrontAudio(const std::string &videoPath,
                            const std::string &frontTrackPath,
                            const std::string &outputPath,
                            std::string &error)
{
    AVFormatContext *videoFmt = nullptr;
    AVFormatContext *frontFmt = nullptr;
    if (avformat_open_input(&videoFmt, videoPath.c_str(), nullptr, nullptr) < 0) {
        error = "mux_open_video_failed";
        return false;
    }
    if (avformat_find_stream_info(videoFmt, nullptr) < 0) {
        avformat_close_input(&videoFmt);
        error = "mux_find_video_info_failed";
        return false;
    }
    if (avformat_open_input(&frontFmt, frontTrackPath.c_str(), nullptr, nullptr) < 0) {
        avformat_close_input(&videoFmt);
        error = "mux_open_front_failed";
        return false;
    }
    if (avformat_find_stream_info(frontFmt, nullptr) < 0) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        error = "mux_find_front_info_failed";
        return false;
    }
    int videoIndex = av_find_best_stream(videoFmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    int audioIndex = av_find_best_stream(frontFmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (videoIndex < 0 || audioIndex < 0) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        error = "mux_required_stream_not_found";
        return false;
    }
    AVFormatContext *outputFmt = nullptr;
    if (avformat_alloc_output_context2(&outputFmt, nullptr, "mp4", outputPath.c_str()) < 0 || outputFmt == nullptr) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        error = "mux_alloc_output_context_failed";
        return false;
    }
    AVStream *videoOut = avformat_new_stream(outputFmt, nullptr);
    AVStream *audioOut = avformat_new_stream(outputFmt, nullptr);
    if (videoOut == nullptr || audioOut == nullptr) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        avformat_free_context(outputFmt);
        error = "mux_create_stream_failed";
        return false;
    }
    if (avcodec_parameters_copy(videoOut->codecpar, videoFmt->streams[videoIndex]->codecpar) < 0 ||
        avcodec_parameters_copy(audioOut->codecpar, frontFmt->streams[audioIndex]->codecpar) < 0) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        avformat_free_context(outputFmt);
        error = "mux_copy_codecpar_failed";
        return false;
    }
    videoOut->codecpar->codec_tag = 0;
    audioOut->codecpar->codec_tag = 0;
    if (!(outputFmt->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&outputFmt->pb, outputPath.c_str(), AVIO_FLAG_WRITE) < 0) {
            avformat_close_input(&videoFmt);
            avformat_close_input(&frontFmt);
            avformat_free_context(outputFmt);
            error = "mux_open_output_failed";
            return false;
        }
    }
    if (avformat_write_header(outputFmt, nullptr) < 0) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avformat_free_context(outputFmt);
        error = "mux_write_header_failed";
        return false;
    }
    AVPacket *packet = av_packet_alloc();
    if (packet == nullptr) {
        avformat_close_input(&videoFmt);
        avformat_close_input(&frontFmt);
        if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
            avio_closep(&outputFmt->pb);
        }
        avformat_free_context(outputFmt);
        error = "mux_alloc_packet_failed";
        return false;
    }
    PacketTimestampState videoTsState;
    PacketTimestampState audioTsState;
    while (av_read_frame(videoFmt, packet) >= 0) {
        if (packet->stream_index != videoIndex) {
            av_packet_unref(packet);
            continue;
        }
        AVStream *inStream = videoFmt->streams[videoIndex];
        packet->stream_index = videoOut->index;
        av_packet_rescale_ts(packet, inStream->time_base, videoOut->time_base);
        packet->duration = av_rescale_q(packet->duration, inStream->time_base, videoOut->time_base);
        applyPacketTimestampFallback(packet->pts, packet->dts, packet->duration, videoTsState);
        if (av_interleaved_write_frame(outputFmt, packet) < 0) {
            av_packet_unref(packet);
            av_packet_free(&packet);
            avformat_close_input(&videoFmt);
            avformat_close_input(&frontFmt);
            if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                avio_closep(&outputFmt->pb);
            }
            avformat_free_context(outputFmt);
            error = "mux_write_video_packet_failed";
            return false;
        }
        av_packet_unref(packet);
    }
    while (av_read_frame(frontFmt, packet) >= 0) {
        if (packet->stream_index != audioIndex) {
            av_packet_unref(packet);
            continue;
        }
        AVStream *inStream = frontFmt->streams[audioIndex];
        packet->stream_index = audioOut->index;
        av_packet_rescale_ts(packet, inStream->time_base, audioOut->time_base);
        packet->duration = av_rescale_q(packet->duration, inStream->time_base, audioOut->time_base);
        applyPacketTimestampFallback(packet->pts, packet->dts, packet->duration, audioTsState);
        if (av_interleaved_write_frame(outputFmt, packet) < 0) {
            av_packet_unref(packet);
            av_packet_free(&packet);
            avformat_close_input(&videoFmt);
            avformat_close_input(&frontFmt);
            if (!(outputFmt->oformat->flags & AVFMT_NOFILE) && outputFmt->pb != nullptr) {
                avio_closep(&outputFmt->pb);
            }
            avformat_free_context(outputFmt);
            error = "mux_write_audio_packet_failed";
            return false;
        }
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
    av_write_trailer(outputFmt);
    avformat_close_input(&videoFmt);
    avformat_close_input(&frontFmt);
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
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x3200, "export_engine", "[%{public}s] %{public}s",
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
                        std::string &error)
{
    for (size_t index = 0; index < uris.size(); ++index) {
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

bool buildFilterPipeline(const ProbeResult &probe, FilterPipeline &pipeline, std::string &error)
{
    pipeline.graph = avfilter_graph_alloc();
    if (pipeline.graph == nullptr) {
        error = "avfilter_graph_alloc_failed";
        return false;
    }
    const AVFilter *bufferSrc = avfilter_get_by_name("buffer");
    const AVFilter *bufferSink = avfilter_get_by_name("buffersink");
    if (bufferSrc == nullptr || bufferSink == nullptr) {
        error = "avfilter_core_filter_not_found";
        return false;
    }
    char args[512] = {0};
    std::snprintf(args,
                  sizeof(args),
                  "video_size=%dx%d:pix_fmt=%d:time_base=1/%d:pixel_aspect=1/1",
                  probe.width > 0 ? probe.width : 1920,
                  probe.height > 0 ? probe.height : 1080,
                  probe.pixFmt >= 0 ? probe.pixFmt : AV_PIX_FMT_YUV420P,
                  probe.frameRate.num > 0 ? probe.frameRate.num : 30);
    if (avfilter_graph_create_filter(&pipeline.bufferSrc,
                                     bufferSrc,
                                     "smartdrive_buffer_src",
                                     args,
                                     nullptr,
                                     pipeline.graph) < 0) {
        error = "avfilter_create_buffer_src_failed";
        return false;
    }
    if (avfilter_graph_create_filter(&pipeline.bufferSink,
                                     bufferSink,
                                     "smartdrive_buffer_sink",
                                     nullptr,
                                     nullptr,
                                     pipeline.graph) < 0) {
        error = "avfilter_create_buffer_sink_failed";
        return false;
    }
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();
    if (outputs == nullptr || inputs == nullptr) {
        if (outputs != nullptr) {
            avfilter_inout_free(&outputs);
        }
        if (inputs != nullptr) {
            avfilter_inout_free(&inputs);
        }
        error = "avfilter_inout_alloc_failed";
        return false;
    }
    outputs->name = av_strdup("in");
    outputs->filter_ctx = pipeline.bufferSrc;
    outputs->pad_idx = 0;
    outputs->next = nullptr;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = pipeline.bufferSink;
    inputs->pad_idx = 0;
    inputs->next = nullptr;
    const std::string filterDesc = "fps=fps=30,format=pix_fmts=yuv420p";
    if (avfilter_graph_parse_ptr(pipeline.graph, filterDesc.c_str(), &inputs, &outputs, nullptr) < 0) {
        avfilter_inout_free(&outputs);
        avfilter_inout_free(&inputs);
        error = "avfilter_graph_parse_failed";
        return false;
    }
    avfilter_inout_free(&outputs);
    avfilter_inout_free(&inputs);
    if (avfilter_graph_config(pipeline.graph, nullptr) < 0) {
        error = "avfilter_graph_config_failed";
        return false;
    }
    return true;
}

void releaseFilterPipeline(FilterPipeline &pipeline)
{
    if (pipeline.graph != nullptr) {
        avfilter_graph_free(&pipeline.graph);
        pipeline.graph = nullptr;
        pipeline.bufferSrc = nullptr;
        pipeline.bufferSink = nullptr;
    }
}

bool warmupDemuxDecodeFilter(const std::string &uri, FilterPipeline &pipeline, std::string &error)
{
    AVFormatContext *fmt = nullptr;
    if (avformat_open_input(&fmt, uri.c_str(), nullptr, nullptr) < 0) {
        error = "warmup_open_input_failed";
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        avformat_close_input(&fmt);
        error = "warmup_find_stream_info_failed";
        return false;
    }
    int streamIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (streamIndex < 0) {
        avformat_close_input(&fmt);
        error = "warmup_video_stream_not_found";
        return false;
    }
    AVStream *stream = fmt->streams[streamIndex];
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (decoder == nullptr) {
        avformat_close_input(&fmt);
        error = "warmup_decoder_not_found";
        return false;
    }
    AVCodecContext *decoderCtx = avcodec_alloc_context3(decoder);
    if (decoderCtx == nullptr) {
        avformat_close_input(&fmt);
        error = "warmup_alloc_decoder_ctx_failed";
        return false;
    }
    if (avcodec_parameters_to_context(decoderCtx, stream->codecpar) < 0) {
        avcodec_free_context(&decoderCtx);
        avformat_close_input(&fmt);
        error = "warmup_copy_codecpar_failed";
        return false;
    }
    const int decoderThreadCount = resolveThreadCount();
    decoderCtx->thread_count = decoderThreadCount;
    decoderCtx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    if (avcodec_open2(decoderCtx, decoder, nullptr) < 0) {
        avcodec_free_context(&decoderCtx);
        avformat_close_input(&fmt);
        error = "warmup_open_decoder_failed";
        return false;
    }
    AVPacket *packet = av_packet_alloc();
    AVFrame *decoded = av_frame_alloc();
    AVFrame *filtered = av_frame_alloc();
    if (packet == nullptr || decoded == nullptr || filtered == nullptr) {
        if (packet != nullptr) {
            av_packet_free(&packet);
        }
        if (decoded != nullptr) {
            av_frame_free(&decoded);
        }
        if (filtered != nullptr) {
            av_frame_free(&filtered);
        }
        avcodec_free_context(&decoderCtx);
        avformat_close_input(&fmt);
        error = "warmup_alloc_packet_or_frame_failed";
        return false;
    }
    int filteredCount = 0;
    while (filteredCount < 8 && av_read_frame(fmt, packet) >= 0) {
        if (packet->stream_index != streamIndex) {
            av_packet_unref(packet);
            continue;
        }
        if (avcodec_send_packet(decoderCtx, packet) < 0) {
            av_packet_unref(packet);
            continue;
        }
        av_packet_unref(packet);
        while (avcodec_receive_frame(decoderCtx, decoded) == 0) {
            if (av_buffersrc_add_frame_flags(pipeline.bufferSrc, decoded, AV_BUFFERSRC_FLAG_KEEP_REF) < 0) {
                av_frame_unref(decoded);
                continue;
            }
            av_frame_unref(decoded);
            while (av_buffersink_get_frame(pipeline.bufferSink, filtered) == 0) {
                filteredCount += 1;
                av_frame_unref(filtered);
                if (filteredCount >= 8) {
                    break;
                }
            }
        }
    }
    avcodec_send_packet(decoderCtx, nullptr);
    while (avcodec_receive_frame(decoderCtx, decoded) == 0) {
        if (av_buffersrc_add_frame_flags(pipeline.bufferSrc, decoded, AV_BUFFERSRC_FLAG_KEEP_REF) >= 0) {
            while (av_buffersink_get_frame(pipeline.bufferSink, filtered) == 0) {
                av_frame_unref(filtered);
            }
        }
        av_frame_unref(decoded);
    }
    av_packet_free(&packet);
    av_frame_free(&decoded);
    av_frame_free(&filtered);
    avcodec_free_context(&decoderCtx);
    avformat_close_input(&fmt);
    if (filteredCount == 0) {
        error = "warmup_filter_no_frame";
        return false;
    }
    return true;
}

OhosPipeBridge initOhosPipeBridge()
{
    OhosPipeBridge bridge;
    bridge.vencLib = dlopen("libnative_media_venc.so", RTLD_NOW);
    bridge.muxerLib = dlopen("libnative_media_avmuxer.so", RTLD_NOW);
    if (bridge.vencLib == nullptr || bridge.muxerLib == nullptr) {
        bridge.error = "oh_pipe_dlopen_failed";
        return bridge;
    }
    const std::vector<const char *> vencSymbols = {
        "OH_VideoEncoder_CreateByMime",
        "OH_VideoEncoder_Destroy",
    };
    const std::vector<const char *> muxerSymbols = {
        "OH_AVMuxer_Create",
        "OH_AVMuxer_Destroy",
    };
    for (const char *symbol : vencSymbols) {
        if (dlsym(bridge.vencLib, symbol) == nullptr) {
            bridge.error = std::string("oh_venc_symbol_missing_") + symbol;
            return bridge;
        }
    }
    for (const char *symbol : muxerSymbols) {
        if (dlsym(bridge.muxerLib, symbol) == nullptr) {
            bridge.error = std::string("oh_muxer_symbol_missing_") + symbol;
            return bridge;
        }
    }
    bridge.ready = true;
    return bridge;
}

void releaseOhosPipeBridge(OhosPipeBridge &bridge)
{
    if (bridge.vencLib != nullptr) {
        dlclose(bridge.vencLib);
        bridge.vencLib = nullptr;
    }
    if (bridge.muxerLib != nullptr) {
        dlclose(bridge.muxerLib);
        bridge.muxerLib = nullptr;
    }
    bridge.ready = false;
}

bool tryWarmupOhosBridge(const std::string &frontUri, const ProbeResult &probe, std::string &error)
{
    OhosPipeBridge bridge = initOhosPipeBridge();
    if (!bridge.ready) {
        error = bridge.error;
        releaseOhosPipeBridge(bridge);
        return false;
    }
    FilterPipeline pipeline;
    std::string bridgeError;
    if (!buildFilterPipeline(probe, pipeline, bridgeError)) {
        releaseFilterPipeline(pipeline);
        releaseOhosPipeBridge(bridge);
        error = "bridge_filter_" + bridgeError;
        return false;
    }
    if (!warmupDemuxDecodeFilter(frontUri, pipeline, bridgeError)) {
        releaseFilterPipeline(pipeline);
        releaseOhosPipeBridge(bridge);
        error = "bridge_warmup_" + bridgeError;
        return false;
    }
    releaseFilterPipeline(pipeline);
    releaseOhosPipeBridge(bridge);
    return true;
}

} // namespace

bool isSupportedTemplateId(const std::string &templateId)
{
    return findTemplateContract(templateId) != nullptr;
}

std::string normalizeTemplateId(const std::string &templateId)
{
    return resolveTemplateContract(templateId).templateId;
}

std::string runExportEnginePipeline(const std::vector<std::string> &frontUris,
                                    const std::vector<std::string> &backUris,
                                    const std::vector<std::string> &sideUris,
                                    const std::string &templateId,
                                    double expectedDurationSec,
                                    const std::string &outputPath,
                                    double startMs,
                                    double endMs,
                                    const std::vector<NativeExportSegment> &segments)
{
    {
        std::ostringstream requestInfo;
        requestInfo << "front=" << frontUris.size() << " back=" << backUris.size()
                    << " side=" << sideUris.size() << " template=" << templateId
                    << " expectedDurationSec=" << expectedDurationSec
                    << " startMs=" << startMs << " endMs=" << endMs
                    << " segments=" << segments.size() << " output=" << outputPath;
        logPipeline("request", requestInfo.str());
        for (size_t i = 0; i < segments.size(); i++) {
            std::ostringstream one;
            one << "#" << i << " startMs=" << segments[i].startMs << " endMs=" << segments[i].endMs
                << " speed=" << segments[i].speed << " muted=" << (segments[i].muted ? 1 : 0);
            logPipeline("request.segment", one.str());
        }
    }
    if (frontUris.empty() || backUris.empty()) {
        logPipeline("validate", "invalid input: front/back uris empty");
        return "__ERROR__:pipeline_invalid_input";
    }
    if (outputPath.empty()) {
        logPipeline("validate", "invalid input: outputPath empty");
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
        return "__ERROR__:pipeline_probe_front_" + error;
    }
    std::ostringstream probeInfo;
    probeInfo << "probe success width=" << probe.width << " height=" << probe.height
              << " pixFmt=" << probe.pixFmt << " fps=" << probe.frameRate.num << "/" << probe.frameRate.den;
    logPipeline("probe", probeInfo.str());

    const NativeTemplateContract &templateContract = resolveTemplateContract(templateId);
    const std::string normalizedTemplate = templateContract.templateId;
    const std::pair<int, int> targetResolution = resolveTemplateTargetResolution(templateContract);
    logPipeline("template", "apply " + normalizedTemplate + " target=" + std::to_string(targetResolution.first) +
        "x" + std::to_string(targetResolution.second));
    const bool needSideTrack = templateContract.needSideTrack;
    const std::vector<std::string> sideSource = !sideUris.empty() ? sideUris : backUris;
    if (!validateTrackSpecs(frontUris, "front", error)) {
        logPipeline("validate", "front track spec invalid: " + error);
        return "__ERROR__:pipeline_spec_" + error;
    }
    if (!validateTrackSpecs(backUris, "back", error)) {
        logPipeline("validate", "back track spec invalid: " + error);
        return "__ERROR__:pipeline_spec_" + error;
    }
    if (needSideTrack && !validateTrackSpecs(sideSource, "side", error)) {
        logPipeline("validate", "side track spec invalid: " + error);
        return "__ERROR__:pipeline_spec_" + error;
    }
    std::string bridgeWarmupError;
    if (!tryWarmupOhosBridge(frontPrimary, probe, bridgeWarmupError)) {
        logPipeline("bridge", "oh_bridge_unavailable_fallback_ffmpeg_only reason=" + bridgeWarmupError);
    } else {
        logPipeline("bridge", "oh_bridge_ready");
    }

    std::string frontTrackPath;
    std::string backTrackPath;
    std::string sideTrackPath;
    std::string frontConcatPath;
    std::string backConcatPath;
    std::string sideConcatPath;

    if (frontUris.size() == 1) {
        frontTrackPath = normalizeUri(frontUris[0]);
    } else {
        frontConcatPath = outputPath + ".front.concat.mp4";
        frontTrackPath = frontConcatPath;
    }

    if (backUris.size() == 1) {
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

    const int threadCount = resolveThreadCount();
    logPipeline("perf", "ffmpeg thread_count=" + std::to_string(threadCount));

    if (!frontConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(frontUris, true, frontConcatPath, localError)) {
            logPipeline("track", "concat front failed: " + localError);
            return "__ERROR__:pipeline_track_front_" + localError;
        }
    }

    if (!backConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(backUris, false, backConcatPath, localError)) {
            logPipeline("track", "concat back failed: " + localError);
            if (!frontConcatPath.empty()) {
                std::remove(frontConcatPath.c_str());
            }
            return "__ERROR__:pipeline_track_back_" + localError;
        }
    }

    if (!sideConcatPath.empty()) {
        std::string localError;
        if (!concatTrackToMp4(sideSource, false, sideConcatPath, localError)) {
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

    bool includeFrontAudio = false;
    if (!templateContract.disableFrontAudio) {
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
        logPipeline("audio", "template " + normalizedTemplate + " disables front audio");
    }

    {
        std::ostringstream trackInfo;
        trackInfo << "frontTrack=" << frontTrackPath << " backTrack=" << backTrackPath
                  << " sideTrack=" << sideTrackPath << " includeFrontAudio=" << (includeFrontAudio ? 1 : 0);
        logPipeline("track", trackInfo.str());
    }
    logPipeline("mux", "emit mp4 by ffmpeg template compose, template=" + normalizedTemplate);
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
    if (!composeTemplateToMp4(normalizedTemplate,
                              frontTrackPath,
                              backTrackPath,
                              sideTrackPath,
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
        if (!frontConcatPath.empty()) {
            std::remove(frontConcatPath.c_str());
        }
        if (!backConcatPath.empty()) {
            std::remove(backConcatPath.c_str());
        }
        if (!sideConcatPath.empty()) {
            std::remove(sideConcatPath.c_str());
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
