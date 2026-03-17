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
#include <cmath>

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

struct NativeExportPipelineRequest {
    std::vector<std::string> frontUris;
    std::vector<std::string> backUris;
    std::vector<std::string> sideUris;
    std::string templateId;
    double expectedDurationSec = 0.0;
    std::string outputPath;
};

struct NativeExportPipelineResult {
    int32_t code = 0;
    std::string message;
    std::string outputPath;
};

static constexpr int32_t EXPORT_OK = 0;
static constexpr int32_t EXPORT_ERR_INVALID_ARG = 1001;
static constexpr int32_t EXPORT_ERR_FRONT_URIS_EMPTY = 1002;
static constexpr int32_t EXPORT_ERR_BACK_URIS_EMPTY = 1003;
static constexpr int32_t EXPORT_ERR_TEMPLATE_ID_INVALID = 1004;
static constexpr int32_t EXPORT_ERR_OUTPUT_PATH_EMPTY = 1005;
static constexpr int32_t EXPORT_ERR_EXPECTED_DURATION_INVALID = 1006;
static constexpr int32_t EXPORT_ERR_NATIVE_EMPTY = 2001;
static constexpr int32_t EXPORT_ERR_NATIVE_FAILED = 2002;
static constexpr int32_t EXPORT_ERR_ASYNC_WORK_FAILED = 2003;

static NativeExportPipelineResult makeErrorResult(int32_t code, const std::string &message)
{
    NativeExportPipelineResult result;
    result.code = code;
    result.message = message;
    return result;
}

static bool isAllowedTemplateId(const std::string &value)
{
    return isSupportedTemplateId(value);
}

static bool getNamedProperty(napi_env env, napi_value obj, const char *name, napi_value &out)
{
    bool hasProperty = false;
    if (napi_has_named_property(env, obj, name, &hasProperty) != napi_ok || !hasProperty) {
        return false;
    }
    return napi_get_named_property(env, obj, name, &out) == napi_ok;
}

static bool readStringArrayFromJs(napi_env env, napi_value value, std::vector<std::string> &output)
{
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return false;
    }
    uint32_t length = 0;
    if (napi_get_array_length(env, value, &length) != napi_ok) {
        return false;
    }
    output.clear();
    output.reserve(length);
    for (uint32_t i = 0; i < length; i++) {
        napi_value element = nullptr;
        if (napi_get_element(env, value, i, &element) != napi_ok) {
            return false;
        }
        napi_valuetype elementType = napi_undefined;
        if (napi_typeof(env, element, &elementType) != napi_ok || elementType != napi_string) {
            return false;
        }
        std::string item = readUtf8Arg(env, element);
        if (item.empty()) {
            return false;
        }
        output.push_back(item);
    }
    return true;
}

static bool parseExportPipelineRequest(napi_env env, napi_callback_info info, NativeExportPipelineRequest &request, NativeExportPipelineResult &error)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_INVALID_ARG");
        return false;
    }
    napi_valuetype argType = napi_undefined;
    if (napi_typeof(env, args[0], &argType) != napi_ok || argType != napi_object) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_INVALID_ARG");
        return false;
    }
    napi_value frontValue = nullptr;
    if (!getNamedProperty(env, args[0], "frontUris", frontValue) || !readStringArrayFromJs(env, frontValue, request.frontUris)) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_FRONT_URIS_INVALID");
        return false;
    }
    napi_value backValue = nullptr;
    if (!getNamedProperty(env, args[0], "backUris", backValue) || !readStringArrayFromJs(env, backValue, request.backUris)) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_BACK_URIS_INVALID");
        return false;
    }
    request.sideUris.clear();
    napi_value sideValue = nullptr;
    if (getNamedProperty(env, args[0], "sideUris", sideValue) && !readStringArrayFromJs(env, sideValue, request.sideUris)) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_SIDE_URIS_INVALID");
        return false;
    }
    napi_value templateValue = nullptr;
    if (!getNamedProperty(env, args[0], "templateId", templateValue)) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_TEMPLATE_ID_INVALID");
        return false;
    }
    request.templateId = readUtf8Arg(env, templateValue);
    napi_value durationValue = nullptr;
    if (!getNamedProperty(env, args[0], "expectedDurationSec", durationValue) ||
        napi_get_value_double(env, durationValue, &request.expectedDurationSec) != napi_ok ||
        std::isnan(request.expectedDurationSec) || std::isinf(request.expectedDurationSec) ||
        request.expectedDurationSec < 0.0) {
        error = makeErrorResult(EXPORT_ERR_EXPECTED_DURATION_INVALID, "ERR_EXPECTED_DURATION_INVALID");
        return false;
    }
    napi_value outputPathValue = nullptr;
    if (!getNamedProperty(env, args[0], "outputPath", outputPathValue)) {
        error = makeErrorResult(EXPORT_ERR_INVALID_ARG, "ERR_OUTPUT_PATH_INVALID");
        return false;
    }
    request.outputPath = readUtf8Arg(env, outputPathValue);
    if (request.frontUris.empty()) {
        error = makeErrorResult(EXPORT_ERR_FRONT_URIS_EMPTY, "ERR_FRONT_URIS_EMPTY");
        return false;
    }
    if (request.backUris.empty()) {
        error = makeErrorResult(EXPORT_ERR_BACK_URIS_EMPTY, "ERR_BACK_URIS_EMPTY");
        return false;
    }
    if (!isAllowedTemplateId(request.templateId)) {
        error = makeErrorResult(EXPORT_ERR_TEMPLATE_ID_INVALID, "ERR_TEMPLATE_ID_INVALID");
        return false;
    }
    if (request.outputPath.empty()) {
        error = makeErrorResult(EXPORT_ERR_OUTPUT_PATH_EMPTY, "ERR_OUTPUT_PATH_EMPTY");
        return false;
    }
    return true;
}

static NativeExportPipelineResult runPipelineAndWrapResult(const NativeExportPipelineRequest &request)
{
    std::string output = runExportEnginePipeline(
        request.frontUris,
        request.backUris,
        request.sideUris,
        request.templateId,
        request.expectedDurationSec,
        request.outputPath);
    if (output.empty()) {
        return makeErrorResult(EXPORT_ERR_NATIVE_EMPTY, "ERR_NATIVE_EMPTY");
    }
    if (output.rfind("__ERROR__", 0) == 0) {
        return makeErrorResult(EXPORT_ERR_NATIVE_FAILED, output);
    }
    NativeExportPipelineResult result;
    result.code = EXPORT_OK;
    result.outputPath = output;
    return result;
}

static napi_value createExportResultValue(napi_env env, const NativeExportPipelineResult &result)
{
    napi_value output = nullptr;
    napi_create_object(env, &output);
    napi_value code = nullptr;
    napi_create_int32(env, result.code, &code);
    napi_set_named_property(env, output, "code", code);
    napi_value message = nullptr;
    napi_create_string_utf8(env, result.message.c_str(), NAPI_AUTO_LENGTH, &message);
    napi_set_named_property(env, output, "message", message);
    napi_value outputPath = nullptr;
    napi_create_string_utf8(env, result.outputPath.c_str(), NAPI_AUTO_LENGTH, &outputPath);
    napi_set_named_property(env, output, "outputPath", outputPath);
    return output;
}

static napi_value RunExportPipeline(napi_env env, napi_callback_info info)
{
    NativeExportPipelineRequest request;
    NativeExportPipelineResult error;
    if (!parseExportPipelineRequest(env, info, request, error)) {
        return createExportResultValue(env, error);
    }
    NativeExportPipelineResult result = runPipelineAndWrapResult(request);
    return createExportResultValue(env, result);
}

struct ExportPipelineAsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    NativeExportPipelineRequest request;
    NativeExportPipelineResult result;
};

static void ExecuteRunExportPipelineAsync(napi_env env, void *data)
{
    (void)env;
    auto *ctx = static_cast<ExportPipelineAsyncContext *>(data);
    if (ctx == nullptr) {
        return;
    }
    ctx->result = runPipelineAndWrapResult(ctx->request);
}

static void CompleteRunExportPipelineAsync(napi_env env, napi_status status, void *data)
{
    auto *ctx = static_cast<ExportPipelineAsyncContext *>(data);
    if (ctx == nullptr) {
        return;
    }
    if (status != napi_ok) {
        ctx->result = makeErrorResult(EXPORT_ERR_ASYNC_WORK_FAILED, "ERR_ASYNC_WORK_FAILED");
    }
    napi_value resultValue = createExportResultValue(env, ctx->result);
    napi_resolve_deferred(env, ctx->deferred, resultValue);
    if (ctx->work != nullptr) {
        napi_delete_async_work(env, ctx->work);
    }
    delete ctx;
}

static napi_value RunExportPipelineAsync(napi_env env, napi_callback_info info)
{
    NativeExportPipelineRequest request;
    NativeExportPipelineResult error;
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    if (!parseExportPipelineRequest(env, info, request, error)) {
        napi_value resultValue = createExportResultValue(env, error);
        napi_resolve_deferred(env, deferred, resultValue);
        return promise;
    }
    auto *ctx = new ExportPipelineAsyncContext();
    ctx->env = env;
    ctx->deferred = deferred;
    ctx->request = request;
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "RunExportPipelineAsync", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env,
                               nullptr,
                               resourceName,
                               ExecuteRunExportPipelineAsync,
                               CompleteRunExportPipelineAsync,
                               ctx,
                               &ctx->work) != napi_ok) {
        NativeExportPipelineResult asyncError = makeErrorResult(EXPORT_ERR_ASYNC_WORK_FAILED, "ERR_ASYNC_WORK_FAILED");
        napi_value resultValue = createExportResultValue(env, asyncError);
        napi_resolve_deferred(env, deferred, resultValue);
        delete ctx;
        return promise;
    }
    if (napi_queue_async_work(env, ctx->work) != napi_ok) {
        NativeExportPipelineResult asyncError = makeErrorResult(EXPORT_ERR_ASYNC_WORK_FAILED, "ERR_ASYNC_WORK_FAILED");
        napi_value resultValue = createExportResultValue(env, asyncError);
        napi_resolve_deferred(env, deferred, resultValue);
        if (ctx->work != nullptr) {
            napi_delete_async_work(env, ctx->work);
        }
        delete ctx;
        return promise;
    }
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
    if (cameraRaw == "rear") {
        return "Back";
    }
    if (cameraRaw == "left") {
        return "Left";
    }
    if (cameraRaw == "left_rear") {
        return "Left";
    }
    if (cameraRaw == "right") {
        return "Right";
    }
    if (cameraRaw == "right_rear") {
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

static napi_value createIntArray(napi_env env, const std::vector<int64_t> &items)
{
    napi_value arr = nullptr;
    napi_create_array_with_length(env, items.size(), &arr);
    for (size_t i = 0; i < items.size(); i++) {
        napi_value v = nullptr;
        napi_create_int64(env, items[i], &v);
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
    const std::regex pattern("^(?:.+_)?DVR_LoopRecording_(\\d{4}-\\d{2}-\\d{2})_(\\d{2})-(\\d{2})-(\\d{2})_([a-z_]+)_camera\\.(mp4|mov|ts)$", std::regex::icase);
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
    std::vector<std::string> clips = splitBy(params[0], ',');
    std::vector<std::string> frontUris;
    std::vector<std::string> backUris;
    std::vector<int64_t> frontIndexes;
    for (size_t clipIndex = 0; clipIndex < clips.size(); clipIndex++) {
        const std::string &clip = clips[clipIndex];
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
            frontIndexes.push_back(static_cast<int64_t>(clipIndex));
        } else if (camera == "Back") {
            backUris.push_back(uri);
        }
    }
    napi_value output = nullptr;
    napi_create_object(env, &output);
    napi_value frontArr = createStringArray(env, frontUris);
    napi_value backArr = createStringArray(env, backUris);
    napi_value frontIndexArr = createIntArray(env, frontIndexes);
    napi_set_named_property(env, output, "frontUris", frontArr);
    napi_set_named_property(env, output, "backUris", backArr);
    napi_set_named_property(env, output, "frontIndexes", frontIndexArr);
    return output;
}

static napi_value GetCoreApiVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value output = nullptr;
    static const char *version = "core-api-v2";
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
