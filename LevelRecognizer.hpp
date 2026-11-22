#pragma once

#include <cctype>
#include <cstdint>
#include <string>

namespace LevelRecognizer {

// Parse one numeric token from OCR text. Accepted range is hero levels 1..16.
// Prefixes such as "Lv." are allowed; multiple numeric groups are rejected.
inline bool ParseLevelText(const std::string& text, int* outLevel) {
    if (!outLevel) return false;
    int groups = 0;
    int value = 0;
    bool inDigits = false;

    for (unsigned char ch : text) {
        if (std::isdigit(ch)) {
            if (!inDigits) {
                ++groups;
                value = 0;
            }
            inDigits = true;
            value = value * 10 + (ch - '0');
            if (value > 99) return false;
        } else {
            inDigits = false;
        }
    }

    if (groups != 1 || value < 1 || value > 16) return false;
    *outLevel = value;
    return true;
}

// Reads a small, caller-supplied crop around the level badge using Apple Vision.
// The crop must exclude most of the red HP fill and contain the level numeral.
bool RecognizeLevelFromBGRA(const uint8_t* bgra,
                            int imageWidth,
                            int imageHeight,
                            int bytesPerRow,
                            float cropX,
                            float cropY,
                            float cropWidth,
                            float cropHeight,
                            int* outLevel,
                            float* outConfidence);

} // namespace LevelRecognizer
