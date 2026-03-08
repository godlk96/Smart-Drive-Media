#include "napi/native_api.h"
#include <cstdio>
#include <dlfcn.h>
#include <fstream>
#include <iomanip>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>
#include <ctime>
#include <cctype>
#include <cstdlib>

static std::string readPayload(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return "";
    }
    size_t size = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &size);
    std::string payload(size, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, args[0], &payload[0], size + 1, &copied);
    payload.resize(copied);
    return payload;
}

static std::string extractString(const std::string &payload, const std::string &key)
{
    std::string marker = "\"" + key + "\":\"";
    size_t start = payload.find(marker);
    if (start == std::string::npos) {
        return "";
    }
    start += marker.size();
    size_t end = payload.find("\"", start);
    if (end == std::string::npos || end <= start) {
        return "";
    }
    return payload.substr(start, end - start);
}

static std::vector<std::string> extractArray(const std::string &payload, const std::string &key)
{
    std::vector<std::string> values;
    std::string marker = "\"" + key + "\":[";
    size_t start = payload.find(marker);
    if (start == std::string::npos) {
        return values;
    }
    start += marker.size();
    size_t end = payload.find("]", start);
    if (end == std::string::npos || end <= start) {
        return values;
    }
    std::string body = payload.substr(start, end - start);
    size_t index = 0;
    while (index < body.size()) {
        size_t left = body.find("\"", index);
        if (left == std::string::npos) {
            break;
        }
        size_t right = body.find("\"", left + 1);
        if (right == std::string::npos) {
            break;
        }
        values.push_back(body.substr(left + 1, right - left - 1));
        index = right + 1;
    }
    return values;
}

static std::string shellQuote(const std::string &value)
{
    std::string escaped;
    for (char ch : value) {
        if (ch == '\'') {
            escaped += "'\\''";
        } else {
            escaped.push_back(ch);
        }
    }
    return "'" + escaped + "'";
}

static std::string normalizeUriForFfmpeg(const std::string &uri)
{
    const std::string prefix = "file://";
    if (uri.rfind(prefix, 0) == 0) {
        return uri.substr(prefix.size());
    }
    return uri;
}

static bool writeConcatList(const std::string &filePath, const std::vector<std::string> &uris)
{
    std::ofstream stream(filePath.c_str(), std::ios::out | std::ios::trunc);
    if (!stream.is_open()) {
        return false;
    }
    for (const std::string &uri : uris) {
        stream << "file " << shellQuote(normalizeUriForFfmpeg(uri)) << "\n";
    }
    stream.close();
    return true;
}

static std::string joinCommand(const std::vector<std::string> &args)
{
    std::ostringstream stream;
    for (size_t index = 0; index < args.size(); index++) {
        if (index > 0) {
            stream << " ";
        }
        stream << shellQuote(args[index]);
    }
    return stream.str();
}

static std::string runFfmpegSdk(const std::string &command)
{
    const std::vector<std::string> libs = {
        "libsmartdrive_ffmpeg_sdk.so",
        "libffmpegkit.so",
        "libffmpegcmd.so",
        "libffmpeg_api.so",
    };
    const std::vector<std::string> symbols = {
        "smartdrive_ffmpeg_execute",
        "ffmpegkit_execute",
        "ffmpeg_execute",
    };
    using ExecuteFunc = int (*)(const char *);
    bool opened = false;
    for (const std::string &lib : libs) {
        void *handle = dlopen(lib.c_str(), RTLD_NOW);
        if (!handle) {
            continue;
        }
        opened = true;
        for (const std::string &symbol : symbols) {
            auto execute = reinterpret_cast<ExecuteFunc>(dlsym(handle, symbol.c_str()));
            if (!execute) {
                continue;
            }
            int code = execute(command.c_str());
            dlclose(handle);
            if (code != 0) {
                return "__ERROR__:ffmpeg_sdk_exit_" + std::to_string(code);
            }
            return "";
        }
        dlclose(handle);
    }
    if (!opened) {
        return "__ERROR__:ffmpeg_sdk_not_found";
    }
    return "__ERROR__:ffmpeg_sdk_symbol_not_found";
}

static std::string composeByFfmpeg(const std::vector<std::string> &frontUris,
                                   const std::vector<std::string> &backUris,
                                   const std::string &outputPath)
{
    if (frontUris.empty() || backUris.empty() || outputPath.empty()) {
        return "__ERROR__:invalid_input";
    }
    std::string frontListPath = outputPath + ".front.concat.txt";
    std::string backListPath = outputPath + ".back.concat.txt";
    if (!writeConcatList(frontListPath, frontUris) || !writeConcatList(backListPath, backUris)) {
        return "__ERROR__:write_concat_failed";
    }
    const std::vector<std::string> args = {
        "ffmpeg",
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        frontListPath,
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        backListPath,
        "-filter_complex",
        "[0:v]setpts=PTS-STARTPTS[top];[1:v]setpts=PTS-STARTPTS[bottom];[top][bottom]vstack=inputs=2[v]",
        "-map",
        "[v]",
        "-c:v",
        "h264_avcodec",
        "-b:v",
        "20M",
        "-preset",
        "fast",
        outputPath};
    const std::string command = joinCommand(args);
    const std::string ffmpegError = runFfmpegSdk(command);
    std::remove(frontListPath.c_str());
    std::remove(backListPath.c_str());
    if (!ffmpegError.empty()) {
        return ffmpegError;
    }
    return outputPath;
}

static napi_value ComposeFrontBackStack(napi_env env, napi_callback_info info)
{
    std::string payload = readPayload(env, info);
    std::vector<std::string> frontUris = extractArray(payload, "frontUris");
    std::vector<std::string> backUris = extractArray(payload, "backUris");
    std::string outputPath = extractString(payload, "outputPath");
    std::string result = composeByFfmpeg(frontUris, backUris, outputPath);
    napi_value output = nullptr;
    napi_create_string_utf8(env, result.c_str(), result.length(), &output);
    return output;
}

static std::string normalizeCamera(const std::string &cameraRaw)
{
    if (cameraRaw == "front") {
        return "Front";
    }
    if (cameraRaw == "back") {
        return "Back";
    }
    if (cameraRaw == "left") {
        return "Left";
    }
    if (cameraRaw == "right") {
        return "Right";
    }
    if (cameraRaw == "left_front") {
        return "LeftFront";
    }
    if (cameraRaw == "right_front") {
        return "RightFront";
    }
    return cameraRaw;
}

static std::vector<std::string> splitBy(const std::string &value, char sep)
{
    std::vector<std::string> parts;
    std::string current;
    for (char ch : value) {
        if (ch == sep) {
            parts.push_back(current);
            current.clear();
        } else {
            current.push_back(ch);
        }
    }
    parts.push_back(current);
    return parts;
}

struct NativeTimelineTrack {
    std::string cameraPosition;
    int segmentCount;
    bool degraded;
};

static std::vector<NativeTimelineTrack> buildTimelineByCsv(const std::string &camerasCsv)
{
    const std::vector<std::string> cameraOrder = {"Front", "Back", "Left", "Right", "LeftFront", "RightFront"};
    std::map<std::string, int> counts;
    for (const std::string &camera : splitBy(camerasCsv, ',')) {
        if (!camera.empty()) {
            counts[camera] += 1;
        }
    }
    std::vector<NativeTimelineTrack> tracks;
    for (const std::string &camera : cameraOrder) {
        int count = counts[camera];
        if (count <= 0) {
            continue;
        }
        tracks.push_back(NativeTimelineTrack{camera, count, count < 2});
    }
    return tracks;
}

static std::vector<NativeTimelineTrack> mergeTimelineByCsv(const std::string &timelineCsv)
{
    const std::vector<std::string> cameraOrder = {"Front", "Back", "Left", "Right", "LeftFront", "RightFront"};
    std::map<std::string, int> counts;
    for (const std::string &timeline : splitBy(timelineCsv, ';')) {
        if (timeline.empty()) {
            continue;
        }
        for (const std::string &pair : splitBy(timeline, '|')) {
            if (pair.empty()) {
                continue;
            }
            std::vector<std::string> kv = splitBy(pair, ':');
            if (kv.size() != 2) {
                continue;
            }
            const std::string &camera = kv[0];
            int count = std::atoi(kv[1].c_str());
            if (count > 0) {
                counts[camera] += count;
            }
        }
    }
    std::vector<NativeTimelineTrack> tracks;
    for (const std::string &camera : cameraOrder) {
        int count = counts[camera];
        if (count <= 0) {
            continue;
        }
        tracks.push_back(NativeTimelineTrack{camera, count, false});
    }
    return tracks;
}

static void setNamedString(napi_env env, napi_value obj, const char *name, const std::string &value)
{
    napi_value v = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.length(), &v);
    napi_set_named_property(env, obj, name, v);
}

static void setNamedInt(napi_env env, napi_value obj, const char *name, int64_t value)
{
    napi_value v = nullptr;
    napi_create_int64(env, value, &v);
    napi_set_named_property(env, obj, name, v);
}

static void setNamedBool(napi_env env, napi_value obj, const char *name, bool value)
{
    napi_value v = nullptr;
    napi_get_boolean(env, value, &v);
    napi_set_named_property(env, obj, name, v);
}

static napi_value createTimelineTrackObject(napi_env env, const NativeTimelineTrack &track)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    setNamedString(env, obj, "cameraPosition", track.cameraPosition);
    setNamedInt(env, obj, "segmentCount", static_cast<int64_t>(track.segmentCount));
    setNamedBool(env, obj, "degraded", track.degraded);
    return obj;
}

static napi_value createTimelineArray(napi_env env, const std::vector<NativeTimelineTrack> &tracks)
{
    napi_value arr = nullptr;
    napi_create_array_with_length(env, tracks.size(), &arr);
    for (size_t i = 0; i < tracks.size(); i++) {
        napi_value obj = createTimelineTrackObject(env, tracks[i]);
        napi_set_element(env, arr, i, obj);
    }
    return arr;
}

static napi_value createStringArray(napi_env env, const std::vector<std::string> &items)
{
    napi_value arr = nullptr;
    napi_create_array_with_length(env, items.size(), &arr);
    for (size_t i = 0; i < items.size(); i++) {
        napi_value v = nullptr;
        napi_create_string_utf8(env, items[i].c_str(), items[i].length(), &v);
        napi_set_element(env, arr, i, v);
    }
    return arr;
}

static napi_value ParseDvrFileName(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string name;
    std::string uri;
    if (argc > 0) {
        size_t size = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &size);
        name.assign(size, '\0');
        size_t copied = 0;
        napi_get_value_string_utf8(env, args[0], &name[0], size + 1, &copied);
        name.resize(copied);
    }
    if (argc > 1) {
        size_t size = 0;
        napi_get_value_string_utf8(env, args[1], nullptr, 0, &size);
        uri.assign(size, '\0');
        size_t copied = 0;
        napi_get_value_string_utf8(env, args[1], &uri[0], size + 1, &copied);
        uri.resize(copied);
    }
    const std::regex pattern("^DVR_LoopRecording_(\\d{4}-\\d{2}-\\d{2})_(\\d{2})-(\\d{2})-(\\d{2})_([a-z_]+)_camera\\.(mp4|mov|ts)$", std::regex::icase);
    std::smatch match;
    if (std::regex_match(name, match, pattern)) {
        std::string date = match[1];
        std::string hh = match[2];
        std::string mm = match[3];
        std::string ss = match[4];
        std::string cameraRaw = match[5];
        for (char &ch : cameraRaw) {
            ch = static_cast<char>(std::tolower(ch));
        }
        std::string camera = normalizeCamera(cameraRaw);
        std::string fullTime = hh + ":" + mm + ":" + ss;
        std::string dateTime = date + "T" + fullTime;
        long timestamp = 0;
        std::tm tm{};
        std::istringstream stream(dateTime);
        stream >> std::get_time(&tm, "%Y-%m-%dT%H:%M:%S");
        if (!stream.fail()) {
            timestamp = static_cast<long>(mktime(&tm)) * 1000L;
        }
        if (timestamp > 0) {
            napi_value output = nullptr;
            napi_create_object(env, &output);
            setNamedString(env, output, "fileName", name);
            setNamedString(env, output, "uri", uri);
            setNamedString(env, output, "date", date);
            setNamedString(env, output, "time", fullTime);
            setNamedString(env, output, "camera", camera);
            setNamedInt(env, output, "timestamp", static_cast<int64_t>(timestamp));
            return output;
        }
    }
    napi_value nil = nullptr;
    napi_get_null(env, &nil);
    return nil;
}

static napi_value BuildTimeline(napi_env env, napi_callback_info info)
{
    std::string camerasCsv = readPayload(env, info);
    std::vector<NativeTimelineTrack> tracks = buildTimelineByCsv(camerasCsv);
    return createTimelineArray(env, tracks);
}

static napi_value MergeTimeline(napi_env env, napi_callback_info info)
{
    std::string timelineCsv = readPayload(env, info);
    std::vector<NativeTimelineTrack> tracks = mergeTimelineByCsv(timelineCsv);
    return createTimelineArray(env, tracks);
}

static napi_value BuildComposeRequest(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::vector<std::string> params(4, "");
    for (size_t i = 0; i < argc && i < 4; i++) {
        size_t size = 0;
        napi_get_value_string_utf8(env, args[i], nullptr, 0, &size);
        params[i].assign(size, '\0');
        size_t copied = 0;
        napi_get_value_string_utf8(env, args[i], &params[i][0], size + 1, &copied);
        params[i].resize(copied);
    }
    std::vector<std::string> frontUris;
    std::vector<std::string> backUris;
    for (const std::string &clip : splitBy(params[0], ',')) {
        if (clip.empty()) {
            continue;
        }
        std::vector<std::string> parts = splitBy(clip, '@');
        if (parts.size() < 3) {
            continue;
        }
        const std::string &camera = parts[0];
        const std::string &uri = parts[2];
        if (camera == "Front") {
            frontUris.push_back(uri);
        } else if (camera == "Back") {
            backUris.push_back(uri);
        }
    }
    napi_value output = nullptr;
    napi_create_object(env, &output);
    napi_value frontArr = createStringArray(env, frontUris);
    napi_value backArr = createStringArray(env, backUris);
    napi_set_named_property(env, output, "frontUris", frontArr);
    napi_set_named_property(env, output, "backUris", backArr);
    return output;
}

static napi_value GetCoreApiVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value output = nullptr;
    static const char *version = "core-api-v1";
    napi_create_string_utf8(env, version, NAPI_AUTO_LENGTH, &output);
    return output;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"composeFrontBackStack", nullptr, ComposeFrontBackStack, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseDvrFileName", nullptr, ParseDvrFileName, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildTimeline", nullptr, BuildTimeline, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mergeTimeline", nullptr, MergeTimeline, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildComposeRequest", nullptr, BuildComposeRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCoreApiVersion", nullptr, GetCoreApiVersion, nullptr, nullptr, nullptr, napi_default, nullptr}};
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "smartdrive_exporter",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSmartDriveExporterModule(void)
{
    napi_module_register(&module);
}
