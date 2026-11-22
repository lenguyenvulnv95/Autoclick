#pragma once
// HP-phu -> Autoclick observation boundary (data adapter only).
// This header intentionally does NOT install Metal hooks, start capture, or
// change HP-phu. The caller must supply a synchronized HP-phu track snapshot.
// All input rectangles/velocities are in HP-phu detector pixels.
#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <cmath>
#include <vector>

namespace HPPhuBridge {
struct TrackSnapshot {
    CGRect barRectPx = CGRectZero;
    float velocityXPxPerSecond = 0.0f;
    float velocityYPxPerSecond = 0.0f;
    float confidence = 0.0f;
    int missedFrames = 0;
};

struct Observation {
    CGRect barRectPt = CGRectZero;
    CGPoint barCenterPt = CGPointZero;
    CGPoint velocityPtPerSecond = CGPointZero;
    float confidence = 0.0f;
    int missedFrames = 0;
    // Not supplied by HP-phu tracks. Never synthesize hero identity,
    // level or remaining HP from red-bar width.
    int level = 0;
    bool levelVerified = false;
    float hpPercent = -1.0f; // unknown
    bool hpVerified = false;
    bool enemyHeroVerified = false;
};

inline std::vector<Observation> Convert(
    const std::vector<TrackSnapshot>& tracks,
    int detectorWidthPx, int detectorHeightPx,
    CGFloat viewWidthPt, CGFloat viewHeightPt,
    int maxMissedFrames = 4)
{
    std::vector<Observation> result;
    if (detectorWidthPx <= 0 || detectorHeightPx <= 0 ||
        !std::isfinite(viewWidthPt) || !std::isfinite(viewHeightPt) ||
        viewWidthPt <= 0 || viewHeightPt <= 0) return result;
    const CGFloat sx = viewWidthPt / detectorWidthPx;
    const CGFloat sy = viewHeightPt / detectorHeightPx;
    result.reserve(tracks.size());
    for (const auto& t : tracks) {
        const CGRect r = t.barRectPx;
        if (!std::isfinite(r.origin.x) || !std::isfinite(r.origin.y) ||
            !std::isfinite(r.size.width) || !std::isfinite(r.size.height) ||
            r.size.width <= 0 || r.size.height <= 0 ||
            t.missedFrames < 0 || t.missedFrames > maxMissedFrames ||
            !std::isfinite(t.confidence) ||
            !std::isfinite(t.velocityXPxPerSecond) ||
            !std::isfinite(t.velocityYPxPerSecond)) continue;
        Observation o;
        o.barRectPt = CGRectMake(r.origin.x * sx, r.origin.y * sy,
                                 r.size.width * sx, r.size.height * sy);
        o.barCenterPt = CGPointMake(CGRectGetMidX(o.barRectPt),
                                    CGRectGetMidY(o.barRectPt));
        o.velocityPtPerSecond = CGPointMake(t.velocityXPxPerSecond * sx,
                                            t.velocityYPxPerSecond * sy);
        o.confidence = std::max(0.0f, std::min(1.0f, t.confidence));
        o.missedFrames = t.missedFrames;
        result.push_back(o);
    }
    return result;
}
} // namespace HPPhuBridge
