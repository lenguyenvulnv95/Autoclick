#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "HealthBarDetector.hpp"
#include "HPAnalyzer.hpp"
#include "LevelRecognizer.hpp"
#include "TargetClassifier.hpp"

namespace HealthBarSegmenter {

struct BarObservation {
    TargetClassifier::TargetKind kind = TargetClassifier::TargetKind::Unknown;
    int level = 0;
    float levelConfidence = 0.0f;
    float hpPercent = 0.0f;
    float hpConfidence = 0.0f;
    float confidence = 0.0f;
    float left = 0.0f;
    float top = 0.0f;
    float width = 0.0f;
    float height = 0.0f;
};

struct RowStats {
    int redCount = 0;
    int yellowCount = 0;
};

inline bool IsDarkTrackPixel(uint8_t b, uint8_t g, uint8_t r) {
    return std::max((int)r, std::max((int)g, (int)b)) < 88;
}

inline std::vector<BarObservation> Detect(const uint8_t* bgra,
                                          int width,
                                          int height,
                                          int stride,
                                          float scale,
                                          int roiX0 = 0,
                                          int roiY0 = 0,
                                          int roiX1 = -1,
                                          int roiY1 = -1) {
    std::vector<BarObservation> output;
    if (!bgra || width <= 0 || height <= 0 || stride < width * 4) return output;

    roiX0 = std::max(0, std::min(width, roiX0));
    roiY0 = std::max(0, std::min(height, roiY0));
    roiX1 = roiX1 < 0 ? width : std::max(0, std::min(width, roiX1));
    roiY1 = roiY1 < 0 ? height : std::max(0, std::min(height, roiY1));
    if (roiX1 <= roiX0 || roiY1 <= roiY0) return output;

    scale = std::max(0.5f, scale);
    const int minRowPixels = std::max(5, (int)std::round(6.0f * scale));
    const int minBandHeight = std::max(2, (int)std::round(3.0f * scale));
    const int maxBandHeight = std::max(minBandHeight, (int)std::round(20.0f * scale));
    const int levelSearchWidth = std::max(24, (int)std::round(76.0f * scale));
    const int levelSearchTopPad = (int)std::round(12.0f * scale);
    const int levelSearchHeightPad = (int)std::round(48.0f * scale);

    std::vector<RowStats> rows((size_t)roiY1);
    for (int y = roiY0; y < roiY1; ++y) {
        const uint8_t* row = bgra + (size_t)y * stride;
        RowStats stats;
        for (int x = roiX0; x < roiX1; ++x) {
            const uint8_t* p = row + (size_t)x * 4;
            const auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
            if (kind == HealthBarDetector::PixelClass::HeroHpRed) ++stats.redCount;
            else if (kind == HealthBarDetector::PixelClass::TowerHpYellow) ++stats.yellowCount;
        }
        rows[(size_t)y] = stats;
    }

    auto processColorBands = [&](bool redMode) {
        int y = roiY0;
        while (y < roiY1) {
            auto active = [&](int yy) {
                const RowStats& s = rows[(size_t)yy];
                return redMode ? s.redCount >= minRowPixels : s.yellowCount >= minRowPixels;
            };
            if (!active(y)) {
                ++y;
                continue;
            }

            const int bandTop = y;
            int bandBottom = y;
            int gap = 0;
            ++y;
            while (y < roiY1) {
                if (active(y)) {
                    bandBottom = y;
                    gap = 0;
                } else if (gap < 1) {
                    ++gap;
                } else {
                    break;
                }
                ++y;
            }

            const int bandHeight = bandBottom - bandTop + 1;
            if (bandHeight < minBandHeight || bandHeight > maxBandHeight) continue;

            int minX = roiX1, maxX = -1;
            int matchingPixels = 0;
            for (int yy = bandTop; yy <= bandBottom; ++yy) {
                const uint8_t* row = bgra + (size_t)yy * stride;
                for (int x = roiX0; x < roiX1; ++x) {
                    const uint8_t* p = row + (size_t)x * 4;
                    const auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
                    const bool match = redMode
                        ? kind == HealthBarDetector::PixelClass::HeroHpRed
                        : kind == HealthBarDetector::PixelClass::TowerHpYellow;
                    if (match) {
                        minX = std::min(minX, x);
                        maxX = std::max(maxX, x);
                        ++matchingPixels;
                    }
                }
            }

            if (maxX < minX) continue;
            const int fillWidth = maxX - minX + 1;
            if (fillWidth < std::max(8, (int)std::round(8.0f * scale))) continue;
            if ((float)fillWidth / (float)bandHeight < 2.0f) continue;

            const int sampleY = (bandTop + bandBottom) / 2;
            int darkTrackPixels = 0;
            bool shieldBoundary = false;
            const int maxTrackSearch = std::max(
                (int)std::round(fillWidth * 2.5f),
                (int)std::round(120.0f * scale));
            const int searchEnd = std::min(roiX1, maxX + 1 + maxTrackSearch);

            for (int x = maxX + 1; x < searchEnd; ++x) {
                const uint8_t* p = bgra + (size_t)sampleY * stride + (size_t)x * 4;
                const auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
                if (kind == HealthBarDetector::PixelClass::ShieldPurple ||
                    kind == HealthBarDetector::PixelClass::ShieldGray) {
                    shieldBoundary = true;
                    break;
                }
                const bool sameFill = redMode
                    ? kind == HealthBarDetector::PixelClass::HeroHpRed
                    : kind == HealthBarDetector::PixelClass::TowerHpYellow;
                if (sameFill || IsDarkTrackPixel(p[0], p[1], p[2])) {
                    ++darkTrackPixels;
                    continue;
                }
                break;
            }

            const int borderAllowance = shieldBoundary ? 0 : (int)std::round(2.0f * scale);
            const int baseWidth = std::max(fillWidth, fillWidth + darkTrackPixels - borderAllowance);
            if (baseWidth < fillWidth) continue;

            std::vector<HealthBarDetector::PixelClass> trackPixels(
                (size_t)baseWidth * (size_t)bandHeight,
                HealthBarDetector::PixelClass::Other);
            int yellowColumns = 0;
            for (int x = 0; x < baseWidth; ++x) {
                int redVotes = 0;
                int yellowVotes = 0;
                for (int yy = 0; yy < bandHeight; ++yy) {
                    const uint8_t* p = bgra + (size_t)(bandTop + yy) * stride +
                                       (size_t)(minX + x) * 4;
                    const auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
                    trackPixels[(size_t)yy * baseWidth + x] = kind;
                    if (kind == HealthBarDetector::PixelClass::HeroHpRed) ++redVotes;
                    if (kind == HealthBarDetector::PixelClass::TowerHpYellow) ++yellowVotes;
                }
                if (yellowVotes >= std::max(1, bandHeight / 2)) ++yellowColumns;
            }

            const int minVotes = std::max(1, bandHeight / 2);
            const int colorColumns = redMode
                ? HPAnalyzer::CountRedFillColumns(trackPixels.data(), baseWidth, bandHeight, minVotes)
                : yellowColumns;
            const float colorCoverage = (float)colorColumns / (float)baseWidth;

            BarObservation observation;
            observation.left = (float)minX / scale;
            observation.top = (float)bandTop / scale;
            observation.width = (float)baseWidth / scale;
            observation.height = (float)bandHeight / scale;

            if (redMode) {
                const HPAnalyzer::HPReading hp = HPAnalyzer::Analyze(
                    trackPixels.data(), baseWidth, bandHeight,
                    (float)baseWidth, minVotes);
                observation.hpPercent = hp.percent;
                observation.hpConfidence = hp.confidence;

                const int cropX = std::max(0, minX - levelSearchWidth);
                const int cropY = std::max(0, bandTop - levelSearchTopPad);
                const int cropW = minX - cropX;
                const int cropH = std::min(height - cropY,
                    bandHeight + levelSearchTopPad + levelSearchHeightPad);

                int level = 0;
                float levelConfidence = 0.0f;
                const bool levelFound = cropW >= 16 &&
                    LevelRecognizer::RecognizeLevelFromBGRA(
                        bgra, width, height, stride,
                        (float)cropX, (float)cropY, (float)cropW, (float)cropH,
                        &level, &levelConfidence);

                TargetClassifier::CandidateFeatures features;
                features.width = (float)baseWidth;
                features.height = (float)bandHeight;
                features.redCoverage = colorCoverage;
                features.level = level;
                features.levelConfidence = levelConfidence;
                features.levelBadgePresent = levelFound;

                const auto classification = TargetClassifier::Classify(features);
                observation.kind = classification.kind;
                observation.level = level;
                observation.levelConfidence = levelConfidence;
                observation.confidence = std::min(classification.confidence, hp.confidence);
                if (observation.kind == TargetClassifier::TargetKind::EnemyHero) {
                    output.push_back(observation);
                }
            } else {
                TargetClassifier::CandidateFeatures features;
                features.width = (float)baseWidth;
                features.height = (float)bandHeight;
                features.yellowCoverage = colorCoverage;
                const auto classification = TargetClassifier::Classify(features);
                observation.kind = classification.kind;
                observation.confidence = classification.confidence;
                if (observation.kind == TargetClassifier::TargetKind::EnemyTower) {
                    output.push_back(observation);
                }
            }
        }
    };

    processColorBands(true);
    processColorBands(false);
    return output;
}

} // namespace HealthBarSegmenter
