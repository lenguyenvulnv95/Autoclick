#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Vision/Vision.h>

#include "LevelRecognizer.hpp"

namespace LevelRecognizer {

bool RecognizeLevelFromBGRA(const uint8_t* bgra,
                            int imageWidth,
                            int imageHeight,
                            int bytesPerRow,
                            float cropX,
                            float cropY,
                            float cropWidth,
                            float cropHeight,
                            int* outLevel,
                            float* outConfidence) {
    if (outLevel) *outLevel = 0;
    if (outConfidence) *outConfidence = 0.0f;
    if (!bgra || !outLevel || imageWidth <= 0 || imageHeight <= 0 ||
        bytesPerRow < imageWidth * 4 || cropWidth <= 0.0f || cropHeight <= 0.0f) {
        return false;
    }

    const int x0 = std::max(0, (int)std::floor(cropX));
    const int y0 = std::max(0, (int)std::floor(cropY));
    const int x1 = std::min(imageWidth, (int)std::ceil(cropX + cropWidth));
    const int y1 = std::min(imageHeight, (int)std::ceil(cropY + cropHeight));
    if (x1 <= x0 || y1 <= y0) return false;

    CGDataProviderRef provider = CGDataProviderCreateWithData(
        nullptr, bgra, (size_t)bytesPerRow * (size_t)imageHeight, nullptr);
    if (!provider) return false;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) {
        CGDataProviderRelease(provider);
        return false;
    }

    CGImageRef fullImage = CGImageCreate(
        imageWidth, imageHeight, 8, 32, bytesPerRow, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!fullImage) return false;

    CGRect cropRect = CGRectMake(x0, y0, x1 - x0, y1 - y0);
    CGImageRef cropImage = CGImageCreateWithImageInRect(fullImage, cropRect);
    CGImageRelease(fullImage);
    if (!cropImage) return false;

    VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRecognizeTextRequestRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    request.minimumTextHeight = 0.015;
    request.recognitionLanguages = @[@"en-US"];

    VNImageRequestHandler* handler =
        [[VNImageRequestHandler alloc] initWithCGImage:cropImage options:@{}];
    NSError* error = nil;
    BOOL performed = [handler performRequests:@[request] error:&error];
    CGImageRelease(cropImage);
    if (!performed || error || request.results.count == 0) return false;

    float bestConfidence = 0.0f;
    int bestLevel = 0;
    for (VNRecognizedTextObservation* observation in request.results) {
        VNRecognizedText* candidate = [[observation topCandidates:3] firstObject];
        if (!candidate) continue;

        const char* utf8 = candidate.string.UTF8String;
        if (!utf8) continue;
        int parsedLevel = 0;
        if (!ParseLevelText(std::string(utf8), &parsedLevel)) continue;

        const float confidence = candidate.confidence;
        if (confidence > bestConfidence) {
            bestConfidence = confidence;
            bestLevel = parsedLevel;
        }
    }

    // Do not turn weak OCR guesses into hero classifications.
    if (bestLevel == 0 || bestConfidence < 0.45f) return false;
    *outLevel = bestLevel;
    if (outConfidence) *outConfidence = bestConfidence;
    return true;
}

} // namespace LevelRecognizer
