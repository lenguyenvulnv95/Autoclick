#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include "HPPhuBridge.h"
#include <cstdio>
#include <vector>
#include <string>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: HPPhuReferenceTests image...\\n");
            return 2;
        }
        int failures = 0;
        for (int i = 1; i < argc; ++i) {
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[i]]];
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
            if (!source) { fprintf(stderr, "UNREADABLE %s\\n", argv[i]); ++failures; continue; }
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
            CFRelease(source);
            if (!image) { fprintf(stderr, "NO_IMAGE %s\\n", argv[i]); ++failures; continue; }
            const int w = (int)CGImageGetWidth(image), h = (int)CGImageGetHeight(image);
            const int stride = w * 4;
            std::vector<unsigned char> bgra((size_t)stride * h);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(bgra.data(), w, h, 8, stride, cs,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(cs);
            if (!ctx) { fprintf(stderr, "CONTEXT_FAILED %s\\n", argv[i]); ++failures; CGImageRelease(image); continue; }
            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
            CGContextRelease(ctx);
            CGImageRelease(image);
            // Monotonic timestamps keep the tracker deterministic across the dataset.
            const double now = 1000.0 + i;
            HPPhuBridge::SubmitBGRA(bgra.data(), w, h, stride, now);
            const auto batch = HPPhuBridge::ReadDetectorSnapshot(now);
            if (batch.frameId == 0 || batch.widthPx <= 0 || batch.heightPx <= 0) {
                fprintf(stderr, "HP_PHU_SNAPSHOT_FAIL %s\\n", argv[i]);
                ++failures;
                continue;
            }
            const auto bars = HPPhuBridge::Convert(batch.tracks, batch.widthPx, batch.heightPx, w, h);
            printf("HP_PHU_IMAGE %s %dx%d detected=%zu frame=%llu\\n", argv[i], w, h,
                bars.size(), (unsigned long long)batch.frameId);
            for (const auto& bar : bars) {
                printf("HP_PHU_BAR x=%.1f y=%.1f w=%.1f h=%.1f confidence=%.2f missed=%d\\n",
                    bar.barRectPt.origin.x, bar.barRectPt.origin.y,
                    bar.barRectPt.size.width, bar.barRectPt.size.height,
                    bar.confidence, bar.missedFrames);
                if (bar.hpVerified || bar.enemyHeroVerified || bar.levelVerified) {
                    fprintf(stderr, "HP_PHU_UNVERIFIED_DATA_MARKED_VERIFIED %s\\n", argv[i]);
                    ++failures;
                }
            }
        }
        return failures ? 1 : 0;
    }
}
