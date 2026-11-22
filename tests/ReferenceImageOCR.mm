#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

#include <algorithm>

#include "LevelRecognizer.hpp"
#include "HealthBarDetector.hpp"
#include <vector>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: ReferenceImageOCR image...\n");
            return 2;
        }
        int failures = 0;
        for (int i = 1; i < argc; ++i) {
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
