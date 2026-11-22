// Extracted from AovVision/HP-phu HPDetector.mm (V4) for Autoclick.
// No Metal hooks, overlays, UIKit windows, OCR or touch injection.
// Receives BGRA from Autoclick's single capture pipeline.
#include "HPPhuBridge.h"
#include <algorithm>
#include <cmath>
#include <mutex>
#include <vector>

namespace HPPhuBridge {
struct HPBox { CGRect rect; int type; float confidence; };
struct HPTrack { HPBox box; float vx; float vy; double lastTime; int missed; };
static std::mutex gMutex;
static std::vector<HPTrack> gTracks;
static uint64_t gFrameCount = 0;
static SnapshotMailbox gMailbox;

static inline bool HPIsEnemyRed(unsigned char b, unsigned char g, unsigned char r, float strictness) {
    const int minR = (int)(95.0f + strictness * 50.0f);       // 95..145
    const float gRatio = 1.22f + strictness * 0.40f;          // 1.22..1.62
    const float bRatio = 1.18f + strictness * 0.35f;          // 1.18..1.53
    const int minDelta = (int)(22.0f + strictness * 38.0f);   // 22..60
    const int maxGB = std::max((int)g, (int)b);
    return (r > minR && (float)r > (float)g * gRatio && (float)r > (float)b * bRatio && (r - maxGB) > minDelta);
}

static bool HPBadgeGeometry(const unsigned char *pixels, int width, int height, int stride,
                            CGRect bar, float strictness, CGRect *badgeOut) {
    const int barX = (int)CGRectGetMinX(bar);
    const int barMidY = (int)CGRectGetMidY(bar);
    const int barH = std::max(3, (int)CGRectGetHeight(bar));
    const int base = std::max(10, (int)std::round(height * 0.042));
    const int minSide = std::max(9, base - 4);
    const int maxSide = base + 5;

    const float minDark = 0.22f + strictness * 0.35f;
    const float minBright = 0.008f + strictness * 0.028f;
    const int darkLumLimit = (int)(128.0f - strictness * 30.0f);

    float bestScore = -1.0f;
    CGRect bestRect = CGRectZero;

    for (int side = minSide; side <= maxSide; side += 2) {
        for (int gap = 0; gap <= 7; gap += 2) {
            for (int yShift = -1; yShift <= std::max(3, barH / 2 + 2); yShift += 2) {
                const int x0 = barX - side - gap;
                const int y0 = barMidY + yShift - side / 2;
                if (x0 < 1 || y0 < 1 || x0 + side >= width - 1 || y0 + side >= height - 1) continue;

                int dark = 0, bright = 0, total = 0;
                const int pad = std::max(1, side / 5);
                for (int y = y0 + pad; y < y0 + side - pad; ++y) {
                    const unsigned char *row = pixels + (size_t)y * stride;
                    for (int x = x0 + pad; x < x0 + side - pad; ++x) {
                        const unsigned char *p = row + (size_t)x * 4;
                        const int b = p[0], g = p[1], r = p[2];
                        const int lum = (r + g + b) / 3;
                        const int chroma = std::max(r, std::max(g, b)) - std::min(r, std::min(g, b));
                        if (lum < darkLumLimit) {
                            ++dark;
                        } else if (lum > 138 && chroma < 80) {
                            ++bright;
                        }
                        ++total;
                    }
                }
                if (total < 9) continue;

                const float darkRatio = (float)dark / (float)total;
                const float brightRatio = (float)bright / (float)total;
                if (darkRatio < minDark || brightRatio < minBright || brightRatio > 0.55f) continue;

                const float score = darkRatio * 2.0f + std::min(brightRatio, 0.25f) * 3.0f - (float)gap * 0.03f;
                if (score > bestScore) {
                    bestScore = score;
                    bestRect = CGRectMake(x0, y0, side, side);
                }
            }
        }
    }

    if (bestScore > 0.0f) {
        *badgeOut = bestRect;
        return true;
    }
    return false;
}


void SubmitBGRA(const unsigned char *pixels, int width, int height, int stride, double capturedAtSeconds) {
    if (!pixels || width < 64 || height < 64 || width > 8192 || height > 8192 || stride < width * 4) return;

    const double now = capturedAtSeconds;
    const float redStrict = 0.50f;
    const float badgeStrict = 0.50f;
    const int maxMissed = 4;

    // Horizontal red-run scan; step 2 rows when height >= 420 to cut CPU time in half.
    std::vector<HPBox> candidates;
    candidates.reserve(256);
    const int yStep = (height >= 420) ? 2 : 1;
    const int minRun = std::max(7, width / 165);
    const int maxRun = std::max(90, width / 6);
    const int maxTickGap = (redStrict < 0.5f) ? 3 : 2;
    const int minRedDensityPct = (int)(60.0f + redStrict * 15.0f);

    for (int y = 1; y < height - 1; y += yStep) {
        const unsigned char *row = pixels + (size_t)y * stride;
        int x = 0;
        while (x < width) {
            const unsigned char *p = row + (size_t)x * 4;
            if (!HPIsEnemyRed(p[0], p[1], p[2], redStrict)) { ++x; continue; }

            const int start = x;
            int lastRed = x;
            int redPixels = 1;
            int gap = 0;
            ++x;

            while (x < width) {
                p = row + (size_t)x * 4;
                if (HPIsEnemyRed(p[0], p[1], p[2], redStrict)) {
                    lastRed = x;
                    ++redPixels;
                    gap = 0;
                } else {
                    if (++gap > maxTickGap) break;
                }
                ++x;
            }

            const int run = lastRed - start + 1;
            if (run >= minRun && run <= maxRun && redPixels * 100 >= run * minRedDensityPct) {
                candidates.push_back({CGRectMake(start, y, run, yStep), 2, 0.35f});
            }
        }
    }

    // Merge adjacent scanlines belonging to the same horizontal red bar.
    std::vector<HPBox> merged;
    merged.reserve(128);
    const int maxBarH = std::max(10, (int)std::round(height * 0.026));
    const int mergeYGap = yStep + 2;
    for (const auto &c : candidates) {
        bool found = false;
        for (auto &m : merged) {
            if (std::abs(CGRectGetMinX(m.rect) - CGRectGetMinX(c.rect)) <= 10 &&
                std::abs(CGRectGetWidth(m.rect) - CGRectGetWidth(c.rect)) <= 18 &&
                CGRectGetMinY(c.rect) - CGRectGetMaxY(m.rect) <= mergeYGap &&
                CGRectGetMinY(c.rect) - CGRectGetMinY(m.rect) <= maxBarH + 4) {
                m.rect = CGRectUnion(m.rect, c.rect);
                m.confidence = std::min(0.85f, m.confidence + 0.06f);
                found = true;
                break;
            }
        }
        if (!found && merged.size() < 384) merged.push_back(c);
    }

    const int minBarH = std::max(2, (int)std::round(height * 0.004));
    const float minAspect = 1.4f + redStrict * 0.8f;
    std::vector<HPBox> filtered;
    filtered.reserve(64);
    for (const auto &m : merged) {
        const CGFloat w = CGRectGetWidth(m.rect);
        const CGFloat h = CGRectGetHeight(m.rect);
        if (h < minBarH || h > maxBarH) continue;
        if (w < h * minAspect) continue;
        if (filtered.size() < 96) filtered.push_back(m);
    }

    std::sort(filtered.begin(), filtered.end(), [](const HPBox &a, const HPBox &b) {
        return CGRectGetWidth(a.rect) > CGRectGetWidth(b.rect);
    });

    // HP-phu's default OCR-off mode: geometry confirms a candidate bar,
    // but does not establish hero identity, level or HP percentage.
    std::vector<HPBox> verified;
    for (const auto& bar : filtered) {
        CGRect badge;
        if (!HPBadgeGeometry(pixels, width, height, stride, bar.rect, badgeStrict, &badge)) continue;
        bool duplicate = false;
        for (const auto& prev : verified) {
            if (std::abs(CGRectGetMidY(prev.rect) - CGRectGetMidY(bar.rect)) < std::max(10.0f, height * 0.025f) &&
                std::abs(CGRectGetMinX(prev.rect) - CGRectGetMinX(bar.rect)) < std::max(14.0f, width * 0.022f)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) verified.push_back(bar);
        if (verified.size() >= 12) break;
    }

    SnapshotBatch batch;
    {
    std::lock_guard<std::mutex> lock(gMutex);
    const float trackDX = std::max(38.0f, width * 0.065f);
    const float trackDY = std::max(28.0f, height * 0.075f);

    std::vector<bool> oldMatched(gTracks.size(), false);
    std::vector<HPTrack> next;
    next.reserve(verified.size() + gTracks.size());

    // Match fresh detections to previous tracks and estimate velocity (vx, vy)
    for (const auto &box : verified) {
        int bestIdx = -1;
        float bestDist = 1e9f;
        for (size_t i = 0; i < gTracks.size(); ++i) {
            if (oldMatched[i]) continue;
            float dx = (float)(CGRectGetMidX(box.rect) - CGRectGetMidX(gTracks[i].box.rect));
            float dy = (float)(CGRectGetMidY(box.rect) - CGRectGetMidY(gTracks[i].box.rect));
            if (std::abs(dx) < trackDX && std::abs(dy) < trackDY) {
                float d = dx * dx + dy * dy;
                if (d < bestDist) { bestDist = d; bestIdx = (int)i; }
            }
        }

        float vx = 0.0f, vy = 0.0f;
        if (bestIdx >= 0) {
            oldMatched[bestIdx] = true;
            const auto &prev = gTracks[bestIdx];
            double dt = now - prev.lastTime;
            if (dt > 0.005 && dt < 0.35) {
                float instVx = (float)((box.rect.origin.x - prev.box.rect.origin.x) / dt);
                float instVy = (float)((box.rect.origin.y - prev.box.rect.origin.y) / dt);
                // Exponential smoothing on velocity to suppress jitter
                vx = prev.vx * 0.35f + instVx * 0.65f;
                vy = prev.vy * 0.35f + instVy * 0.65f;
                const float maxSpeed = (float)width * 1.2f;
                vx = std::max(-maxSpeed, std::min(maxSpeed, vx));
                vy = std::max(-maxSpeed, std::min(maxSpeed, vy));
            }
        }
        next.push_back({box, vx, vy, now, 0});
    }

    // Keep unmatched tracks briefly if they still have a nearby bar or within hold window
    for (size_t i = 0; i < gTracks.size(); ++i) {
        if (oldMatched[i]) continue;
        const auto &track = gTracks[i];
        if (track.missed >= maxMissed) continue;

        bool kept = false;
        for (const auto &bar : filtered) {
            if (std::abs(CGRectGetMidX(bar.rect) - CGRectGetMidX(track.box.rect)) > trackDX ||
                std::abs(CGRectGetMidY(bar.rect) - CGRectGetMidY(track.box.rect)) > trackDY) continue;
            CGRect badge;
            if (!HPBadgeGeometry(pixels, width, height, stride, bar.rect, std::max(0.0f, badgeStrict - 0.15f), &badge)) continue;
            double dt = now - track.lastTime;
            float vx = track.vx * 0.5f, vy = track.vy * 0.5f;
            if (dt > 0.005 && dt < 0.35) {
                vx = (float)((bar.rect.origin.x - track.box.rect.origin.x) / dt) * 0.5f + track.vx * 0.5f;
                vy = (float)((bar.rect.origin.y - track.box.rect.origin.y) / dt) * 0.5f + track.vy * 0.5f;
            }
            next.push_back({bar, vx, vy, now, track.missed + 1});
            kept = true;
            break;
        }
        if (!kept && track.missed < std::min(2, maxMissed)) {
            next.push_back({track.box, track.vx * 0.5f, track.vy * 0.5f, track.lastTime, track.missed + 1});
        }
    }

    gTracks.swap(next);
    batch.widthPx = width;
    batch.heightPx = height;
    batch.frameId = ++gFrameCount;
    batch.capturedAtSeconds = now;
    batch.tracks.reserve(gTracks.size());
    for (const auto& t : gTracks) {
        TrackSnapshot snap;
        snap.barRectPx = t.box.rect;
        snap.velocityXPxPerSecond = t.vx;
        snap.velocityYPxPerSecond = t.vy;
        snap.confidence = t.box.confidence;
        snap.missedFrames = t.missed;
        batch.tracks.push_back(snap);
    }
    } // Release tracker mutex before publishing to the consumer mailbox.
    gMailbox.Publish(std::move(batch));

}


SnapshotBatch ReadDetectorSnapshot(double nowSeconds, double maxAgeSeconds) {
    return gMailbox.ReadFresh(nowSeconds, maxAgeSeconds);
}
} // namespace HPPhuBridge
