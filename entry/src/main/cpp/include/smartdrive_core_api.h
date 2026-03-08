#ifndef SMARTDRIVE_CORE_API_H
#define SMARTDRIVE_CORE_API_H

#ifdef __cplusplus
extern "C" {
#endif

const char *smartdrive_parse_dvr_file_name(const char *name, const char *uri);
const char *smartdrive_build_timeline(const char *cameras_csv);
const char *smartdrive_merge_timeline(const char *timeline_csv);
const char *smartdrive_build_compose_request(const char *clips_csv, const char *file_name, const char *output_path,
                                             const char *flags_csv);
const char *smartdrive_get_core_api_version();

#ifdef __cplusplus
}
#endif

#endif
