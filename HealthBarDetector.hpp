#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace HealthBarDetector {

enum class PixelClass : uint8_t {
    Other = 0,
    HeroHpRed,
    TowerHpYellow,
    ShieldPurple,
    ShieldGray
};

struct HSV {
    float h; // degrees [0, 360)
    float s; // [0, 1]
    float v; // [0, 1]
};

inline HSV ToHSV(uint8_t b8, uint8_t g8, uint8_t r8) {
    const float r = r8 / 255.0f;
    const float g = g8 / 255.0f;
    const float b = b8 / 255.0f;
    const float hi = std::max(r, std::max(g, b));
    const float lo = std::min(r, std::min(g, b));
    const float d = hi - lo;

    float h = 0.0f;
    if (d > 0.0001f) {
        if (hi == r) {
            h = 60.0f * std::fmod((g - b) / d, 6.0f);
        } else if (hi == g) {
            h = 60.0f * (((b - r) / d) + 2.0f);
        } else {
            h = 60.0f * (((r - g) / d) + 4.0f);
        }
        if (h < 0.0f) h += 360.0f;
    }
    return {h, hi <= 0.0001f ? 0.0f : d / hi, hi};
}

// Broad hue windows deliberately tolerate moderate lighting and shader shifts.
// Geometry and Level recognition must still validate a candidate before it is
// accepted as an enemy hero.
inline PixelClass ClassifyPixel(uint8_t b, uint8_t g, uint8_t r) {
    const HSV hsv = ToHSV(b, g, r);
    if (hsv.s < 0.28f || hsv.v < 0.16f) return PixelClass::Other;

    const bool redHue = (hsv.h <= 25.0f || hsv.h >= 335.0f);
    if (redHue && r >= g * 1.12f && r >= b * 1.18f) {
        return PixelClass::HeroHpRed;
    }

    const bool yellowHue = (hsv.h >= 35.0f && hsv.h <= 72.0f);
    if (yellowHue && r >= b * 1.35f && g >= b * 1.25f) {
        return PixelClass::TowerHpYellow;
    }

    // Shield colors are identified only to exclude them from base-HP math.
    if (hsv.h >= 245.0f && hsv.h <= 305.0f && hsv.s >= 0.20f) {
        return PixelClass::ShieldPurple;
    }
    if (hsv.s < 0.22f && hsv.v >= 0.24f) {
        return PixelClass::ShieldGray;
    }
    return PixelClass::Other;
}

inline bool IsEnemyHeroRedPixel(uint8_t b, uint8_t g, uint8_t r) {
    return ClassifyPixel(b, g, r) == PixelClass::HeroHpRed;
}

inline bool IsTowerYellowPixel(uint8_t b, uint8_t g, uint8_t r) {
    return ClassifyPixel(b, g, r) == PixelClass::TowerHpYellow;
}

inline bool IsValidHeroLevel(int level) {
    return level >= 1 && level <= 16;
}

inline bool IsPlausibleBarShape(float width, float height,
                                float minWidth, float minHeight,
                                float maxHeight) {
    if (width < minWidth || height < minHeight || height > maxHeight) return false;
    const float aspect = width / std::max(1.0f, height);
    return aspect >= 4.0f;
}

inline float EstimateBaseHpPercent(float redFillWidth, float baseHpWidth) {
    if (baseHpWidth <= 0.0f || redFillWidth <= 0.0f) return 0.0f;
    const float ratio = (redFillWidth / baseHpWidth) * 100.0f;
    return std::max(0.0f, std::min(100.0f, ratio));
}

} // namespace HealthBarDetector
