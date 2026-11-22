#include "HPPhuBridge.h"
#include <cassert>
#include <cmath>
#include <iostream>
using namespace HPPhuBridge;
int main() {
    SnapshotMailbox box;
    assert(box.ReadFresh(10.0).frameId == 0);
    SnapshotBatch first;
    first.frameId = 1;
    first.widthPx = 640;
    first.heightPx = 360;
    first.capturedAtSeconds = 10.0;
    first.tracks.push_back({CGRectMake(100, 50, 40, 6), 20, -10, 0.8f, 0});
    box.Publish(first);
    auto read = box.ReadFresh(10.1);
    assert(read.frameId == 1 && read.tracks.size() == 1);
    auto bars = Convert(read.tracks, read.widthPx, read.heightPx, 320, 180);
    assert(bars.size() == 1);
    assert(std::fabs(bars[0].barCenterPt.x - 60.0) < 0.001);
    assert(std::fabs(bars[0].barCenterPt.y - 26.5) < 0.001);
    assert(std::fabs(bars[0].velocityPtPerSecond.x - 10.0) < 0.001);
    assert(!bars[0].enemyHeroVerified && !bars[0].hpVerified && bars[0].hpPercent == -1.0f);
    assert(box.ReadFresh(10.3).frameId == 0);
    assert(box.ReadFresh(9.9).frameId == 0);
    SnapshotBatch stale = first;
    stale.capturedAtSeconds = 10.2;
    box.Publish(stale);
    assert(box.Read().capturedAtSeconds == 10.0);
    SnapshotBatch second = first;
    second.frameId = 2;
    second.capturedAtSeconds = 10.4;
    second.tracks.clear();
    box.Publish(second);
    assert(box.ReadFresh(10.45).frameId == 2);
    assert(box.ReadFresh(10.45).tracks.empty());
    assert(Convert(first.tracks, 0, 360, 320, 180).empty());
    auto invalid = first.tracks;
    invalid[0].barRectPx.size.width = -1;
    assert(Convert(invalid, 640, 360, 320, 180).empty());
    invalid = first.tracks;
    invalid[0].missedFrames = 5;
    assert(Convert(invalid, 640, 360, 320, 180).empty());
    std::cout << "HPPhuBridge tests: PASS\\n";
}
