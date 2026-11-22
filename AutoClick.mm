#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>

#include <unistd.h>
#include <vector>
#include <array>
#include <string>
#include <cmath>
#include <random>
#include <mutex>
#include <atomic>
#include <algorithm>

#include "HealthBarDetector.hpp"
#include "HealthBarSegmenter.hpp"
#include "TargetSelector.hpp"

#include "imgui.h"
#include "imgui_impl_metal.h"

// ============================================================================
// IOKIT / IOHIDEVENT PRIVATE DECLARATIONS (TOUCH INJECTION IOS 16 - 26)
// ============================================================================
typedef struct __IOHIDEvent *IOHIDEventRef;
extern "C" {
    IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
                                                 uint64_t timeStamp,
                                                 uint32_t transducerType,
                                                 uint32_t index,
                                                 uint32_t identity,
                                                 uint32_t eventMask,
                                                 uint32_t buttonMask,
                                                 float x,
                                                 float y,
                                                 float z,
                                                 float tipPressure,
                                                 float barrelPressure,
                                                 Boolean range,
                                                 Boolean touch,
                                                 uint32_t options);

    IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator,
                                                       uint64_t timeStamp,
                                                       uint32_t index,
                                                       uint32_t identity,
                                                       uint32_t eventMask,
                                                       float x,
                                                       float y,
                                                       float z,
                                                       float tipPressure,
                                                       float twist,
                                                       Boolean range,
                                                       Boolean touch,
                                                       uint32_t options);

    void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
    void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);
}

#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDDigitizerEventRange         (1 << 0)
#define kIOHIDDigitizerEventTouch         (1 << 1)
#define kIOHIDDigitizerEventPosition      (1 << 2)
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 720921

// ============================================================================
// CẤU HÌNH HỆ THỐNG & PRESET CHO NAK
// ============================================================================
enum class NakComboType {
    GANK_LONG_RANGE = 1,    // C1: Gank / bắt lẻ từ xa
    CLOSE_COMBAT    = 2,    // C2: Địch ở gần
    POKE_AND_RUN    = 3     // C3: Cấu rỉa / ra vào nhanh (rút lui ngược hướng S1 lần 2)
};

struct Config {
    bool masterEnable = false;          // Công tắc tổng (mặc định tắt)
    bool autoEngage = false;            // Tự động kích hoạt combo khi khóa mục tiêu
    bool targetQueueEnable = false;     // Khóa tuần tự 5 mục tiêu A -> E
    bool drawDebugEsp = true;           // Vẽ khung nhận diện thanh máu & mục tiêu lock
    bool showQuickComboBtns = true;     // Hiển thị cụm 3 nút C1, C2, C3 trên màn hình
    float uiOpacity = 0.85f;            // Độ mờ nút điều khiển nổi

    int captureFps = 60;                // Mục tiêu tối đa; FPS thực tế phụ thuộc tốc độ xử lý Vision
    float standardHpWidth = 68.0f;      // Chiều rộng chuẩn thanh máu theo UIKit point
    float minHpHeight = 4.0f;           // Chiều cao tối thiểu thanh máu (px)
    float maxHpHeight = 14.0f;          // Chiều cao tối đa thanh máu (px)
    int minConfirmFrames = 2;           // Số frame liên tiếp để xác nhận mục tiêu

    float floatingTogglePos[2] = {0.03f, 0.28f}; // Nút ON/OFF
    float menuTogglePos[2] = {0.09f, 0.28f};    // Nút mở menu PX
    // Vị trí riêng của các nút kích hoạt combo, tách khỏi tọa độ skill trong game.
    float quickC1Pos[2] = {0.12f, 0.14f};
    float quickC2Pos[2] = {0.18f, 0.14f};
    float quickC3Pos[2] = {0.24f, 0.14f};
    float quickAAPos[2] = {0.30f, 0.14f};
    float quickButtonSize = 42.0f;
    float quickAAButtonSize = 42.0f;
    float skill1Pos[2] = {0.78f, 0.82f}; // Chiêu 1 (2 lần)
    float skill2Pos[2] = {0.84f, 0.65f}; // Chiêu 2 (lướt ngược)
    float skill3Pos[2] = {0.92f, 0.52f}; // Chiêu 3 (Ulti)
    float attackPos[2] = {0.91f, 0.85f}; // Đánh thường / Đánh cường hóa

    NakComboType selectedCombo = NakComboType::GANK_LONG_RANGE;

    float posJitterPx = 3.5f;
    int timeJitterMs = 12;

    int delayAfterS2Ms = 80;
    int delayAfterS1_1Ms = 90;
    int delayAfterEmpAAMs = 110;
    int delayAfterS3Ms = 160;
    int delayAfterS1_2Ms = 90;

    float mainScanRoi[4] = {0.15f, 0.10f, 0.70f, 0.75f};
    float minimapRoi[4]  = {0.01f, 0.01f, 0.18f, 0.30f};
};

static Config g_Cfg;
static std::recursive_mutex g_ConfigMutex;
static std::mutex g_StateMutex;
static std::atomic<bool> g_MasterEnable{false};
static std::atomic<int> g_CaptureFps{60};

static Config GetConfigSnapshot() {
    std::lock_guard<std::recursive_mutex> lock(g_ConfigMutex);
    return g_Cfg;
}
static std::atomic<float> g_ScreenPointWidth{0.0f};
static std::atomic<float> g_ScreenPointHeight{0.0f};
static std::atomic<uint64_t> g_ImGuiFrameCounter{0};
static std::atomic<uint64_t> g_ImGuiMousePressFrame{0};
static std::atomic<bool> g_ImGuiMouseReleasePending{false};
static bool g_ShowImGuiMenu = false;

static CGSize CachedScreenPointSize() {
    return CGSizeMake(
        (CGFloat)g_ScreenPointWidth.load(std::memory_order_acquire),
        (CGFloat)g_ScreenPointHeight.load(std::memory_order_acquire));
}

static void UpdateCachedScreenPointSize(CGSize size) {
    if (size.width <= 0.0 || size.height <= 0.0) return;
    g_ScreenPointWidth.store((float)size.width, std::memory_order_release);
    g_ScreenPointHeight.store((float)size.height, std::memory_order_release);
}

// ============================================================================
// LƯU / TẢI CẤU HÌNH JSON VÀO DOCUMENTS
// ============================================================================
namespace ConfigStorage {
    NSString* GetConfigFilePath(NSString *presetName) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docsDir = paths.firstObject;
        return [docsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"nak_%@.json", presetName]];
    }

    void SavePreset(const char* name) {
        std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
        NSDictionary *dict = @{
            @"autoEngage": @(g_Cfg.autoEngage),
            @"targetQueueEnable": @(g_Cfg.targetQueueEnable),
            @"drawDebugEsp": @(g_Cfg.drawDebugEsp),
            @"showQuickComboBtns": @(g_Cfg.showQuickComboBtns),
            @"uiOpacity": @(g_Cfg.uiOpacity),
            @"captureFps": @(g_Cfg.captureFps),
            @"selectedCombo": @((int)g_Cfg.selectedCombo),
            @"standardHpWidth": @(g_Cfg.standardHpWidth),
            @"minConfirmFrames": @(g_Cfg.minConfirmFrames),
            @"posJitterPx": @(g_Cfg.posJitterPx),
            @"timeJitterMs": @(g_Cfg.timeJitterMs),
            @"delayAfterS2Ms": @(g_Cfg.delayAfterS2Ms),
            @"delayAfterS1_1Ms": @(g_Cfg.delayAfterS1_1Ms),
            @"delayAfterEmpAAMs": @(g_Cfg.delayAfterEmpAAMs),
            @"delayAfterS3Ms": @(g_Cfg.delayAfterS3Ms),
            @"delayAfterS1_2Ms": @(g_Cfg.delayAfterS1_2Ms),
            @"floatingToggleX": @(g_Cfg.floatingTogglePos[0]), @"floatingToggleY": @(g_Cfg.floatingTogglePos[1]),
            @"menuToggleX": @(g_Cfg.menuTogglePos[0]), @"menuToggleY": @(g_Cfg.menuTogglePos[1]),
            @"quickC1X": @(g_Cfg.quickC1Pos[0]), @"quickC1Y": @(g_Cfg.quickC1Pos[1]),
            @"quickC2X": @(g_Cfg.quickC2Pos[0]), @"quickC2Y": @(g_Cfg.quickC2Pos[1]),
            @"quickC3X": @(g_Cfg.quickC3Pos[0]), @"quickC3Y": @(g_Cfg.quickC3Pos[1]),
            @"quickAAX": @(g_Cfg.quickAAPos[0]), @"quickAAY": @(g_Cfg.quickAAPos[1]),
            @"quickButtonSize": @(g_Cfg.quickButtonSize),
            @"quickAAButtonSize": @(g_Cfg.quickAAButtonSize),
            @"skill1X": @(g_Cfg.skill1Pos[0]), @"skill1Y": @(g_Cfg.skill1Pos[1]),
            @"skill2X": @(g_Cfg.skill2Pos[0]), @"skill2Y": @(g_Cfg.skill2Pos[1]),
            @"skill3X": @(g_Cfg.skill3Pos[0]), @"skill3Y": @(g_Cfg.skill3Pos[1]),
            @"attackX": @(g_Cfg.attackPos[0]), @"attackY": @(g_Cfg.attackPos[1])
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
        if (jsonData) {
            [jsonData writeToFile:GetConfigFilePath([NSString stringWithUTF8String:name]) atomically:YES];
        }
    }

    void LoadPreset(const char* name) {
        std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
        NSData *data = [NSData dataWithContentsOfFile:GetConfigFilePath([NSString stringWithUTF8String:name])];
        if (!data) return;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![dict isKindOfClass:[NSDictionary class]]) return;

        if (dict[@"autoEngage"]) g_Cfg.autoEngage = [dict[@"autoEngage"] boolValue];
        if (dict[@"targetQueueEnable"]) g_Cfg.targetQueueEnable = [dict[@"targetQueueEnable"] boolValue];
        if (dict[@"drawDebugEsp"]) g_Cfg.drawDebugEsp = [dict[@"drawDebugEsp"] boolValue];
        if (dict[@"showQuickComboBtns"]) g_Cfg.showQuickComboBtns = [dict[@"showQuickComboBtns"] boolValue];
        if (dict[@"uiOpacity"]) g_Cfg.uiOpacity = [dict[@"uiOpacity"] floatValue];
        if (dict[@"captureFps"]) {
            g_Cfg.captureFps = std::max(6, std::min(60, [dict[@"captureFps"] intValue]));
        }
        g_CaptureFps.store(g_Cfg.captureFps, std::memory_order_release);
        if (dict[@"selectedCombo"]) g_Cfg.selectedCombo = (NakComboType)[dict[@"selectedCombo"] intValue];
        if (dict[@"standardHpWidth"]) g_Cfg.standardHpWidth = [dict[@"standardHpWidth"] floatValue];
        if (dict[@"minConfirmFrames"]) g_Cfg.minConfirmFrames = [dict[@"minConfirmFrames"] intValue];
        if (dict[@"posJitterPx"]) g_Cfg.posJitterPx = [dict[@"posJitterPx"] floatValue];
        if (dict[@"timeJitterMs"]) g_Cfg.timeJitterMs = [dict[@"timeJitterMs"] intValue];
        if (dict[@"delayAfterS2Ms"]) g_Cfg.delayAfterS2Ms = [dict[@"delayAfterS2Ms"] intValue];
        if (dict[@"delayAfterS1_1Ms"]) g_Cfg.delayAfterS1_1Ms = [dict[@"delayAfterS1_1Ms"] intValue];
        if (dict[@"delayAfterEmpAAMs"]) g_Cfg.delayAfterEmpAAMs = [dict[@"delayAfterEmpAAMs"] intValue];
        if (dict[@"delayAfterS3Ms"]) g_Cfg.delayAfterS3Ms = [dict[@"delayAfterS3Ms"] intValue];
        if (dict[@"delayAfterS1_2Ms"]) g_Cfg.delayAfterS1_2Ms = [dict[@"delayAfterS1_2Ms"] intValue];

        if (dict[@"floatingToggleX"]) g_Cfg.floatingTogglePos[0] = [dict[@"floatingToggleX"] floatValue];
        if (dict[@"floatingToggleY"]) g_Cfg.floatingTogglePos[1] = [dict[@"floatingToggleY"] floatValue];
        if (dict[@"menuToggleX"]) g_Cfg.menuTogglePos[0] = [dict[@"menuToggleX"] floatValue];
        if (dict[@"menuToggleY"]) g_Cfg.menuTogglePos[1] = [dict[@"menuToggleY"] floatValue];
        if (dict[@"quickC1X"]) g_Cfg.quickC1Pos[0] = [dict[@"quickC1X"] floatValue];
        if (dict[@"quickC1Y"]) g_Cfg.quickC1Pos[1] = [dict[@"quickC1Y"] floatValue];
        if (dict[@"quickC2X"]) g_Cfg.quickC2Pos[0] = [dict[@"quickC2X"] floatValue];
        if (dict[@"quickC2Y"]) g_Cfg.quickC2Pos[1] = [dict[@"quickC2Y"] floatValue];
        if (dict[@"quickC3X"]) g_Cfg.quickC3Pos[0] = [dict[@"quickC3X"] floatValue];
        if (dict[@"quickC3Y"]) g_Cfg.quickC3Pos[1] = [dict[@"quickC3Y"] floatValue];
        if (dict[@"quickAAX"]) g_Cfg.quickAAPos[0] = [dict[@"quickAAX"] floatValue];
        if (dict[@"quickAAY"]) g_Cfg.quickAAPos[1] = [dict[@"quickAAY"] floatValue];
        if (dict[@"quickButtonSize"]) g_Cfg.quickButtonSize = [dict[@"quickButtonSize"] floatValue];
        if (dict[@"quickAAButtonSize"]) g_Cfg.quickAAButtonSize = [dict[@"quickAAButtonSize"] floatValue];
        if (dict[@"skill1X"]) g_Cfg.skill1Pos[0] = [dict[@"skill1X"] floatValue];
        if (dict[@"skill1Y"]) g_Cfg.skill1Pos[1] = [dict[@"skill1Y"] floatValue];
        if (dict[@"skill2X"]) g_Cfg.skill2Pos[0] = [dict[@"skill2X"] floatValue];
        if (dict[@"skill2Y"]) g_Cfg.skill2Pos[1] = [dict[@"skill2Y"] floatValue];
        if (dict[@"skill3X"]) g_Cfg.skill3Pos[0] = [dict[@"skill3X"] floatValue];
        if (dict[@"skill3Y"]) g_Cfg.skill3Pos[1] = [dict[@"skill3Y"] floatValue];
        if (dict[@"attackX"]) g_Cfg.attackPos[0] = [dict[@"attackX"] floatValue];
        if (dict[@"attackY"]) g_Cfg.attackPos[1] = [dict[@"attackY"] floatValue];
    }
}

// ============================================================================
// CẤU TRÚC THỊ GIÁC MÁY TÍNH & TRACKER
// ============================================================================
struct TrackedTarget {
    int id = -1;
    CGPoint center = CGPointZero;
    CGPoint velocity = CGPointZero;
    float width = 0.0f;
    int consecutiveFrames = 0;
    int missingFrames = 0;
    int queueSlot = -1;
    TargetClassifier::TargetKind targetType = TargetClassifier::TargetKind::Unknown;
    int level = 0;
    float levelConfidence = 0.0f;
    float hpPercent = 0.0f;
    float detectionConfidence = 0.0f;
};

enum class BotState {
    IDLE,
    SCANNING,
    LOCKED,
    EXECUTING
};

static std::atomic<BotState> g_BotState{BotState::IDLE};
static std::vector<TrackedTarget> g_TrackedTargets;
static int g_CurrentLockedId = -1;
static std::atomic<float> g_VisionMeasuredFps{0.0f};

// ============================================================================
// BỘ TỔNG HỢP CHẠM & VUỐT (IOHIDEVENT + UNITY VIEW TARGETING + NAK COMBOS)
// ============================================================================
namespace TouchEngine {
    static std::atomic<uint64_t> g_HoldGeneration{0};
    static thread_local std::mt19937 rng(std::random_device{}());

    bool HoldIsActive(uint64_t token) {
        return token != 0 && g_HoldGeneration.load(std::memory_order_acquire) == token;
    }

    bool WaitForHold(uint64_t token, int milliseconds) {
        int remaining = std::max(0, milliseconds);
        while (remaining > 0) {
            if (!HoldIsActive(token)) return false;
            int slice = std::min(remaining, 5);
            usleep(slice * 1000);
            remaining -= slice;
        }
        return HoldIsActive(token);
    }
    static NSMutableDictionary<NSNumber *, UITouch *> *g_ActiveTouches = nil;

    CGPoint ApplyJitter(CGPoint pt) {
        const Config cfg = GetConfigSnapshot();
        std::uniform_real_distribution<float> dist(-cfg.posJitterPx, cfg.posJitterPx);
        return CGPointMake(pt.x + dist(rng), pt.y + dist(rng));
    }

    int ApplyDelayJitter(int baseMs) {
        const Config cfg = GetConfigSnapshot();
        std::uniform_int_distribution<int> dist(-cfg.timeJitterMs, cfg.timeJitterMs);
        return std::max(5, baseMs + dist(rng));
    }

    UIView* FindMetalViewInHierarchy(UIView *root) {
        if ([root.layer isKindOfClass:[CAMetalLayer class]] &&
            ![root.layer.name isEqualToString:@"PXOverlayLayer"]) {
            return root;
        }
        for (UIView *sub in root.subviews) {
            UIView *found = FindMetalViewInHierarchy(sub);
            if (found) return found;
        }
        return nil;
    }

    UIWindow* FindGameWindow(UIView **outGameView) {
        UIWindow *fallbackWin = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if ([NSStringFromClass([w class]) isEqualToString:@"PXPassthroughWindow"] || w.hidden) continue;
                    UIView *metalView = FindMetalViewInHierarchy(w);
                    if (metalView) {
                        if (outGameView) *outGameView = metalView;
                        return w;
                    }
                    if (!fallbackWin || w.isKeyWindow) fallbackWin = w;
                }
            }
        }
        if (outGameView && fallbackWin) {
            *outGameView = fallbackWin.rootViewController.view ?: fallbackWin;
        }
        return fallbackWin;
    }

    IOHIDEventRef CreateTouchHIDEvent(UITouchPhase phase, CGPoint point, NSInteger fingerId) {
        uint64_t machTime = mach_absolute_time();
        CGSize screen = CachedScreenPointSize();
        if (screen.width <= 0.0 || screen.height <= 0.0) return nullptr;
        float normX = (float)(point.x / std::max(1.0, screen.width));
        float normY = (float)(point.y / std::max(1.0, screen.height));

        Boolean isTouching = (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved || phase == UITouchPhaseStationary);
        uint32_t eventMask = kIOHIDDigitizerEventPosition;
        if (phase == UITouchPhaseBegan || phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
            eventMask |= (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
        }

        IOHIDEventRef handEvent = IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, machTime, kIOHIDDigitizerTransducerTypeHand,
            0, 0, eventMask, 0,
            normX, normY, 0.0f, 0.0f, 0.0f,
            isTouching, isTouching, 0
        );

        IOHIDEventRef fingerEvent = IOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault, machTime,
            (uint32_t)fingerId, (uint32_t)fingerId,
            eventMask, normX, normY, 0.0f,
            isTouching ? 1.0f : 0.0f, 0.0f,
            isTouching, isTouching, 0
        );

        if (handEvent && fingerEvent) {
            IOHIDEventSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
            IOHIDEventSetIntegerValue(fingerEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
            IOHIDEventAppendEvent(handEvent, fingerEvent, 0);
            CFRelease(fingerEvent);
        }
        return handEvent;
    }

    void DispatchTouchEvent(UITouchPhase phase, CGPoint point, NSInteger fingerId) {
        void (^dispatchBlock)(void) = ^{
            if (!g_ActiveTouches) g_ActiveTouches = [NSMutableDictionary dictionary];

            UIView *targetView = nil;
            UIWindow *gameWin = FindGameWindow(&targetView);
            if (!gameWin || !targetView) return;

            NSNumber *key = @(fingerId);
            UITouch *touch = g_ActiveTouches[key];

            if (phase == UITouchPhaseBegan || !touch) {
                touch = [[UITouch alloc] init];
                g_ActiveTouches[key] = touch;

                UIView *hitView = [targetView hitTest:[gameWin convertPoint:point toView:targetView] withEvent:nil];
                if (!hitView) hitView = targetView;

                SEL setWindowSel = NSSelectorFromString(@"setWindow:");
                SEL setViewSel   = NSSelectorFromString(@"setView:");
                SEL setTapSel    = NSSelectorFromString(@"setTapCount:");
                SEL setIsTapSel  = NSSelectorFromString(@"setIsTap:");

                if ([touch respondsToSelector:setWindowSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(touch, setWindowSel, gameWin);
                }
                if ([touch respondsToSelector:setViewSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(touch, setViewSel, hitView);
                }
                if ([touch respondsToSelector:setTapSel]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(touch, setTapSel, 1);
                }
                if ([touch respondsToSelector:setIsTapSel]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(touch, setIsTapSel, YES);
                }
            }

            IOHIDEventRef hidEvent = CreateTouchHIDEvent(phase, point, fingerId);
            SEL setHidSel   = NSSelectorFromString(@"_setHidEvent:");
            SEL setPhaseSel = NSSelectorFromString(@"setPhase:");
            SEL setTimeSel  = NSSelectorFromString(@"setTimestamp:");
            SEL setLocSel   = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");

            if (hidEvent && [touch respondsToSelector:setHidSel]) {
                ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(touch, setHidSel, hidEvent);
            }
            if ([touch respondsToSelector:setPhaseSel]) {
                ((void (*)(id, SEL, UITouchPhase))objc_msgSend)(touch, setPhaseSel, phase);
            }
            if ([touch respondsToSelector:setTimeSel]) {
                ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(touch, setTimeSel, CACurrentMediaTime());
            }
            if ([touch respondsToSelector:setLocSel]) {
                ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, setLocSel, point, (phase == UITouchPhaseBegan));
            }

            UIApplication *app = [UIApplication sharedApplication];
            SEL touchesEventSel = NSSelectorFromString(@"_touchesEvent");
            if ([app respondsToSelector:touchesEventSel]) {
                UIEvent *event = ((id (*)(id, SEL))objc_msgSend)(app, touchesEventSel);
                if (event) {
                    SEL setEventHidSel = NSSelectorFromString(@"_setHIDEvent:");
                    SEL clearSel       = NSSelectorFromString(@"_clearTouches");
                    SEL addSel         = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");

                    if (hidEvent && [event respondsToSelector:setEventHidSel]) {
                        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(event, setEventHidSel, hidEvent);
                    }
                    if ([event respondsToSelector:clearSel]) {
                        ((void (*)(id, SEL))objc_msgSend)(event, clearSel);
                    }
                    if ([event respondsToSelector:addSel]) {
                        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addSel, touch, NO);
                    }
                    [app sendEvent:event];
                }
            }

            if (hidEvent) {
                CFRelease(hidEvent);
            }

            if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
                [g_ActiveTouches removeObjectForKey:key];
            }
        };

        if ([NSThread isMainThread]) {
            dispatchBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), dispatchBlock);
        }
    }

    void TapAt(const float normPos[2], int holdMs = 30, uint64_t token = 0) {
        CGSize screen = CachedScreenPointSize();
        if (screen.width <= 0.0 || screen.height <= 0.0) return;
        CGPoint pt = ApplyJitter(CGPointMake(normPos[0] * screen.width, normPos[1] * screen.height));
        DispatchTouchEvent(UITouchPhaseBegan, pt, 1);
        bool keepGoing = token == 0
            ? (usleep(ApplyDelayJitter(holdMs) * 1000), true)
            : WaitForHold(token, ApplyDelayJitter(holdMs));
        DispatchTouchEvent(keepGoing ? UITouchPhaseEnded : UITouchPhaseCancelled, pt, 1);
    }

    void SwipeSkillToward(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 50, uint64_t token = 0) {
        CGSize screen = CachedScreenPointSize();
        if (screen.width <= 0.0 || screen.height <= 0.0) return;
        CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
        CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);

        float dx = targetScreenPt.x - playerCenter.x;
        float dy = targetScreenPt.y - playerCenter.y;
        float len = std::hypot(dx, dy);
        if (len < 2.0f) return; // Khong co huong muc tieu hop le, khong tu dong tap theo huong nhin.

        float dragRadius = 56.0f;
        CGPoint endPt = ApplyJitter(CGPointMake(
            startPt.x + (dx / len) * dragRadius,
            startPt.y + (dy / len) * dragRadius
        ));

        DispatchTouchEvent(UITouchPhaseBegan, startPt, 2);
        int steps = 4;
        int stepDelayUs = (ApplyDelayJitter(swipeDurationMs) * 1000) / steps;
        for (int i = 1; i <= steps; ++i) {
            float t = (float)i / (float)steps;
            CGPoint mid = CGPointMake(
                startPt.x + (endPt.x - startPt.x) * t,
                startPt.y + (endPt.y - startPt.y) * t
            );
            bool keepGoing = token == 0
                ? (usleep(stepDelayUs), true)
                : WaitForHold(token, std::max(1, stepDelayUs / 1000));
            if (!keepGoing) {
                DispatchTouchEvent(UITouchPhaseCancelled, mid, 2);
                return;
            }
            DispatchTouchEvent(UITouchPhaseMoved, mid, 2);
        }
        DispatchTouchEvent(UITouchPhaseEnded, endPt, 2);
    }

    void SwipeSkillS2OppositeToward(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 55, uint64_t token = 0) {
        CGSize screen = CachedScreenPointSize();
        if (screen.width <= 0.0 || screen.height <= 0.0) return;
        CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
        CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);

        float dx = targetScreenPt.x - playerCenter.x;
        float dy = targetScreenPt.y - playerCenter.y;
        float len = std::hypot(dx, dy);
        if (len < 2.0f) return; // Khong co huong muc tieu hop le, khong tu dong tap S2.

        float dragRadius = 58.0f;
        CGPoint endPt = ApplyJitter(CGPointMake(
            startPt.x - (dx / len) * dragRadius,
            startPt.y - (dy / len) * dragRadius
        ));

        DispatchTouchEvent(UITouchPhaseBegan, startPt, 2);
        int steps = 4;
        int stepDelayUs = (ApplyDelayJitter(swipeDurationMs) * 1000) / steps;
        for (int i = 1; i <= steps; ++i) {
            float t = (float)i / (float)steps;
            CGPoint mid = CGPointMake(
                startPt.x + (endPt.x - startPt.x) * t,
                startPt.y + (endPt.y - startPt.y) * t
            );
            bool keepGoing = token == 0
                ? (usleep(stepDelayUs), true)
                : WaitForHold(token, std::max(1, stepDelayUs / 1000));
            if (!keepGoing) {
                DispatchTouchEvent(UITouchPhaseCancelled, mid, 2);
                return;
            }
            DispatchTouchEvent(UITouchPhaseMoved, mid, 2);
        }
        DispatchTouchEvent(UITouchPhaseEnded, endPt, 2);
    }

    void SwipeSkillAwayFrom(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 50, uint64_t token = 0) {
        CGSize screen = CachedScreenPointSize();
        if (screen.width <= 0.0 || screen.height <= 0.0) return;
        CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
        CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);

        float dx = targetScreenPt.x - playerCenter.x;
        float dy = targetScreenPt.y - playerCenter.y;
        float len = std::hypot(dx, dy);
        if (len < 2.0f) return; // Khong co huong muc tieu hop le, khong tu dong tap S2.

        float dragRadius = 58.0f;
        CGPoint endPt = ApplyJitter(CGPointMake(
            startPt.x - (dx / len) * dragRadius,
            startPt.y - (dy / len) * dragRadius
        ));

        DispatchTouchEvent(UITouchPhaseBegan, startPt, 2);
        int steps = 4;
        int stepDelayUs = (ApplyDelayJitter(swipeDurationMs) * 1000) / steps;
        for (int i = 1; i <= steps; ++i) {
            float t = (float)i / (float)steps;
            CGPoint mid = CGPointMake(
                startPt.x + (endPt.x - startPt.x) * t,
                startPt.y + (endPt.y - startPt.y) * t
            );
            bool keepGoing = token == 0
                ? (usleep(stepDelayUs), true)
                : WaitForHold(token, std::max(1, stepDelayUs / 1000));
            if (!keepGoing) {
                DispatchTouchEvent(UITouchPhaseCancelled, mid, 2);
                return;
            }
            DispatchTouchEvent(UITouchPhaseMoved, mid, 2);
        }
        DispatchTouchEvent(UITouchPhaseEnded, endPt, 2);
    }

    void RunComboSequence(CGPoint targetPt, NakComboType comboType, uint64_t token) {
        const Config cfg = GetConfigSnapshot();
        auto active = [&]() { return token == 0 || HoldIsActive(token); };
        auto delay = [&](int ms) { return token == 0 ? (usleep(std::max(0, ms) * 1000), true) : WaitForHold(token, ms); };

        switch (comboType) {
            case NakComboType::GANK_LONG_RANGE:
                // C1: S2 -> S1 -> S1 -> S3 -> AA
                if (!active()) return;
                SwipeSkillS2OppositeToward(cfg.skill2Pos, targetPt, 55, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS2Ms))) return;
                SwipeSkillToward(cfg.skill1Pos, targetPt, 50, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS1_1Ms))) return;
                SwipeSkillToward(cfg.skill1Pos, targetPt, 50, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS1_2Ms))) return;
                TapAt(cfg.skill3Pos, 35, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS3Ms))) return;
                if (active()) TapAt(cfg.attackPos, 28, token);
                break;

            case NakComboType::CLOSE_COMBAT:
                // C2: S1 -> AA -> S3 -> S2 -> AA -> S1
                if (!active()) return;
                SwipeSkillToward(cfg.skill1Pos, targetPt, 50, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS1_1Ms))) return;
                TapAt(cfg.attackPos, 28, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterEmpAAMs))) return;
                TapAt(cfg.skill3Pos, 35, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS3Ms))) return;
                SwipeSkillS2OppositeToward(cfg.skill2Pos, targetPt, 55, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS2Ms))) return;
                TapAt(cfg.attackPos, 28, token);
                if (!delay(90)) return;
                if (active()) SwipeSkillToward(cfg.skill1Pos, targetPt, 50, token);
                break;

            case NakComboType::POKE_AND_RUN:
                // C3: S2 -> S1 -> AA -> S1 retreat
                if (!active()) return;
                SwipeSkillS2OppositeToward(cfg.skill2Pos, targetPt, 55, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS2Ms))) return;
                SwipeSkillToward(cfg.skill1Pos, targetPt, 50, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterS1_1Ms))) return;
                TapAt(cfg.attackPos, 30, token);
                if (!delay(ApplyDelayJitter(cfg.delayAfterEmpAAMs))) return;
                if (active()) SwipeSkillAwayFrom(cfg.skill1Pos, targetPt, 50, token);
                break;
        }
    }

    void StartHeldComboForTarget(int targetId, NakComboType comboType) {
        const uint64_t token = g_HoldGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int activeTargetId = targetId;
            while (HoldIsActive(token)) {
                CGPoint targetPt = CGPointZero;
                bool targetPresent = false;
                {
                    std::lock_guard<std::mutex> lock(g_StateMutex);
                    if (activeTargetId < 0) activeTargetId = g_CurrentLockedId;
                    for (const auto& target : g_TrackedTargets) {
                        if (activeTargetId >= 0 && target.id == activeTargetId &&
                            target.missingFrames <= 4 &&
                            target.targetType == TargetClassifier::TargetKind::EnemyHero) {
                            targetPt = CGPointMake(target.center.x, target.center.y + 42.0f);
                            targetPresent = true;
                            break;
                        }
                    }
                }
                if (!targetPresent && activeTargetId < 0) {
                    if (!WaitForHold(token, 50)) break;
                    continue;
                }
                // Keep attacking this exact target; never silently switch to another hero.
                if (!targetPresent) break;
                RunComboSequence(targetPt, comboType, token);
                if (!WaitForHold(token, 70)) break;
            }
            uint64_t expected = token;
            g_HoldGeneration.compare_exchange_strong(expected, token + 1, std::memory_order_acq_rel);
        });
    }

    void StopHeldAction() {
        g_HoldGeneration.fetch_add(1, std::memory_order_acq_rel);
    }

    void ExecuteNakSelectedCombo(CGPoint targetPt, NakComboType comboType, bool isManualTrigger = false) {
        BotState prevState = g_BotState.load();
        if (prevState == BotState::EXECUTING) return;
        if (!isManualTrigger && prevState == BotState::IDLE) return;
        if (!g_BotState.compare_exchange_strong(prevState, BotState::EXECUTING)) return;

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            RunComboSequence(targetPt, comboType, 0);
            usleep(60 * 1000);
            g_BotState.store(GetConfigSnapshot().masterEnable ? BotState::SCANNING : BotState::IDLE);
        });
    }
}

// ============================================================================
// XỬ LÝ THỊ GIÁC MÁY TÍNH (BLIT ENCODER BẤT ĐỒNG BỘ - GIỮ 60 FPS)
// ============================================================================
namespace VisionEngine {
    static dispatch_queue_t g_VisionQueue = dispatch_queue_create("com.px.vision.queue", DISPATCH_QUEUE_SERIAL);
    static std::atomic<bool> g_IsProcessing{false};
    static std::atomic<double> g_LastFrameTime{0.0};
    static int g_NextTargetId = 1;
    static id<MTLBuffer> g_ReadbackBuffer = nil;
    static NSUInteger g_ReadbackBufferSize = 0;
    static std::atomic<int> g_FullScreenScanFrames{0};

    bool ShouldCapture() {
        return g_MasterEnable.load(std::memory_order_acquire) ||
               g_FullScreenScanFrames.load(std::memory_order_acquire) > 0;
    }

    void RequestFullScreenScan() {
        g_FullScreenScanFrames.store(10, std::memory_order_release);
    }

    inline bool IsEnemyHpColor(uint8_t b, uint8_t g, uint8_t r) {
        // Tolerant HSV classification replaces the previous narrow RGB threshold.
        // This is only a red-HP candidate filter; shape and Level validation
        // remain separate stages before a candidate can be confirmed as a hero.
        return HealthBarDetector::IsEnemyHeroRedPixel(b, g, r);
    }

    void ProcessFrameBuffer(const uint8_t* data, int texW, int texH, int stride,
                            float scaleX, float scaleY, CGSize screenPt) {
        if (!data || texW <= 0 || texH <= 0 ||
            scaleX <= 0.0f || scaleY <= 0.0f ||
            screenPt.width <= 0.0 || screenPt.height <= 0.0) {
            g_IsProcessing.store(false, std::memory_order_release);
            return;
        }
        const Config cfg = GetConfigSnapshot();
        const float detectorScale = std::sqrt(scaleX * scaleY);
        const bool fullScreenScan = g_FullScreenScanFrames.load(std::memory_order_acquire) > 0;
        if (fullScreenScan) {
            int remaining = g_FullScreenScanFrames.load(std::memory_order_relaxed);
            while (remaining > 0 &&
                   !g_FullScreenScanFrames.compare_exchange_weak(
                       remaining, remaining - 1, std::memory_order_acq_rel)) {}
        }
        int rx0 = fullScreenScan ? 0 : (int)(cfg.mainScanRoi[0] * texW);
        int ry0 = fullScreenScan ? 0 : (int)(cfg.mainScanRoi[1] * texH);
        int rx1 = fullScreenScan ? texW : std::min(texW, (int)((cfg.mainScanRoi[0] + cfg.mainScanRoi[2]) * texW));
        int ry1 = fullScreenScan ? texH : std::min(texH, (int)((cfg.mainScanRoi[1] + cfg.mainScanRoi[3]) * texH));
        if (rx1 <= rx0 || ry1 <= ry0) {
            g_IsProcessing.store(false);
            return;
        }

        // Detect red hero bars and yellow tower bars separately. Only confirmed
        // or provisional hero observations are allowed into the hero tracker.
        static std::atomic<uint64_t> frameSequence{0};
        const bool runLevelOCR =
            (frameSequence.fetch_add(1, std::memory_order_relaxed) % 4u) == 0u;
        auto observations = HealthBarSegmenter::Detect(
            data, texW, texH, stride, detectorScale, rx0, ry0, rx1, ry1,
            runLevelOCR, cfg.standardHpWidth);

        // Convert the detector's isotropic point estimate with the actual
        // horizontal and vertical drawable-to-view scales independently.
        const float xCorrection = detectorScale / scaleX;
        const float yCorrection = detectorScale / scaleY;
        for (auto& observation : observations) {
            observation.left *= xCorrection;
            observation.width *= xCorrection;
            observation.top *= yCorrection;
            observation.height *= yCorrection;
        }

        struct RawTarget {
            CGPoint centerPt;
            float widthPt;
            int level;
            float levelConfidence;
            bool levelOCRAttempted;
            float hpPercent;
            float confidence;
        };
        std::vector<RawTarget> detectedTargets;
        detectedTargets.reserve(observations.size());

        for (const auto& observation : observations) {
            if (observation.kind != TargetClassifier::TargetKind::EnemyHero) continue;
            if (observation.confidence < 0.50f) continue;

            detectedTargets.push_back({
                CGPointMake(observation.left + observation.width * 0.5f,
                            observation.top + observation.height * 0.5f),
                observation.width,
                observation.level,
                observation.levelConfidence,
                observation.levelOCRAttempted,
                observation.hpPercent,
                observation.confidence
            });
        }

        std::lock_guard<std::mutex> lock(g_StateMutex);
        for (auto& target : g_TrackedTargets) {
            target.missingFrames++;
        }

        std::vector<bool> matched(g_TrackedTargets.size(), false);
        for (const auto& observation : detectedTargets) {
            int bestIdx = -1;
            float bestDist = 48.0f;

            for (size_t i = 0; i < g_TrackedTargets.size(); ++i) {
                if (matched[i]) continue;
                const auto& tracked = g_TrackedTargets[i];
                // A nearby bar must not inherit a clearly incompatible level
                // from a different hero's track. One-level upward changes are
                // allowed to account for normal in-game level progression.
                if (observation.level > 0 && tracked.level > 0 &&
                    (observation.level < tracked.level ||
                     observation.level > tracked.level + 1)) {
                    continue;
                }
                CGPoint predicted = CGPointMake(
                    tracked.center.x + tracked.velocity.x,
                    tracked.center.y + tracked.velocity.y
                );
                const float distance = std::hypot(
                    observation.centerPt.x - predicted.x,
                    observation.centerPt.y - predicted.y);
                if (distance < bestDist) {
                    bestDist = distance;
                    bestIdx = (int)i;
                }
            }

            if (bestIdx >= 0) {
                auto& target = g_TrackedTargets[(size_t)bestIdx];
                matched[(size_t)bestIdx] = true;
                target.velocity = CGPointMake(
                    observation.centerPt.x - target.center.x,
                    observation.centerPt.y - target.center.y);
                target.center = observation.centerPt;
                target.width = observation.widthPt;
                target.targetType = TargetClassifier::TargetKind::EnemyHero;
                bool targetIdentityChanged = false;
                if (observation.levelOCRAttempted) {
                    if (observation.level >= 1 && observation.level <= 16 &&
                        observation.levelConfidence >= 0.45f) {
                        targetIdentityChanged =
                            target.level != observation.level;
                        target.level = observation.level;
                        target.levelConfidence = observation.levelConfidence;
                    } else {
                        // An attempted but failed OCR read invalidates the
                        // cached label; never keep a previous hero's level.
                        targetIdentityChanged = target.level != 0;
                        target.level = 0;
                        target.levelConfidence = 0.0f;
                    }
                }
                // Do not blend a newly identified hero with the previous
                // track's HP estimate; that can preserve a stale 20% reading.
                target.hpPercent = (target.consecutiveFrames > 0 && !targetIdentityChanged)
                    ? (target.hpPercent * 0.25f + observation.hpPercent * 0.75f)
                    : observation.hpPercent;
                target.detectionConfidence = observation.confidence;
                target.consecutiveFrames++;
                target.missingFrames = 0;
            } else {
                TrackedTarget newTarget;
                newTarget.id = g_NextTargetId++;
                newTarget.center = observation.centerPt;
                newTarget.velocity = CGPointZero;
                newTarget.width = observation.widthPt;
                newTarget.consecutiveFrames = 1;
                newTarget.missingFrames = 0;
                newTarget.queueSlot = -1;
                newTarget.targetType = TargetClassifier::TargetKind::EnemyHero;
                newTarget.level = observation.level;
                newTarget.levelConfidence = observation.levelConfidence;
                newTarget.hpPercent = observation.hpPercent;
                newTarget.detectionConfidence = observation.confidence;
                g_TrackedTargets.push_back(newTarget);
                matched.push_back(true);
            }
        }

        g_TrackedTargets.erase(
            std::remove_if(g_TrackedTargets.begin(), g_TrackedTargets.end(),
                [](const TrackedTarget& target) {
                    if (target.missingFrames > 4) {
                        if (target.id == g_CurrentLockedId) g_CurrentLockedId = -1;
                        return true;
                    }
                    return false;
                }),
            g_TrackedTargets.end()
        );

        CGPoint screenCenter = CGPointMake(screenPt.width * 0.5f, screenPt.height * 0.5f);
        std::vector<TargetSelector::Candidate> selectionCandidates;
        selectionCandidates.reserve(g_TrackedTargets.size());
        for (const auto& target : g_TrackedTargets) {
            TargetSelector::Candidate candidate;
            candidate.id = target.id;
            candidate.hpPercent = target.hpPercent;
            candidate.confidence = target.detectionConfidence;
            candidate.centerDistance = std::hypot(
                target.center.x - screenCenter.x,
                target.center.y - screenCenter.y);
            candidate.level = target.level;
            candidate.consecutiveFrames = target.consecutiveFrames;
            candidate.missingFrames = target.missingFrames;
            candidate.isEnemyHero =
                target.targetType == TargetClassifier::TargetKind::EnemyHero;
            selectionCandidates.push_back(candidate);
        }

        const int selectedIndex = TargetSelector::SelectLowestHP(
            selectionCandidates,
            cfg.minConfirmFrames,
            0.75f,
            g_CurrentLockedId,
            1.0f);
        TrackedTarget* chosenTarget = selectedIndex >= 0
            ? &g_TrackedTargets[(size_t)selectedIndex]
            : nullptr;

        if (chosenTarget) g_CurrentLockedId = chosenTarget->id;
        else g_CurrentLockedId = -1;

        if (chosenTarget && chosenTarget->level > 0 &&
            chosenTarget->detectionConfidence >= 0.75f &&
            cfg.autoEngage && g_BotState.load() != BotState::EXECUTING) {
            g_BotState.store(BotState::LOCKED);
            CGPoint bodyAimPoint = CGPointMake(
                chosenTarget->center.x, chosenTarget->center.y + 42.0f);
            TouchEngine::ExecuteNakSelectedCombo(
                bodyAimPoint, cfg.selectedCombo, false);
        }

        // Measure the effective Vision processing rate over a rolling one-second window.
        static CFTimeInterval fpsWindowStart = CACurrentMediaTime();
        static int fpsWindowFrames = 0;
        ++fpsWindowFrames;
        const CFTimeInterval fpsNow = CACurrentMediaTime();
        const CFTimeInterval fpsElapsed = fpsNow - fpsWindowStart;
        if (fpsElapsed >= 1.0) {
            g_VisionMeasuredFps.store((float)fpsWindowFrames / (float)fpsElapsed,
                                      std::memory_order_relaxed);
            fpsWindowFrames = 0;
            fpsWindowStart = fpsNow;
        }

        g_IsProcessing.store(false);
    }

    void SubmitMetalTextureAsync(id<MTLTexture> texture,
                                  id<MTLCommandBuffer> commandBuffer) {
        if (!ShouldCapture() || !texture || !commandBuffer) return;
        if (texture.pixelFormat != MTLPixelFormatBGRA8Unorm) return;

        const double now = CACurrentMediaTime();
        const int captureFps = std::max(1, g_CaptureFps.load(std::memory_order_acquire));
        const double minInterval = 1.0 / (double)captureFps;
        const double previousFrameTime = g_LastFrameTime.load(std::memory_order_relaxed);
        if ((now - previousFrameTime) < minInterval) return;
        if (g_IsProcessing.exchange(true, std::memory_order_acq_rel)) return;

        auto releaseProcessing = [] {
            g_IsProcessing.store(false, std::memory_order_release);
        };

        const int w = (int)texture.width;
        const int h = (int)texture.height;
        const CGSize screenPt = CachedScreenPointSize();
        if (w <= 0 || h <= 0 || screenPt.width <= 0.0 || screenPt.height <= 0.0 ||
            (NSUInteger)w > NSUIntegerMax / 4) {
            releaseProcessing();
            return;
        }

        const float scaleX = (float)w / (float)screenPt.width;
        const float scaleY = (float)h / (float)screenPt.height;
        if (!std::isfinite(scaleX) || !std::isfinite(scaleY) ||
            scaleX <= 0.0f || scaleY <= 0.0f) {
            releaseProcessing();
            return;
        }

        const NSUInteger bytesPerRow = (NSUInteger)w * 4;
        if ((NSUInteger)h > NSUIntegerMax / bytesPerRow) {
            releaseProcessing();
            return;
        }
        const NSUInteger totalBytes = bytesPerRow * (NSUInteger)h;

        id<MTLDevice> device = texture.device;
        if (!device || commandBuffer.commandQueue.device != device) {
            releaseProcessing();
            return;
        }

        if (!g_ReadbackBuffer || g_ReadbackBufferSize < totalBytes ||
            g_ReadbackBuffer.device != device) {
            id<MTLBuffer> newBuffer =
                [device newBufferWithLength:totalBytes options:MTLResourceStorageModeShared];
            if (!newBuffer) {
                releaseProcessing();
                return;
            }
            g_ReadbackBuffer = newBuffer;
            g_ReadbackBufferSize = totalBytes;
        }

        id<MTLBuffer> readbackBuffer = g_ReadbackBuffer;
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (!blit) {
            releaseProcessing();
            return;
        }

        // Encode on the presenting command buffer: render writes are ordered
        // before this blit, and presentation waits for the command buffer.
        [blit copyFromTexture:texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(w, h, 1)
                     toBuffer:readbackBuffer
            destinationOffset:0
       destinationBytesPerRow:bytesPerRow
     destinationBytesPerImage:totalBytes];
        [blit endEncoding];

        g_LastFrameTime.store(now, std::memory_order_relaxed);
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
            if (buffer.status == MTLCommandBufferStatusCompleted) {
                const uint8_t* ptr = (const uint8_t*)[readbackBuffer contents];
                if (ptr) {
                    dispatch_async(g_VisionQueue, ^{
                        ProcessFrameBuffer(ptr, w, h, (int)bytesPerRow,
                                           scaleX, scaleY, screenPt);
                    });
                    return;
                }
            }
            releaseProcessing();
        }];
    }
}

// ============================================================================
static void (*orig_commandBufferCommit)(id, SEL) = nullptr;

static void hooked_commandBufferCommit(id self, SEL _cmd) {
    SEL presentedDrawableSel = sel_registerName("presentedDrawable");
    if (VisionEngine::ShouldCapture() && [self respondsToSelector:presentedDrawableSel]) {
        id<CAMetalDrawable> drawable =
            ((id (*)(id, SEL))objc_msgSend)(self, presentedDrawableSel);
        CAMetalLayer *layer = drawable.layer;
        if (drawable.texture && layer && ![layer.name isEqualToString:@"PXOverlayLayer"]) {
            VisionEngine::SubmitMetalTextureAsync(drawable.texture,
                                                  (id<MTLCommandBuffer>)self);
        }
    }
    if (orig_commandBufferCommit) orig_commandBufferCommit(self, _cmd);
}

static void InstallCommandBufferCommitHook(id<MTLDevice> device) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> probe = [queue commandBuffer];
        if (!probe) return;

        Class commandBufferClass = object_getClass(probe);
        Method commitMethod = class_getInstanceMethod(commandBufferClass, @selector(commit));
        if (!commandBufferClass || !commitMethod) return;

        orig_commandBufferCommit = (void (*)(id, SEL))method_getImplementation(commitMethod);
        const char *types = method_getTypeEncoding(commitMethod);
        if (!class_addMethod(commandBufferClass, @selector(commit),
                             (IMP)hooked_commandBufferCommit, types)) {
            method_setImplementation(commitMethod, (IMP)hooked_commandBufferCommit);
        }
    });
}

// SWIZZLE CAMETALLAYER
// ============================================================================
static id<CAMetalDrawable> (*orig_nextDrawable)(id self, SEL _cmd);
static void (*orig_setFramebufferOnly)(id self, SEL _cmd, BOOL flag);

static void hooked_setFramebufferOnly(id self, SEL _cmd, BOOL flag) {
    orig_setFramebufferOnly(self, _cmd, VisionEngine::ShouldCapture() ? NO : flag);
}

static id<CAMetalDrawable> hooked_nextDrawable(id self, SEL _cmd) {
    CALayer *layer = (CALayer *)self;
    if (![layer.name isEqualToString:@"PXOverlayLayer"] && [self respondsToSelector:@selector(framebufferOnly)]) {
        BOOL fbOnly = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(framebufferOnly));
        BOOL desiredFbOnly = VisionEngine::ShouldCapture() ? NO : YES;
        if (fbOnly != desiredFbOnly && orig_setFramebufferOnly) {
            orig_setFramebufferOnly(self, @selector(setFramebufferOnly:), desiredFbOnly);
        }
    }

    id<CAMetalDrawable> drawable = orig_nextDrawable(self, _cmd);
    if (drawable && drawable.texture && VisionEngine::ShouldCapture() &&
        ![layer.name isEqualToString:@"PXOverlayLayer"]) {
        InstallCommandBufferCommitHook(drawable.texture.device);
    }
    return drawable;
}

// ============================================================================
// OVERLAY WINDOW & IMGUI RENDERER (ĐÃ SỬA ĐÓNG/MỞ MENU BẰNG NÚT PX & DẤU X)
// ============================================================================
static CGRect g_ImGuiWindowRect = CGRectZero;

@interface PXPassthroughWindow : UIWindow
@end
@implementation PXPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!hitView) return nil;

    // Luôn ưu tiên bắt chạm cho các nút nổi (OFF/ON, PX, C1, C2, C3) trước ImGui
    if (hitView.tag == 999 || (hitView.superview && hitView.superview.tag == 999)) {
        return hitView;
    }

    if (!g_ShowImGuiMenu) return nil;
    if (!CGRectIsEmpty(g_ImGuiWindowRect) && CGRectContainsPoint(g_ImGuiWindowRect, point)) return hitView;
    if (ImGui::GetCurrentContext() != nullptr && ImGui::GetIO().WantCaptureMouse) return hitView;
    return nil;
}
@end

@interface PXOverlayController : UIViewController <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) BOOL imguiInitialized;
@property (nonatomic, strong) UIButton *floatingToggleBtn;
@property (nonatomic, strong) UIButton *menuToggleBtn;
@property (nonatomic, strong) UIButton *btnC1;
@property (nonatomic, strong) UIButton *btnC2;
@property (nonatomic, strong) UIButton *btnC3;
@property (nonatomic, strong) UIButton *btnAA;
@property (nonatomic, strong) UIButton *skillMarker1;
@property (nonatomic, strong) UIButton *skillMarker2;
@property (nonatomic, strong) UIButton *skillMarker3;
@end

@implementation PXOverlayController

// Giữ riêng giao diện overlay/menu ở chế độ ngang.
// Không thay đổi orientation policy của ứng dụng game chủ.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    UpdateCachedScreenPointSize(self.view.bounds.size);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"[PXOverlay] Metal device unavailable");
        return;
    }
    self.commandQueue = [device newCommandQueue];
    if (!self.commandQueue) {
        NSLog(@"[PXOverlay] Metal command queue creation failed");
        return;
    }

    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.mtkView.opaque = NO;
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    self.mtkView.layer.name = @"PXOverlayLayer";
    [self.view addSubview:self.mtkView];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().WindowRounding = 8.0f;
    ImGui::GetStyle().FrameRounding = 4.0f;
    self.imguiInitialized = ImGui_ImplMetal_Init(device);
    if (!self.imguiInitialized) {
        NSLog(@"[PXOverlay] ImGui Metal backend initialization failed");
        ImGui::DestroyContext();
        return;
    }

    self.floatingToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingToggleBtn.tag = 999;
    self.floatingToggleBtn.frame = CGRectMake(24, 110, 46, 46);
    self.floatingToggleBtn.layer.cornerRadius = 23;
    self.floatingToggleBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:GetConfigSnapshot().uiOpacity];
    [self.floatingToggleBtn setTitle:@"OFF" forState:UIControlStateNormal];
    self.floatingToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [self.floatingToggleBtn addTarget:self action:@selector(onToggleBot) forControlEvents:UIControlEventTouchUpInside];
    [self makeDraggable:self.floatingToggleBtn];
    [self.view addSubview:self.floatingToggleBtn];

    self.menuToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.menuToggleBtn.tag = 999;
    self.menuToggleBtn.frame = CGRectMake(78, 110, 46, 46);
    self.menuToggleBtn.layer.cornerRadius = 23;
    self.menuToggleBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.20 alpha:GetConfigSnapshot().uiOpacity];
    [self.menuToggleBtn setTitle:@"PX" forState:UIControlStateNormal];
    self.menuToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.menuToggleBtn addTarget:self action:@selector(onToggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self makeDraggable:self.menuToggleBtn];
    [self.view addSubview:self.menuToggleBtn];

    self.btnC1 = [self createQuickButton:@"C1" frame:CGRectMake(132, 110, 42, 42) combo:NakComboType::GANK_LONG_RANGE];
    self.btnC2 = [self createQuickButton:@"C2" frame:CGRectMake(180, 110, 42, 42) combo:NakComboType::CLOSE_COMBAT];
    self.btnC3 = [self createQuickButton:@"C3" frame:CGRectMake(228, 110, 42, 42) combo:NakComboType::POKE_AND_RUN];
    self.btnAA = [self createQuickButton:@"AA" frame:CGRectMake(276, 110, 42, 42) combo:NakComboType::GANK_LONG_RANGE];

    // Ba dau moc tron vang la toa do cham/vuot skill that trong game.
    self.skillMarker1 = [self createSkillMarker:@"S1"];
    self.skillMarker2 = [self createSkillMarker:@"S2"];
    self.skillMarker3 = [self createSkillMarker:@"S3"];

    [self updateQuickButtonHighlights];

    UITapGestureRecognizer *stealthTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onStealthGesture)];
    stealthTap.numberOfTouchesRequired = 3;
    stealthTap.numberOfTapsRequired = 2;
    stealthTap.cancelsTouchesInView = NO;
    stealthTap.delaysTouchesEnded = NO;
    [self.view addGestureRecognizer:stealthTap];

    ConfigStorage::LoadPreset("default");
    [self syncControlButtonFramesFromConfig];
    [self updateQuickButtonHighlights];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UpdateCachedScreenPointSize(self.view.bounds.size);
    [self syncControlButtonFramesFromConfig];
}

- (void)syncControlButtonFramesFromConfig {
    std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
    const Config cfg = g_Cfg;
    CGSize size = self.view.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0) return;
    const CGFloat d = 42.0f;
    self.floatingToggleBtn.center = CGPointMake(cfg.floatingTogglePos[0] * size.width, cfg.floatingTogglePos[1] * size.height);
    self.menuToggleBtn.center = CGPointMake(cfg.menuTogglePos[0] * size.width, cfg.menuTogglePos[1] * size.height);
    self.btnC1.center = CGPointMake(cfg.quickC1Pos[0] * size.width, cfg.quickC1Pos[1] * size.height);
    self.btnC2.center = CGPointMake(cfg.quickC2Pos[0] * size.width, cfg.quickC2Pos[1] * size.height);
    self.btnC3.center = CGPointMake(cfg.quickC3Pos[0] * size.width, cfg.quickC3Pos[1] * size.height);
    self.btnAA.center = CGPointMake(cfg.quickAAPos[0] * size.width, cfg.quickAAPos[1] * size.height);
    const CGFloat quickD = MAX(30.0f, MIN(72.0f, cfg.quickButtonSize));
    const CGFloat aaD = MAX(30.0f, MIN(88.0f, cfg.quickAAButtonSize));
    self.btnC1.bounds = CGRectMake(0, 0, quickD, quickD);
    self.btnC2.bounds = CGRectMake(0, 0, quickD, quickD);
    self.btnC3.bounds = CGRectMake(0, 0, quickD, quickD);
    self.btnAA.bounds = CGRectMake(0, 0, aaD, aaD);
    self.btnC1.layer.cornerRadius = quickD * 0.5f;
    self.btnC2.layer.cornerRadius = quickD * 0.5f;
    self.btnC3.layer.cornerRadius = quickD * 0.5f;
    self.btnAA.layer.cornerRadius = aaD * 0.5f;
    self.skillMarker1.center = CGPointMake(cfg.skill1Pos[0] * size.width, cfg.skill1Pos[1] * size.height);
    self.skillMarker2.center = CGPointMake(cfg.skill2Pos[0] * size.width, cfg.skill2Pos[1] * size.height);
    self.skillMarker3.center = CGPointMake(cfg.skill3Pos[0] * size.width, cfg.skill3Pos[1] * size.height);
    self.floatingToggleBtn.alpha = cfg.uiOpacity;
    self.menuToggleBtn.alpha = cfg.uiOpacity;
    self.btnC1.alpha = cfg.uiOpacity;
    self.btnC2.alpha = cfg.uiOpacity;
    self.btnC3.alpha = cfg.uiOpacity;
    self.btnAA.alpha = cfg.uiOpacity;
    self.skillMarker1.hidden = !g_ShowImGuiMenu;
    self.skillMarker2.hidden = !g_ShowImGuiMenu;
    self.skillMarker3.hidden = !g_ShowImGuiMenu;
}

- (UIButton *)createSkillMarker:(NSString *)title {
    UIButton *marker = [UIButton buttonWithType:UIButtonTypeCustom];
    marker.tag = 999;
    marker.bounds = CGRectMake(0, 0, 38, 38);
    marker.layer.cornerRadius = 19;
    marker.layer.borderWidth = 2.0f;
    marker.layer.borderColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.10 alpha:1.0].CGColor;
    marker.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.0 alpha:0.78];
    [marker setTitle:title forState:UIControlStateNormal];
    marker.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [marker setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    marker.hidden = YES;
    [self makeDraggable:marker];
    [self.view addSubview:marker];
    return marker;
}

- (UIButton *)createQuickButton:(NSString *)title frame:(CGRect)frame combo:(NakComboType)combo {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = 999;
    btn.frame = frame;
    btn.layer.cornerRadius = 21;
    btn.backgroundColor = [UIColor colorWithRed:0.20 green:0.20 blue:0.30 alpha:GetConfigSnapshot().uiOpacity];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    if ([title isEqualToString:@"AA"]) {
        [btn addTarget:self action:@selector(onQuickAAStart:) forControlEvents:UIControlEventTouchDown];
        [btn addTarget:self action:@selector(onQuickAAStop:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    } else {
        [btn addTarget:self action:@selector(onQuickComboTap:) forControlEvents:UIControlEventTouchUpInside];
    }
    objc_setAssociatedObject(btn, "comboType", @((int)combo), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self makeDraggable:btn];
    [self.view addSubview:btn];
    return btn;
}

- (UIButton *)makeDraggable:(UIButton *)btn {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onButtonPan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    [btn addGestureRecognizer:pan];
    return btn;
}

- (void)onButtonPan:(UIPanGestureRecognizer *)pan {
    // Chỉ cho phép sắp xếp vị trí khi menu PX đang mở.
    if (!g_ShowImGuiMenu) return;

    UIView *btn = pan.view;
    CGPoint translation = [pan translationInView:self.view];
    CGPoint newCenter = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);

    CGSize screen = self.view.bounds.size;
    newCenter.x = MAX(25, MIN(screen.width - 25, newCenter.x));
    newCenter.y = MAX(25, MIN(screen.height - 25, newCenter.y));

    btn.center = newCenter;
    [pan setTranslation:CGPointZero inView:self.view];

    // The floating skill controls also define the in-game touch coordinates.
    std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
    const float nx = (float)(newCenter.x / MAX(1.0, screen.width));
    const float ny = (float)(newCenter.y / MAX(1.0, screen.height));
    if (btn == self.floatingToggleBtn) {
        g_Cfg.floatingTogglePos[0] = nx; g_Cfg.floatingTogglePos[1] = ny;
    } else if (btn == self.menuToggleBtn) {
        g_Cfg.menuTogglePos[0] = nx; g_Cfg.menuTogglePos[1] = ny;
    } else if (btn == self.btnC1) {
        g_Cfg.quickC1Pos[0] = nx; g_Cfg.quickC1Pos[1] = ny;
    } else if (btn == self.btnC2) {
        g_Cfg.quickC2Pos[0] = nx; g_Cfg.quickC2Pos[1] = ny;
    } else if (btn == self.btnC3) {
        g_Cfg.quickC3Pos[0] = nx; g_Cfg.quickC3Pos[1] = ny;
    } else if (btn == self.btnAA) {
        g_Cfg.quickAAPos[0] = nx; g_Cfg.quickAAPos[1] = ny;
    } else if (btn == self.skillMarker1) {
        g_Cfg.skill1Pos[0] = nx; g_Cfg.skill1Pos[1] = ny;
    } else if (btn == self.skillMarker2) {
        g_Cfg.skill2Pos[0] = nx; g_Cfg.skill2Pos[1] = ny;
    } else if (btn == self.skillMarker3) {
        g_Cfg.skill3Pos[0] = nx; g_Cfg.skill3Pos[1] = ny;
    }
}

- (CGPoint)currentAimPoint {
    CGPoint aimPt = CGPointZero;
    std::lock_guard<std::mutex> lock(g_StateMutex);
    for (const auto& t : g_TrackedTargets) {
        if (t.id == g_CurrentLockedId) {
            aimPt = CGPointMake(t.center.x, t.center.y + 42.0f);
            break;
        }
    }
    return aimPt;
}

- (int)currentLockedTargetId {
    std::lock_guard<std::mutex> lock(g_StateMutex);
    return g_CurrentLockedId;
}

- (void)onQuickComboTap:(UIButton *)sender {
    std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
    int comboInt = [objc_getAssociatedObject(sender, "comboType") intValue];
    if (comboInt < 1 || comboInt > 3) return;
    g_Cfg.selectedCombo = (NakComboType)comboInt;
    [self updateQuickButtonHighlights];
}

- (void)onQuickAAStart:(UIButton *)sender {
    const Config cfg = GetConfigSnapshot();
    if (!cfg.masterEnable) {
        objc_setAssociatedObject(sender, "isActive", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self updateQuickButtonHighlights];
        return;
    }
    const int targetId = [self currentLockedTargetId];
    objc_setAssociatedObject(sender, "isActive", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // If Vision is still confirming the target, the held-AA worker waits for its lock.
    TouchEngine::StartHeldComboForTarget(targetId, cfg.selectedCombo);
    [self updateQuickButtonHighlights];
}

- (void)onQuickAAStop:(UIButton *)sender {
    TouchEngine::StopHeldAction();
    objc_setAssociatedObject(sender, "isActive", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateQuickButtonHighlights];
}

- (void)updateQuickButtonHighlights {
    const Config cfg = GetConfigSnapshot();
    UIColor *stoppedCol = [UIColor colorWithRed:0.82 green:0.12 blue:0.16 alpha:cfg.uiOpacity];
    UIColor *activeCol = [UIColor colorWithRed:0.10 green:0.75 blue:0.35 alpha:cfg.uiOpacity];
    UIButton *comboButtons[] = { self.btnC1, self.btnC2, self.btnC3 };
    for (int i = 0; i < 3; ++i) {
        NakComboType type = (NakComboType)(i + 1);
        comboButtons[i].backgroundColor = (cfg.selectedCombo == type) ? activeCol : stoppedCol;
        comboButtons[i].hidden = self.floatingToggleBtn.hidden || !cfg.showQuickComboBtns;
    }
    self.btnAA.backgroundColor =
        [objc_getAssociatedObject(self.btnAA, "isActive") boolValue] ? activeCol : stoppedCol;
    self.btnAA.hidden = self.floatingToggleBtn.hidden || !cfg.showQuickComboBtns;
    BOOL hideMarkers = self.floatingToggleBtn.hidden || !g_ShowImGuiMenu;
    self.skillMarker1.hidden = hideMarkers;
    self.skillMarker2.hidden = hideMarkers;
    self.skillMarker3.hidden = hideMarkers;
}

- (void)onToggleBot {
    std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
    g_Cfg.masterEnable = !g_Cfg.masterEnable;
    g_MasterEnable.store(g_Cfg.masterEnable, std::memory_order_release);
    if (!g_Cfg.masterEnable) {
        TouchEngine::StopHeldAction();
        objc_setAssociatedObject(self.btnAA, "isActive", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self updateQuickButtonHighlights];
    }
    g_BotState.store(g_Cfg.masterEnable ? BotState::SCANNING : BotState::IDLE);

    [self.floatingToggleBtn setTitle:(g_Cfg.masterEnable ? @"ON" : @"OFF") forState:UIControlStateNormal];
    self.floatingToggleBtn.backgroundColor = g_Cfg.masterEnable
        ? [UIColor colorWithRed:0.10 green:0.75 blue:0.35 alpha:g_Cfg.uiOpacity]
        : [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:g_Cfg.uiOpacity];
}

- (void)onToggleMenu {
    g_ShowImGuiMenu = !g_ShowImGuiMenu;
    if (!g_ShowImGuiMenu) {
        g_ImGuiWindowRect = CGRectZero;
        g_ImGuiMouseReleasePending.store(false, std::memory_order_release);
        if (self.imguiInitialized && ImGui::GetCurrentContext() != nullptr) {
            ImGuiIO &io = ImGui::GetIO();
            io.AddMouseButtonEvent(0, false);
        }
    }
    [self.view bringSubviewToFront:self.floatingToggleBtn];
    [self.view bringSubviewToFront:self.menuToggleBtn];
    [self.view bringSubviewToFront:self.btnC1];
    [self.view bringSubviewToFront:self.btnC2];
    [self.view bringSubviewToFront:self.btnC3];
    [self.view bringSubviewToFront:self.btnAA];
    if (g_ShowImGuiMenu) {
        [self.view bringSubviewToFront:self.skillMarker1];
        [self.view bringSubviewToFront:self.skillMarker2];
        [self.view bringSubviewToFront:self.skillMarker3];
    }
    [self updateQuickButtonHighlights];
}

- (void)onStealthGesture {
    const Config cfg = GetConfigSnapshot();
    BOOL hide = !self.floatingToggleBtn.hidden;
    self.floatingToggleBtn.hidden = hide;
    self.menuToggleBtn.hidden = hide;
    self.btnC1.hidden = hide || !cfg.showQuickComboBtns;
    self.btnC2.hidden = hide || !cfg.showQuickComboBtns;
    self.btnC3.hidden = hide || !cfg.showQuickComboBtns;
    self.btnAA.hidden = hide || !cfg.showQuickComboBtns;
    if (hide) {
        TouchEngine::StopHeldAction();
        objc_setAssociatedObject(self.btnAA, "isActive", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self updateQuickButtonHighlights];
    }
    if (hide) {
        g_ShowImGuiMenu = false;
        g_ImGuiWindowRect = CGRectZero;
        self.skillMarker1.hidden = YES;
        self.skillMarker2.hidden = YES;
        self.skillMarker3.hidden = YES;
    }
}

- (void)updateImGuiTouch:(NSSet<UITouch *> *)touches phase:(UITouchPhase)phase {
    if (!g_ShowImGuiMenu || !self.imguiInitialized || ImGui::GetCurrentContext() == nullptr) return;
    UITouch *touch = [touches anyObject];
    if (!touch) return;
    CGPoint loc = [touch locationInView:self.mtkView];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)loc.x, (float)loc.y);
    if (phase == UITouchPhaseBegan) {
        g_ImGuiMousePressFrame.store(
            g_ImGuiFrameCounter.load(std::memory_order_acquire),
            std::memory_order_release);
        g_ImGuiMouseReleasePending.store(false, std::memory_order_release);
        io.AddMouseButtonEvent(0, true);
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        // Defer release until the press has been consumed by at least one
        // ImGui frame; a very short tap must not collapse into one frame.
        g_ImGuiMouseReleasePending.store(true, std::memory_order_release);
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseBegan]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseMoved]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseEnded]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseCancelled]; }

- (void)RenderImGuiTabs {
    std::lock_guard<std::recursive_mutex> configLock(g_ConfigMutex);
    ImGui::SetNextWindowSize(ImVec2(480, 380), ImGuiCond_FirstUseEver);
    if (!ImGui::Begin("PX · Nak Quick Combos", &g_ShowImGuiMenu, ImGuiWindowFlags_NoCollapse)) {
        if (!g_ShowImGuiMenu) {
            g_ImGuiWindowRect = CGRectZero;
            self.skillMarker1.hidden = YES;
            self.skillMarker2.hidden = YES;
            self.skillMarker3.hidden = YES;
        } else {
            ImVec2 pos = ImGui::GetWindowPos();
            ImVec2 size = ImGui::GetWindowSize();
            g_ImGuiWindowRect = CGRectMake(pos.x, pos.y, size.x, size.y);
        }
        ImGui::End();
        return;
    }

    if (!g_ShowImGuiMenu) {
        g_ImGuiWindowRect = CGRectZero;
        self.skillMarker1.hidden = YES;
        self.skillMarker2.hidden = YES;
        self.skillMarker3.hidden = YES;
        ImGui::End();
        return;
    }

    ImVec2 pos = ImGui::GetWindowPos();
    ImVec2 size = ImGui::GetWindowSize();
    g_ImGuiWindowRect = CGRectMake(pos.x, pos.y, size.x, size.y);

    if (ImGui::BeginTabBar("PXNakTabs")) {
        if (ImGui::BeginTabItem("Combo & Nut Nhanh")) {
            ImGui::Checkbox("Auto-Engage (Tu dong khi khoa muc tieu)", &g_Cfg.autoEngage);
            if (ImGui::Checkbox("Hien thi cum 3 nut C1 C2 C3 tren man hinh", &g_Cfg.showQuickComboBtns)) {
                [self updateQuickButtonHighlights];
            }
            ImGui::Separator();
            ImGui::Text("Chon Loai Combo & Mo Ta Chi Tiet:");

            int comboVal = (int)g_Cfg.selectedCombo;
            if (ImGui::RadioButton("C1: Gank tu xa", &comboVal, 1)) {
                g_Cfg.selectedCombo = NakComboType::GANK_LONG_RANGE;
                [self updateQuickButtonHighlights];
            }
            ImGui::SameLine(); ImGui::TextDisabled("(S2 -> S1 -> S1 -> S3 -> AA)");

            if (ImGui::RadioButton("C2: Dich o gan", &comboVal, 2)) {
                g_Cfg.selectedCombo = NakComboType::CLOSE_COMBAT;
                [self updateQuickButtonHighlights];
            }
            ImGui::SameLine(); ImGui::TextDisabled("(S1 -> AA -> S3 -> S2 -> AA -> S1)");

            if (ImGui::RadioButton("C3: Cau ria / Rut lui", &comboVal, 3)) {
                g_Cfg.selectedCombo = NakComboType::POKE_AND_RUN;
                [self updateQuickButtonHighlights];
            }
            ImGui::SameLine(); ImGui::TextDisabled("(S2 -> S1 -> AA -> S1 lui)");

            ImGui::Separator();
            if (ImGui::Button("Test Chay Combo Da Chon")) {
                CGPoint target = [self currentAimPoint];
                if (target.x > 0.0f || target.y > 0.0f) {
                    TouchEngine::ExecuteNakSelectedCombo(target, g_Cfg.selectedCombo, true);
                }
            }

            ImGui::Separator();
            ImGui::SliderFloat("Touch Jitter (px)", &g_Cfg.posJitterPx, 0.0f, 12.0f, "%.1f");
            ImGui::SliderInt("Delay Jitter (ms)", &g_Cfg.timeJitterMs, 0, 45);
            ImGui::Separator();
            if (ImGui::SliderFloat("Kich thuoc nut C1/C2/C3", &g_Cfg.quickButtonSize, 30.0f, 72.0f, "%.0f px")) {
                [self syncControlButtonFramesFromConfig];
            }
            if (ImGui::SliderFloat("Kich thuoc nut AA (rieng)", &g_Cfg.quickAAButtonSize, 30.0f, 88.0f, "%.0f px")) {
                [self syncControlButtonFramesFromConfig];
            }
            ImGui::EndTabItem();
        }

        if (ImGui::BeginTabItem("Toa Do Nut")) {
            ImGui::Text("Keo 3 moc tron VANG S1/S2/S3 tren man hinh vao dung vi tri skill trong game.");
            ImGui::TextDisabled("Moc vang chi hien khi menu PX mo; toa do nay duoc dung de cham/vuot skill.");
            if (ImGui::SliderFloat2("Chieu 1 (X, Y)", g_Cfg.skill1Pos, 0.5f, 1.0f, "%.2f")) [self syncControlButtonFramesFromConfig];
            if (ImGui::SliderFloat2("Chieu 2 (X, Y)", g_Cfg.skill2Pos, 0.5f, 1.0f, "%.2f")) [self syncControlButtonFramesFromConfig];
            if (ImGui::SliderFloat2("Chieu 3 (X, Y)", g_Cfg.skill3Pos, 0.5f, 1.0f, "%.2f")) [self syncControlButtonFramesFromConfig];
            ImGui::SliderFloat2("Danh Thuong (X, Y)", g_Cfg.attackPos, 0.5f, 1.0f, "%.2f");
            if (ImGui::Button("Cap nhat vi tri moc vang")) [self syncControlButtonFramesFromConfig];
            ImGui::EndTabItem();
        }

        if (ImGui::BeginTabItem("Vision")) {
            ImGui::Checkbox("Ve khung Debug ESP", &g_Cfg.drawDebugEsp);
            if (ImGui::SliderInt("Tan suat quet (FPS)", &g_Cfg.captureFps, 6, 60)) {
                g_CaptureFps.store(g_Cfg.captureFps, std::memory_order_release);
            }
            ImGui::SliderFloat("Chieu rong HP chuan (point)", &g_Cfg.standardHpWidth, 40.0f, 110.0f, "%.0f");
            ImGui::SliderInt("Temporal Confirm Frames", &g_Cfg.minConfirmFrames, 1, 6);
            ImGui::Separator();
            if (ImGui::Button("Quet toan man hinh")) VisionEngine::RequestFullScreenScan();
            ImGui::SameLine();
            ImGui::TextDisabled("Quet full frame trong 10 frame tiep theo.");
            ImGui::EndTabItem();
        }

        if (ImGui::BeginTabItem("Vision Monitor")) {
            ImGui::Text("VISION REAL-TIME MONITOR");
            ImGui::Separator();

            const BotState state = g_BotState.load(std::memory_order_relaxed);
            const char* stateName = "IDLE";
            switch (state) {
                case BotState::IDLE: stateName = "IDLE"; break;
                case BotState::SCANNING: stateName = "SCANNING"; break;
                case BotState::LOCKED: stateName = "LOCKED"; break;
                case BotState::EXECUTING: stateName = "EXECUTING"; break;
            }
            ImGui::Text("Bot State: %s", stateName);
            ImGui::Text("Master: %s | Auto-Engage: %s",
                        g_Cfg.masterEnable ? "ON" : "OFF",
                        g_Cfg.autoEngage ? "ON" : "OFF");
            ImGui::Text("Vision FPS (processed): %.1f",
                        g_VisionMeasuredFps.load(std::memory_order_relaxed));

            std::vector<TrackedTarget> monitorTargets;
            int lockedTargetId = -1;
            {
                std::lock_guard<std::mutex> lock(g_StateMutex);
                monitorTargets = g_TrackedTargets;
                lockedTargetId = g_CurrentLockedId;
            }

            ImGui::Text("Tracked targets: %d | Locked ID: %d",
                        (int)monitorTargets.size(), lockedTargetId);
            ImGui::Separator();

            if (monitorTargets.empty()) {
                ImGui::TextDisabled("Chua phat hien muc tieu nao.");
            } else {
                ImGui::Text("ID   LEVEL   HP%%   CONF   FRAMES   POSITION");
                for (const auto& target : monitorTargets) {
                    const bool locked = target.id == lockedTargetId;
                    if (locked) ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(255, 90, 90, 255));
                    ImGui::Text("%-3d  L%-2d     %5.1f  %4.2f   %3d/%-2d   %.0f, %.0f%s",
                                target.id,
                                target.level,
                                target.hpPercent,
                                target.detectionConfidence,
                                target.consecutiveFrames,
                                target.missingFrames,
                                target.center.x,
                                target.center.y,
                                locked ? "  [LOCKED]" : "");
                    if (locked) ImGui::PopStyleColor();
                }
            }
            ImGui::Separator();
            ImGui::TextDisabled("FPS la so frame Vision xu ly thanh cong, khong phai FPS render cua game.");
            ImGui::TextDisabled("CONF la do tin cay nhan dien; FRAMES la so frame lien tiep / frame bi mat.");
            ImGui::EndTabItem();
        }

        if (ImGui::BeginTabItem("Config")) {
            if (ImGui::SliderFloat("Do mo nut noi", &g_Cfg.uiOpacity, 0.2f, 1.0f, "%.2f")) {
                self.floatingToggleBtn.alpha = g_Cfg.uiOpacity;
                self.menuToggleBtn.alpha = g_Cfg.uiOpacity;
                self.btnC1.alpha = g_Cfg.uiOpacity;
                self.btnC2.alpha = g_Cfg.uiOpacity;
                self.btnC3.alpha = g_Cfg.uiOpacity;
                self.btnAA.alpha = g_Cfg.uiOpacity;
            }
            ImGui::Text("An/Hien nhanh: Cham 3 ngon 2 lan");
            ImGui::Separator();
            if (ImGui::Button("Luu Toa Do Nut")) {
                ConfigStorage::SavePreset("default");
            }
            ImGui::SameLine();
            if (ImGui::Button("Luu Default")) ConfigStorage::SavePreset("default");
            ImGui::SameLine();
            if (ImGui::Button("Tai Default")) { ConfigStorage::LoadPreset("default"); [self syncControlButtonFramesFromConfig]; [self updateQuickButtonHighlights]; }
            ImGui::EndTabItem();
        }

        ImGui::EndTabBar();
    }
    ImGui::End();
}

- (void)drawInMTKView:(MTKView *)view {
    const Config cfg = GetConfigSnapshot();
    bool hasEspToDraw = false;
    if (cfg.masterEnable && cfg.drawDebugEsp) {
        std::lock_guard<std::mutex> lock(g_StateMutex);
        hasEspToDraw = !g_TrackedTargets.empty();
    }

    if (!self.imguiInitialized || ImGui::GetCurrentContext() == nullptr || !self.commandQueue || !view.device) return;
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable) return;

    // Khi menu vừa đóng và không có ESP, clear frame sạch sẽ 1 lần để xóa bóng menu cũ
    if (!g_ShowImGuiMenu && !hasEspToDraw) {
        g_ImGuiWindowRect = CGRectZero;
        id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
        if (!cmdBuf) return;
        id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
        if (!encoder) return;
        [encoder endEncoding];
        [cmdBuf presentDrawable:drawable];
        [cmdBuf commit];
        return;
    }

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)view.bounds.size.width, (float)view.bounds.size.height);
    float scale = (float)(view.window.screen.scale ?: [UIScreen mainScreen].scale);
    io.DisplayFramebufferScale = ImVec2(scale, scale);

    id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
    if (!cmdBuf) return;
    id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    if (!encoder) return;

    ImGui_ImplMetal_NewFrame(rpd);
    const uint64_t imguiFrame = g_ImGuiFrameCounter.fetch_add(1, std::memory_order_acq_rel) + 1;
    const uint64_t pressFrame = g_ImGuiMousePressFrame.load(std::memory_order_acquire);
    if (g_ImGuiMouseReleasePending.load(std::memory_order_acquire) &&
        imguiFrame > pressFrame + 1 &&
        g_ImGuiMouseReleasePending.exchange(false, std::memory_order_acq_rel)) {
        io.AddMouseButtonEvent(0, false);
    }
    ImGui::NewFrame();

    if (hasEspToDraw) {
        ImDrawList *bg = ImGui::GetBackgroundDrawList();
        std::lock_guard<std::mutex> lock(g_StateMutex);
        for (const auto& t : g_TrackedTargets) {
            if (t.consecutiveFrames < cfg.minConfirmFrames) continue;
            bool isLocked = (t.id == g_CurrentLockedId);
            ImU32 col = isLocked ? IM_COL32(255, 50, 50, 230) : IM_COL32(255, 210, 40, 190);
            float halfW = t.width * 0.5f;
            bg->AddRect(
                ImVec2((float)t.center.x - halfW, (float)t.center.y - 8.0f),
                ImVec2((float)t.center.x + halfW, (float)t.center.y + 8.0f),
                col, 2.0f, 0, isLocked ? 2.5f : 1.5f
            );
            char targetLabel[40];
            if (t.level >= 1 && t.level <= 16) {
                snprintf(targetLabel, sizeof(targetLabel), "L%02d  HP %.0f%%",
                         t.level, t.hpPercent);
            } else {
                snprintf(targetLabel, sizeof(targetLabel), "L--  HP %.0f%%",
                         t.hpPercent);
            }
            bg->AddText(
                ImVec2((float)t.center.x - halfW, (float)t.center.y - 25.0f),
                col, targetLabel);
        }
    }

    if (g_ShowImGuiMenu) {
        [self RenderImGuiTabs];
    } else {
        g_ImGuiWindowRect = CGRectZero;
    }

    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmdBuf, encoder);

    [encoder endEncoding];
    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

// ============================================================================
// ENTRY POINT DYLIB
// ============================================================================
static PXPassthroughWindow *g_OverlayWindow = nil;

static void SetupOverlayWindow() {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (activeScene) {
            g_OverlayWindow = [[PXPassthroughWindow alloc] initWithWindowScene:activeScene];
        } else {
            g_OverlayWindow = [[PXPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
    } else {
        g_OverlayWindow = [[PXPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    g_OverlayWindow.windowLevel = UIWindowLevelAlert + 100;
    g_OverlayWindow.backgroundColor = [UIColor clearColor];
    g_OverlayWindow.rootViewController = [[PXOverlayController alloc] init];

    // Keep the controller view in UIWindow's normal UIKit hierarchy.
    // Reparenting it into a secure UITextField's private subview can prevent rendering on newer iOS.
    g_OverlayWindow.hidden = NO;
}

__attribute__((constructor))
static void PX_DylibEntry() {
    Class metalLayerCls = objc_getClass("CAMetalLayer");
    if (metalLayerCls) {
        Method mFb = class_getInstanceMethod(metalLayerCls, @selector(setFramebufferOnly:));
        if (mFb) {
            orig_setFramebufferOnly = (void (*)(id, SEL, BOOL))method_getImplementation(mFb);
            method_setImplementation(mFb, (IMP)hooked_setFramebufferOnly);
        }

        Method mDraw = class_getInstanceMethod(metalLayerCls, @selector(nextDrawable));
        if (mDraw) {
            orig_nextDrawable = (id<CAMetalDrawable> (*)(id, SEL))method_getImplementation(mDraw);
            method_setImplementation(mDraw, (IMP)hooked_nextDrawable);
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SetupOverlayWindow();
    });
}
