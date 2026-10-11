#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdint.h>
#import <string.h>
#import <stdarg.h>

#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#ifndef ROOT_PATH_NS
#define ROOT_PATH_NS(path) (@"/var/jb" path)
#endif

// NSLog + kalıcı günlük. Dosya işlemleri ve tarih biçimleme yalnız bu kuyrukta yapılır.
static void HaciOSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void HaciOSLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"[HaciOS] %@", message);
    NSDate *timestamp = [NSDate date];
    static dispatch_queue_t logQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("com.yigit.hacios.log", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(logQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    dispatch_async(logQueue, ^{
        @autoreleasepool {
            NSFileHandle *handle = nil;
            @try {
                NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Logs/HaciOS.log");
                NSFileManager *files = [NSFileManager defaultManager];
                NSError *error = nil;
                if (![files createDirectoryAtPath:path.stringByDeletingLastPathComponent
                     withIntermediateDirectories:YES attributes:nil error:&error]) {
                    NSLog(@"[HaciOS] log directory failed: %@", error);
                    return;
                }
                static NSDateFormatter *formatter;
                if (!formatter) {
                    formatter = [[NSDateFormatter alloc] init];
                    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
                    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
                }
                // Beklenmeyen uzun hata metinleri de 200 KB sınırını aşmasın.
                NSString *singleLine = [[message stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"]
                                        stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
                NSString *bounded = singleLine.length > 4096 ?
                    [[singleLine substringToIndex:4096] stringByAppendingString:@" [truncated]"] : singleLine;
                NSString *line = [NSString stringWithFormat:@"%@ [HaciOS] %@\n",
                                  [formatter stringFromDate:timestamp], bounded];
                NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
                if (![files fileExistsAtPath:path] && ![files createFileAtPath:path contents:nil attributes:nil]) {
                    NSLog(@"[HaciOS] log file creation failed: %@", path);
                    return;
                }
                handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
                if (!handle) {
                    NSLog(@"[HaciOS] log file open failed: %@", path);
                    return;
                }
                unsigned long long size = [handle seekToEndOfFile];
                if (size + data.length > 200 * 1024) {
                    // En yeni ~100 KB'yi satır sınırında tut; büyük eski dosyayı bütünüyle okuma.
                    unsigned long long start = size > 100 * 1024 ? size - 100 * 1024 : 0;
                    [handle seekToFileOffset:start];
                    NSData *tail = [handle readDataOfLength:100 * 1024];
                    NSUInteger offset = 0;
                    if (start > 0) {
                        const uint8_t *bytes = tail.bytes;
                        while (offset < tail.length && bytes[offset] != '\n') offset++;
                        if (offset < tail.length) offset++;
                    }
                    NSMutableData *trimmed = [[tail subdataWithRange:NSMakeRange(offset, tail.length - offset)] mutableCopy];
                    [trimmed appendData:data];
                    [handle closeFile];
                    handle = nil;
                    if (![trimmed writeToFile:path options:NSDataWritingAtomic error:&error]) {
                        NSLog(@"[HaciOS] log trim failed: %@", error);
                    }
                } else {
                    [handle writeData:data];
                }
            } @catch (NSException *exception) {
                // Günlük hatasında aynı kuyruğa tekrar günlük ekleyip sonsuz döngü oluşturma.
                NSLog(@"[HaciOS] file logging failed: %@", exception);
            } @finally {
                @try { [handle closeFile]; }
                @catch (__unused NSException *exception) {}
            }
        }
    });
}

// Tekrarlayan layout/özel API hataları günlüğü veya pili tüketmesin.
static void HaciOSErrorOnce(NSString *scope, NSString *detail) {
    static NSMutableSet<NSString *> *reported;
    @synchronized ([NSProcessInfo class]) {
        if (!reported) reported = [NSMutableSet set];
        if ([reported containsObject:scope]) return;
        [reported addObject:scope];
    }
    HaciOSLog(@"error %@: %@", scope, detail);
}

@class HaciOSCoordinator, HaciOSOverlayView;
static HaciOSCoordinator *HaciOSOrbit;
static BOOL HaciOSHiddenUntilRespring = NO;
static BOOL HaciOSFrontIsHome = YES;
static BOOL HaciOSScreenBlanked = NO;
static int HaciOSBlankToken = -1;
static NSHashTable<UIView *> *HaciOSChromeViews;
static void HaciOSRefreshChrome(void);

static BOOL HaciOSIsDisabled(void) {
    @try {
        // Dosya ve klasör aynı kurtarma işaretidir; isDirectory filtresi kullanma.
        return [[NSFileManager defaultManager] fileExistsAtPath:
                ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.yigit.hacios.disabled")];
    } @catch (NSException *exception) {
        HaciOSErrorOnce(@"disabled", exception.name);
        return YES;
    }
}

static void HaciOSReadBlankState(int token) {
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    // Mevcut davranış: 0 açık; başka değer/hata animasyonu duraklatır.
    HaciOSScreenBlanked = status != NOTIFY_STATUS_OK || state != 0;
    if (status != NOTIFY_STATUS_OK || state > 1)
        HaciOSErrorOnce(@"blank state", [NSString stringWithFormat:@"status=%u state=%llu", status, (unsigned long long)state]);
}

static BOOL HaciOSViewIsVisible(UIView *view) {
    if (!view || !view.window || view.window.hidden) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview)
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
    return YES;
}

@interface HaciOSIconControl : UIControl
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) CAGradientLayer *surface;
@property (nonatomic, strong) CAShapeLayer *glyph;
- (instancetype)initWithKey:(NSString *)key name:(NSString *)name;
- (BOOL)containsOverlayPoint:(CGPoint)point;
- (void)flash;
@end

@interface HaciOSOverlayView : UIView
@property (nonatomic, weak) HaciOSCoordinator *coordinator;
@property (nonatomic, strong) UIView *scene;
@property (nonatomic, strong) UIView *hole;
@property (nonatomic, strong) NSArray<UIView *> *orbits;
@property (nonatomic, strong) NSArray<NSArray<HaciOSIconControl *> *> *icons;
@property (nonatomic, strong) NSArray<CAShapeLayer *> *rings;
@property (nonatomic, strong) NSArray<CAGradientLayer *> *disks;
@property (nonatomic, strong) CAGradientLayer *halo;
@property (nonatomic, strong) CAGradientLayer *photon;
@property (nonatomic, strong) CAShapeLayer *photonMask;
@property (nonatomic, strong) CAShapeLayer *horizon;
@property (nonatomic, strong) UIView *clock;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIControl *capsule;
@property (nonatomic, strong) CALayer *pulse;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) NSTimer *labelTimer;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) NSUInteger clockTapCount;
@property (nonatomic, assign) CFTimeInterval firstClockTap;
- (void)updateClock;
- (void)setScenePaused:(BOOL)paused;
- (void)showStatus:(NSString *)text;
@end

@interface HaciOSCoordinator : NSObject
@property (nonatomic, strong) HaciOSOverlayView *overlay;
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, assign) BOOL ownerVisible;
@property (nonatomic, assign) BOOL refreshing;
- (void)attachToController:(UIViewController *)controller;
- (void)refreshVisibility;
- (void)openKey:(NSString *)key;
- (void)hideUntilRespring;
@end
// performSelector nesne argümanları alır; suspended: BOOL için NSInvocation kullan.
// Özel API'nin void/BOOL dönüşünü çalışma anındaki imzadan oku.
static BOOL HaciOSInvokeLaunch(id target, SEL selector, NSString *bundleID, BOOL suspendedArgument) {
    @try {
        if (!target || ![target respondsToSelector:selector]) return NO;
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != (suspendedArgument ? 4u : 3u)) return NO;
        if (strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) != 0) return NO;
        if (suspendedArgument && strcmp([signature getArgumentTypeAtIndex:3], @encode(BOOL)) != 0) return NO;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        [invocation setArgument:&bundleID atIndex:2];
        if (suspendedArgument) {
            BOOL suspended = NO;
            [invocation setArgument:&suspended atIndex:3];
        }
        [invocation invoke];
        const char *type = signature.methodReturnType;
        while (*type && strchr("rnNoORV", *type)) type++;
        if (*type == 'v') return YES; // Void API yalnızca isteğin iletildiğini doğrular.
        if (*type && strchr("BcCsSiIlLqQ", *type) && signature.methodReturnLength <= sizeof(uint64_t)) {
            uint64_t result = 0;
            [invocation getReturnValue:&result];
            return result != 0;
        }
        return NO;
    } @catch (NSException *exception) {
        HaciOSLog(@"launch API failed (%@): %@", bundleID, exception.name);
        return NO;
    }
}

static BOOL HaciOSLaunchBundle(NSString *bundleID) {
    BOOL opened = HaciOSInvokeLaunch([UIApplication sharedApplication],
                                    NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:"),
                                    bundleID, YES);
    if (!opened) {
        @try {
            Class workspaceClass = objc_getClass("LSApplicationWorkspace");
            SEL defaultWorkspace = NSSelectorFromString(@"defaultWorkspace");
            if (workspaceClass && [workspaceClass respondsToSelector:defaultWorkspace]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id workspace = [workspaceClass performSelector:defaultWorkspace];
#pragma clang diagnostic pop
                opened = HaciOSInvokeLaunch(workspace, NSSelectorFromString(@"openApplicationWithBundleID:"),
                                           bundleID, NO);
            }
        } @catch (NSException *exception) {
            HaciOSLog(@"workspace failed: %@", exception.name);
        }
    }
    HaciOSLog(@"open %@: %@", bundleID, opened ? @"accepted" : @"failed");
    return opened;
}

// SVG A komutunu eliptik yaydan kübik Bezier parçalarına çevirir (en çok 90°).
static void HaciOSArc(UIBezierPath *path, CGPoint from, CGPoint to, CGFloat rx, CGFloat ry,
                      CGFloat degrees, BOOL large, BOOL sweep) {
    rx = fabs(rx); ry = fabs(ry);
    if (CGPointEqualToPoint(from, to)) return;
    if (rx == 0 || ry == 0) { [path addLineToPoint:to]; return; }
    double phi = degrees * M_PI / 180.0, c = cos(phi), s = sin(phi);
    double dx = (from.x - to.x) / 2.0, dy = (from.y - to.y) / 2.0;
    double x = c * dx + s * dy, y = -s * dx + c * dy;
    double scale = x*x/(rx*rx) + y*y/(ry*ry);
    if (scale > 1) { rx *= sqrt(scale); ry *= sqrt(scale); }
    double denominator = rx*rx*y*y + ry*ry*x*x;
    double factor = denominator > 0 ? sqrt(fmax(0, (rx*rx*ry*ry - denominator) / denominator)) : 0;
    if (large == sweep) factor = -factor;
    double cxp = factor * rx * y / ry, cyp = -factor * ry * x / rx;
    double cx = c * cxp - s * cyp + (from.x + to.x)/2.0;
    double cy = s * cxp + c * cyp + (from.y + to.y)/2.0;
    double ux = (x-cxp)/rx, uy = (y-cyp)/ry, vx = (-x-cxp)/rx, vy = (-y-cyp)/ry;
    double start = atan2(uy, ux), delta = atan2(ux*vy-uy*vx, ux*vx+uy*vy);
    if (!sweep && delta > 0) delta -= 2*M_PI;
    if (sweep && delta < 0) delta += 2*M_PI;
    NSInteger pieces = MAX(1, (NSInteger)ceil(fabs(delta)/(M_PI/2.0)));
    double step = delta / pieces;
    for (NSInteger i = 0; i < pieces; i++) {
        double a = start+i*step, b = a+step, k = 4.0/3.0*tan(step/4.0);
        CGPoint p1 = CGPointMake(cx+rx*c*cos(a)-ry*s*sin(a), cy+rx*s*cos(a)+ry*c*sin(a));
        CGPoint p2 = CGPointMake(cx+rx*c*cos(b)-ry*s*sin(b), cy+rx*s*cos(b)+ry*c*sin(b));
        CGPoint v1 = CGPointMake(-rx*c*sin(a)-ry*s*cos(a), -rx*s*sin(a)+ry*c*cos(a));
        CGPoint v2 = CGPointMake(-rx*c*sin(b)-ry*s*cos(b), -rx*s*sin(b)+ry*c*cos(b));
        [path addCurveToPoint:i == pieces-1 ? to : p2
               controlPoint1:CGPointMake(p1.x+k*v1.x, p1.y+k*v1.y)
               controlPoint2:CGPointMake(p2.x-k*v2.x, p2.y-k*v2.y)];
    }
}

// Prototipteki M/L/H/V/A/C/Z yolları; 24×24 koordinatları aynen korunur.
static UIBezierPath *HaciOSSVGPath(NSString *data) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    NSScanner *scanner = [NSScanner scannerWithString:data];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\t\r\n"];
    NSCharacterSet *commands = [NSCharacterSet characterSetWithCharactersInString:@"MmLlHhVvAaCcZz"];
    unichar command = 0;
    CGPoint current = CGPointZero, start = CGPointZero;
    while (!scanner.isAtEnd) {
        NSString *token = nil;
        if ([scanner scanCharactersFromSet:commands intoString:&token]) command = [token characterAtIndex:0];
        BOOL relative = command >= 'a' && command <= 'z';
        unichar op = relative ? command - ('a'-'A') : command;
        if (op == 'Z') { [path closePath]; current = start; command = 0; continue; }
        NSUInteger count = op == 'A' ? 7 : op == 'C' ? 6 : (op == 'H' || op == 'V') ? 1 : 2;
        double n[7] = {0};
        if (op != 'M' && op != 'L' && op != 'H' && op != 'V' && op != 'A' && op != 'C')
            [NSException raise:@"HaciOSSVG" format:@"Unsupported path command"];
        for (NSUInteger i = 0; i < count; i++)
            if (![scanner scanDouble:&n[i]]) [NSException raise:@"HaciOSSVG" format:@"Incomplete path"];
        CGPoint base = relative ? current : CGPointZero;
        CGPoint next = CGPointMake(base.x+n[0], base.y+n[1]);
        if (op == 'M') {
            [path moveToPoint:next]; start = next; command = relative ? 'l' : 'L';
        } else if (op == 'L') [path addLineToPoint:next];
        else if (op == 'H') { next = CGPointMake(base.x+n[0], current.y); [path addLineToPoint:next]; }
        else if (op == 'V') { next = CGPointMake(current.x, base.y+n[0]); [path addLineToPoint:next]; }
        else if (op == 'C') {
            next = CGPointMake(base.x+n[4], base.y+n[5]);
            [path addCurveToPoint:next controlPoint1:CGPointMake(base.x+n[0], base.y+n[1])
                   controlPoint2:CGPointMake(base.x+n[2], base.y+n[3])];
        } else if (op == 'A') {
            next = CGPointMake(base.x+n[5], base.y+n[6]);
            HaciOSArc(path, current, next, n[0], n[1], n[2], n[3] != 0, n[4] != 0);
        }
        current = next;
    }
    return path;
}

static UIBezierPath *HaciOSGlyph(NSString *key) {
    NSDictionary *paths = @{
        @"telefon": @"M6 4h3l1.5 4-2 1.3a10 10 0 0 0 5.2 5.2L15 12.5l4 1.5v3a2 2 0 0 1-2 2A13 13 0 0 1 4 6a2 2 0 0 1 2-2z",
        @"mesaj": @"M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H10l-4 3.5V16h-.0A2.5 2.5 0 0 1 4 13.5z",
        @"safari": @"M15.8 8.2l-2.2 5.4-5.4 2.2 2.2-5.4z",
        @"kamera": @"M4 8.5A1.5 1.5 0 0 1 5.5 7H8l1.2-2h5.6L16 7h2.5A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z",
        @"foto": @"M12 3.5v8.5l6-6M20.5 12H12l6 6M12 20.5V12l-6 6M3.5 12H12L6 6",
        @"not": @"M7 4h8l3 3v13H7z M10 10h5M10 13.5h5M10 17h3",
        @"mail": @"M4.5 7.5l7.5 6 7.5-6",
        @"whatsapp": @"M5.3 17.4 4 21l4.2-1.2A8.5 8.5 0 1 0 5.3 17.4z m8 7 1.7-.2 1 2.5-1.1.9a7.5 7.5 0 0 0 3.7 3.7l.9-1.1 2.5 1-.2 1.7c-.2 1-1.2 1.5-2.1 1.3A10 10 0 0 1 6.7 9.1C6.5 8.2 7 7.2 8 7z",
        @"dosya": @"M3.5 7A1.5 1.5 0 0 1 5 5.5h4l2 2h8A1.5 1.5 0 0 1 20.5 9v9A1.5 1.5 0 0 1 19 19.5H5A1.5 1.5 0 0 1 3.5 18z M3.5 10h17",
        @"ayar": @"M12 3.5v2.5M12 18v2.5M3.5 12H6M18 12h2.5M6 6l1.8 1.8M16.2 16.2L18 18M18 6l-1.8 1.8M7.8 16.2L6 18",
        @"haci": @"M5 19V5M19 19V5M5 12h14",
        @"claude": @"M12 3.5v17M3.5 12h17M6 6l12 12M18 6L6 18"
    };
    UIBezierPath *path = HaciOSSVGPath(paths[key]);
    if ([key isEqualToString:@"safari"] || [key isEqualToString:@"foto"])
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(3.5, 3.5, 17, 17)]];
    if ([key isEqualToString:@"kamera"])
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(8.6, 9.6, 6.8, 6.8)]];
    if ([key isEqualToString:@"ayar"])
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(9, 9, 6, 6)]];
    if ([key isEqualToString:@"haci"])
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(10.6, 10.6, 2.8, 2.8)]];
    if ([key isEqualToString:@"mail"])
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4, 6, 16, 12) cornerRadius:2]];
    return path;
}

static UIColor *HaciOSWhite(CGFloat alpha) { return [UIColor colorWithWhite:1 alpha:alpha]; }
static void HaciOSRotate(CALayer *layer, CFTimeInterval duration, CGFloat direction, CFTimeInterval epoch) {
    CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotation.fromValue = @0;
    rotation.toValue = @(direction * 2 * M_PI);
    rotation.duration = duration;
    rotation.repeatCount = HUGE_VALF;
    rotation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    // Parent ve ikon ters dönüşleri aynı yerel başlangıcı kullanır; faz kayması olmaz.
    rotation.beginTime = epoch;
    [layer addAnimation:rotation forKey:@"orbit.rotation"];
}
static NSAttributedString *HaciOSText(NSString *text, UIFont *font, CGFloat spacing, CGFloat alpha) {
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font, NSKernAttributeName: @(spacing), NSForegroundColorAttributeName: HaciOSWhite(alpha)
    }];
}

@implementation HaciOSIconControl
- (instancetype)initWithKey:(NSString *)key name:(NSString *)name {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 50, 50)])) {
        self.key = key;
        self.accessibilityLabel = name;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.isAccessibilityElement = YES;
        self.layer.cornerRadius = 25;
        self.layer.borderWidth = 1;
        self.layer.borderColor = HaciOSWhite(.55).CGColor;
        self.layer.shadowColor = UIColor.whiteColor.CGColor;
        self.layer.shadowOpacity = .12;
        self.layer.shadowRadius = 7;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;
        self.surface = [CAGradientLayer layer];
        self.surface.type = kCAGradientLayerRadial;
        self.surface.colors = @[(id)[UIColor colorWithWhite:.11 alpha:1].CGColor, (id)[UIColor colorWithWhite:.024 alpha:1].CGColor];
        self.surface.locations = @[@0, @1];
        self.surface.startPoint = CGPointMake(.32, .28);
        self.surface.endPoint = CGPointMake(1, 1);
        self.surface.frame = self.bounds;
        self.surface.cornerRadius = 25;
        [self.layer addSublayer:self.surface];
        self.glyph = [CAShapeLayer layer];
        self.glyph.frame = CGRectMake(13, 13, 24, 24);
        self.glyph.path = HaciOSGlyph(key).CGPath;
        self.glyph.strokeColor = HaciOSWhite(.96).CGColor;
        self.glyph.fillColor = UIColor.clearColor.CGColor;
        self.glyph.lineWidth = 1.4;
        self.glyph.lineCap = kCALineCapRound;
        self.glyph.lineJoin = kCALineJoinRound;
        [self.layer addSublayer:self.glyph];
    }
    return self;
}
- (BOOL)containsOverlayPoint:(CGPoint)point {
    // İki layer da aynı presentation ağacından alınır. Model frame'i dönen ikona ait değildir.
    CALayer *target = self.layer.presentationLayer;
    CALayer *root = HaciOSOrbit.overlay.layer.presentationLayer;
    if (!target || !root) { target = self.layer; root = HaciOSOrbit.overlay.layer; }
    CGPoint local = [target convertPoint:point fromLayer:root];
    CGFloat dx = local.x - CGRectGetMidX(target.bounds), dy = local.y - CGRectGetMidY(target.bounds);
    return dx*dx + dy*dy <= 25*25;
}
- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    return [self containsOverlayPoint:[touch locationInView:HaciOSOrbit.overlay]];
}
- (BOOL)continueTracking:(UITouch *)touch withEvent:(UIEvent *)event { return YES; }
- (void)endTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    // UIControl'un model koordinatlarına dayanan varsayılan touchUpInside hesabını kullanma.
    if (touch && [self containsOverlayPoint:[touch locationInView:HaciOSOrbit.overlay]])
        [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}
- (BOOL)accessibilityActivate {
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}
- (void)flash {
    CABasicAnimation *flash = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    flash.fromValue = @.65;
    flash.toValue = @.12;
    flash.duration = .5;
    [self.layer addAnimation:flash forKey:@"touch.flash"];
}
@end
@implementation HaciOSOverlayView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.opaque = YES;
        self.multipleTouchEnabled = NO;
        self.scene = [[UIView alloc] initWithFrame:self.bounds];
        self.scene.userInteractionEnabled = YES;
        [self addSubview:self.scene];
        self.hole = [[UIView alloc] initWithFrame:CGRectZero];
        self.hole.userInteractionEnabled = NO;
        [self.scene addSubview:self.hole];

        self.halo = [CAGradientLayer layer];
        self.halo.type = kCAGradientLayerRadial;
        self.halo.startPoint = CGPointMake(.5, .5);
        self.halo.endPoint = CGPointMake(1, 1);
        self.halo.colors = @[(id)HaciOSWhite(0).CGColor, (id)HaciOSWhite(.11).CGColor,
                             (id)HaciOSWhite(.04).CGColor, (id)HaciOSWhite(0).CGColor];
        self.halo.locations = @[@0, @.29, @.46, @1];
        [self.hole.layer addSublayer:self.halo];
        NSMutableArray *disks = [NSMutableArray array];
        for (NSUInteger i = 0; i < 3; i++) {
            CAGradientLayer *disk = [CAGradientLayer layer];
            disk.type = kCAGradientLayerConic;
            disk.startPoint = CGPointMake(.5, .5);
            disk.endPoint = CGPointMake(.5, 0);
            disk.colors = @[(id)HaciOSWhite(.02).CGColor, (id)HaciOSWhite(.35).CGColor,
                            (id)HaciOSWhite(.06).CGColor, (id)HaciOSWhite(.16).CGColor, (id)HaciOSWhite(.02).CGColor];
            disk.locations = @[@0, @.3, @.5, @.8, @1];
            CAShapeLayer *mask = [CAShapeLayer layer];
            mask.fillColor = UIColor.clearColor.CGColor;
            mask.strokeColor = UIColor.whiteColor.CGColor;
            mask.lineWidth = 3 + i*2;
            disk.mask = mask;
            [self.hole.layer addSublayer:disk];
            [disks addObject:disk];
        }
        self.disks = disks;
        self.photon = [CAGradientLayer layer];
        self.photon.type = kCAGradientLayerConic;
        self.photon.startPoint = CGPointMake(.5, .5);
        self.photon.endPoint = CGPointMake(.5, 0);
        self.photon.colors = @[(id)HaciOSWhite(.9).CGColor, (id)HaciOSWhite(.35).CGColor,
                              (id)HaciOSWhite(1).CGColor, (id)HaciOSWhite(.6).CGColor, (id)HaciOSWhite(.9).CGColor];
        self.photon.locations = @[@0, @.25, @.5, @.75, @1];
        self.photonMask = [CAShapeLayer layer];
        self.photonMask.fillColor = UIColor.clearColor.CGColor;
        self.photonMask.strokeColor = UIColor.whiteColor.CGColor;
        self.photonMask.lineWidth = 1.35;
        self.photon.mask = self.photonMask;
        // Ayrı CAShapeLayer gölgesi maskenin glow'u kesmesini önler.
        CAShapeLayer *glow = [CAShapeLayer layer];
        glow.name = @"photon.glow";
        glow.fillColor = UIColor.clearColor.CGColor;
        glow.strokeColor = HaciOSWhite(.28).CGColor;
        glow.lineWidth = 3;
        glow.shadowColor = UIColor.whiteColor.CGColor;
        glow.shadowOpacity = .65;
        glow.shadowRadius = 7;
        glow.shadowOffset = CGSizeZero;
        [self.hole.layer addSublayer:glow];
        [self.hole.layer addSublayer:self.photon];
        self.horizon = [CAShapeLayer layer];
        self.horizon.fillColor = UIColor.blackColor.CGColor;
        [self.hole.layer addSublayer:self.horizon];

        NSArray *keys = @[@[@"haci", @"claude", @"kamera", @"safari", @"mesaj"],
                           @[@"telefon", @"foto", @"not", @"mail", @"whatsapp", @"dosya", @"ayar"]];
        NSDictionary *names = @{@"haci": @"Hacı", @"claude": @"Claude", @"kamera": @"Kamera",
            @"safari": @"Safari", @"mesaj": @"Mesajlar", @"telefon": @"Telefon", @"foto": @"Fotoğraflar",
            @"not": @"Notlar", @"mail": @"Mail", @"whatsapp": @"WhatsApp", @"dosya": @"Dosyalar", @"ayar": @"Ayarlar"};
        NSMutableArray *orbits = [NSMutableArray array], *icons = [NSMutableArray array], *rings = [NSMutableArray array];
        for (NSUInteger r = 0; r < 2; r++) {
            CAShapeLayer *ring = [CAShapeLayer layer];
            ring.fillColor = UIColor.clearColor.CGColor;
            ring.strokeColor = HaciOSWhite(.07).CGColor;
            ring.lineWidth = 1;
            [self.scene.layer addSublayer:ring];
            [rings addObject:ring];
            UIView *orbit = [[UIView alloc] initWithFrame:CGRectZero];
            [self.scene addSubview:orbit];
            [orbits addObject:orbit];
            NSMutableArray *buttons = [NSMutableArray array];
            for (NSString *key in keys[r]) {
                HaciOSIconControl *icon = [[HaciOSIconControl alloc] initWithKey:key name:names[key]];
                [icon addTarget:self action:@selector(pickIcon:) forControlEvents:UIControlEventTouchUpInside];
                [orbit addSubview:icon];
                [buttons addObject:icon];
            }
            [icons addObject:buttons];
        }
        self.orbits = orbits; self.icons = icons; self.rings = rings;
        self.clock = [[UIView alloc] initWithFrame:CGRectZero];
        self.clock.accessibilityLabel = @"Saate bir saniye içinde üç kez dokunarak normal ana ekrana dön";
        self.clock.accessibilityTraits = UIAccessibilityTraitButton;
        self.clock.isAccessibilityElement = YES;
        [self addSubview:self.clock];
        self.timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.timeLabel.textAlignment = NSTextAlignmentCenter;
        self.dateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.dateLabel.textAlignment = NSTextAlignmentCenter;
        [self.clock addSubview:self.timeLabel]; [self.clock addSubview:self.dateLabel];
        [self.clock addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(clockTapped:)]];
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        self.statusLabel.hidden = YES;
        self.statusLabel.isAccessibilityElement = YES;
        [self addSubview:self.statusLabel];
        self.capsule = [[UIControl alloc] initWithFrame:CGRectZero];
        self.capsule.layer.cornerRadius = 22;
        self.capsule.layer.borderWidth = 1;
        self.capsule.layer.borderColor = HaciOSWhite(.35).CGColor;
        self.capsule.clipsToBounds = YES;
        self.capsule.accessibilityLabel = @"Hacı'ya sor, yakında";
        self.capsule.accessibilityTraits = UIAccessibilityTraitButton;
        self.capsule.isAccessibilityElement = YES;
        [self.capsule addTarget:self action:@selector(askHaci:) forControlEvents:UIControlEventTouchUpInside];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.userInteractionEnabled = NO;
        [self.capsule addSubview:blur];
        UILabel *ask = [[UILabel alloc] initWithFrame:CGRectMake(33, 0, 240, 44)];
        ask.attributedText = HaciOSText(@"Hacı'ya sor", [UIFont systemFontOfSize:12], 1.68, .62);
        ask.userInteractionEnabled = NO;
        [self.capsule addSubview:ask];
        self.pulse = [CALayer layer];
        self.pulse.frame = CGRectMake(16, 18.5, 7, 7);
        self.pulse.cornerRadius = 3.5;
        self.pulse.backgroundColor = HaciOSWhite(.96).CGColor;
        self.pulse.shadowColor = UIColor.whiteColor.CGColor;
        self.pulse.shadowOpacity = .8;
        self.pulse.shadowRadius = 5;
        self.pulse.shadowOffset = CGSizeZero;
        self.pulse.opacity = .4;
        [self.capsule.layer addSublayer:self.pulse];
        // Kapsül de scene altında: tek layer saati bütün CA animasyonlarını durdurur.
        [self.scene addSubview:self.capsule];
        self.timeFormatter = [[NSDateFormatter alloc] init];
        self.timeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"tr_TR"];
        self.timeFormatter.dateFormat = @"HH:mm";
        self.dateFormatter = [[NSDateFormatter alloc] init];
        self.dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"tr_TR"];
        self.dateFormatter.dateFormat = @"EEEE d MMMM";
        CFTimeInterval epoch = [self.scene.layer convertTime:CACurrentMediaTime() fromLayer:nil];
        if (!UIAccessibilityIsReduceMotionEnabled()) {
            for (NSUInteger r = 0; r < 2; r++) {
                CGFloat direction = r == 0 ? 1 : -1;
                CFTimeInterval duration = 2*M_PI/(r == 0 ? .055 : .034);
                HaciOSRotate(self.orbits[r].layer, duration, direction, epoch);
                for (HaciOSIconControl *icon in self.icons[r]) HaciOSRotate(icon.layer, duration, -direction, epoch);
            }
            for (NSUInteger i = 0; i < self.disks.count; i++) HaciOSRotate(self.disks[i], 90+i*37, i == 1 ? -1 : 1, epoch);
            HaciOSRotate(self.photon, 150, 1, epoch);
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
            pulse.fromValue = @.4; pulse.toValue = @1;
            pulse.duration = 1.6; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
            pulse.beginTime = epoch;
            pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.pulse addAnimation:pulse forKey:@"haci.pulse"];
        }
        [self updateClock];
        [self setScenePaused:YES];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    @try {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        @try {
            CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
            self.scene.frame = self.bounds;
            // Prototip CY=.47 alttan ölçülür → UIKit'te üstten .53.
            CGPoint center = CGPointMake(width*.5, height*.53);
            CGFloat outer = MAX(0, MIN(MIN(width, height*.46)*.46, width*.5-32));
            CGFloat radii[2] = {outer*.57, outer};
            CGFloat size = height*.4, horizon = height*.058;
            self.hole.bounds = CGRectMake(0, 0, size, size);
            self.hole.center = center;
            self.halo.frame = self.hole.bounds;
            CGPoint holeCenter = CGPointMake(size*.5, size*.5);
            for (NSUInteger i = 0; i < self.disks.count; i++) {
                CAGradientLayer *disk = self.disks[i];
                CGFloat w = MIN(width*.95, horizon*(6.2-i*.65)), h = horizon*(1.5+i*.18);
                disk.bounds = CGRectMake(0, 0, w, h);
                disk.position = holeCenter;
                CAShapeLayer *mask = (CAShapeLayer *)disk.mask;
                mask.frame = disk.bounds;
                mask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(disk.bounds, 5, 5)].CGPath;
            }
            CGFloat photonRadius = horizon*1.1;
            CGRect photonRect = CGRectMake(holeCenter.x-photonRadius, holeCenter.y-photonRadius, 2*photonRadius, 2*photonRadius);
            self.photon.bounds = self.hole.bounds;
            self.photon.position = holeCenter;
            self.photonMask.frame = self.photon.bounds;
            self.photonMask.path = [UIBezierPath bezierPathWithOvalInRect:photonRect].CGPath;
            for (CALayer *layer in self.hole.layer.sublayers) {
                if ([layer.name isEqualToString:@"photon.glow"]) {
                    CAShapeLayer *glow = (CAShapeLayer *)layer;
                    glow.frame = self.hole.bounds;
                    glow.path = [UIBezierPath bezierPathWithOvalInRect:photonRect].CGPath;
                }
            }
            self.horizon.frame = self.hole.bounds;
            self.horizon.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(holeCenter.x-horizon, holeCenter.y-horizon, 2*horizon, 2*horizon)].CGPath;
            for (NSUInteger r = 0; r < 2; r++) {
                CGFloat radius = radii[r];
                UIView *orbit = self.orbits[r];
                orbit.bounds = CGRectMake(0, 0, 2*radius, 2*radius);
                orbit.center = center;
                CAShapeLayer *ring = self.rings[r];
                ring.frame = self.scene.bounds;
                ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(center.x-radius, center.y-radius, 2*radius, 2*radius)].CGPath;
                NSArray *icons = self.icons[r];
                for (NSUInteger i = 0; i < icons.count; i++) {
                    CGFloat angle = (CGFloat)i/icons.count*2*M_PI + (r ? M_PI/icons.count : 0) - M_PI/2;
                    HaciOSIconControl *icon = icons[i];
                    icon.center = CGPointMake(radius+cos(angle)*radius, radius+sin(angle)*radius);
                }
            }
            self.clock.frame = CGRectMake(0, MAX(self.safeAreaInsets.top, 14), width, 60);
            self.timeLabel.frame = CGRectMake(0, 8, width, 20);
            self.dateLabel.frame = CGRectMake(0, 34, width, 16);
            self.statusLabel.frame = CGRectMake(0, center.y+outer+40, width, 24);
            CGFloat capsuleWidth = MIN(width*.78, 300);
            self.capsule.bounds = CGRectMake(0, 0, capsuleWidth, 44);
            self.capsule.center = CGPointMake(width*.5, height-MAX(self.safeAreaInsets.bottom, 22)-22);
        } @finally { [CATransaction commit]; }
        [self.coordinator refreshVisibility];
    } @catch (NSException *exception) { HaciOSErrorOnce(@"layout", exception.name); }
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    @try {
        if (self.hidden || self.alpha <= .01 || !self.userInteractionEnabled || ![self pointInside:point withEvent:event]) return nil;
        // Önce ekrandaki sunum konumu; UIView'ın eski model frame'ine geri düşme.
        for (NSArray *ring in [self.icons reverseObjectEnumerator])
            for (HaciOSIconControl *icon in [ring reverseObjectEnumerator])
                if ([icon containsOverlayPoint:point]) return icon;
        UIView *hit = [super hitTest:point withEvent:event];
        if ([hit isKindOfClass:[HaciOSIconControl class]]) return self;
        return hit ?: self;
    } @catch (NSException *exception) { HaciOSErrorOnce(@"hit test", exception.name); return self; }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    @try { [self.coordinator refreshVisibility]; }
    @catch (NSException *exception) { HaciOSErrorOnce(@"window", exception.name); }
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    @try { [self.coordinator refreshVisibility]; }
    @catch (NSException *exception) { HaciOSErrorOnce(@"parent", exception.name); }
}
- (void)updateClock {
    NSDate *now = [NSDate date];
    self.timeFormatter.timeZone = NSTimeZone.localTimeZone;
    self.dateFormatter.timeZone = NSTimeZone.localTimeZone;
    NSString *time = [self.timeFormatter stringFromDate:now];
    NSString *date = [[self.dateFormatter stringFromDate:now] uppercaseStringWithLocale:self.dateFormatter.locale];
    self.timeLabel.attributedText = HaciOSText(time, [UIFont systemFontOfSize:15 weight:UIFontWeightLight], 4.8, .92);
    self.dateLabel.attributedText = HaciOSText(date, [UIFont systemFontOfSize:10], 4.2, .45);
    self.dateLabel.adjustsFontSizeToFitWidth = YES;
    self.dateLabel.minimumScaleFactor = .7;
    self.clock.accessibilityValue = [NSString stringWithFormat:@"%@, %@", time, date];
}
- (void)setScenePaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    CALayer *layer = self.scene.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (paused) {
        CFTimeInterval local = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
        layer.speed = 0;
        layer.timeOffset = local;
    } else {
        CFTimeInterval saved = layer.timeOffset;
        layer.speed = 1;
        layer.timeOffset = 0;
        layer.beginTime = 0;
        layer.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - saved;
    }
    [CATransaction commit];
    [self.clockTimer invalidate]; self.clockTimer = nil;
    [self.labelTimer invalidate]; self.labelTimer = nil;
    self.statusLabel.hidden = YES;
    self.clockTapCount = 0;
    if (paused) {
        for (NSArray *ring in self.icons)
            for (HaciOSIconControl *icon in ring) [icon.layer removeAnimationForKey:@"touch.flash"];
    } else {
        [self updateClock];
        __weak HaciOSOverlayView *weakSelf = self;
        self.clockTimer = [NSTimer timerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
            @try { [weakSelf updateClock]; }
            @catch (NSException *exception) { HaciOSErrorOnce(@"clock", exception.name); }
        }];
        self.clockTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:60-fmod(NSDate.date.timeIntervalSince1970, 60)];
        self.clockTimer.tolerance = 1;
        [[NSRunLoop mainRunLoop] addTimer:self.clockTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)showStatus:(NSString *)text {
    if (self.paused) return;
    [self.labelTimer invalidate];
    self.statusLabel.attributedText = HaciOSText([text uppercaseStringWithLocale:self.dateFormatter.locale], [UIFont systemFontOfSize:11], 4.18, .9);
    self.statusLabel.hidden = NO;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    __weak HaciOSOverlayView *weakSelf = self;
    self.labelTimer = [NSTimer timerWithTimeInterval:1.6 repeats:NO block:^(NSTimer *timer) {
        weakSelf.statusLabel.hidden = YES;
        weakSelf.labelTimer = nil;
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.labelTimer forMode:NSRunLoopCommonModes];
}
- (void)pickIcon:(HaciOSIconControl *)icon {
    @try {
        if (self.paused || self.hidden) return;
        [icon flash];
        [self showStatus:icon.accessibilityLabel];
        [self.coordinator openKey:icon.key];
    } @catch (NSException *exception) { HaciOSErrorOnce(@"pick", exception.name); [self showStatus:@"AÇILAMADI"]; }
}
- (void)askHaci:(UIControl *)sender {
    @try { [self.coordinator openKey:@"haci"]; }
    @catch (NSException *exception) { HaciOSErrorOnce(@"capsule", exception.name); }
}
- (void)clockTapped:(UITapGestureRecognizer *)gesture {
    @try {
        if (self.hidden) return;
        CFTimeInterval now = CACurrentMediaTime();
        if (!self.clockTapCount || now-self.firstClockTap > 1) { self.clockTapCount = 0; self.firstClockTap = now; }
        if (++self.clockTapCount == 3) { self.clockTapCount = 0; [self.coordinator hideUntilRespring]; }
    } @catch (NSException *exception) { HaciOSErrorOnce(@"clock tap", exception.name); }
}
- (void)dealloc { [self.clockTimer invalidate]; [self.labelTimer invalidate]; }
@end
@implementation HaciOSCoordinator
- (void)attachToController:(UIViewController *)controller {
    @try {
        if (!controller || HaciOSHiddenUntilRespring || HaciOSIsDisabled()) { [self refreshVisibility]; return; }
        UIView *home = controller.viewIfLoaded;
        UIWindow *host = home.window;
        Class homeWindow = objc_getClass("SBHomeScreenWindow");
        // Çalıştığı doğrulanan ana ekran penceresinde kal; uygulama/key window oluşturma.
        if (!homeWindow || ![host isKindOfClass:homeWindow] || CGRectIsEmpty(host.bounds)) return;
        BOOL newOwner = self.owner != controller;
        self.owner = controller;
        self.ownerVisible = YES;
        if (!self.overlay) {
            self.overlay = [[HaciOSOverlayView alloc] initWithFrame:host.bounds];
            self.overlay.coordinator = self;
            self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.overlay.hidden = YES;
        }
        if (self.overlay.superview != host) {
            [self.overlay removeFromSuperview];
            self.overlay.frame = host.bounds;
            [host addSubview:self.overlay];
            HaciOSLog(@"attach: %@ in %@", NSStringFromClass(controller.class), NSStringFromClass(host.class));
        } else if (newOwner) {
            HaciOSLog(@"attach: owner %@", NSStringFromClass(controller.class));
        }
        [host bringSubviewToFront:self.overlay];
        [self.overlay setNeedsLayout];
        [self.overlay layoutIfNeeded];
        [self refreshVisibility];
    } @catch (NSException *exception) {
        self.ownerVisible = NO;
        [self refreshVisibility];
        HaciOSErrorOnce(@"attach", exception.name);
    }
}
- (void)refreshVisibility {
    if (![NSThread isMainThread]) {
        __weak HaciOSCoordinator *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshVisibility]; });
        return;
    }
    if (self.refreshing) return;
    self.refreshing = YES;
    @try {
        BOOL visible = self.overlay.superview && self.ownerVisible && HaciOSFrontIsHome &&
            !HaciOSHiddenUntilRespring && !HaciOSIsDisabled() && HaciOSViewIsVisible(self.owner.viewIfLoaded);
        BOOL paused = !visible || HaciOSScreenBlanked || !HaciOSViewIsVisible(self.overlay.superview);
        BOOL changed = self.overlay && (self.overlay.hidden == visible || self.overlay.paused != paused);
        self.overlay.hidden = !visible;
        if (visible && self.overlay.superview.subviews.lastObject != self.overlay)
            [self.overlay.superview bringSubviewToFront:self.overlay];
        [self.overlay setScenePaused:paused];
        HaciOSRefreshChrome();
        if (changed) HaciOSLog(@"visibility: visible=%d paused=%d", visible, paused);
    } @catch (NSException *exception) {
        HaciOSHiddenUntilRespring = YES; // Hata halinde stok ana ekranı serbest bırak.
        self.overlay.hidden = YES;
        [self.overlay setScenePaused:YES];
        HaciOSRefreshChrome();
        HaciOSErrorOnce(@"visibility", exception.name);
    } @finally { self.refreshing = NO; }
}
- (void)hideUntilRespring {
    HaciOSHiddenUntilRespring = YES;
    [self refreshVisibility];
}
- (void)openKey:(NSString *)key {
    @try {
        if (HaciOSHiddenUntilRespring || HaciOSIsDisabled()) { [self refreshVisibility]; return; }
        if (self.overlay.hidden || self.overlay.paused || !HaciOSFrontIsHome) return;
        if ([key isEqualToString:@"haci"]) {
            [self.overlay showStatus:@"YAKINDA"];
            HaciOSLog(@"open haci: YAKINDA");
            return;
        }
        if ([key isEqualToString:@"claude"]) {
            __weak HaciOSCoordinator *weakSelf = self;
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://claude.ai"] options:@{}
                completionHandler:^(BOOL success) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            HaciOSLog(@"open claude URL: %@", success ? @"accepted" : @"failed");
                            if (!success) [weakSelf.overlay showStatus:@"AÇILAMADI"];
                        } @catch (NSException *exception) { HaciOSErrorOnce(@"URL result", exception.name); }
                    });
                }];
            return;
        }
        NSDictionary *bundles = @{
            @"telefon": @"com.apple.mobilephone", @"mesaj": @"com.apple.MobileSMS",
            @"safari": @"com.apple.mobilesafari", @"kamera": @"com.apple.camera",
            @"foto": @"com.apple.mobileslideshow", @"not": @"com.apple.mobilenotes",
            @"mail": @"com.apple.mobilemail", @"whatsapp": @"net.whatsapp.WhatsApp",
            @"dosya": @"com.apple.DocumentsApp", @"ayar": @"com.apple.Preferences"
        };
        NSString *bundleID = bundles[key];
        if (!bundleID || !HaciOSLaunchBundle(bundleID)) [self.overlay showStatus:@"AÇILAMADI"];
    } @catch (NSException *exception) {
        HaciOSErrorOnce(@"open", exception.name);
        [self.overlay showStatus:@"AÇILAMADI"];
    }
}
@end

@interface HaciOSChromeState : NSObject
@property (nonatomic, assign) CGFloat alpha;
@property (nonatomic, assign) BOOL interactive;
@property (nonatomic, assign) BOOL suppressed;
@property (nonatomic, assign) BOOL applying;
@end
@implementation HaciOSChromeState
@end
static char HaciOSChromeStateKey;
static HaciOSChromeState *HaciOSStateForChrome(UIView *view) {
    return objc_getAssociatedObject(view, &HaciOSChromeStateKey);
}
static BOOL HaciOSShouldHideChrome(void) {
    return HaciOSOrbit.overlay && !HaciOSOrbit.overlay.hidden && HaciOSFrontIsHome &&
        HaciOSOrbit.ownerVisible && !HaciOSHiddenUntilRespring && !HaciOSIsDisabled();
}
static void HaciOSApplyChrome(UIView *view) {
    @try {
        if (![view isKindOfClass:[UIView class]]) return;
        if (!HaciOSChromeViews) HaciOSChromeViews = [NSHashTable weakObjectsHashTable];
        [HaciOSChromeViews addObject:view];
        HaciOSChromeState *state = HaciOSStateForChrome(view);
        BOOL hide = HaciOSShouldHideChrome();
        if (!state && !hide) return;
        if (!state) {
            state = [[HaciOSChromeState alloc] init];
            objc_setAssociatedObject(view, &HaciOSChromeStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (hide && !state.suppressed) {
            state.alpha = view.alpha;
            state.interactive = view.userInteractionEnabled;
            state.suppressed = YES;
        }
        if (!hide && !state.suppressed) return;
        state.applying = YES;
        @try {
            [UIView performWithoutAnimation:^{
                view.alpha = hide ? 0 : state.alpha;
                view.userInteractionEnabled = hide ? NO : state.interactive;
            }];
            if (!hide) state.suppressed = NO;
        } @finally { state.applying = NO; }
    } @catch (NSException *exception) { HaciOSErrorOnce(@"chrome", exception.name); }
}
static void HaciOSRefreshChrome(void) {
    for (UIView *view in HaciOSChromeViews.allObjects) HaciOSApplyChrome(view);
}
static void HaciOSDiscoverChrome(UIView *root) {
    if (!root || root == HaciOSOrbit.overlay) return;
    // Tek seferlik attach taraması; dock ayrı penceredeyse o pencere de taranır.
    for (NSString *name in @[@"SBDockView", @"SBFloatingDockView", @"SBIconListPageControl"]) {
        Class cls = NSClassFromString(name);
        if (cls && [root isKindOfClass:cls]) { HaciOSApplyChrome(root); break; }
    }
    for (UIView *child in root.subviews) HaciOSDiscoverChrome(child);
}

static void HaciOSAttach(id candidate) {
    __weak id weakCandidate = candidate;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id controller = weakCandidate;
            if (![controller isKindOfClass:[UIViewController class]]) return;
            if (HaciOSHiddenUntilRespring || HaciOSIsDisabled()) { [HaciOSOrbit refreshVisibility]; return; }
            if (!HaciOSOrbit) HaciOSOrbit = [[HaciOSCoordinator alloc] init];
            [HaciOSOrbit attachToController:controller];
            // Önceden layout olmuş ayrı dock pencereleri de ilk attach'te saklanır.
            for (UIWindow *window in UIApplication.sharedApplication.windows) HaciOSDiscoverChrome(window);
        } @catch (NSException *exception) { HaciOSErrorOnce(@"attach dispatch", exception.name); }
    });
}

%group HaciOSHome
%hook HaciOSHomeController
- (void)viewDidLoad {
    @try { %orig; HaciOSAttach(self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"home load", exception.name); }
}
- (void)viewDidAppear:(BOOL)animated {
    @try { %orig; HaciOSAttach(self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"home appear", exception.name); }
}
- (void)viewWillDisappear:(BOOL)animated {
    @try { %orig;
        if (HaciOSOrbit.owner == (id)self) { HaciOSOrbit.ownerVisible = NO; [HaciOSOrbit refreshVisibility]; }
    } @catch (NSException *exception) { HaciOSErrorOnce(@"home disappear", exception.name); }
}
%end
%end

%group HaciOSFrontDisplay
%hook SpringBoard
- (void)frontDisplayDidChange:(id)display {
    @try {
        %orig;
        BOOL home = display == nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { HaciOSFrontIsHome = home; [HaciOSOrbit refreshVisibility]; }
            @catch (NSException *exception) { HaciOSErrorOnce(@"front display", exception.name); }
        });
    } @catch (NSException *exception) { HaciOSErrorOnce(@"front display hook", exception.name); }
}
%end
%end

// Pencere gizlenmesi de timer/CA saatini anında durdursun; uygulama pencerelerini hook'lama.
%group HaciOSHomeWindow
%hook HaciOSHomeScreenWindow
- (void)setHidden:(BOOL)hidden {
    @try { %orig; [HaciOSOrbit refreshVisibility]; }
    @catch (NSException *exception) { HaciOSErrorOnce(@"home window hidden", exception.name); }
}
- (void)layoutSubviews {
    @try { %orig; [HaciOSOrbit refreshVisibility]; }
    @catch (NSException *exception) { HaciOSErrorOnce(@"home window layout", exception.name); }
}
%end
%end

%group HaciOSDock
%hook HaciOSDockView
- (void)layoutSubviews {
    @try { %orig; HaciOSApplyChrome((UIView *)self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"dock layout", exception.name); }
}
- (void)didMoveToWindow {
    @try { %orig; HaciOSApplyChrome((UIView *)self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"dock window", exception.name); }
}
- (void)setAlpha:(CGFloat)alpha {
    HaciOSChromeState *state = nil;
    BOOL wasApplying = NO;
    @try {
        state = HaciOSStateForChrome((UIView *)self);
        wasApplying = state.applying;
        if (state.suppressed && !wasApplying) {
            state.alpha = alpha; alpha = 0;
            // Alt/üst sınıfın hook'u aynı isteği ikinci kez kaydetmesin.
            state.applying = YES;
        }
        %orig(alpha);
    } @catch (NSException *exception) { HaciOSErrorOnce(@"dock alpha", exception.name); }
    @finally { state.applying = wasApplying; }
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    HaciOSChromeState *state = nil;
    BOOL wasApplying = NO;
    @try {
        state = HaciOSStateForChrome((UIView *)self);
        wasApplying = state.applying;
        if (state.suppressed && !wasApplying) {
            state.interactive = enabled; enabled = NO;
            state.applying = YES;
        }
        %orig(enabled);
    } @catch (NSException *exception) { HaciOSErrorOnce(@"dock interaction", exception.name); }
    @finally { state.applying = wasApplying; }
}
%end
%end

%group HaciOSFloatingDock
%hook HaciOSFloatingDockView
- (void)layoutSubviews {
    @try { %orig; HaciOSApplyChrome((UIView *)self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"floating dock layout", exception.name); }
}
- (void)didMoveToWindow {
    @try { %orig; HaciOSApplyChrome((UIView *)self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"floating dock window", exception.name); }
}
- (void)setAlpha:(CGFloat)alpha {
    HaciOSChromeState *state = nil;
    BOOL wasApplying = NO;
    @try {
        state = HaciOSStateForChrome((UIView *)self);
        wasApplying = state.applying;
        if (state.suppressed && !wasApplying) {
            state.alpha = alpha; alpha = 0;
            // Alt/üst sınıfın hook'u aynı isteği ikinci kez kaydetmesin.
            state.applying = YES;
        }
        %orig(alpha);
    } @catch (NSException *exception) { HaciOSErrorOnce(@"floating dock alpha", exception.name); }
    @finally { state.applying = wasApplying; }
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    HaciOSChromeState *state = nil;
    BOOL wasApplying = NO;
    @try {
        state = HaciOSStateForChrome((UIView *)self);
        wasApplying = state.applying;
        if (state.suppressed && !wasApplying) {
            state.interactive = enabled; enabled = NO;
            state.applying = YES;
        }
        %orig(enabled);
    } @catch (NSException *exception) { HaciOSErrorOnce(@"floating dock interaction", exception.name); }
    @finally { state.applying = wasApplying; }
}
%end
%end

%group HaciOSPageControl
%hook HaciOSIconListPageControl
- (void)layoutSubviews {
    @try { %orig; HaciOSApplyChrome((UIView *)self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"page layout", exception.name); }
}
- (void)didMoveToWindow {
    @try { %orig; HaciOSApplyChrome((UIView *)self); }
    @catch (NSException *exception) { HaciOSErrorOnce(@"page window", exception.name); }
}
- (void)setAlpha:(CGFloat)alpha {
    HaciOSChromeState *state = nil;
    BOOL wasApplying = NO;
    @try {
        state = HaciOSStateForChrome((UIView *)self);
        wasApplying = state.applying;
        if (state.suppressed && !wasApplying) {
            state.alpha = alpha; alpha = 0;
            // Alt/üst sınıfın hook'u aynı isteği ikinci kez kaydetmesin.
            state.applying = YES;
        }
        %orig(alpha);
    } @catch (NSException *exception) { HaciOSErrorOnce(@"page alpha", exception.name); }
    @finally { state.applying = wasApplying; }
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    HaciOSChromeState *state = nil;
    BOOL wasApplying = NO;
    @try {
        state = HaciOSStateForChrome((UIView *)self);
        wasApplying = state.applying;
        if (state.suppressed && !wasApplying) {
            state.interactive = enabled; enabled = NO;
            state.applying = YES;
        }
        %orig(enabled);
    } @catch (NSException *exception) { HaciOSErrorOnce(@"page interaction", exception.name); }
    @finally { state.applying = wasApplying; }
}
%end
%end

static BOOL HaciOSCanHookHome(Class cls) {
    return cls && [cls isSubclassOfClass:[UIViewController class]] &&
        class_getInstanceMethod(cls, @selector(viewDidLoad)) && class_getInstanceMethod(cls, @selector(viewDidAppear:)) &&
        class_getInstanceMethod(cls, @selector(viewWillDisappear:));
}
static BOOL HaciOSCanHookChrome(Class cls) {
    return cls && [cls isSubclassOfClass:[UIView class]] &&
        class_getInstanceMethod(cls, @selector(layoutSubviews)) && class_getInstanceMethod(cls, @selector(didMoveToWindow)) &&
        class_getInstanceMethod(cls, @selector(setAlpha:)) && class_getInstanceMethod(cls, @selector(setUserInteractionEnabled:));
}

%ctor {
    @autoreleasepool {
        @try {
            HaciOSLog(@"initializing 0.2.0: native Orbit");
            if (HaciOSIsDisabled()) return;
            Class homeClass = objc_getClass("SBHomeScreenViewController");
            if (!HaciOSCanHookHome(homeClass)) homeClass = objc_getClass("SBIconController");
            Class springBoardClass = objc_getClass("SpringBoard");
            Class homeWindow = objc_getClass("SBHomeScreenWindow");
            if (!HaciOSCanHookHome(homeClass) || !springBoardClass ||
                !class_getInstanceMethod(springBoardClass, NSSelectorFromString(@"frontDisplayDidChange:")) ||
                !homeWindow || ![homeWindow isSubclassOfClass:[UIWindow class]]) {
                HaciOSErrorOnce(@"startup", @"home/front display/window API unavailable; skipped");
                return;
            }
            uint32_t status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &HaciOSBlankToken,
                dispatch_get_main_queue(), ^(int token) {
                    @try { HaciOSReadBlankState(token); [HaciOSOrbit refreshVisibility]; }
                    @catch (NSException *exception) { HaciOSErrorOnce(@"blank notification", exception.name); }
                });
            if (status != NOTIFY_STATUS_OK) {
                HaciOSBlankToken = -1; HaciOSScreenBlanked = YES;
                HaciOSErrorOnce(@"blank registration", @"animations remain paused");
            } else HaciOSReadBlankState(HaciOSBlankToken);
            // Her özel sınıf ayrı grupta; bulunmayan dock/page sınıfı sessizce atlanır.
            Class dockClass = objc_getClass("SBDockView");
            if (HaciOSCanHookChrome(dockClass)) { %init(HaciOSDock, HaciOSDockView = dockClass); }
            Class floatingClass = objc_getClass("SBFloatingDockView");
            if (HaciOSCanHookChrome(floatingClass)) { %init(HaciOSFloatingDock, HaciOSFloatingDockView = floatingClass); }
            Class pageClass = objc_getClass("SBIconListPageControl");
            if (HaciOSCanHookChrome(pageClass)) { %init(HaciOSPageControl, HaciOSIconListPageControl = pageClass); }
            if (class_getInstanceMethod(homeWindow, @selector(setHidden:)) && class_getInstanceMethod(homeWindow, @selector(layoutSubviews))) {
                %init(HaciOSHomeWindow, HaciOSHomeScreenWindow = homeWindow);
            }
            %init(HaciOSFrontDisplay);
            %init(HaciOSHome, HaciOSHomeController = homeClass);
        } @catch (NSException *exception) {
            HaciOSHiddenUntilRespring = YES;
            [HaciOSOrbit refreshVisibility];
            HaciOSErrorOnce(@"initialization", exception.name);
        }
    }
}
