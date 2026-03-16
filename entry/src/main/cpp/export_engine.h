#ifndef SMARTDRIVE_EXPORT_ENGINE_H
#define SMARTDRIVE_EXPORT_ENGINE_H

#include <string>
#include <vector>

std::string runExportEnginePipeline(const std::vector<std::string> &frontUris,
                                    const std::vector<std::string> &backUris,
                                    const std::vector<std::string> &sideUris,
                                    const std::string &templateId,
                                    double expectedDurationSec,
                                    const std::string &outputPath);

#endif
