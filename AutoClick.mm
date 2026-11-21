#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>
#include <vector>
#include <array>
#include <string>
#include <cmath>
#include <random>
#include <mutex>
#include <atomic>
#include <algorithm>
#include "imgui.h"
#include "imgui_impl_metal.h"
// ============================================================================
// CẤU HÌNH HỆ THỐNG & PRESET CHO NAKROTH
// ============================================================================
enum class NakrothComboType {
GANK_LONG_RANGE = 1,    // C1: Gank / bắt lẻ từ xa
CLOSE_COMBAT    = 2,    // C2: Địch ở gần
POKE_AND_RUN    = 3     // C3: Cấu rỉa / ra vào nhanh (rút lui ngược hướng S1 lần 2)
};
struct Config {
bool masterEnable = false;          // Công tắc tổng (mặc định tắt)
bool autoEngage = false;            // Tự động kích hoạt combo khi khóa mục tiêu
bool targetQueueEnable = false;     // Khóa tuần tự 5 mục tiêu A -> E
bool drawDebugEsp = true;           // Vẽ khung nhận diện thanh máu & mục tiêu lock
bool stealthMode = true;            // Ẩn khỏi quay màn hình / chụp ảnh
bool showQuickComboBtns = true;     // Hiển thị cụm 3 nút C1, C2, C3 trên màn hình
float uiOpacity = 0.85f;            // Độ mờ nút điều khiển nổi
int captureFps = 14;                // Tần suất quét CV (12 - 16 FPS)
float standardHpWidth = 68.0f;      // Chiều rộng chuẩn 1 thanh máu tướng (px)
float minHpHeight = 4.0f;           // Chiều cao tối thiểu thanh máu (px)
float maxHpHeight = 14.0f;          // Chiều cao tối đa thanh máu (px)
int minConfirmFrames = 3;           // Số frame liên tiếp để xác nhận mục tiêu
float skill1Pos[2] = {0.78f, 0.82f}; // Bồi Thẩm Đoàn (2 lần)
float skill2Pos[2] = {0.84f, 0.65f}; // Nguồn Cơn Rắc Rối (lướt ngược)
float skill3Pos[2] = {0.92f, 0.52f}; // Gươm Hành Quyết (Ulti)
float attackPos[2] = {0.91f, 0.85f}; // Đánh thường / Đánh cường hóa
NakrothComboType selectedCombo = NakrothComboType::GANK_LONG_RANGE;
float posJitterPx = 4.0f;
int timeJitterMs = 15;
int delayAfterS2Ms = 80;
int delayAfterS1_1Ms = 90;
int delayAfterEmpAAMs = 110;
int delayAfterS3Ms = 160;
int delayAfterS1_2Ms = 90;
float mainScanRoi[4] = {0.15f, 0.10f, 0.70f, 0.75f};
float minimapRoi[4]  = {0.01f, 0.01f, 0.18f, 0.30f};
};
static Config g_Cfg;
static std::mutex g_StateMutex;
static bool g_ShowImGuiMenu = false;
// ============================================================================
// LƯU / TẢI CẤU HÌNH JSON VÀO DOCUMENTS
// ============================================================================
namespace ConfigStorage {
NSString* GetConfigFilePath(NSString *presetName) {
NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
NSString *docsDir = paths.firstObject;
return [docsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"nakroth_%@.json", presetName]];
}
void SavePreset(const char* name) {
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
NSData *data = [NSData dataWithContentsOfFile:GetConfigFilePath([NSString stringWithUTF8String:name])];
if (!data) return;
NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
if (![dict isKindOfClass:[NSDictionary class]]) return;
if (dict[@"autoEngage"]) g_Cfg.autoEngage = [dict[@"autoEngage"] boolValue];
if (dict[@"targetQueueEnable"]) g_Cfg.targetQueueEnable = [dict[@"targetQueueEnable"] boolValue];
if (dict[@"drawDebugEsp"]) g_Cfg.drawDebugEsp = [dict[@"drawDebugEsp"] boolValue];
if (dict[@"showQuickComboBtns"]) g_Cfg.showQuickComboBtns = [dict[@"showQuickComboBtns"] boolValue];
if (dict[@"uiOpacity"]) g_Cfg.uiOpacity = [dict[@"uiOpacity"] floatValue];
if (dict[@"captureFps"]) g_Cfg.captureFps = [dict[@"captureFps"] intValue];
if (dict[@"selectedCombo"]) g_Cfg.selectedCombo = (NakrothComboType)[dict[@"selectedCombo"] intValue];
if (dict[@"standardHpWidth"]) g_Cfg.standardHpWidth = [dict[@"standardHpWidth"] floatValue];
if (dict[@"minConfirmFrames"]) g_Cfg.minConfirmFrames = [dict[@"minConfirmFrames"] intValue];
if (dict[@"posJitterPx"]) g_Cfg.posJitterPx = [dict[@"posJitterPx"] floatValue];
if (dict[@"timeJitterMs"]) g_Cfg.timeJitterMs = [dict[@"timeJitterMs"] intValue];
if (dict[@"delayAfterS2Ms"]) g_Cfg.delayAfterS2Ms = [dict[@"delayAfterS2Ms"] intValue];
if (dict[@"delayAfterS1_1Ms"]) g_Cfg.delayAfterS1_1Ms = [dict[@"delayAfterS1_1Ms"] intValue];
if (dict[@"delayAfterEmpAAMs"]) g_Cfg.delayAfterEmpAAMs = [dict[@"delayAfterEmpAAMs"] intValue];
if (dict[@"delayAfterS3Ms"]) g_Cfg.delayAfterS3Ms = [dict[@"delayAfterS3Ms"] intValue];
if (dict[@"delayAfterS1_2Ms"]) g_Cfg.delayAfterS1_2Ms = [dict[@"delayAfterS1_2Ms"] intValue];
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
int id;
CGPoint center;
CGPoint velocity;
float width;
int consecutiveFrames;
int missingFrames;
int queueSlot;
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
// BỘ TỔNG HỢP CHẠM & VUỐT (TOUCH ENGINE + NAKROTH COMBOS)
// ============================================================================
@interface PXFakeTouch : NSObject
@property (nonatomic, strong) UITouch *touch;
@end
@implementation PXFakeTouch
@end
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
((void ()(id, SEL, id))objc_msgSend)(touch, setWindowSel, gameWin);
}
if ([touch respondsToSelector:setViewSel]) {
((void ()(id, SEL, id))objc_msgSend)(touch, setViewSel, hitView);
}
if ([touch respondsToSelector:setTapSel]) {
((void ()(id, SEL, NSUInteger))objc_msgSend)(touch, setTapSel, 1);
}
if ([touch respondsToSelector:setIsTapSel]) {
((void ()(id, SEL, BOOL))objc_msgSend)(touch, setIsTapSel, YES);
}
}
SEL setPhaseSel = NSSelectorFromString(@"setPhase:");
SEL setTimeSel  = NSSelectorFromString(@"setTimestamp:");
SEL setLocSel   = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
if ([touch respondsToSelector:setPhaseSel]) {
((void ()(id, SEL, UITouchPhase))objc_msgSend)(touch, setPhaseSel, phase);
}
if ([touch respondsToSelector:setTimeSel]) {
((void ()(id, SEL, NSTimeInterval))objc_msgSend)(touch, setTimeSel, CACurrentMediaTime());
}
if ([touch respondsToSelector:setLocSel]) {
((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, setLocSel, point, (phase == UITouchPhaseBegan));
}
UIApplication app = [UIApplication sharedApplication];
SEL touchesEventSel = NSSelectorFromString(@"_touchesEvent");
if ([app respondsToSelector:touchesEventSel]) {
UIEvent event = ((id ()(id, SEL))objc_msgSend)(app, touchesEventSel);
if (event) {
SEL clearSel = NSSelectorFromString(@"_clearTouches");
SEL addSel   = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
if ([event respondsToSelector:clearSel]) {
((void ()(id, SEL))objc_msgSend)(event, clearSel);
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
void TapAt(const float normPos[2], int holdMs = 30) {
CGSize screen = [UIScreen mainScreen].bounds.size;
CGPoint pt = ApplyJitter(CGPointMake(normPos[0] * screen.width, normPos[1] * screen.height));
DispatchTouchEvent(UITouchPhaseBegan, pt, 101);
usleep(ApplyDelayJitter(holdMs) * 1000);
DispatchTouchEvent(UITouchPhaseEnded, pt, 101);
}
void SwipeSkillToward(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 50) {
CGSize screen = [UIScreen mainScreen].bounds.size;
CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);
float dx = targetScreenPt.x - playerCenter.x;
float dy = targetScreenPt.y - playerCenter.y;
float len = std::hypot(dx, dy);
if (len < 2.0f) {
TapAt(normSkillPos, 30);
return;
}
float dragRadius = 56.0f;
CGPoint endPt = ApplyJitter(CGPointMake(
startPt.x + (dx / len) * dragRadius,
startPt.y + (dy / len) * dragRadius
));
DispatchTouchEvent(UITouchPhaseBegan, startPt, 102);
int steps = 4;
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
void SwipeSkillS2OppositeToward(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 55) {
CGSize screen = [UIScreen mainScreen].bounds.size;
CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);
float dx = targetScreenPt.x - playerCenter.x;
float dy = targetScreenPt.y - playerCenter.y;
float len = std::hypot(dx, dy);
if (len < 2.0f) {
TapAt(normSkillPos, 30);
return;
}
float dragRadius = 58.0f;
CGPoint endPt = ApplyJitter(CGPointMake(
startPt.x - (dx / len) * dragRadius,
startPt.y - (dy / len) * dragRadius
));
DispatchTouchEvent(UITouchPhaseBegan, startPt, 102);
int steps = 4;
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
void SwipeSkillAwayFrom(const float normSkillPos[2], CGPoint targetScreenPt, int swipeDurationMs = 50) {
CGSize screen = [UIScreen mainScreen].bounds.size;
CGPoint startPt = ApplyJitter(CGPointMake(normSkillPos[0] * screen.width, normSkillPos[1] * screen.height));
CGPoint playerCenter = CGPointMake(screen.width * 0.5f, screen.height * 0.5f);
float dx = targetScreenPt.x - playerCenter.x;
float dy = targetScreenPt.y - playerCenter.y;
float len = std::hypot(dx, dy);
if (len < 2.0f) {
TapAt(normSkillPos, 30);
return;
}
float dragRadius = 58.0f;
CGPoint endPt = ApplyJitter(CGPointMake(
startPt.x - (dx / len) * dragRadius,
startPt.y - (dy / len) * dragRadius
));
DispatchTouchEvent(UITouchPhaseBegan, startPt, 102);
int steps = 4;
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
SwipeSkillS2OppositeToward(g_Cfg.skill2Pos, targetPt, 55);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS2Ms) * 1000);
TapAt(g_Cfg.attackPos, 28);
usleep(ApplyDelayJitter(g_Cfg.delayAfterEmpAAMs) * 1000);
SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 50);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS1_1Ms) * 1000);
TapAt(g_Cfg.skill3Pos, 35);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS3Ms) * 1000);
TapAt(g_Cfg.attackPos, 28);
usleep(90 * 1000);
SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 50);
break;
}
case NakrothComboType::CLOSE_COMBAT: {
SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 50);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS1_1Ms) * 1000);
TapAt(g_Cfg.attackPos, 28);
usleep(ApplyDelayJitter(g_Cfg.delayAfterEmpAAMs) * 1000);
TapAt(g_Cfg.skill3Pos, 35);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS3Ms) * 1000);
SwipeSkillS2OppositeToward(g_Cfg.skill2Pos, targetPt, 55);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS2Ms) * 1000);
TapAt(g_Cfg.attackPos, 28);
usleep(90 * 1000);
SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 50);
break;
}
case NakrothComboType::POKE_AND_RUN: {
SwipeSkillS2OppositeToward(g_Cfg.skill2Pos, targetPt, 55);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS2Ms) * 1000);
SwipeSkillToward(g_Cfg.skill1Pos, targetPt, 50);
usleep(ApplyDelayJitter(g_Cfg.delayAfterS1_1Ms) * 1000);
TapAt(g_Cfg.attackPos, 30);
usleep(ApplyDelayJitter(g_Cfg.delayAfterEmpAAMs) * 1000);
SwipeSkillAwayFrom(g_Cfg.skill1Pos, targetPt, 50);
break;
}
}
usleep(80 * 1000);
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
return (r > 175 && g < 95 && b < 65 && (r - g) > 95);
}
bool CheckContextAboveHp(const uint8_t* bgra, int width, int height, int stride, int centerX, int topY) {
int y0 = std::max(0, topY - 16);
int y1 = std::max(0, topY - 3);
int x0 = std::max(0, centerX - 22);
int x1 = std::min(width - 1, centerX + 22);
int contextHits = 0;
for (int y = y0; y <= y1; ++y) {
const uint8_t* row = bgra + y * stride;
for (int x = x0; x <= x1; ++x) {
uint8_t b = row[x * 4 + 0];
uint8_t g = row[x * 4 + 1];
uint8_t r = row[x * 4 + 2];
bool isText = (r > 195 && g > 195 && b > 195);
bool isBorder = (r < 48 && g < 48 && b < 48);
if (isText || isBorder) contextHits++;
}
}
return contextHits >= 12;
}
bool HasMinimapEnemyPresence(const uint8_t* bgra, int width, int height, int stride) {
int x0 = (int)(g_Cfg.minimapRoi[0] * width);
int y0 = (int)(g_Cfg.minimapRoi[1] * height);
int x1 = std::min(width, (int)((g_Cfg.minimapRoi[0] + g_Cfg.minimapRoi[2]) * width));
int y1 = std::min(height, (int)((g_Cfg.minimapRoi[1] + g_Cfg.minimapRoi[3]) * height));
int redDots = 0;
for (int y = y0; y < y1; y += 2) {
const uint8_t* row = bgra + y * stride;
for (int x = x0; x < x1; x += 2) {
if (IsEnemyHpColor(row[x * 4], row[x * 4 + 1], row[x * 4 + 2])) {
if (++redDots >= 5) return true;
}
}
}
return false;
}
void ProcessFrameBuffer(std::vector<uint8_t>&& buffer, int texW, int texH, int stride, float scale) {
const uint8_t* data = buffer.data();
if (!HasMinimapEnemyPresence(data, texW, texH, stride)) {
std::lock_guardstd::mutex lock(g_StateMutex);
g_TrackedTargets.clear();
g_CurrentLockedId = -1;
if (g_BotState.load() != BotState::EXECUTING) {
g_BotState.store(BotState::SCANNING);
}
g_IsProcessing.store(false);
return;
}
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
if (blobW < scaledStdWidth * 0.65f || blobH < scaledMinH || blobH > scaledMaxH * 2.5f) {
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
std::lock_guardstd::mutex lock(g_StateMutex);
for (auto& t : g_TrackedTargets) {
t.missingFrames++;
}
for (const auto& blob : detectedBlobs) {
int bestIdx = -1;
float bestDist = 48.0f;
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
newT.queueSlot = -1;
g_TrackedTargets.push_back(newT);
}
}
g_TrackedTargets.erase(
std::remove_if(g_TrackedTargets.begin(), g_TrackedTargets.end(), [](const TrackedTarget& t) {
if (t.missingFrames > 4) {
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
if (t.id == g_CurrentLockedId && t.consecutiveFrames >= g_Cfg.minConfirmFrames) {
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
if (chosenTarget && g_Cfg.autoEngage && g_BotState.load() != BotState::EXECUTING) {
g_BotState.store(BotState::LOCKED);
CGPoint bodyAimPt = CGPointMake(chosenTarget->center.x, chosenTarget->center.y + 42.0f);
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
dispatch_async(g_VisionQueue, 
mutable {
ProcessFrameBuffer(std::move(buf), w, h, stride, scale);
});
}
}
// ============================================================================
// SWIZZLE CAMETALLAYER
// ============================================================================
static id<CAMetalDrawable> (*orig_nextDrawable)(id self, SEL _cmd);
static void (*orig_setFramebufferOnly)(id self, SEL _cmd, BOOL flag);
static void hooked_setFramebufferOnly(id self, SEL _cmd, BOOL flag) {
orig_setFramebufferOnly(self, @selector(setFramebufferOnly:), NO);
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
// OVERLAY WINDOW & IMGUI RENDERER
// ============================================================================
@interface PXNoFocusTextField : UITextField
@end
@implementation PXNoFocusTextField
￼ (BOOL)canBecomeFirstResponder { return NO; }
@end
static CGRect g_ImGuiWindowRect = CGRectZero;
@interface PXPassthroughWindow : UIWindow
@end
@implementation PXPassthroughWindow
￼ (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
UIView *hitView = [super hitTest:point withEvent:event];
if (!hitView) return nil;
if (hitView.tag == 999) return hitView;
if (!g_ShowImGuiMenu) return nil;
if (!CGRectIsEmpty(g_ImGuiWindowRect) && CGRectContainsPoint(g_ImGuiWindowRect, point)) return hitView;
if (ImGui::GetCurrentContext() != nullptr && ImGui::GetIO().WantCaptureMouse) return hitView;
return nil;
}
@end
@interface PXOverlayController : UIViewController <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) UIButton *floatingToggleBtn;
@property (nonatomic, strong) UIButton *menuToggleBtn;
@property (nonatomic, strong) UIButton *btnC1;
@property (nonatomic, strong) UIButton *btnC2;
@property (nonatomic, strong) UIButton *btnC3;
@end
@implementation PXOverlayController
￼ (void)viewDidLoad {
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
IMGUI_CHECKVERSION();
ImGui::CreateContext();
ImGuiIO &io = ImGui::GetIO();
io.IniFilename = nullptr;
ImGui::StyleColorsDark();
ImGui::GetStyle().WindowRounding = 8.0f;
ImGui::GetStyle().FrameRounding = 4.0f;
ImGui_ImplMetal_Init(device);
self.floatingToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
self.floatingToggleBtn.tag = 999;
self.floatingToggleBtn.frame = CGRectMake(24, 110, 46, 46);
self.floatingToggleBtn.layer.cornerRadius = 23;
self.floatingToggleBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:g_Cfg.uiOpacity];
[self.floatingToggleBtn setTitle:@"OFF" forState:UIControlStateNormal];
self.floatingToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
[self.floatingToggleBtn addTarget:self action:@selector(onToggleBot) forControlEvents:UIControlEventTouchUpInside];
[self makeDraggable:self.floatingToggleBtn];
[self.view addSubview:self.floatingToggleBtn];
self.menuToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
self.menuToggleBtn.tag = 999;
self.menuToggleBtn.frame = CGRectMake(78, 110, 46, 46);
self.menuToggleBtn.layer.cornerRadius = 23;
self.menuToggleBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.20 alpha:g_Cfg.uiOpacity];
[self.menuToggleBtn setTitle:@"PX" forState:UIControlStateNormal];
self.menuToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
[self.menuToggleBtn addTarget:self action:@selector(onToggleMenu) forControlEvents:UIControlEventTouchUpInside];
[self makeDraggable:self.menuToggleBtn];
[self.view addSubview:self.menuToggleBtn];
self.btnC1 = [self createQuickButton:@"C1" frame:CGRectMake(132, 110, 42, 42) combo:NakrothComboType::GANK_LONG_RANGE];
self.btnC2 = [self createQuickButton:@"C2" frame:CGRectMake(180, 110, 42, 42) combo:NakrothComboType::CLOSE_COMBAT];
self.btnC3 = [self createQuickButton:@"C3" frame:CGRectMake(228, 110, 42, 42) combo:NakrothComboType::POKE_AND_RUN];
[self updateQuickButtonHighlights];
UITapGestureRecognizer *stealthTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onStealthGesture)];
stealthTap.numberOfTouchesRequired = 3;
stealthTap.numberOfTapsRequired = 2;
stealthTap.cancelsTouchesInView = NO;
stealthTap.delaysTouchesEnded = NO;
[self.view addGestureRecognizer:stealthTap];
ConfigStorage::LoadPreset("default");
}
￼ (UIButton *)createQuickButton:(NSString *)title frame:(CGRect)frame combo:(NakrothComboType)combo {
UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
btn.tag = 999;
btn.frame = frame;
btn.layer.cornerRadius = 21;
btn.backgroundColor = [UIColor colorWithRed:0.20 green:0.20 blue:0.30 alpha:g_Cfg.uiOpacity];
[btn setTitle:title forState:UIControlStateNormal];
btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
[btn addTarget:self action:@selector(onQuickComboTapped:) forControlEvents:UIControlEventTouchUpInside];
objc_setAssociatedObject(btn, "comboType", @((int)combo), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
[self makeDraggable:btn];
[self.view addSubview:btn];
return btn;
}
￼ (UIButton *)makeDraggable:(UIButton *)btn {
UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onButtonPan:)];
[btn addGestureRecognizer:pan];
return btn;
}
￼ (void)onButtonPan:(UIPanGestureRecognizer *)pan {
UIView *btn = pan.view;
CGPoint translation = [pan translationInView:self.view];
CGPoint newCenter = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
CGSize screen = self.view.bounds.size;
newCenter.x = MAX(25, MIN(screen.width - 25, newCenter.x));
newCenter.y = MAX(25, MIN(screen.height - 25, newCenter.y));
btn.center = newCenter;
[pan setTranslation:CGPointZero inView:self.view];
}
￼ (void)onQuickComboTapped:(UIButton *)sender {
int comboInt = [objc_getAssociatedObject(sender, "comboType") intValue];
g_Cfg.selectedCombo = (NakrothComboType)comboInt;
[self updateQuickButtonHighlights];
CGPoint centerPt = CGPointMake(self.mtkView.bounds.size.width * 0.5f, self.mtkView.bounds.size.height * 0.5f);
TouchEngine::ExecuteNakrothSelectedCombo(centerPt, g_Cfg.selectedCombo);
}
￼ (void)updateQuickButtonHighlights {
UIColor *normalCol = [UIColor colorWithRed:0.20 green:0.20 blue:0.30 alpha:g_Cfg.uiOpacity];
UIColor *activeCol = [UIColor colorWithRed:0.90 green:0.50 blue:0.10 alpha:g_Cfg.uiOpacity];
self.btnC1.backgroundColor = (g_Cfg.selectedCombo == NakrothComboType::GANK_LONG_RANGE) ? activeCol : normalCol;
self.btnC2.backgroundColor = (g_Cfg.selectedCombo == NakrothComboType::CLOSE_COMBAT) ? activeCol : normalCol;
self.btnC3.backgroundColor = (g_Cfg.selectedCombo == NakrothComboType::POKE_AND_RUN) ? activeCol : normalCol;
self.btnC1.hidden = !g_Cfg.showQuickComboBtns;
self.btnC2.hidden = !g_Cfg.showQuickComboBtns;
self.btnC3.hidden = !g_Cfg.showQuickComboBtns;
}
￼ (void)onToggleBot {
g_Cfg.masterEnable = !g_Cfg.masterEnable;
g_BotState.store(g_Cfg.masterEnable ? BotState::SCANNING : BotState::IDLE);
[self.floatingToggleBtn setTitle:(g_Cfg.masterEnable ? @"ON" : @"OFF") forState:UIControlStateNormal];
self.floatingToggleBtn.backgroundColor = g_Cfg.masterEnable
? [UIColor colorWithRed:0.10 green:0.75 blue:0.35 alpha:g_Cfg.uiOpacity]
: [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:g_Cfg.uiOpacity];
}
￼ (void)onToggleMenu {
g_ShowImGuiMenu = !g_ShowImGuiMenu;
if (!g_ShowImGuiMenu) g_ImGuiWindowRect = CGRectZero;
}
￼ (void)onStealthGesture {
BOOL hide = !self.floatingToggleBtn.hidden;
self.floatingToggleBtn.hidden = hide;
self.menuToggleBtn.hidden = hide;
self.btnC1.hidden = hide || !g_Cfg.showQuickComboBtns;
self.btnC2.hidden = hide || !g_Cfg.showQuickComboBtns;
self.btnC3.hidden = hide || !g_Cfg.showQuickComboBtns;
if (hide) {
g_ShowImGuiMenu = false;
g_ImGuiWindowRect = CGRectZero;
}
}
￼ (void)updateImGuiTouch:(NSSet<UITouch *> *)touches phase:(UITouchPhase)phase {
if (!g_ShowImGuiMenu) return;
UITouch *touch = [touches anyObject];
if (!touch) return;
CGPoint loc = [touch locationInView:self.mtkView];
ImGuiIO &io = ImGui::GetIO();
io.AddMousePosEvent((float)loc.x, (float)loc.y);
if (phase == UITouchPhaseBegan) {
io.AddMouseButtonEvent(0, true);
} else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
io.AddMouseButtonEvent(0, false);
}
}
￼ (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseBegan]; }
￼ (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseMoved]; }
￼ (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseEnded]; }
￼ (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateImGuiTouch:touches phase:UITouchPhaseCancelled]; }
￼ (void)RenderImGuiTabs {
ImGui::SetNextWindowSize(ImVec2(480, 380), ImGuiCond_FirstUseEver);
if (!ImGui::Begin("PX · Nakroth Quick Combos", &g_ShowImGuiMenu, ImGuiWindowFlags_NoCollapse)) {
ImVec2 pos = ImGui::GetWindowPos();
ImVec2 size = ImGui::GetWindowSize();
g_ImGuiWindowRect = CGRectMake(pos.x, pos.y, size.x, size.y);
ImGui::End();
return;
}
ImVec2 pos = ImGui::GetWindowPos();
ImVec2 size = ImGui::GetWindowSize();
g_ImGuiWindowRect = CGRectMake(pos.x, pos.y, size.x, size.y);
if (ImGui::BeginTabBar("PXNakrothTabs")) {
if (ImGui::BeginTabItem("Combo & Nut Nhanh")) {
ImGui::Checkbox("Auto-Engage (Tu dong khi khoa muc tieu)", &g_Cfg.autoEngage);
if (ImGui::Checkbox("Hien thi cum 3 nut C1 C2 C3 tren man hinh", &g_Cfg.showQuickComboBtns)) {
[self updateQuickButtonHighlights];
}
ImGui::Separator();
ImGui::Text("Chon Loai Combo & Mo Ta Chi Tiet:");
int comboVal = (int)g_Cfg.selectedCombo;
if (ImGui::RadioButton("C1: Gank tu xa", &comboVal, 1)) {
g_Cfg.selectedCombo = NakrothComboType::GANK_LONG_RANGE;
[self updateQuickButtonHighlights];
}
ImGui::SameLine(); ImGui::TextDisabled("(S2 -> AA -> S1 -> S3 -> AA -> S1)");
if (ImGui::RadioButton("C2: Dich o gan", &comboVal, 2)) {
g_Cfg.selectedCombo = NakrothComboType::CLOSE_COMBAT;
[self updateQuickButtonHighlights];
}
ImGui::SameLine(); ImGui::TextDisabled("(S1 -> AA -> S3 -> S2 -> AA -> S1)");
if (ImGui::RadioButton("C3: Cau ria / Rut lui", &comboVal, 3)) {
g_Cfg.selectedCombo = NakrothComboType::POKE_AND_RUN;
[self updateQuickButtonHighlights];
}
ImGui::SameLine(); ImGui::TextDisabled("(S2 -> S1 -> AA -> S1 lui)");
ImGui::Separator();
if (ImGui::Button("Test Chay Combo Da Chon")) {
CGPoint centerPt = CGPointMake(self.mtkView.bounds.size.width * 0.5f, self.mtkView.bounds.size.height * 0.5f);
TouchEngine::ExecuteNakrothSelectedCombo(centerPt, g_Cfg.selectedCombo);
}
ImGui::Separator();
ImGui::SliderFloat("Touch Jitter (px)", &g_Cfg.posJitterPx, 0.0f, 12.0f, "%.1f");
ImGui::SliderInt("Delay Jitter (ms)", &g_Cfg.timeJitterMs, 0, 45);
ImGui::EndTabItem();
}
if (ImGui::BeginTabItem("Vision")) {
ImGui::Checkbox("Ve khung Debug ESP", &g_Cfg.drawDebugEsp);
ImGui::SliderInt("Tan suat quet (FPS)", &g_Cfg.captureFps, 6, 20);
ImGui::SliderFloat("Chieu rong HP chuan (px)", &g_Cfg.standardHpWidth, 40.0f, 110.0f, "%.0f");
ImGui::SliderInt("Temporal Confirm Frames", &g_Cfg.minConfirmFrames, 1, 6);
ImGui::EndTabItem();
}
if (ImGui::BeginTabItem("Config")) {
if (ImGui::SliderFloat("Do mo nut noi", &g_Cfg.uiOpacity, 0.2f, 1.0f, "%.2f")) {
self.floatingToggleBtn.alpha = g_Cfg.uiOpacity;
self.menuToggleBtn.alpha = g_Cfg.uiOpacity;
self.btnC1.alpha = g_Cfg.uiOpacity;
self.btnC2.alpha = g_Cfg.uiOpacity;
self.btnC3.alpha = g_Cfg.uiOpacity;
}
ImGui::Text("An/Hien nhanh: Cham 3 ngon 2 lan");
ImGui::Separator();
if (ImGui::Button("Luu Default")) ConfigStorage::SavePreset("default");
ImGui::SameLine();
if (ImGui::Button("Tai Default")) ConfigStorage::LoadPreset("default");
ImGui::EndTabItem();
}
ImGui::EndTabBar();
}
ImGui::End();
}
￼ (void)drawInMTKView:(MTKView *)view {
MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
if (!rpd) return;
ImGuiIO &io = ImGui::GetIO();
io.DisplaySize = ImVec2((float)view.bounds.size.width, (float)view.bounds.size.height);
float scale = (float)[UIScreen mainScreen].scale;
io.DisplayFramebufferScale = ImVec2(scale, scale);
id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
ImGui_ImplMetal_NewFrame(rpd);
ImGui::NewFrame();
if (g_Cfg.masterEnable && g_Cfg.drawDebugEsp) {
ImDrawList *bg = ImGui::GetBackgroundDrawList();
std::lock_guardstd::mutex lock(g_StateMutex);
for (const auto& t : g_TrackedTargets) {
if (t.consecutiveFrames < g_Cfg.minConfirmFrames) continue;
bool isLocked = (t.id == g_CurrentLockedId);
ImU32 col = isLocked ? IM_COL32(255, 50, 50, 230) : IM_COL32(255, 210, 40, 190);
float halfW = t.width * 0.5f;
bg->AddRect(
ImVec2((float)t.center.x - halfW, (float)t.center.y - 8.0f),
ImVec2((float)t.center.x + halfW, (float)t.center.y + 8.0f),
col, 2.0f, 0, isLocked ? 2.5f : 1.5f
);
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
[cmdBuf presentDrawable:view.currentDrawable];
[cmdBuf commit];
}
￼ (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
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
if (g_Cfg.stealthMode) {
PXNoFocusTextField *secureField = [[PXNoFocusTextField alloc] initWithFrame:g_OverlayWindow.bounds];
secureField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
secureField.secureTextEntry = YES;
secureField.userInteractionEnabled = YES;
secureField.backgroundColor = [UIColor clearColor];
UIView *secureContainer = secureField.subviews.firstObject;
if (secureContainer) {
secureContainer.frame = g_OverlayWindow.bounds;
secureContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
secureContainer.userInteractionEnabled = YES;
[g_OverlayWindow addSubview:secureField];
[secureContainer addSubview:g_OverlayWindow.rootViewController.view];
}
}
g_OverlayWindow.hidden = NO;
}
attribute((constructor))
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
