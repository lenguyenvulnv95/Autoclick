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

inline bool FindLevelBadgeBounds(const uint8_t* bgra,
                                 int width,
                                 int height,
                                 int stride,
                                 int x0,
                                 int y0,
                                 int cropWidth,
                                 int cropHeight,
                                 float barLeft,
                                 float barTop,
                                 float barWidth,
                                 float barHeight,
                                 LevelBadgeBounds* outBounds) {
    if (!bgra || !outBounds || cropWidth <= 0 || cropHeight <= 0) return false;

    const int x1 = std::min(width, x0 + cropWidth);
    const int y1 = std::min(height, y0 + cropHeight);
    const int localWidth = x1 - std::max(0, x0);
    const int localHeight = y1 - std::max(0, y0);
    const int localX0 = std::max(0, x0);
    const int localY0 = std::max(0, y0);
    if (localWidth <= 0 || localHeight <= 0) return false;

    std::vector<uint8_t> visited((size_t)localWidth * localHeight, 0);
    std::vector<int> queue;
    float bestScore = std::numeric_limits<float>::max();
    bool found = false;

    for (int sy = 0; sy < localHeight; ++sy) {
        for (int sx = 0; sx < localWidth; ++sx) {
            const size_t seed = (size_t)sy * localWidth + sx;
            if (visited[seed]) continue;
            const uint8_t* sp = bgra + (size_t)(localY0 + sy) * stride +
                                (size_t)(localX0 + sx) * 4;
            if (HealthBarDetector::ClassifyPixel(sp[0], sp[1], sp[2]) !=
                HealthBarDetector::PixelClass::TowerHpYellow) {
                visited[seed] = 1;
                continue;
            }

            int minX = sx, maxX = sx, minY = sy, maxY = sy;
            int pixelCount = 0;
            queue.clear();
            queue.push_back((int)seed);
            visited[seed] = 1;

            for (size_t qi = 0; qi < queue.size(); ++qi) {
                const int index = queue[qi];
                const int px = index % localWidth;
                const int py = index / localWidth;
                ++pixelCount;
                minX = std::min(minX, px); maxX = std::max(maxX, px);
                minY = std::min(minY, py); maxY = std::max(maxY, py);

                // Bridge tiny gaps in the decorative badge border while
                // keeping separate nearby badges as independent components.
                for (int dy = -2; dy <= 2; ++dy) {
                    for (int dx = -2; dx <= 2; ++dx) {
                        if (dx == 0 && dy == 0) continue;
                        const int nx = px + dx, ny = py + dy;
                        if (nx < 0 || ny < 0 || nx >= localWidth || ny >= localHeight) continue;
                        const size_t ni = (size_t)ny * localWidth + nx;
                        if (visited[ni]) continue;
                        const uint8_t* np = bgra + (size_t)(localY0 + ny) * stride +
                                            (size_t)(localX0 + nx) * 4;
                        visited[ni] = 1;
                        if (HealthBarDetector::ClassifyPixel(np[0], np[1], np[2]) ==
                            HealthBarDetector::PixelClass::TowerHpYellow) {
                            queue.push_back((int)ni);
                        }
                    }
                }
            }

            const int badgeWidth = maxX - minX + 1;
            const int badgeHeight = maxY - minY + 1;
            const float aspect = (float)badgeWidth / (float)std::max(1, badgeHeight);
            const float density = (float)pixelCount /
                                  (float)(badgeWidth * badgeHeight);
            if (pixelCount < 8 || badgeWidth < 10 || badgeHeight < 10 ||
                aspect < 0.45f || aspect > 1.80f || density < 0.03f) continue;

            const float badgeLeft = (float)(localX0 + minX);
            const float badgeTop = (float)(localY0 + minY);
            if (!TargetClassifier::IsLevelBadgeAdjacentToBar(
                    barLeft, barTop, barWidth, barHeight,
                    badgeLeft, badgeTop, (float)badgeWidth, (float)badgeHeight)) continue;

            const float horizontalGap = barLeft - (badgeLeft + badgeWidth);
            const float verticalDelta = std::fabs(
                (barTop + barHeight * 0.5f) - (badgeTop + badgeHeight * 0.5f));
            const float score = std::fabs(horizontalGap) + verticalDelta * 0.5f;
            if (score < bestScore) {
                bestScore = score;
                outBounds->left = (int)badgeLeft;
                outBounds->top = (int)badgeTop;
                outBounds->width = badgeWidth;
                outBounds->height = badgeHeight;
                found = true;
            }
        }
    }
    return found;
}


inline bool HasNearbyLevelBadgeShape(const uint8_t* bgra,
                                     int width,
                                     int height,
                                     int stride,
                                     int x0,
                                     int y0,
                                     int cropWidth,
                                     int cropHeight,
                                     float barLeft,
                                     float barTop,
                                     float barWidth,
                                     float barHeight,
                                     LevelBadgeBounds* outBounds) {
    if (!bgra || cropWidth <= 0 || cropHeight <= 0) return false;
    int minX = x0 + cropWidth, maxX = x0 - 1;
    int minY = y0 + cropHeight, maxY = y0 - 1;
    int yellowPixels = 0;
    const int x1 = std::min(width, x0 + cropWidth);
    const int y1 = std::min(height, y0 + cropHeight);
    for (int y = std::max(0, y0); y < y1; ++y) {
        const uint8_t* row = bgra + (size_t)y * stride;
        for (int x = std::max(0, x0); x < x1; ++x) {
            const uint8_t* p = row + (size_t)x * 4;
            if (HealthBarDetector::ClassifyPixel(p[0], p[1], p[2]) ==
                HealthBarDetector::PixelClass::TowerHpYellow) {
                ++yellowPixels;
                minX = std::min(minX, x); maxX = std::max(maxX, x);
                minY = std::min(minY, y); maxY = std::max(maxY, y);
            }
        }
    }
    if (yellowPixels < 10 || maxX < minX || maxY < minY) return false;
    const float badgeWidth = (float)(maxX - minX + 1);
    const float badgeHeight = (float)(maxY - minY + 1);
    const float aspect = badgeWidth / std::max(1.0f, badgeHeight);
    if (badgeWidth < 12.0f || badgeHeight < 12.0f ||
        aspect < 0.55f || aspect > 1.55f ||
        !TargetClassifier::IsLevelBadgeAdjacentToBar(
            barLeft, barTop, barWidth, barHeight,
            (float)minX, (float)minY, badgeWidth, badgeHeight)) {
        return false;
    }

    if (outBounds) {
        outBounds->left = minX;
        outBounds->top = minY;
        outBounds->width = (int)badgeWidth;
        outBounds->height = (int)badgeHeight;
    }
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
                                           float maxHpHeightPoints = 14.0f) {
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
    const int levelSearchWidth = std::max(24, (int)std::round(76.0f * scale));
    const int levelSearchTopPad = (int)std::round(12.0f * scale);
    const int levelSearchHeightPad = (int)std::round(20.0f * scale);

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
                        ? kind == HealthBarDetector::PixelClass::HeroHpRed
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

                const int searchX = std::max(0, minX - levelSearchWidth);
                const int searchY = std::max(0, bandTop - levelSearchTopPad);
                const int searchW = minX - searchX;
                const int searchH = std::min(height - searchY,
                    bandHeight + levelSearchTopPad + levelSearchHeightPad);

                LevelBadgeBounds badge;
                const bool badgeAdjacent =
                    FindLevelBadgeBounds(
                        bgra, width, height, stride,
                        searchX, searchY, searchW, searchH,
                        (float)minX, (float)bandTop, (float)baseWidth, (float)bandHeight,
                        &badge) ||
                    // Overlapping nameplates can fragment the yellow badge border.
                    // This bounded local-window fallback preserves detection when
                    // the badge is visually adjacent but its outline is fragmented.
                    HasNearbyLevelBadgeShape(
                        bgra, width, height, stride,
                        searchX, searchY, searchW, searchH,
                        (float)minX, (float)bandTop,
                        (float)baseWidth, (float)bandHeight, &badge);

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
