#include "napi/native_api.h"
#include "export_engine.h"
#include <iomanip>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>
#include <ctime>
#include <cctype>
#include <cstdlib>

static std::string readUtf8Arg(napi_env env, napi_value value)
{
    if (value == nullptr) {
        return "";
    }
    napi_valuetype valueType = napi_undefined;
    if (napi_typeof(env, value, &valueType) != napi_ok) {
        return "";
    }
    if (valueType == napi_undefined || valueType == napi_null) {
        return "";
    }
    napi_value textValue = value;
    if (valueType != napi_string) {
        if (napi_coerce_to_string(env, value, &textValue) != napi_ok) {
            return "";
        }
    }
    size_t size = 0;
    if (napi_get_value_string_utf8(env, textValue, nullptr, 0, &size) != napi_ok) {
        return "";
    }
    if (size == 0) {
        return "";
    }
    std::vector<char> buffer(size + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, textValue, buffer.data(), size + 1, &copied) != napi_ok) {
        return "";
    }
    return std::string(buffer.data(), copied);
}

static std::string readPayload(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return "";
    }
    return readUtf8Arg(env, args[0]);
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

static double extractNumber(const std::string &payload, const std::string &key)
{
    std::string marker = "\"" + key + "\":";
    size_t start = payload.find(marker);
    if (start == std::string::npos) {
        return 0.0;
    }
    start += marker.size();
    size_t end = start;
    while (end < payload.size()) {
        const char ch = payload[end];
        if ((ch >= '0' && ch <= '9') || ch == '.' || ch == '-') {
            end += 1;
            continue;
        }
        break;
    }
    if (end <= start) {
        return 0.0;
    }
    return std::atof(payload.substr(start, end - start).c_str());
}

static napi_value RunExportPipeline(napi_env env, napi_callback_info info)
{
    std::string payload = readPayload(env, info);
    std::vector<std::string> frontUris = extractArray(payload, "frontUris");
    std::vector<std::string> backUris = extractArray(payload, "backUris");
    std::vector<std::string> sideUris = extractArray(payload, "sideUris");
    std::string templateId = extractString(payload, "templateId");
    double expectedDurationSec = extractNumber(payload, "expectedDurationSec");
    std::string outputPath = extractString(payload, "outputPath");
    std::string result = runExportEnginePipeline(frontUris, backUris, sideUris, templateId, expectedDurationSec, outputPath);
    napi_value output = nullptr;
    napi_create_string_utf8(env, result.c_str(), result.length(), &output);
    return output;
}

struct ExportPipelineAsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string payload;
    std::string result;
    std::string error;
};

static void ExecuteRunExportPipelineAsync(napi_env env, void *data)
{
    (void)env;
    auto *ctx = static_cast<ExportPipelineAsyncContext *>(data);
    if (ctx == nullptr) {
        return;
    }
    std::vector<std::string> frontUris = extractArray(ctx->payload, "frontUris");
    std::vector<std::string> backUris = extractArray(ctx->payload, "backUris");
    std::vector<std::string> sideUris = extractArray(ctx->payload, "sideUris");
    std::string templateId = extractString(ctx->payload, "templateId");
    double expectedDurationSec = extractNumber(ctx->payload, "expectedDurationSec");
    std::string outputPath = extractString(ctx->payload, "outputPath");
    ctx->result = runExportEnginePipeline(frontUris, backUris, sideUris, templateId, expectedDurationSec, outputPath);
    if (ctx->result.empty()) {
        ctx->error = "native export returned empty";
    } else if (ctx->result.rfind("__ERROR__", 0) == 0) {
        ctx->error = ctx->result;
    }
}

static void CompleteRunExportPipelineAsync(napi_env env, napi_status status, void *data)
{
    auto *ctx = static_cast<ExportPipelineAsyncContext *>(data);
    if (ctx == nullptr) {
        return;
    }
    if (status != napi_ok && ctx->error.empty()) {
        ctx->error = "native async work failed";
    }
    if (!ctx->error.empty()) {
        napi_value errorMessage = nullptr;
        napi_create_string_utf8(env, ctx->error.c_str(), NAPI_AUTO_LENGTH, &errorMessage);
        napi_value errorObj = nullptr;
        napi_create_error(env, nullptr, errorMessage, &errorObj);
        napi_reject_deferred(env, ctx->deferred, errorObj);
    } else {
        napi_value resultValue = nullptr;
        napi_create_string_utf8(env, ctx->result.c_str(), NAPI_AUTO_LENGTH, &resultValue);
        napi_resolve_deferred(env, ctx->deferred, resultValue);
    }
    if (ctx->work != nullptr) {
        napi_delete_async_work(env, ctx->work);
    }
    delete ctx;
}

static napi_value RunExportPipelineAsync(napi_env env, napi_callback_info info)
{
    std::string payload = readPayload(env, info);
    auto *ctx = new ExportPipelineAsyncContext();
    ctx->env = env;
    ctx->payload = payload;
    napi_value promise = nullptr;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "RunExportPipelineAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env,
                           nullptr,
                           resourceName,
                           ExecuteRunExportPipelineAsync,
                           CompleteRunExportPipelineAsync,
                           ctx,
                           &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
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
    std::string name = argc > 0 ? readUtf8Arg(env, args[0]) : "";
    std::string uri = argc > 1 ? readUtf8Arg(env, args[1]) : "";
    if (name.empty() || uri.empty()) {
        napi_value nil = nullptr;
        napi_get_null(env, &nil);
        return nil;
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
        params[i] = readUtf8Arg(env, args[i]);
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
        {"runExportPipeline", nullptr, RunExportPipeline, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runExportPipelineAsync", nullptr, RunExportPipelineAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
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
