#include "TargetSelector.hpp"
#include <cassert>
#include <iostream>
#include <vector>

using TargetSelector::Candidate;

static Candidate Hero(int id, float hp, float distance = 100.0f) {
    Candidate c;
    c.id = id;
    c.hpPercent = hp;
    c.confidence = 0.90f;
    c.centerDistance = distance;
    c.level = 10;
    c.consecutiveFrames = 5;
    c.isEnemyHero = true;
    return c;
}

int main() {
    {
        std::vector<Candidate> list{Hero(1, 80.0f), Hero(2, 24.0f), Hero(3, 51.0f)};
        assert(TargetSelector::SelectLowestHP(list, 3, 0.75f) == 1);
    }
    {
        std::vector<Candidate> list{Hero(1, 20.0f), Hero(2, 21.5f)};
        assert(TargetSelector::SelectLowestHP(list, 3, 0.75f, 2, 1.0f) == 0);
        list[1].hpPercent = 20.8f;
        assert(TargetSelector::SelectLowestHP(list, 3, 0.75f, 2, 1.0f) == 1);
    }
    {
        auto tower = Hero(1, 1.0f);
        tower.isEnemyHero = false;
        auto unknownLevel = Hero(2, 2.0f);
        unknownLevel.level = 0;
        auto weak = Hero(3, 3.0f);
        weak.confidence = 0.40f;
        auto unconfirmed = Hero(4, 4.0f);
        unconfirmed.consecutiveFrames = 1;
        std::vector<Candidate> list{tower, unknownLevel, weak, unconfirmed, Hero(5, 40.0f)};
        assert(TargetSelector::SelectLowestHP(list, 3, 0.75f) == 4);
    }
    {
        auto missing = Hero(1, 1.0f);
        missing.missingFrames = 1;
        auto invalid = Hero(2, 2.0f);
        invalid.hpPercent = 101.0f;
        std::vector<Candidate> list{missing, invalid};
        assert(TargetSelector::SelectLowestHP(list, 3, 0.75f) == -1);
    }
    {
        std::vector<Candidate> list{Hero(1, 30.0f, 90.0f), Hero(2, 30.0f, 20.0f)};
        assert(TargetSelector::SelectLowestHP(list, 3, 0.75f) == 1);
    }
    std::cout << "PASS (5 scenarios)\n";
    return 0;
}
