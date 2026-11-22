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
    float redCoverage = 0.0f;      // Fraction of base-bar pixels classified red.
    float yellowCoverage = 0.0f;   // Fraction of base-bar pixels classified yellow.
    int level = 0;
    float levelConfidence = 0.0f;
    bool levelBadgePresent = false;
};

struct Classification {
    TargetKind kind = TargetKind::Unknown;
    float confidence = 0.0f;
};

inline float Clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

// Level + badge geometry is the strongest hero cue. Color is supporting
// evidence rather than a hard gate, allowing shader/lighting shifts.
// Yellow bars without a reliable hero badge are classified as towers.
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

    // Red-only candidates are deliberately left unconfirmed until Level OCR
    // or other structural evidence is available.
    return {TargetKind::Unknown, 0.0f};
}

} // namespace TargetClassifier
