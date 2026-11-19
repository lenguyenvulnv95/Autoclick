// AutoClick.m - iOS auto click dylib (tiêm bằng ESign / TrollFools)
// Phiên bản v3 - Đã vá các lỗi runtime:
// 1. Khóa màn hình ngang (Landscape)
// 2. Chạm 3 ngón tay 3 lần bất kỳ trên màn hình để mở/đóng menu (lọc chạm hủy & chạm xen giữa)
// 3. Thêm 2 chế độ Play/Stop trên đầu menu: Chạm bật/tắt & Giữ để chạy (thả ra dừng)
// 4. Bảo toàn chạm thật khi inject touch (sửa lỗi văng/kẹt ở Chế độ 2)
// 5. Chống kích hoạt nhầm khi kéo Hub lúc mở menu ở Chế độ 2
// 6. Tự động lưu vị trí các điểm, vị trí Hub và chế độ chạy
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wincomplete-implementation"

#define MAXP 10

#pragma mark - IOHIDEvent Constants

#define kIOHIDDigitizerTransducerTypeHand   3
#define kIOHIDDigitizerEventRange           (1 << 0)
#define kIOHIDDigitizerEventTouch           (1 << 1)
#define kIOHIDDigitizerEventPosition        (1 << 2)

#define kIOHIDEventFieldDigitizerX                      0xb0000
#define kIOHIDEventFieldDigitizerY                      0xb0001
#define kIOHIDEventFieldDigitizerMajorRadius            0xb0014
#define kIOHIDEventFieldDigitizerMinorRadius            0xb0015
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated    0xb0019

#pragma mark - Private API declarations

typedef struct __IOHIDEvent *IOHIDEventRef;

static IOHIDEventRef (*pCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int);
static void (*pSetFloat)(IOHIDEventRef, uint32_t, double);

@interface UITouch (ACPrivate)
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)setTapCount:(NSUInteger)c;
- (void)setIsTap:(BOOL)b;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)setPhase:(UITouchPhase)p;
- (void)setGestureView:(UIView *)v;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setIsFirstTouchForView:(BOOL)b;
- (void)_setIsTapToClick:(BOOL)b;
- (void)_setHidEvent:(IOHIDEventRef)e;
@end

@interface UIEvent (ACPrivate)
- (void)_setHIDEvent:(IOHIDEventRef)e;
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
@end

@interface UIApplication (ACPrivate)
- (UIEvent *)_touchesEvent;
@end

@class ACController;
static UIWindow *gOverlay = nil;
static __weak ACController *gController = nil;
static BOOL gIsInjectingTouch = NO;

#pragma mark - Touch Injection Engine

static BOOL LoadIOKit(void) {
    static BOOL ok = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) return;
        pCreateDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent");
        pCreateFinger    = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        pAppend          = dlsym(h, "IOHIDEventAppendEvent");
        pSetInt          = dlsym(h, "IOHIDEventSetIntegerValue");
        pSetFloat        = dlsym(h, "IOHIDEventSetFloatValue");
        ok = (pCreateDigitizer && pCreateFinger && pAppend && pSetInt && pSetFloat);
    });
    return ok;
}

static IOHIDEventRef MakeHID(UITouchPhase phase, CGPoint windowPoint, UIWindow *window) {
    uint64_t ts = mach_absolute_time();
    BOOL touching = (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved || phase == UITouchPhaseStationary);
    uint32_t handMask = (phase == UITouchPhaseMoved) ? kIOHIDDigitizerEventPosition : kIOHIDDigitizerEventTouch;
    uint32_t fingerMask = (phase == UITouchPhaseMoved) ? kIOHIDDigitizerEventPosition : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

    CGSize screenBounds = UIScreen.mainScreen.bounds.size;
    CGPoint screenPt = [window convertPoint:windowPoint toWindow:nil];
    double normX = (screenBounds.width > 0) ? (screenPt.x / screenBounds.width) : screenPt.x;
    double normY = (screenBounds.height > 0) ? (screenPt.y / screenBounds.height) : screenPt.y;

    IOHIDEventRef hand = pCreateDigitizer(kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 0, handMask, 0, normX, normY, 0.0, 0.0, 0.0, NO, touching, 0);
    if (!hand) return NULL;
    pSetInt(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    IOHIDEventRef finger = pCreateFinger(kCFAllocatorDefault, ts, 1, 2, fingerMask, normX, normY, 0.0, touching ? 1.0 : 0.0, 0.0, touching, touching, 0);
    if (finger) {
        pSetFloat(finger, kIOHIDEventFieldDigitizerMajorRadius, 5.0);
        pSetFloat(finger, kIOHIDEventFieldDigitizerMinorRadius, 5.0);
        pAppend(hand, finger, 0);
        CFRelease(finger);
    }
    return hand;
}

static UIWindow *TargetWindow(void) {
    UIWindow *best = nil;
    NSMutableArray<UIWindow *> *winList = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive)) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                [winList addObjectsFromArray:ws.windows];
            }
        }
    }
    if (winList.count == 0) [winList addObjectsFromArray:UIApplication.sharedApplication.windows];

    for (UIWindow *w in winList) {
        if (w == gOverlay || w.hidden || w.alpha < 0.01) continue;
        if ([NSStringFromClass(w.class) hasPrefix:@"UIRemoteKeyboard"] || [NSStringFromClass(w.class) hasPrefix:@"UITextEffects"]) continue;
        if (w.isKeyWindow) return w;
        if (w.windowLevel == UIWindowLevelNormal) best = w;
        else if (!best) best = w;
    }
    return best;
}

static void SendTouch(UITouch *t, UITouchPhase phase, CGPoint p, UIWindow *w) {
    if (!t || !w) return;
    if ([t respondsToSelector:@selector(setPhase:)]) [t setPhase:phase];
    if ([t respondsToSelector:@selector(setTimestamp:)]) [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    if ([t respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]) {
        [t _setLocationInWindow:p resetPrevious:(phase == UITouchPhaseBegan)];
    }
    if (![UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)]) return;
    UIEvent *ev = [UIApplication.sharedApplication _touchesEvent];
    if (!ev) return;

    // Lưu tạm các ngón tay thật đang giữ trên màn hình (ví dụ đang giữ nút Play/Stop ở Chế độ 2)
    NSMutableArray<UITouch *> *savedRealTouches = [NSMutableArray array];
    NSSet<UITouch *> *currentTouches = [ev allTouches];
    for (UITouch *existing in currentTouches) {
        if (existing != t && (existing.phase == UITouchPhaseBegan || existing.phase == UITouchPhaseMoved || existing.phase == UITouchPhaseStationary)) {
            [savedRealTouches addObject:existing];
        }
    }

    if ([ev respondsToSelector:@selector(_clearTouches)]) [ev _clearTouches];

    IOHIDEventRef hid = MakeHID(phase, p, w);
    if (hid) {
        if ([t respondsToSelector:@selector(_setHidEvent:)]) [t _setHidEvent:hid];
        if ([ev respondsToSelector:@selector(_setHIDEvent:)]) [ev _setHIDEvent:hid];
        CFRelease(hid);
    }
    if ([ev respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) [ev _addTouch:t forDelayedDelivery:NO];

    gIsInjectingTouch = YES;
    [UIApplication.sharedApplication sendEvent:ev];
    gIsInjectingTouch = NO;

    // Khôi phục lại các ngón tay thật đang giữ để không làm ngắt sự kiện TouchUp/TouchCancel
    if (savedRealTouches.count > 0) {
        if ([ev respondsToSelector:@selector(_clearTouches)]) [ev _clearTouches];
        if ([ev respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) {
            for (UITouch *real in savedRealTouches) {
                [ev _addTouch:real forDelayedDelivery:NO];
            }
        }
    }
}

static void DoTap(CGPoint screenPoint, NSTimeInterval hold) {
    if (!LoadIOKit()) return;
    UIWindow *w = TargetWindow();
    if (!w) return;

    CGPoint winPoint = gOverlay ? [w convertPoint:screenPoint fromWindow:gOverlay] : screenPoint;
    UIView *v = [w hitTest:winPoint withEvent:nil];
    if (!v) v = w;

    UITouch *t = [[UITouch alloc] init];
    if ([t respondsToSelector:@selector(setTapCount:)]) [t setTapCount:1];
    if ([t respondsToSelector:@selector(setIsTap:)]) [t setIsTap:YES];
    if ([t respondsToSelector:@selector(_setIsTapToClick:)]) [t _setIsTapToClick:YES];
    if ([t respondsToSelector:@selector(setWindow:)]) [t setWindow:w];
    if ([t respondsToSelector:@selector(setView:)]) [t setView:v];
    if ([t respondsToSelector:@selector(_setIsFirstTouchForView:)]) [t _setIsFirstTouchForView:YES];
    if ([t respondsToSelector:@selector(setGestureView:)]) [t setGestureView:v];

    SendTouch(t, UITouchPhaseBegan, winPoint, w);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SendTouch(t, UITouchPhaseEnded, winPoint, w);
    });
}

#pragma mark - Overlay Window

@interface ACWindow : UIWindow
@end
@implementation ACWindow
- (UIView *)hitTest:(CGPoint)pt withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:pt withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

#pragma mark - Controller & UI

@interface ACController : UIViewController {
    UIView *_hub, *_panel;
    UIButton *_play;
    UIButton *_modeTapBtn, *_modeHoldBtn;
    UIPanGestureRecognizer *_hubPan;
    UIScrollView *_scroll;
    NSMutableArray<UILabel *> *_markers;
    NSMutableDictionary<NSNumber *, UIStepper *> *_steppers;
    NSMutableDictionary<NSNumber *, UILabel *> *_vals, *_titles;
    BOOL _running, _menuOpen;
    NSUInteger _token;
    int _runMode; // 0 = Chạm bật / Chạm tắt | 1 = Giữ để chạy / Thả ra dừng
    int _count, _hold, _loops, _delay[MAXP];
    double _px[MAXP], _py[MAXP];
    CGPoint _hubPos;
}
- (void)toggleMenu;
@end

@implementation ACController

// Cố định màn hình ngang (Landscape)
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }

- (void)loadDefaults {
    _runMode = 0; _count = 3; _hold = 50; _loops = 0; _hubPos = CGPointMake(40, 90);
    for (int i = 0; i < MAXP; i++) {
        _delay[i] = 500;
        _px[i] = 0.75;
        _py[i] = 0.15 + 0.07 * i;
    }
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"AC_cfg"];
    if (!d) return;
    if (d[@"runMode"]) _runMode = ([d[@"runMode"] intValue] == 1) ? 1 : 0;
    if (d[@"count"])   _count   = MAX(1, MIN(MAXP, [d[@"count"] intValue]));
    if (d[@"hold"])    _hold    = MAX(10, MIN(2000, [d[@"hold"] intValue]));
    if (d[@"loops"])   _loops   = MAX(0, MIN(999, [d[@"loops"] intValue]));
    if (d[@"hx"] && d[@"hy"]) {
        _hubPos = CGPointMake([d[@"hx"] doubleValue], [d[@"hy"] doubleValue]);
    }
    NSArray *dl = d[@"delay"], *x = d[@"x"], *y = d[@"y"];
    for (int i = 0; i < MAXP; i++) {
        if ((NSUInteger)i < dl.count) _delay[i] = MAX(0, [dl[i] intValue]);
        if ((NSUInteger)i < x.count)  _px[i] = MIN(1.0, MAX(0.0, [x[i] doubleValue]));
        if ((NSUInteger)i < y.count)  _py[i] = MIN(1.0, MAX(0.0, [y[i] doubleValue]));
    }
}

- (void)save {
    NSMutableArray *dl = [NSMutableArray array], *x = [NSMutableArray array], *y = [NSMutableArray array];
    for (int i = 0; i < MAXP; i++) {
        [dl addObject:@(_delay[i])];
        [x addObject:@(_px[i])];
        [y addObject:@(_py[i])];
    }
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"runMode": @(_runMode),
        @"count":   @(_count),
        @"hold":    @(_hold),
        @"loops":   @(_loops),
        @"hx":      @(_hubPos.x),
        @"hy":      @(_hubPos.y),
        @"delay":   dl,
        @"x":       x,
        @"y":       y
    } forKey:@"AC_cfg"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    gController = self;
    self.view.backgroundColor = UIColor.clearColor;
    [self loadDefaults];
    _markers  = [NSMutableArray array];
    _steppers = [NSMutableDictionary dictionary];
    _vals     = [NSMutableDictionary dictionary];
    _titles   = [NSMutableDictionary dictionary];
    [self buildMarkers];
    [self buildPanel];
    [self buildHub];
    [self refreshAll];
}

#pragma mark Hub & Play/Stop Modes

- (void)buildHub {
    _hub = [[UIView alloc] initWithFrame:CGRectMake(_hubPos.x, _hubPos.y, 50, 50)];
    _hub.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    _hub.layer.cornerRadius = 25;
    _hub.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _hub.layer.borderWidth = 1.0;

    _play = [UIButton buttonWithType:UIButtonTypeCustom];
    _play.frame = CGRectMake(5, 5, 40, 40);
    _play.layer.cornerRadius = 20;
    _play.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];

    // Gắn sự kiện cho cả 2 chế độ: Chạm bật/tắt và Giữ để chạy
    [_play addTarget:self action:@selector(playTouchDown) forControlEvents:UIControlEventTouchDown];
    [_play addTarget:self action:@selector(playTouchUpInside) forControlEvents:UIControlEventTouchUpInside];
    [_play addTarget:self action:@selector(playTouchUpOutside) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    [_hub addSubview:_play];
    _hubPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panHub:)];
    _hubPan.cancelsTouchesInView = YES;
    [_hub addGestureRecognizer:_hubPan];
    [self.view addSubview:_hub];
}

- (void)toggleMenu {
    _menuOpen = !_menuOpen;
    if (_menuOpen && _runMode == 1 && _running) {
        [self stop];
    }
    [self refreshAll];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feed = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feed impactOccurred];
    }
}

- (void)playTouchDown {
    // Ở Chế độ 2, không tự kích hoạt chạy khi đang mở menu để người dùng kéo dời vị trí Hub thoải mái
    if (_runMode == 1 && !_menuOpen) {
        [self start];
    }
}

- (void)playTouchUpInside {
    if (_runMode == 0) {
        // Chế độ 1: Chạm bật / Chạm tắt
        [self togglePlay];
    } else {
        // Chế độ 2: Thả tay ra là dừng
        [self stop];
    }
}

- (void)playTouchUpOutside {
    if (_runMode == 1) {
        // Chế độ 2: Trượt tay ra ngoài hoặc bị hủy chạm cũng dừng ngay
        [self stop];
    }
}

- (void)refreshPlayButton {
    if (_running) {
        _play.backgroundColor = [UIColor colorWithRed:0.1 green:0.75 blue:0.2 alpha:1];
        [_play setTitle:@"▶" forState:UIControlStateNormal];
    } else {
        _play.backgroundColor = [UIColor colorWithRed:0.9 green:0.15 blue:0.15 alpha:1];
        [_play setTitle:@"■" forState:UIControlStateNormal];
    }
}

- (void)panHub:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && _runMode == 1 && _running) {
        [self stop];
    }
    CGPoint tr = [g translationInView:self.view];
    [g setTranslation:CGPointZero inView:self.view];
    CGRect b = self.view.bounds;
    CGPoint c = CGPointMake(_hub.center.x + tr.x, _hub.center.y + tr.y);
    c.x = MIN(MAX(c.x, 25), b.size.width - 25);
    c.y = MIN(MAX(c.y, 25), b.size.height - 25);
    _hub.center = c;
    _hubPos = _hub.frame.origin;
    [self layoutPanel];
    if (g.state == UIGestureRecognizerStateEnded) [self save];
}

#pragma mark Markers (1..10) - Tự động lưu vị trí khi kéo thả

- (void)buildMarkers {
    for (int i = 0; i < MAXP; i++) {
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
        m.text = [NSString stringWithFormat:@"%d", i + 1];
        m.textAlignment = NSTextAlignmentCenter;
        m.textColor = UIColor.whiteColor;
        m.font = [UIFont boldSystemFontOfSize:16];
        m.backgroundColor = [UIColor colorWithRed:0.1 green:0.4 blue:0.95 alpha:0.75];
        m.layer.cornerRadius = 19;
        m.layer.masksToBounds = YES;
        m.layer.borderColor = UIColor.whiteColor.CGColor;
        m.layer.borderWidth = 2;
        m.userInteractionEnabled = YES;
        m.tag = i;
        [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMarker:)]];
        [self.view insertSubview:m atIndex:0];
        [_markers addObject:m];
    }
}

- (CGPoint)pointForIndex:(int)i {
    CGSize b = self.view.bounds.size;
    return CGPointMake(_px[i] * b.width, _py[i] * b.height);
}

- (void)panMarker:(UIPanGestureRecognizer *)g {
    UIView *m = g.view;
    int i = (int)m.tag;
    CGPoint tr = [g translationInView:self.view];
    [g setTranslation:CGPointZero inView:self.view];
    CGSize b = self.view.bounds.size;
    if (b.width <= 0 || b.height <= 0) return;
    CGPoint c = CGPointMake(MIN(MAX(m.center.x + tr.x, 0), b.width), MIN(MAX(m.center.y + tr.y, 0), b.height));
    m.center = c;
    _px[i] = c.x / b.width;
    _py[i] = c.y / b.height;
    if (g.state == UIGestureRecognizerStateEnded) {
        [self save];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (int i = 0; i < MAXP; i++) {
        _markers[i].center = [self pointForIndex:i];
    }
    CGRect b = self.view.bounds;
    CGRect f = _hub.frame;
    f.origin.x = MIN(MAX(f.origin.x, 0), MAX(0, b.size.width - f.size.width));
    f.origin.y = MIN(MAX(f.origin.y, 0), MAX(0, b.size.height - f.size.height));
    _hub.frame = f;
    _hubPos = f.origin;
    [self layoutPanel];
}

#pragma mark Panel (Cài đặt)

- (UIButton *)makeModeButtonAtY:(CGFloat)y tag:(int)tag title:(NSString *)title {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(12, y, 276, 36);
    btn.tag = tag;
    btn.layer.cornerRadius = 8;
    btn.layer.borderWidth = 1.0;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    btn.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    btn.titleLabel.adjustsFontSizeToFitWidth = YES;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(selectMode:) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:btn];
    return btn;
}

- (void)selectMode:(UIButton *)btn {
    int newMode = (int)btn.tag;
    if (_runMode != newMode) {
        if (_running) [self stop];
        _runMode = newMode;
        [self save];
        [self refreshAll];
    }
}

- (UIStepper *)addRowAtY:(CGFloat)y tag:(int)tag title:(NSString *)title min:(double)mn max:(double)mx step:(double)st value:(double)v {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 125, 44)];
    t.text = title; t.textColor = UIColor.whiteColor; t.font = [UIFont systemFontOfSize:13];
    t.adjustsFontSizeToFitWidth = YES;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(135, y, 62, 44)];
    l.textColor = [UIColor colorWithRed:0.5 green:1 blue:0.6 alpha:1];
    l.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    l.textAlignment = NSTextAlignmentRight;

    UIStepper *s = [[UIStepper alloc] initWithFrame:CGRectMake(204, y + 7, 94, 30)];
    s.minimumValue = mn; s.maximumValue = mx; s.stepValue = st; s.value = v; s.tag = tag;
    [s addTarget:self action:@selector(stepChanged:) forControlEvents:UIControlEventValueChanged];

    [_scroll addSubview:t]; [_scroll addSubview:l]; [_scroll addSubview:s];
    _steppers[@(tag)] = s; _vals[@(tag)] = l; _titles[@(tag)] = t;
    return s;
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 420)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.90];
    _panel.layer.cornerRadius = 14;
    _panel.clipsToBounds = YES;

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 276, 30)];
    h.text = @"Cài đặt Auto Click (3 ngón x3)";
    h.textColor = UIColor.whiteColor;
    h.font = [UIFont boldSystemFontOfSize:14];
    [_panel addSubview:h];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 36, 300, 384)];
    [_panel addSubview:_scroll];

    CGFloat y = 6;
    // 2 Tùy chọn chế độ Play/Stop đặt trên cùng của menu
    _modeTapBtn  = [self makeModeButtonAtY:y tag:0 title:@"Chạm Play/Stop: Chạy liên tục / Dừng"]; y += 42;
    _modeHoldBtn = [self makeModeButtonAtY:y tag:1 title:@"Giữ Play/Stop: Chạy / Thả tay ra dừng"]; y += 44;

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, y, 276, 1)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    [_scroll addSubview:sep];
    y += 8;

    [self addRowAtY:y tag:100 title:@"Số điểm click" min:1 max:MAXP step:1 value:_count]; y += 44;
    [self addRowAtY:y tag:101 title:@"Thời gian nhấn (ms)" min:10 max:2000 step:10 value:_hold]; y += 44;
    [self addRowAtY:y tag:102 title:@"Số vòng (0 = ∞)" min:0 max:999 step:1 value:_loops]; y += 44;
    for (int i = 0; i < MAXP; i++) {
        [self addRowAtY:y tag:i title:[NSString stringWithFormat:@"Điểm %d - chờ (ms)", i + 1] min:0 max:600000 step:50 value:_delay[i]];
        y += 44;
    }

    UIButton *r = [UIButton buttonWithType:UIButtonTypeSystem];
    r.frame = CGRectMake(12, y + 6, 276, 36);
    [r setTitle:@"Đặt lại vị trí các điểm" forState:UIControlStateNormal];
    [r addTarget:self action:@selector(resetPos) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:r];

    _scroll.contentSize = CGSizeMake(300, y + 56);
    [self.view addSubview:_panel];
}

- (void)layoutPanel {
    CGRect b = self.view.bounds, f = _panel.frame;
    f.size.height = MIN(420, MAX(180, b.size.height - 90));
    _scroll.frame = CGRectMake(0, 36, 300, f.size.height - 36);
    f.origin.x = MIN(MAX(_hub.frame.origin.x, 8), MAX(8, b.size.width - 300 - 8));
    CGFloat below = CGRectGetMaxY(_hub.frame) + 8;
    f.origin.y = (below + f.size.height <= b.size.height) ? below : MAX(8, _hub.frame.origin.y - 8 - f.size.height);
    _panel.frame = f;
}

- (void)stepChanged:(UIStepper *)s {
    int v = (int)s.value, t = (int)s.tag;
    if (t == 100) _count = v;
    else if (t == 101) _hold = v;
    else if (t == 102) _loops = v;
    else if (t >= 0 && t < MAXP) _delay[t] = v;
    [self save];
    [self refreshAll];
}

- (void)resetPos {
    for (int i = 0; i < MAXP; i++) {
        _px[i] = 0.75;
        _py[i] = 0.15 + 0.07 * i;
    }
    [self save];
    [self.view setNeedsLayout];
}

- (void)refreshModeButtons {
    UIColor *activeBg = [UIColor colorWithRed:0.1 green:0.65 blue:0.25 alpha:0.35];
    UIColor *activeBd = [UIColor colorWithRed:0.2 green:0.85 blue:0.35 alpha:1.0];
    UIColor *idleBg   = [UIColor colorWithWhite:1 alpha:0.08];
    UIColor *idleBd   = [UIColor colorWithWhite:1 alpha:0.2];

    BOOL isTap = (_runMode == 0);
    [_modeTapBtn setTitle:(isTap ? @"● Chạm Play/Stop: Chạy / Nhấn lại dừng" : @"○ Chạm Play/Stop: Chạy / Nhấn lại dừng") forState:UIControlStateNormal];
    _modeTapBtn.backgroundColor = isTap ? activeBg : idleBg;
    _modeTapBtn.layer.borderColor = (isTap ? activeBd : idleBd).CGColor;
    [_modeTapBtn setTitleColor:(isTap ? UIColor.whiteColor : [UIColor colorWithWhite:0.75 alpha:1]) forState:UIControlStateNormal];

    [_modeHoldBtn setTitle:(!isTap ? @"● Giữ Play/Stop: Chạy / Thả tay ra dừng" : @"○ Giữ Play/Stop: Chạy / Thả tay ra dừng") forState:UIControlStateNormal];
    _modeHoldBtn.backgroundColor = !isTap ? activeBg : idleBg;
    _modeHoldBtn.layer.borderColor = (!isTap ? activeBd : idleBd).CGColor;
    [_modeHoldBtn setTitleColor:(!isTap ? UIColor.whiteColor : [UIColor colorWithWhite:0.75 alpha:1]) forState:UIControlStateNormal];
}

- (void)refreshAll {
    [self refreshPlayButton];
    [self refreshModeButtons];
    _panel.hidden = !_menuOpen;
    // Ở chế độ Giữ để chạy, chỉ cho kéo Hub khi đang mở menu để lúc nhấn giữ không bị trượt tay hủy chạy
    _hubPan.enabled = (_runMode == 0 || _menuOpen);
    for (int i = 0; i < MAXP; i++) {
        _markers[i].hidden = !(_menuOpen && i < _count);
    }
    for (NSNumber *k in _vals) {
        int t = k.intValue;
        int v = (int)_steppers[k].value;
        _vals[k].text = (t == 102 && v == 0) ? @"∞" : [NSString stringWithFormat:@"%d", v];
        if (t < MAXP) {
            CGFloat a = (t < _count) ? 1.0 : 0.35;
            _vals[k].alpha = a; _titles[k].alpha = a;
            _steppers[k].enabled = (t < _count);
            _steppers[k].alpha = a;
        }
    }
    [self layoutPanel];
}

#pragma mark Run Loop Engine

- (void)togglePlay {
    _running ? [self stop] : [self start];
}

- (void)start {
    if (_running) return;
    _running = YES;
    _token++;
    [self refreshPlayButton];
    [self stepToken:_token index:0 loops:0];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    _token++;
    [self refreshPlayButton];
}

- (void)stepToken:(NSUInteger)tok index:(int)i loops:(int)n {
    if (tok != _token || !_running) return;
    if (i >= _count) {
        n++;
        if (_loops > 0 && n >= _loops) {
            [self stop];
            return;
        }
        i = 0;
    }
    int idx = i;
    int loopsDone = n;
    int waitMs = MAX(10, _delay[idx]);
    double holdSec = _hold / 1000.0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitMs / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (tok != self->_token || !self->_running) return;
        CGPoint p = [self pointForIndex:idx];
        DoTap(p, holdSec);

        UILabel *m = self->_markers[idx];
        if (!m.hidden) {
            [UIView animateWithDuration:0.12 animations:^{
                m.transform = CGAffineTransformMakeScale(1.4, 1.4);
            } completion:^(BOOL f) {
                m.transform = CGAffineTransformIdentity;
            }];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdSec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self stepToken:tok index:idx + 1 loops:loopsDone];
        });
    });
}

@end

#pragma mark - 3-Finger Triple Tap Detector (Non-blocking UIApplication sendEvent hook)

static void (*gOrigSendEvent)(id, SEL, UIEvent *) = NULL;
static NSUInteger gMaxFingersInCluster = 0;
static NSTimeInterval gClusterStartTime = 0;
static BOOL gClusterHadCancel = NO;
static NSUInteger gThreeFingerTapCount = 0;
static NSTimeInterval gLastThreeFingerTapTime = 0;

static void ACHookSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (!gIsInjectingTouch && event.type == UIEventTypeTouches) {
        NSSet<UITouch *> *all = [event allTouches];
        NSUInteger downCount = 0;
        for (UITouch *t in all) {
            if (t.phase == UITouchPhaseBegan || t.phase == UITouchPhaseMoved || t.phase == UITouchPhaseStationary) {
                downCount++;
            } else if (t.phase == UITouchPhaseCancelled) {
                gClusterHadCancel = YES;
            }
        }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (downCount > 0) {
            if (gClusterStartTime == 0) gClusterStartTime = now;
            if (downCount > gMaxFingersInCluster) gMaxFingersInCluster = downCount;
        } else if (gMaxFingersInCluster > 0) {
            // Tất cả ngón tay vừa nhấc lên
            if (!gClusterHadCancel && gMaxFingersInCluster == 3 && (now - gClusterStartTime) < 0.5) {
                if ((now - gLastThreeFingerTapTime) < 0.65) {
                    gThreeFingerTapCount++;
                } else {
                    gThreeFingerTapCount = 1;
                }
                gLastThreeFingerTapTime = now;
                if (gThreeFingerTapCount >= 3) {
                    gThreeFingerTapCount = 0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gController toggleMenu];
                    });
                }
            } else {
                // Reset chuỗi đếm nếu có chạm khác 3 ngón xen giữa hoặc bị hệ thống hủy chạm
                gThreeFingerTapCount = 0;
            }
            gMaxFingersInCluster = 0;
            gClusterStartTime = 0;
            gClusterHadCancel = NO;
        }
    }
    if (gOrigSendEvent) gOrigSendEvent(self, _cmd, event);
}

static void ACInstallThreeFingerHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method m = class_getInstanceMethod(UIApplication.class, @selector(sendEvent:));
        if (m) {
            gOrigSendEvent = (void (*)(id, SEL, UIEvent *))method_getImplementation(m);
            method_setImplementation(m, (IMP)ACHookSendEvent);
        }
    });
}

#pragma mark - Constructor & Lifecycle

static void ACSetup(void) {
    if (gOverlay) return;
    ACInstallThreeFingerHook();
    ACWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class] && (s.activationState == UISceneActivationStateForegroundActive || s.activationState == UISceneActivationStateForegroundInactive)) {
                w = [[ACWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                break;
            }
        }
    }
    if (!w) w = [[ACWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [[ACController alloc] init];
    w.hidden = NO;
    gOverlay = w;
}

__attribute__((constructor)) static void ACInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ACSetup(); });
        }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ACSetup(); });
        }
    });
}
