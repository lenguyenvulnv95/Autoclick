#pragma once

#include <algorithm>
#include <cstdint>
#include <vector>

#include "HealthBarDetector.hpp"

namespace HPAnalyzer {

struct HPReading {
    float percent = 0.0f;
    int redFillColumns = 0;
    float confidence = 0.0f;
    bool valid = false;
};

// A column counts as HP only when enough pixels in the sampled vertical band
// are classified as base red. Purple/gray shield pixels never contribute.
inline int CountRedFillColumns(const HealthBarDetector::PixelClass* pixels,
                               int width,
                               int height,
                               int minimumRedRows = 1) {
    if (!pixels || width <= 0 || height <= 0) return 0;
    minimumRedRows = std::max(1, std::min(height, minimumRedRows));

    int columns = 0;
    for (int x = 0; x < width; ++x) {
        int redRows = 0;
        for (int y = 0; y < height; ++y) {
            if (pixels[y * width + x] == HealthBarDetector::PixelClass::HeroHpRed) {
                ++redRows;
            }
        }
        if (redRows >= minimumRedRows) ++columns;
    }
    return columns;
}

inline HPReading Analyze(const HealthBarDetector::PixelClass* pixels,
                         int width,
                         int height,
                         float baseHpWidth,
                         int minimumRedRows = 1) {
    HPReading result;
    if (!pixels || width <= 0 || height <= 0 || baseHpWidth <= 0.0f) return result;

    result.redFillColumns = CountRedFillColumns(pixels, width, height, minimumRedRows);
    result.percent = HealthBarDetector::EstimateBaseHpPercent(
        (float)result.redFillColumns, baseHpWidth);

    const float rowSupport = (float)std::max(1, std::min(height, minimumRedRows)) /
                             (float)height;
    const float coverage = (float)result.redFillColumns / (float)width;
    result.confidence = std::max(0.0f, std::min(1.0f,
        0.55f + 0.35f * rowSupport + 0.10f * coverage));
    result.valid = true;
    return result;
}

} // namespace HPAnalyzer
