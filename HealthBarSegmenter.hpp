#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
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
    bool levelOCRAttempted = false;
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
    return std::max((int)r, std::max((int)g, (int)b)) < 48;
}

struct LevelBadgeBounds {
    int left = 0;
    int top = 0;
    int width = 0;
    int height = 0;
};

// Locate the level glyph relative to the HP fill. XP ring color varies.
inline bool FindLevelDigits(const uint8_t* bgra, int width, int height, int stride,
                            int left, int top, int barHeight, LevelBadgeBounds* bounds) {
    const float h = (float)barHeight;
    const float cx = left - 2.1f * h;
    const float cy = top + 0.65f * h;
    const int x0 = std::max(0, (int)std::floor(cx - 1.2f * h));
    const int x1 = std::min(width, (int)std::ceil(cx + 1.2f * h));
    const int y0 = std::max(0, (int)std::floor(cy - h));
    const int y1 = std::min(height, (int)std::ceil(cy + h));
    int xmin = x1, xmax = -1, ymin = y1, ymax = -1, dark = 0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const auto* pixel = bgra + (size_t)y * stride + (size_t)x * 4;
            const int lo = std::min({pixel[0], pixel[1], pixel[2]});
            const int hi = std::max({pixel[0], pixel[1], pixel[2]});
            if (hi < 115) ++dark;
            if (lo < 145 || hi - lo > 55) continue;
            xmin = std::min(xmin, x); xmax = std::max(xmax, x);
            ymin = std::min(ymin, y); ymax = std::max(ymax, y);
        }
    }
    if (xmax < xmin || ymax - ymin + 1 < 0.55f * h ||
        dark < (x1 - x0) * (y1 - y0) * 0.45f) return false;
    *bounds = {xmin, ymin, xmax - xmin + 1, ymax - ymin + 1};
    return true;
}

inline std::vector<BarObservation> Detect(const uint8_t* bgra,
                                          int width,
                                          int height,
                                          int stride,
                                          float scale,
                                          int roiX0 = 0,
                                          int roiY0 = 0,
                                          int roiX1 = -1,
                                          int roiY1 = -1,
                                          bool performLevelOCR = true,
                                           float standardHpWidthPoints = 68.0f,
                                           float minHpHeightPoints = 4.0f,
                                           float maxHpHeightPoints = 14.0f,
                                           const HealthBarDetector::EnemyHpCalibration& hpCalibration = {}) {
    std::vector<BarObservation> output;
    if (!bgra || width <= 0 || height <= 0 || stride < width * 4) return output;

    roiX0 = std::max(0, std::min(width, roiX0));
    roiY0 = std::max(0, std::min(height, roiY0));
    roiX1 = roiX1 < 0 ? width : std::max(0, std::min(width, roiX1));
    roiY1 = roiY1 < 0 ? height : std::max(0, std::min(height, roiY1));
    if (roiX1 <= roiX0 || roiY1 <= roiY0) return output;

    scale = std::max(0.5f, scale);
    const int minRowPixels = std::max(5, (int)std::round(6.0f * scale));
    const int minBandHeight = std::max(
        2, (int)std::round(std::max(1.0f, minHpHeightPoints) * scale));
    const int maxBandHeight = std::max(
        minBandHeight,
        (int)std::round(std::max(minHpHeightPoints, maxHpHeightPoints) * scale));

    std::vector<RowStats> rows((size_t)roiY1);
    for (int y = roiY0; y < roiY1; ++y) {
        const uint8_t* row = bgra + (size_t)y * stride;
        RowStats stats;
        for (int x = roiX0; x < roiX1; ++x) {
            const uint8_t* p = row + (size_t)x * 4;
            const auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
            if (HealthBarDetector::IsEnemyHeroRedPixel(p[0], p[1], p[2], hpCalibration)) ++stats.redCount;
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
            // Exclude status/item graphics attached to the very top edge of
            // cropped reference frames; the live main-game ROI starts below HUD.
            if (bandTop < (int)std::round(12.0f * scale)) continue;
            if (bandHeight < minBandHeight || bandHeight > maxBandHeight) continue;

            std::vector<int> columnVotes((size_t)roiX1, 0);
            for (int yy = bandTop; yy <= bandBottom; ++yy) {
                const uint8_t* row = bgra + (size_t)yy * stride;
                for (int x = roiX0; x < roiX1; ++x) {
                    const uint8_t* p = row + (size_t)x * 4;
                    const auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
                    const bool match = redMode
                        ? HealthBarDetector::IsEnemyHeroRedPixel(p[0], p[1], p[2], hpCalibration)
                        : kind == HealthBarDetector::PixelClass::TowerHpYellow;
                    if (match) ++columnVotes[(size_t)x];
                }
            }
            // Anti-aliased red HP fills may not classify on half of every
            // row. Keep tower-yellow detection at the stricter half-row rule.
            const int columnVoteThreshold = redMode
                ? std::max(1, (bandHeight + 2) / 3)
                : std::max(1, bandHeight / 2);
            std::vector<std::pair<int, int>> horizontalRuns;
            int runStart = -1;
            int runGap = 0;
            for (int x = roiX0; x < roiX1; ++x) {
                const bool activeColumn = columnVotes[(size_t)x] >= columnVoteThreshold;
                if (activeColumn) {
                    if (runStart < 0) runStart = x;
                    runGap = 0;
                } else if (runStart >= 0 && runGap < 2) {
                    ++runGap;
                } else if (runStart >= 0) {
                    const int runEnd = x - runGap - 1;
                    if (runEnd >= runStart) horizontalRuns.push_back({runStart, runEnd});
                    runStart = -1;
                    runGap = 0;
                }
            }
            if (runStart >= 0) horizontalRuns.push_back({runStart, roiX1 - 1});
            if (horizontalRuns.empty()) continue;

            for (const auto& run : horizontalRuns) {
            int minX = run.first;
            int maxX = run.second;
            const int fillWidth = maxX - minX + 1;
            if (fillWidth < std::max(8, (int)std::round(8.0f * scale))) continue;
            if ((float)fillWidth / (float)bandHeight < 1.2f) continue;

            const int sampleY = (bandTop + bandBottom) / 2;
            int darkTrackPixels = 0;
            bool shieldBoundary = false;
            // Bound the dark-track scan to a plausible health-bar width.
            // Without this limit, a dark game background contiguous with the
            // unfilled bar can be mistaken for HP track and drive HP% too low.
            const float configuredWidth = std::max(40.0f, standardHpWidthPoints);
            const int maxPlausibleBarWidth =
                std::max(fillWidth, (int)std::round(configuredWidth * 1.5f * scale));
            const int maxTrackSearch = std::max(0, maxPlausibleBarWidth - fillWidth);
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
                    ? HealthBarDetector::IsEnemyHeroRedPixel(p[0], p[1], p[2], hpCalibration)
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
                    auto kind = HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]);
                    if (redMode && HealthBarDetector::IsEnemyHeroRedPixel(
                            p[0], p[1], p[2], hpCalibration)) {
                        kind = HealthBarDetector::PixelClass::HeroHpRed;
                    }
                    trackPixels[(size_t)yy * baseWidth + x] = kind;
                    if (kind == HealthBarDetector::PixelClass::HeroHpRed) ++redVotes;
                    if (kind == HealthBarDetector::PixelClass::TowerHpYellow) ++yellowVotes;
                }
                if (yellowVotes >= std::max(1, bandHeight / 2)) ++yellowColumns;
            }

            const int minVotes = std::max(1, (bandHeight + 2) / 3);
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

                LevelBadgeBounds badge;
                const bool badgeAdjacent = FindLevelDigits(bgra, width, height, stride,
                    minX, bandTop, bandHeight, &badge);

                int level = 0;
                float levelConfidence = 0.0f;
                const int cropPadding = 8;
                const int cropX = badgeAdjacent ? std::max(0, badge.left - cropPadding) : 0;
                const int cropY = badgeAdjacent ? std::max(0, badge.top - cropPadding) : 0;
                const int cropW = badgeAdjacent
                    ? std::min(width - cropX, badge.width + cropPadding * 2) : 0;
                const int cropH = badgeAdjacent
                    ? std::min(height - cropY, badge.height + cropPadding * 2) : 0;
                const bool canReadBadge = badgeAdjacent && performLevelOCR &&
                    cropW >= 12 && cropH >= 12;
                observation.levelOCRAttempted = canReadBadge;
                const bool levelFound = canReadBadge &&
                    LevelRecognizer::RecognizeLevelFromBGRA(
                        bgra, width, height, stride,
                        (float)cropX, (float)cropY, (float)cropW, (float)cropH,
                        &level, &levelConfidence);

                // Deliberately do not OCR the entire neighboring search window:
                // it can include another hero's level badge and transfer that
                // level to this HP bar. Only the geometrically matched badge crop
                // is authoritative for this candidate.

                TargetClassifier::CandidateFeatures features;
                features.width = (float)baseWidth;
                features.height = (float)bandHeight;
                features.redCoverage = colorCoverage;
                features.level = level;
                features.levelConfidence = levelConfidence;
                // Both visual components must be present and geometrically adjacent.
                // OCR can be sampled less often, but a detached badge never confirms a hero.
                features.levelBadgePresent = badgeAdjacent;

                const auto classification = TargetClassifier::Classify(features);
                observation.kind = classification.kind;
                observation.level = level;
                observation.levelConfidence = levelConfidence;
                observation.confidence = std::min(classification.confidence, hp.confidence);
                // Keep unknown red candidates in the diagnostic output so the
                // reference-image tests can reveal OCR misses; callers must filter
                // by kind before adding anything to the live target tracker.
                output.push_back(observation);
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
            } // each independent horizontal color run
        }
    };

    processColorBands(true);
    processColorBands(false);
    return output;
}

} // namespace HealthBarSegmenter
