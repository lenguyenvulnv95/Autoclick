#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <vector>

namespace TargetSelector {

struct Candidate {
    int id = -1;
    float hpPercent = 100.0f;
    float confidence = 0.0f;
    float centerDistance = std::numeric_limits<float>::max();
    int level = 0;
    int consecutiveFrames = 0;
    int missingFrames = 0;
    bool isEnemyHero = false;
};

// Select the confirmed enemy hero with the lowest estimated base HP.
// A previous lock is retained only when it is within the small hysteresis
// window of the current minimum, preventing rapid swaps on near-equal HP.
inline int SelectLowestHP(const std::vector<Candidate>& candidates,
                          int minConfirmFrames,
                          float minConfidence,
                          int preferredId = -1,
                          float hysteresisPercent = 1.0f) {
    int bestIndex = -1;
    float lowestHP = std::numeric_limits<float>::max();

    for (size_t i = 0; i < candidates.size(); ++i) {
        const Candidate& c = candidates[i];
        if (!c.isEnemyHero || c.id < 0 || c.level < 1 || c.level > 16 ||
            c.consecutiveFrames < minConfirmFrames || c.missingFrames != 0 ||
            c.confidence < minConfidence || !std::isfinite(c.hpPercent) ||
            c.hpPercent < 0.0f || c.hpPercent > 100.0f) {
            continue;
        }

        if (c.hpPercent < lowestHP ||
            (std::fabs(c.hpPercent - lowestHP) < 0.001f &&
             bestIndex >= 0 &&
             c.centerDistance < candidates[(size_t)bestIndex].centerDistance)) {
            lowestHP = c.hpPercent;
            bestIndex = (int)i;
        }
    }

    if (bestIndex < 0) return -1;

    if (preferredId >= 0 && hysteresisPercent > 0.0f) {
        for (size_t i = 0; i < candidates.size(); ++i) {
            const Candidate& c = candidates[i];
            if (c.id == preferredId && c.isEnemyHero && c.level >= 1 &&
                c.level <= 16 && c.consecutiveFrames >= minConfirmFrames &&
                c.missingFrames == 0 && c.confidence >= minConfidence &&
                std::isfinite(c.hpPercent) && c.hpPercent >= 0.0f &&
                c.hpPercent <= 100.0f &&
                c.hpPercent <= lowestHP + hysteresisPercent) {
                return (int)i;
            }
        }
    }

    return bestIndex;
}

} // namespace TargetSelector
