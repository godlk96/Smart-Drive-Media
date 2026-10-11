#ifndef SMARTDRIVE_EXPORT_ENGINE_H
#define SMARTDRIVE_EXPORT_ENGINE_H

#include <string>
#include <vector>

bool isSupportedTemplateId(const std::string &templateId);
std::string normalizeTemplateId(const std::string &templateId);

std::string runExportEnginePipeline(const std::vector<std::string> &frontUris,
                                    const std::vector<std::string> &backUris,
                                    const std::vector<std::string> &sideUris,
                                    const std::string &templateId,
                                    double expectedDurationSec,
                                    bool hideSpeed,
                                    bool hideVin,
                                    bool hideTime,
                                    const std::string &outputPath);

#endif
