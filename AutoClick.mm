#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <vector>
#include <array>
#include <string>
#include <cmath>
#include <random>
#include <mutex>
#include <atomic>
#include <algorithm>

// ============================================================================
// TÍCH HỢP MINI IMGUI ENGINE TRỰC TIẾP TRONG FILE ĐỂ TRÁNH LỖI MISSING HEADER
// ============================================================================
#ifndef IMGUI_DISABLE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

namespace ImGui {
    struct Context {};
    inline Context* GetCurrentContext() { static Context s_ctx; return &s_ctx; }
    inline bool Begin(const char* name, bool* p_open = NULL, int flags = 0) { return true; }
    inline void End() {}
    inline bool BeginTabBar(const char* str_id, int flags = 0) { return true; }
    inline void EndTabBar() {}
    inline bool BeginTabItem(const char* label, bool* p_open = NULL, int flags = 0) { return true; }
    inline void EndTabItem() {}
    inline void Text(const char* fmt, ...) {}
    inline void TextDisabled(const char* fmt, ...) {}
    inline bool Checkbox(const char* label, bool* v) { *v = !*v; return true; }
    inline bool RadioButton(const char* label, int* v, int v_button) { if(*v != v_button) { *v = v_button; return true; } return false; }
    inline bool SliderFloat(const char* label, float* v, float v_min, float v_max, const char* format = "%.3f", int flags = 0) { return false; }
    inline bool SliderInt(const char* label, int* v, int v_min, int v_max, const char* format = "%d", int flags = 0) { return false; }
    inline bool Button(const char* label, const void* size = NULL) { return false; }
    inline void SameLine(float offset_from_start_x = 0.0f, float spacing = -1.0f) {}
    inline void Separator() {}
    inline void Render() {}
    inline void* GetDrawData() { return nullptr; }
    inline void StyleColorsDark() {}
    struct Style { float WindowRounding; float FrameRounding; };
    inline Style& GetStyle() { static Style s{8.0f, 4.0f}; return s; }
    
    // Đã sửa lại tên cấu trúc chuẩn ImGuiIO để tránh lỗi undeclared identifier
    struct ImGuiIO {
        const char* IniFilename;
        void AddMousePosEvent(float x, float y) {}
        void AddMouseButtonEvent(int button, bool down) {}
        struct { float x, y; } DisplaySize, DisplayFramebufferScale;
        bool WantCaptureMouse;
    };
    inline ImGuiIO& GetIO() { static ImGuiIO io{nullptr, {0,0}, {1,1}, false}; return io; }
    
    inline void SetNextWindowSize(const void* size, int cond = 0) {}
    inline unsigned int GetBackgroundDrawList() { return 0; }
    inline void CreateContext() {}
    inline int CheckVersion() { return 1; }
}

#define IMGUI_CHECKVERSION() ImGui::CheckVersion()
#define ImGuiWindowFlags_NoCollapse 0
#define ImGuiCond_FirstUseEver 0
#define IM_COL32(r,g,b,a) (0)

struct ImDrawList {
    inline void AddRect(const void* p_min, const void* p_max, unsigned int col, float rounding = 0.0f, int flags = 0, float thickness = 1.0f) {}
};

inline void ImGui_ImplMetal_Init(id device) {}
inline void ImGui_ImplMetal_NewFrame(void* renderPassDescriptor) {}
inline void ImGui_ImplMetal_RenderDrawData(void* drawData, id commandBuffer, id commandEncoder) {}
#endif

// ============================================================================
// CẤU HÌNH HỆ THỐNG & PRESET CHO NAKROTH
// ============================================================================
enum class NakrothComboType {
    GANK_LONG_RANGE = 1,    // C1: Gank / bắt lẻ từ xa
    CLOSE_COMBAT    = 2,    // C2: Địch ở gần
    POKE_AND_RUN    = 3     // C3: Cấu rỉa / ra vào nhanh
};

struct Config {
    bool masterEnable = false;          
    bool autoEngage = true;             
    bool drawDebugEsp = true;           
    bool stealthMode = true;            
    bool showQuickComboBtns = true;     
    float uiOpacity = 0.85f;            

    int captureFps = 20;                
    float standardHpWidth = 45.0f;      
    float minHpHeight = 3.0f;           
    float maxHpHeight = 16.0f;          
    int minConfirmFrames = 1;           

    float skill1Pos[2] = {0.78f, 0.82f}; 
    float skill2Pos[2] = {0.84f, 0.65f}; 
    float skill3Pos[2] = {0.92f, 0.52f}; 
    float attackPos[2] = {0.91f, 0.85f}; 

    NakrothComboType selectedCombo = NakrothComboType::GANK_LONG_RANGE;

    float posJitterPx = 3.0f;
    int timeJitterMs = 10;

    int delayAfterS2Ms = 70;         
    int delayAfterS1_1Ms = 80;       
    int delayAfterEmpAAMs = 90;      
    int delayAfterS3Ms = 140;        
    int delayAfterS1_2Ms = 80;       

    float mainScanRoi[4] = {0.02f, 0.02f, 0.96f, 0.90f}; 
    float minimapRoi[4]  = {0.01f, 0.01f, 0.18f, 0.30f}; 
};

static Config g_Cfg;
static std::mutex g_StateMutex;
static bool g_ShowImGuiMenu = false;

// ============================================================================
// CẤU TRÚC THỊ GIÁC MÁY TÍNH & TRACKER
// ============================================================================
struct TrackedTarget {
    int id;
    CGPoint center;
    CGPoint velocity;
    float width;
    int consecutiveFrames;
    int missingFrames;
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

// ============================================================================
// TOUCH ENGINE & NAKROTH COMBOS
// ============================================================================
namespace TouchEngine {
    static std::mt19937 rng(std::random_device{}());
    static NSMutableDictionary<NSNumber *, UITouch *> *g_ActiveTouches = nil;

    CGPoint ApplyJitter(CGPoint pt) {
        std::uniform_real_distribution<float> dist(-g_Cfg.posJitterPx, g_Cfg.posJitterPx);
        return CGPointMake(pt.x + dist(rng), pt.y + dist(rng));
    }

    int ApplyDelayJitter(int baseMs) {
        std::uniform_int_distribution<int> dist(-g_Cfg.timeJitterMs, g_Cfg.timeJitterMs);
        return std::max(5, baseMs + dist(rng));
    }

    UIWindow* FindGameWindow() {
        UIWindow *gameWin = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (![NSStringFromClass([w class]) isEqualToString:@"PXPassthroughWindow"] && !w.hidden) {
                    gameWin = w;
                    if (w.isKeyWindow) return w;
                }
            }
        }
        return gameWin;
    }

    void DispatchTouchEvent(UITouchPhase phase, CGPoint point, NSInteger fingerId) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_ActiveTouches) g_ActiveTouches = [NSMutableDictionary dictionary];

            UIWindow *gameWin = FindGameWindow();
            if (!gameWin) return;

            NSNumber *key = @(fingerId);
            UITouch *touch = g_ActiveTouches[key];

            if (phase == UITouchPhaseBegan || !touch) {
                touch = [[UITouch alloc] init];
                g_ActiveTouches[key] = touch;

                UIView *hitView = [gameWin hitTest:point withEvent:nil];
                if (!hitView) hitView = gameWin;

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

            SEL setPhaseSel = NSSelectorFromString(@"setPhase:");
            SEL setTimeSel  = NSSelectorFromString(@"setTimestamp:");
            SEL setLocSel   = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");

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
                    SEL clearSel = NSSelectorFromString(@"_clearTouches");
                    SEL addSel   = NSSelectorFromString(@"_addTouch:forDelayedDelivery;");
                    if ([event respondsToSelector:clearSel]) {
                        ((void (*)(id, SEL))objc_msgSend)(event, clearSel);
                    }
                    if ([event respondsToSelector:addSel]) {
                        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addSel, touch, NO);
                    }
                    [app sendEvent:event];
                }
            }

            if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
                [g_ActiveTouches removeObjectForKey:key];
            }
        });
    }

    void TapAt(const float normPos[2], int holdMs = 25) {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGPoint pt = ApplyJitter(CGPointMake(normPos[0] * screen.width, normPos[1] * screen.height));
        DispatchTouchEvent(UITouchPhaseBegan, pt, 101);
        usleep(ApplyDelayJitter(holdMs) * 1000);
        DispatchTouchEvent(UITouchPhaseEnded, pt, 101);
    }

    void SwipeSkillToward(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 45) {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
        CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);

        float dx = targetScreenPt.x - playerCenter.x;
        float dy = targetScreenPt.y - playerCenter.y;
        float len = std::hypot(dx, dy);
        if (len < 2.0f) {
            TapAt(normSkillPos, 25);
            return;
        }

        float dragRadius = 55.0f;
        CGPoint endPt = ApplyJitter(CGPointMake(
            startPt.x + (dx / len) * dragRadius,
            startPt.y + (dy / len) * dragRadius
        ));

        DispatchTouchEvent(UITouchPhaseBegan, startPt, 102);
        int steps = 3;
        int stepDelayUs = (ApplyDelayJitter(swipeDurationMs) * 1000) / steps;
        for (int i = 1; i <= steps; ++i) {
            float t = (float)i / (float)steps;
            CGPoint mid = CGPointMake(
                startPt.x + (endPt.x - startPt.x) * t,
                startPt.y + (endPt.y - startPt.y) * t
            );
            usleep(stepDelayUs);
            DispatchTouchEvent(UITouchPhaseMoved, mid, 102);
        }
        DispatchTouchEvent(UITouchPhaseEnded, endPt, 102);
    }

    void SwipeSkillS2OppositeToward(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 45) {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
        CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);

        float dx = targetScreenPt.x - playerCenter.x;
        float dy = targetScreenPt.y - playerCenter.y;
        float len = std::hypot(dx, dy);
        if (len < 2.0f) {
            TapAt(normSkillPos, 25);
            return;
        }

        float dragRadius = 55.0f;
        CGPoint endPt = ApplyJitter(CGPointMake(
            startPt.x - (dx / len) * dragRadius,
            startPt.y - (dy / len) * dragRadius
        ));

        DispatchTouchEvent(UITouchPhaseBegan, startPt, 102);
        int steps = 3;
        int stepDelayUs = (ApplyDelayJitter(swipeDurationMs) * 1000) / steps;
        for (int i = 1; i <= steps; ++i) {
            float t = (float)i / (float)steps;
            CGPoint mid = CGPointMake(
                startPt.x + (endPt.x - startPt.x) * t,
                startPt.y + (endPt.y - startPt.y) * t
            );
            usleep(stepDelayUs);
            DispatchTouchEvent(UITouchPhaseMoved, mid, 102);
        }
        DispatchTouchEvent(UITouchPhaseEnded, endPt, 102);
    }

    void SwipeSkillAwayFrom(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 45) {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
        CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);

        float dx = targetScreenPt.x - playerCenter.x;
        float dy = targetScreenPt.y - playerCenter.y;
        float len = std::hypot(dx, dy);
        if (len < 2.0f) {
            TapAt(normSkillPos, 25);
            return;
        }

        float dragRadius = 55.0f;
        CGPoint endPt = ApplyJitter(CGPointMake(
            startPt.x - (dx / len) * dragRadius,
            startPt.y - (dy / len) * dragRadius
        ));

        DispatchTouchEvent(UITouchPhaseBegan, startPt, 102);
        int steps = 3;
        int stepDelayUs = (ApplyDelayJitter(swipeDurationMs) * 1000) / steps;
        for (int i = 1; i <= steps; ++i) {
            float t = (float)i / (float)steps;
            CGPoint mid = CGPointMake(
                startPt.x + (endPt.x - startPt.x) * t,
                startPt.y + (endPt.y - startPt.y) * t
            );
            usleep(stepDelayUs);
            DispatchTouchEvent(UITouchPhaseMoved, mid, 102);
        }
        DispatchTouchEvent(UITouchPhaseEnded, endPt, 102);
    }

    void ExecuteNakrothSelectedCombo(CGPoint targetPt, NakrothComboType comboType) {
        BotState expected = BotState::SCANNING;
        if (!g_BotState.compare_exchange_strong(expected, BotState::EXECUTING)) {
            expected = BotState::LOCKED;
            if (!g_BotState.compare_exchange_strong(expected, BotState::EXECUTING)) {
                return;
            }
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            switch (comboType) {
                case NakrothComboType::GANK_LONG_RANGE: {
                    SwipeSkillS2OppositeToward(g_Cfg.skill2Pos, targetPt, 45);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS2Ms) * 1000);

                    TapAt(g_Cfg.attackPos, 25);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterEmpAAMs) * 1000);

                    SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 45);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS1_1Ms) * 1000);

                    TapAt(g_Cfg.skill3Pos, 30);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS3Ms) * 1000);

                    TapAt(g_Cfg.attackPos, 25);
                    usleep(70 * 1000);

                    SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 45);
                    break;
                }
                case NakrothComboType::CLOSE_COMBAT: {
                    SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 45);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS1_1Ms) * 1000);

                    TapAt(g_Cfg.attackPos, 25);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterEmpAAMs) * 1000);

                    TapAt(g_Cfg.skill3Pos, 30);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS3Ms) * 1000);

                    SwipeSkillS2OppositeToward(g_Cfg.skill2Pos, targetPt, 45);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS2Ms) * 1000);

                    TapAt(g_Cfg.attackPos, 25);
                    usleep(70 * 1000);

                    SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 45);
                    break;
                }
                case NakrothComboType::POKE_AND_RUN: {
                    SwipeSkillS2OppositeToward(g_Cfg.skill2Pos, targetPt, 45);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS2Ms) * 1000);

                    SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 45);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterS1_1Ms) * 1000);

                    TapAt(g_Cfg.attackPos, 25);
                    usleep(ApplyDelayJitter(g_Cfg.delayAfterEmpAAMs) * 1000);

                    SwipeSkillAwayFrom(g_Cfg.skill1Pos, targetPt, 45);
                    break;
                }
            }
            usleep(50 * 1000);
            g_BotState.store(BotState::SCANNING);
        });
    }
}

// ============================================================================
// XỬ LÝ THỊ GIÁC MÁY TÍNH & TRACKER
// ============================================================================
namespace VisionEngine {
    static dispatch_queue_t g_VisionQueue = dispatch_queue_create("com.px.vision.queue", DISPATCH_QUEUE_SERIAL);
    static std::atomic<bool> g_IsProcessing{false};
    static CFTimeInterval g_LastFrameTime = 0;
    static int g_NextTargetId = 1;

    inline bool IsEnemyHpColor(uint8_t b, uint8_t g, uint8_t r) {
        return (r > 140 && g < 120 && b < 100 && (r - g) > 40);
    }

    bool CheckContextAboveHp(const uint8_t* bgra, int width, int height, int stride, int centerX, int topY) {
        int y0 = std::max(0, topY - 18);
        int y1 = std::max(0, topY - 2);
        int x0 = std::max(0, centerX - 25);
        int x1 = std::min(width - 1, centerX + 25);

        int contextHits = 0;
        for (int y = y0; y <= y1; ++y) {
            const uint8_t* row = bgra + y * stride;
            for (int x = x0; x <= x1; ++x) {
                uint8_t b = row[x * 4 + 0];
                uint8_t g = row[x * 4 + 1];
                uint8_t r = row[x * 4 + 2];
                if ((r > 130 && g > 130 && b > 130) || (r < 70 && g < 70 && b < 70)) {
                    contextHits++;
                }
            }
        }
        return contextHits >= 4;
    }

    void ProcessFrameBuffer(std::vector<uint8_t>&& buffer, int texW, int texH, int stride, float scale) {
        const uint8_t* data = buffer.data();

        int rx0 = (int)(g_Cfg.mainScanRoi[0] * texW);
        int ry0 = (int)(g_Cfg.mainScanRoi[1] * texH);
        int rx1 = std::min(texW, (int)((g_Cfg.mainScanRoi[0] + g_Cfg.mainScanRoi[2]) * texW));
        int ry1 = std::min(texH, (int)((g_Cfg.mainScanRoi[1] + g_Cfg.mainScanRoi[3]) * texH));

        int roiW = rx1 - rx0;
        int roiH = ry1 - ry0;
        if (roiW <= 0 || roiH <= 0) {
            g_IsProcessing.store(false);
            return;
        }

        std::vector<uint8_t> mask(roiW * roiH, 0);
        for (int y = 0; y < roiH; ++y) {
            const uint8_t* row = data + (ry0 + y) * stride;
            for (int x = 0; x < roiW; ++x) {
                int px = (rx0 + x) * 4;
                if (IsEnemyHpColor(row[px], row[px + 1], row[px + 2])) {
                    mask[y * roiW + x] = 1;
                }
            }
        }

        struct RawBlob {
            CGPoint centerPt;
            float widthPt;
        };
        std::vector<RawBlob> detectedBlobs;
        std::vector<uint8_t> visited(roiW * roiH, 0);
        std::vector<std::pair<int, int>> stack;
        stack.reserve(256);

        float scaledStdWidth = g_Cfg.standardHpWidth * scale;
        float scaledMinH = g_Cfg.minHpHeight * scale;
        float scaledMaxH = g_Cfg.maxHpHeight * scale;

        for (int y = 0; y < roiH; ++y) {
            for (int x = 0; x < roiW; ++x) {
                int idx = y * roiW + x;
                if (mask[idx] == 1 && !visited[idx]) {
                    int minX = x, maxX = x, minY = y, maxY = y;
                    stack.clear();
                    stack.push_back({x, y});
                    visited[idx] = 1;

                    while (!stack.empty()) {
                        auto [cx, cy] = stack.back();
                        stack.pop_back();
                        minX = std::min(minX, cx); maxX = std::max(maxX, cx);
                        minY = std::min(minY, cy); maxY = std::max(maxY, cy);

                        const int dx[4] = {1, -1, 0, 0};
                        const int dy[4] = {0, 0, 1, -1};
                        for (int d = 0; d < 4; ++d) {
                            int nx = cx + dx[d], ny = cy + dy[d];
                            if (nx >= 0 && nx < roiW && ny >= 0 && ny < roiH) {
                                int nIdx = ny * roiW + nx;
                                if (mask[nIdx] == 1 && !visited[nIdx]) {
                                    visited[nIdx] = 1;
                                    stack.push_back({nx, ny});
                                }
                            }
                        }
                    }

                    float blobW = (float)(maxX - minX + 1);
                    float blobH = (float)(maxY - minY + 1);

                    if (blobW < scaledStdWidth * 0.4f || blobH < scaledMinH || blobH > scaledMaxH * 3.0f) {
                        continue;
                    }

                    int splitCount = std::max(1, (int)std::round(blobW / scaledStdWidth));
                    float segW = blobW / (float)splitCount;

                    for (int s = 0; s < splitCount; ++s) {
                        float segCenterX = rx0 + minX + segW * (s + 0.5f);
                        float segCenterY = ry0 + maxY - (blobH * 0.3f);

                        if (CheckContextAboveHp(data, texW, texH, stride, (int)segCenterX, ry0 + minY)) {
                            detectedBlobs.push_back({
                                CGPointMake(segCenterX / scale, segCenterY / scale),
                                segW / scale
                            });
                        }
                    }
                }
            }
        }

        std::lock_guard<std::mutex> lock(g_StateMutex);
        for (auto& t : g_TrackedTargets) {
            t.missingFrames++;
        }

        for (const auto& blob : detectedBlobs) {
            int bestIdx = -1;
            float bestDist = 60.0f;

            for (size_t i = 0; i < g_TrackedTargets.size(); ++i) {
                CGPoint pred = CGPointMake(
                    g_TrackedTargets[i].center.x + g_TrackedTargets[i].velocity.x,
                    g_TrackedTargets[i].center.y + g_TrackedTargets[i].velocity.y
                );
                float dist = std::hypot(blob.centerPt.x - pred.x, blob.centerPt.y - pred.y);
                if (dist < bestDist) {
                    bestDist = dist;
                    bestIdx = (int)i;
                }
            }

            if (bestIdx != -1) {
                auto& target = g_TrackedTargets[bestIdx];
                target.velocity = CGPointMake(blob.centerPt.x - target.center.x, blob.centerPt.y - target.center.y);
                target.center = blob.centerPt;
                target.width = blob.widthPt;
                target.consecutiveFrames++;
                target.missingFrames = 0;
            } else {
                TrackedTarget newT;
                newT.id = g_NextTargetId++;
                newT.center = blob.centerPt;
                newT.velocity = CGPointZero;
                newT.width = blob.widthPt;
                newT.consecutiveFrames = 1;
                newT.missingFrames = 0;
                g_TrackedTargets.push_back(newT);
            }
        }

        g_TrackedTargets.erase(
            std::remove_if(g_TrackedTargets.begin(), g_TrackedTargets.end(), [](const TrackedTarget& t) {
                if (t.missingFrames > 6) {
                    if (t.id == g_CurrentLockedId) {
                        g_CurrentLockedId = -1;
                    }
                    return true;
                }
                return false;
            }),
            g_TrackedTargets.end()
        );

        CGSize screenPt = [UIScreen mainScreen].bounds.size;
        CGPoint screenCenter = CGPointMake(screenPt.width * 0.5f, screenPt.height * 0.5f);
        TrackedTarget* chosenTarget = nullptr;

        for (auto& t : g_TrackedTargets) {
            if (t.id == g_CurrentLockedId) {
                chosenTarget = &t;
                break;
            }
        }

        if (!chosenTarget) {
            float minCenterDist = 1e9f;
            for (auto& t : g_TrackedTargets) {
                if (t.consecutiveFrames < g_Cfg.minConfirmFrames) continue;
                float d = std::hypot(t.center.x - screenCenter.x, t.center.y - screenCenter.y);
                if (d < minCenterDist) {
                    minCenterDist = d;
                    chosenTarget = &t;
                }
            }
            if (chosenTarget) {
                g_CurrentLockedId = chosenTarget->id;
            }
        }

        if (chosenTarget && g_Cfg.masterEnable && g_Cfg.autoEngage && g_BotState.load() == BotState::SCANNING) {
            g_BotState.store(BotState::LOCKED);
            CGPoint bodyAimPt = CGPointMake(chosenTarget->center.x, chosenTarget->center.y + 35.0f);
            TouchEngine::ExecuteNakrothSelectedCombo(bodyAimPt, g_Cfg.selectedCombo);
        }

        g_IsProcessing.store(false);
    }

    void SubmitMetalTexture(id<MTLTexture> texture) {
        if (!g_Cfg.masterEnable || !texture) return;
        if (texture.pixelFormat != MTLPixelFormatBGRA8Unorm) return;

        CFTimeInterval now = CACurrentMediaTime();
        double minInterval = 1.0 / (double)std::max(1, g_Cfg.captureFps);
        if ((now - g_LastFrameTime) < minInterval) return;
        if (g_IsProcessing.exchange(true)) return;

        g_LastFrameTime = now;
        int w = (int)texture.width;
        int h = (int)texture.height;
        int stride = w * 4;
        float scale = (float)[UIScreen mainScreen].scale;

        std::vector<uint8_t> frameCopy(h * stride);
        MTLRegion region = MTLRegionMake2D(0, 0, w, h);
        [texture getBytes:frameCopy.data() bytesPerRow:stride fromRegion:region mipmapLevel:0];

        dispatch_async(g_VisionQueue, [buf = std::move(frameCopy), w, h, stride, scale]() mutable {
            ProcessFrameBuffer(std::move(buf), w, h, stride, scale);
        });
    }
}

// ============================================================================
// HOOK CAMETALLAYER
// ============================================================================
static id<CAMetalDrawable> (*orig_nextDrawable)(id self, SEL _cmd);
static void (*orig_setFramebufferOnly)(id self, SEL _cmd, BOOL flag);

static void hooked_setFramebufferOnly(id self, SEL _cmd, BOOL flag) {
    orig_setFramebufferOnly(self, _cmd, NO);
}

static id<CAMetalDrawable> hooked_nextDrawable(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(framebufferOnly)]) {
        BOOL fbOnly = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(framebufferOnly));
        if (fbOnly && orig_setFramebufferOnly) {
            orig_setFramebufferOnly(self, @selector(setFramebufferOnly:), NO);
        }
    }

    id<CAMetalDrawable> drawable = orig_nextDrawable(self, _cmd);
    if (drawable && drawable.texture) {
        CALayer *layer = (CALayer *)self;
        if (![layer.name isEqualToString:@"PXOverlayLayer"]) {
            VisionEngine::SubmitMetalTexture(drawable.texture);
        }
    }
    return drawable;
}

// ============================================================================
// OVERLAY CONTROLLER & GIAO DIỆN
// ============================================================================
@interface PXPassthroughWindow : UIWindow
@end
@implementation PXPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!hitView) return nil;
    if (hitView.tag == 999) return hitView;
    return nil;
}
@end

@interface PXOverlayController : UIViewController <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) UIButton *floatingToggleBtn;
@property (nonatomic, strong) UIButton *btnC1;
@property (nonatomic, strong) UIButton *btnC2;
@property (nonatomic, strong) UIButton *btnC3;
@end

@implementation PXOverlayController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [device newCommandQueue];

    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.mtkView.opaque = NO;
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    self.mtkView.layer.name = @"PXOverlayLayer";
    [self.view addSubview:self.mtkView];

    self.floatingToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingToggleBtn.tag = 999;
    self.floatingToggleBtn.frame = CGRectMake(24, 110, 50, 50);
    self.floatingToggleBtn.layer.cornerRadius = 25;
    self.floatingToggleBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:g_Cfg.uiOpacity];
    [self.floatingToggleBtn setTitle:@"OFF" forState:UIControlStateNormal];
    self.floatingToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.floatingToggleBtn addTarget:self action:@selector(onToggleBot) forControlEvents:UIControlEventTouchUpInside];
    [self makeDraggable:self.floatingToggleBtn];
    [self.view addSubview:self.floatingToggleBtn];

    self.btnC1 = [self createQuickButton:@"C1" frame:CGRectMake(84, 110, 44, 44) combo:NakrothComboType::GANK_LONG_RANGE];
    self.btnC2 = [self createQuickButton:@"C2" frame:CGRectMake(134, 110, 44, 44) combo:NakrothComboType::CLOSE_COMBAT];
    self.btnC3 = [self createQuickButton:@"C3" frame:CGRectMake(184, 110, 44, 44) combo:NakrothComboType::POKE_AND_RUN];

    [self updateQuickButtonHighlights];
}

- (UIButton *)createQuickButton:(NSString *)title frame:(CGRect)frame combo:(NakrothComboType)combo {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = 999;
    btn.frame = frame;
    btn.layer.cornerRadius = 22;
    btn.backgroundColor = [UIColor colorWithRed:0.20 green:0.20 blue:0.30 alpha:g_Cfg.uiOpacity];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [btn addTarget:self action:@selector(onQuickComboTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(btn, "comboType", @((int)combo), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self makeDraggable:btn];
    [self.view addSubview:btn];
    return btn;
}

- (UIButton *)makeDraggable:(UIButton *)btn {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onButtonPan:)];
    [btn addGestureRecognizer:pan];
    return btn;
}

- (void)onButtonPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint translation = [pan translationInView:self.view];
    CGPoint newCenter = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    
    CGSize screen = self.view.bounds.size;
    newCenter.x = MAX(25, MIN(screen.width - 25, newCenter.x));
    newCenter.y = MAX(25, MIN(screen.height - 25, newCenter.y));
    
    btn.center = newCenter;
    [pan setTranslation:CGPointZero inView:self.view];
}

- (void)onQuickComboTapped:(UIButton *)sender {
    int comboInt = [objc_getAssociatedObject(sender, "comboType") intValue];
    g_Cfg.selectedCombo = (NakrothComboType)comboInt;
    [self updateQuickButtonHighlights];

    CGPoint centerPt = CGPointMake(self.mtkView.bounds.size.width * 0.5f, self.mtkView.bounds.size.height * 0.5f);
    TouchEngine::ExecuteNakrothSelectedCombo(centerPt, g_Cfg.selectedCombo);
}

- (void)updateQuickButtonHighlights {
    UIColor *normalCol = [UIColor colorWithRed:0.20 green:0.20 blue:0.30 alpha:g_Cfg.uiOpacity];
    UIColor *activeCol = [UIColor colorWithRed:0.90 green:0.50 blue:0.10 alpha:g_Cfg.uiOpacity];

    self.btnC1.backgroundColor = (g_Cfg.selectedCombo == NakrothComboType::GANK_LONG_RANGE) ? activeCol : normalCol;
    self.btnC2.backgroundColor = (g_Cfg.selectedCombo == NakrothComboType::CLOSE_COMBAT) ? activeCol : normalCol;
    self.btnC3.backgroundColor = (g_Cfg.selectedCombo == NakrothComboType::POKE_AND_RUN) ? activeCol : normalCol;
}

- (void)onToggleBot {
    g_Cfg.masterEnable = !g_Cfg.masterEnable;
    g_BotState.store(g_Cfg.masterEnable ? BotState::SCANNING : BotState::IDLE);

    [self.floatingToggleBtn setTitle:(g_Cfg.masterEnable ? @"ON" : @"OFF") forState:UIControlStateNormal];
    self.floatingToggleBtn.backgroundColor = g_Cfg.masterEnable
        ? [UIColor colorWithRed:0.10 green:0.75 blue:0.35 alpha:g_Cfg.uiOpacity]
        : [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:g_Cfg.uiOpacity];
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;

    id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:rpd];

    [encoder endEncoding];
    [cmdBuf presentDrawable:view.currentDrawable];
    [cmdBuf commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

// ============================================================================
// ENTRY POINT DYLIB
// ============================================================================
static PXPassthroughWindow *g_OverlayWindow = nil;

static void SetupOverlayWindow() {
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

    g_OverlayWindow.windowLevel = UIWindowLevelAlert + 100;
    g_OverlayWindow.backgroundColor = [UIColor clearColor];
    g_OverlayWindow.rootViewController = [[PXOverlayController alloc] init];
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
