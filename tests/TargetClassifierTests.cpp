#include "TargetClassifier.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

using TargetClassifier::CandidateFeatures;
using TargetClassifier::TargetKind;

int main() {
    CandidateFeatures hero;
    hero.width = 120.0f;
    hero.height = 12.0f;
    hero.redCoverage = 0.38f;
    hero.level = 12;
    hero.levelConfidence = 0.91f;
    hero.levelBadgePresent = true;
    auto result = TargetClassifier::Classify(hero);
    assert(result.kind == TargetKind::EnemyHero);
    assert(result.confidence >= 0.80f);

    CandidateFeatures heroUnderColorShift = hero;
    heroUnderColorShift.redCoverage = 0.03f;
    result = TargetClassifier::Classify(heroUnderColorShift);
    assert(result.kind == TargetKind::EnemyHero);

    CandidateFeatures tower;
    tower.width = 140.0f;
    tower.height = 13.0f;
    tower.yellowCoverage = 0.65f;
    result = TargetClassifier::Classify(tower);
    assert(result.kind == TargetKind::EnemyTower);

    CandidateFeatures redWithoutLevel = hero;
    redWithoutLevel.levelBadgePresent = false;
    result = TargetClassifier::Classify(redWithoutLevel);
    assert(result.kind == TargetKind::Unknown);

    CandidateFeatures invalidLevel = hero;
    invalidLevel.level = 17;
    result = TargetClassifier::Classify(invalidLevel);
    assert(result.kind == TargetKind::Unknown);

    CandidateFeatures weakOCR = hero;
    weakOCR.levelConfidence = 0.40f;
    result = TargetClassifier::Classify(weakOCR);
    assert(result.kind == TargetKind::Unknown);

    CandidateFeatures badShape = hero;
    badShape.width = 30.0f;
    badShape.height = 15.0f;
    result = TargetClassifier::Classify(badShape);
    assert(result.kind == TargetKind::Unknown);

    std::cout << "TargetClassifier tests: PASS (7 scenarios)\\n";
    return 0;
}
