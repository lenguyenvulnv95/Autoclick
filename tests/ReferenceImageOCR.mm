#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: ReferenceImageOCR image...\\n");
            return 2;
        }
        int failures = 0;
        for (int i = 1; i < argc; ++i) {
            NSString* path = [NSString stringWithUTF8String:argv[i]];
            NSURL* url = [NSURL fileURLWithPath:path];
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
            if (!source) {
                fprintf(stderr, "UNREADABLE %s\\n", argv[i]);
                ++failures;
                continue;
            }
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
            CFRelease(source);
            if (!image) {
                fprintf(stderr, "NO_IMAGE %s\\n", argv[i]);
                ++failures;
                continue;
            }

            VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = NO;
            request.minimumTextHeight = 0.005;
            request.recognitionLanguages = @[@"en-US"];

            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
            NSError* error = nil;
            BOOL ok = [handler performRequests:@[request] error:&error];
            const size_t width = CGImageGetWidth(image);
            const size_t height = CGImageGetHeight(image);
            printf("IMAGE %s %zux%zu\\n", argv[i], width, height);

            if (!ok || error) {
                fprintf(stderr, "OCR_ERROR %s %s\\n", argv[i],
                        error.localizedDescription.UTF8String ?: "unknown");
                ++failures;
            } else {
                for (VNRecognizedTextObservation* observation in request.results) {
                    VNRecognizedText* candidate = [[observation topCandidates:1] firstObject];
                    if (!candidate) continue;
                    CGRect box = observation.boundingBox;
                    printf("TEXT %s conf=%.3f box=%.3f,%.3f,%.3f,%.3f\\n",
                           candidate.string.UTF8String ?: "",
                           candidate.confidence, box.origin.x, box.origin.y,
                           box.size.width, box.size.height);
                }
            }
            CGImageRelease(image);
        }
        return failures == 0 ? 0 : 1;
    }
}
