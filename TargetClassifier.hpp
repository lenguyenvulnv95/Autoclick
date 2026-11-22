#pragma once

#include <algorithm>
#include "HealthBarDetector.hpp"

namespace TargetClassifier {

enum class TargetKind {
    Unknown = 0,
    EnemyHero,
    EnemyTower
};

struct CandidateFeatures {
    float width = 0.0f;
    float height = 0.0f;
    float redCoverage = 0.0f;
    float yellowCoverage = 0.0f;
    int level = 0;
    float levelConfidence = 0.0f;
    bool levelBadgePresent = false;
};

struct Classification {
    TargetKind kind = TargetKind::Unknown;
    float confidence = 0.0f;
};

// The level badge must be physically adjacent to the candidate HP bar.
// Coordinates are expressed in the same image-space units.
inline bool IsLevelBadgeAdjacentToBar(float barLeft, float barTop,
                                      float barWidth, float barHeight,
                                      float badgeLeft, float badgeTop,
                                      float badgeWidth, float badgeHeight) {
    if (barWidth <= 0.0f || barHeight <= 0.0f ||
        badgeWidth <= 0.0f || badgeHeight <= 0.0f) return false;

    const float badgeAspect = badgeWidth / std::max(1.0f, badgeHeight);
    if (badgeAspect < 0.55f || badgeAspect > 1.55f) return false;

    // The level box is expected immediately to the left of the HP bar.
    const float horizontalGap = barLeft - (badgeLeft + badgeWidth);
    const float maxGap = std::max(14.0f, barHeight * 2.5f);
    const float maxOverlap = std::max(4.0f, barHeight * 0.75f);
    if (horizontalGap < -maxOverlap || horizontalGap > maxGap) return false;

    const float barCenterY = barTop + barHeight * 0.5f;
    const float badgeCenterY = badgeTop + badgeHeight * 0.5f;
    const float verticalTolerance = std::max(barHeight * 3.5f, badgeHeight * 1.5f);
    return std::fabs(barCenterY - badgeCenterY) <= verticalTolerance;
}

inline float Clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

// A valid adjacent level badge is mandatory for hero confirmation.
// OCR confidence strengthens the classification; badge geometry still
// permits provisional tracking on frames where OCR is intentionally skipped.
inline Classification Classify(const CandidateFeatures& f) {
    if (f.width <= 0.0f || f.height <= 0.0f ||
        (f.width / f.height) < 4.0f) {
        return {TargetKind::Unknown, 0.0f};
    }

    const bool reliableLevel =
        f.levelBadgePresent &&
        HealthBarDetector::IsValidHeroLevel(f.level) &&
        f.levelConfidence >= 0.55f;

    if (reliableLevel) {
        const float colorSupport = Clamp01(f.redCoverage / 0.30f);
        const float confidence = Clamp01(0.62f +
            0.28f * f.levelConfidence + 0.10f * colorSupport);
        return {TargetKind::EnemyHero, confidence};
    }

    if (f.yellowCoverage >= 0.22f) {
        const float confidence = Clamp01(0.55f + 0.40f * f.yellowCoverage);
        return {TargetKind::EnemyTower, confidence};
    }

    if (f.levelBadgePresent && f.redCoverage >= 0.10f &&
        f.yellowCoverage < 0.10f) {
        const float confidence = Clamp01(0.50f +
            0.18f * Clamp01(f.redCoverage / 0.35f));
        return {TargetKind::EnemyHero, confidence};
    }

    return {TargetKind::Unknown, 0.0f};
}

} // namespace TargetClassifier
