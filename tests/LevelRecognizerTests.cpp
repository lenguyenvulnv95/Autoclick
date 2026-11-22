#include "LevelRecognizer.hpp"
#include <cassert>
#include <iostream>

int main() {
    int level = 0;
    assert(LevelRecognizer::ParseLevelText("1", &level) && level == 1);
    assert(LevelRecognizer::ParseLevelText("16", &level) && level == 16);
    assert(LevelRecognizer::ParseLevelText("Lv. 12", &level) && level == 12);
    assert(LevelRecognizer::ParseLevelText("Level 9", &level) && level == 9);
    assert(!LevelRecognizer::ParseLevelText("0", &level));
    assert(!LevelRecognizer::ParseLevelText("17", &level));
    assert(!LevelRecognizer::ParseLevelText("Lv. 1 6", &level));
    assert(!LevelRecognizer::ParseLevelText("no level", &level));
    assert(!LevelRecognizer::ParseLevelText("12/3", &level));
    assert(!LevelRecognizer::ParseLevelText("8", nullptr));
    std::cout << "LevelRecognizer parser tests: PASS (10 assertions)\\n";
    return 0;
}
