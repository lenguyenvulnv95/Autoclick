#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

#include <algorithm>
#include <string>

#include "LevelRecognizer.hpp"
#include "HealthBarDetector.hpp"
#include "HealthBarSegmenter.hpp"
#include <vector>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const bool legacySegmentation = argc >= 3 && std::string(argv[1]) == "--legacy-segmentation";
        const int firstImage = legacySegmentation ? 2 : 1;
        if (argc <= firstImage) {
            fprintf(stderr, "Usage: ReferenceImageOCR [--legacy-segmentation] image...\n");
            return 2;
        }
        int failures = 0;
        for (int i = firstImage; i < argc; ++i) {
            NSString* path = [NSString stringWithUTF8String:argv[i]];
            NSURL* url = [NSURL fileURLWithPath:path];
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
            if (!source) {
                fprintf(stderr, "UNREADABLE %s\n", argv[i]);
                ++failures;
                continue;
            }
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
            CFRelease(source);
            if (!image) {
                fprintf(stderr, "NO_IMAGE %s\n", argv[i]);
                ++failures;
                continue;
            }

            const size_t width = CGImageGetWidth(image);
            const size_t height = CGImageGetHeight(image);
            const size_t sourceStride = width * 4;
            std::vector<uint8_t> bgra(sourceStride * height, 0);
            CGColorSpaceRef sourceColorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef sourceContext = CGBitmapContextCreate(
                bgra.data(), width, height, 8, sourceStride, sourceColorSpace,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(sourceColorSpace);
            if (!sourceContext) {
                CGImageRelease(image);
                fprintf(stderr, "BGRA_CONTEXT_FAILED %s\\n", argv[i]);
                ++failures;
                continue;
            }
            CGContextDrawImage(sourceContext, CGRectMake(0, 0, width, height), image);
            CGContextRelease(sourceContext);

            int redMinX = (int)width, redMinY = (int)height, redMaxX = -1, redMaxY = -1;
            int yellowMinX = (int)width, yellowMinY = (int)height, yellowMaxX = -1, yellowMaxY = -1;
            for (int py = 0; py < (int)height; ++py) {
                for (int px = 0; px < (int)width; ++px) {
                    const uint8_t* pixel = bgra.data() + (size_t)py * sourceStride + (size_t)px * 4;
                    const auto kind = HealthBarDetector::ClassifyPixel(pixel[0], pixel[1], pixel[2]);
                    if (kind == HealthBarDetector::PixelClass::HeroHpRed) {
                        redMinX = std::min(redMinX, px); redMaxX = std::max(redMaxX, px);
                        redMinY = std::min(redMinY, py); redMaxY = std::max(redMaxY, py);
                    } else if (kind == HealthBarDetector::PixelClass::TowerHpYellow) {
                        yellowMinX = std::min(yellowMinX, px); yellowMaxX = std::max(yellowMaxX, px);
                        yellowMinY = std::min(yellowMinY, py); yellowMaxY = std::max(yellowMaxY, py);
                    }
                }
            }
            if (redMaxX >= 0) printf("RED_BOUNDS x=%d..%d y=%d..%d\\n", redMinX, redMaxX, redMinY, redMaxY);
            if (yellowMaxX >= 0) printf("YELLOW_BOUNDS x=%d..%d y=%d..%d\\n", yellowMinX, yellowMaxX, yellowMinY, yellowMaxY);

            int recognizedLevel = 0;
            float levelConfidence = 0.0f;
            const bool levelFound = LevelRecognizer::RecognizeLevelFromBGRA(
                bgra.data(), (int)width, (int)height, (int)sourceStride,
                0.0f, 0.0f, (float)width, (float)height,
                &recognizedLevel, &levelConfidence);
            if (!levelFound) {
                fprintf(stderr, "LEVEL_NOT_RECOGNIZED %s\\n", argv[i]);
                ++failures;
            } else {
                printf("LEVEL_RESULT %s level=%d confidence=%.3f\\n",
                       argv[i], recognizedLevel, levelConfidence);
            }
            if (legacySegmentation) {
            const auto observations = HealthBarSegmenter::Detect(
                bgra.data(), (int)width, (int)height, (int)sourceStride,
                3.0f, 0, 0, (int)width, (int)height);
            printf("SEGMENTED_BARS %s count=%zu\\n", argv[i], observations.size());
            for (const auto& bar : observations) {
                printf("BAR type=%d level=%d hp=%.1f levelConf=%.2f hpConf=%.2f box=%.1f,%.1f,%.1f,%.1f\\n",
                       (int)bar.kind, bar.level, bar.hpPercent,
                       bar.levelConfidence, bar.hpConfidence,
                       bar.left, bar.top, bar.width, bar.height);
            }

            std::vector<HealthBarSegmenter::BarObservation> heroes;
            for (const auto& bar : observations) {
                if (bar.kind == TargetClassifier::TargetKind::EnemyHero) heroes.push_back(bar);
            }
            const std::string filePath(argv[i]);
            auto failDataset = [&](const char* reason) {
                fprintf(stderr, "DATASET_ASSERT_FAIL %s: %s\\n", argv[i], reason);
                ++failures;
            };
            if (filePath.find("IMG_4111") != std::string::npos) {
                if (heroes.size() != 1 || heroes[0].level != 1 || heroes[0].hpPercent < 90.0f)
                    failDataset("expected one level-1 hero at near-full HP");
            } else if (filePath.find("IMG_4112") != std::string::npos) {
                if (heroes.size() != 1 || heroes[0].level != 1 ||
                    heroes[0].hpPercent < 35.0f || heroes[0].hpPercent > 55.0f)
                    failDataset("expected one level-1 hero in the labeled half-health range");
            } else if (filePath.find("IMG_4113") != std::string::npos) {
                if (heroes.size() != 1 || heroes[0].level != 2 ||
                    heroes[0].hpPercent < 10.0f || heroes[0].hpPercent > 30.0f)
                    failDataset("expected one level-2 hero in the labeled low-health range");
            } else if (filePath.find("IMG_4115") != std::string::npos) {
                if (heroes.size() != 1 || heroes[0].level != 15 || heroes[0].hpPercent < 90.0f)
                    failDataset("expected one level-15 high-HP hero; shield must be excluded");
            } else if (filePath.find("IMG_4114") != std::string::npos) {
                int confirmedLevels = 0;
                for (const auto& hero : heroes) if (hero.level >= 1 && hero.level <= 16) ++confirmedLevels;
                if (heroes.size() != 4 || confirmedLevels < 3)
                    failDataset("expected four overlapping hero bars, at least three with readable levels");
            }
            } // Legacy segmentation assertions are independent of level OCR.
            const size_t scaledWidth = width * 3;
            const size_t scaledHeight = height * 3;
            CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
            CGContextRef bitmap = CGBitmapContextCreate(
                nullptr, scaledWidth, scaledHeight, 8, 0, rgb,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(rgb);
            if (!bitmap) {
                CGImageRelease(image);
                fprintf(stderr, "UPSCALE_FAILED %s\n", argv[i]);
                ++failures;
                continue;
            }
            CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
            CGContextDrawImage(bitmap, CGRectMake(0, 0, scaledWidth, scaledHeight), image);
            CGImageRef scaledImage = CGBitmapContextCreateImage(bitmap);
            CGContextRelease(bitmap);
            CGImageRelease(image);
            if (!scaledImage) {
                fprintf(stderr, "UPSCALE_IMAGE_FAILED %s\n", argv[i]);
                ++failures;
                continue;
            }

            VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = NO;
            request.minimumTextHeight = 0.003;
            request.recognitionLanguages = @[@"en-US"];

            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCGImage:scaledImage options:@{}];
            NSError* error = nil;
            BOOL ok = [handler performRequests:@[request] error:&error];
            CGImageRelease(scaledImage);
            printf("IMAGE %s %zux%zu\n", argv[i], width, height);

            if (!ok || error) {
                fprintf(stderr, "OCR_ERROR %s %s\n", argv[i],
                        error.localizedDescription.UTF8String ?: "unknown");
                ++failures;
            } else {
                for (VNRecognizedTextObservation* observation in request.results) {
                    VNRecognizedText* candidate = [[observation topCandidates:1] firstObject];
                    if (!candidate) continue;
                    CGRect box = observation.boundingBox;
                    printf("TEXT %s conf=%.3f box=%.3f,%.3f,%.3f,%.3f\n",
                           candidate.string.UTF8String ?: "",
                           candidate.confidence, box.origin.x, box.origin.y,
                           box.size.width, box.size.height);
                }
            }
        }
        return failures == 0 ? 0 : 1;
    }
}
