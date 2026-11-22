#include "HPAnalyzer.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

using HealthBarDetector::PixelClass;

static void ExpectNear(float actual, float expected) {
    assert(std::fabs(actual - expected) < 0.01f);
}

int main() {
    {
        std::vector<PixelClass> pixels(100 * 4, PixelClass::Other);
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 100; ++x)
                pixels[y * 100 + x] = PixelClass::HeroHpRed;
        auto hp = HPAnalyzer::Analyze(pixels.data(), 100, 4, 100.0f, 2);
        assert(hp.valid);
        ExpectNear(hp.percent, 100.0f);
    }
    {
        std::vector<PixelClass> pixels(100 * 4, PixelClass::Other);
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 50; ++x)
                pixels[y * 100 + x] = PixelClass::HeroHpRed;
        auto hp = HPAnalyzer::Analyze(pixels.data(), 100, 4, 100.0f, 2);
        ExpectNear(hp.percent, 50.0f);
    }
    {
        std::vector<PixelClass> pixels(100 * 4, PixelClass::Other);
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 25; ++x)
                pixels[y * 100 + x] = PixelClass::HeroHpRed;
        auto hp = HPAnalyzer::Analyze(pixels.data(), 100, 4, 100.0f, 2);
        ExpectNear(hp.percent, 25.0f);
    }
    {
        std::vector<PixelClass> pixels(100 * 4, PixelClass::Other);
        for (int y = 0; y < 4; ++y) {
            for (int x = 0; x < 50; ++x) pixels[y * 100 + x] = PixelClass::HeroHpRed;
            for (int x = 50; x < 80; ++x) pixels[y * 100 + x] = PixelClass::ShieldPurple;
        }
        auto hp = HPAnalyzer::Analyze(pixels.data(), 100, 4, 100.0f, 2);
        ExpectNear(hp.percent, 50.0f); // Shield must not inflate base HP.
    }
    {
        std::vector<PixelClass> pixels(20 * 4, PixelClass::Other);
        for (int x = 0; x < 20; ++x) pixels[x] = PixelClass::HeroHpRed; // one-row noise
        auto hp = HPAnalyzer::Analyze(pixels.data(), 20, 4, 20.0f, 2);
        assert(hp.redFillColumns == 0);
        ExpectNear(hp.percent, 0.0f);
    }
    {
        std::vector<PixelClass> pixels(10 * 2, PixelClass::HeroHpRed);
        auto hp = HPAnalyzer::Analyze(pixels.data(), 10, 2, 5.0f, 1);
        ExpectNear(hp.percent, 100.0f); // Clamp oversized measurement.
    }

    std::cout << "HPAnalyzer tests: PASS (6 scenarios)\\n";
    return 0;
}
