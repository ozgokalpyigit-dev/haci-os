#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
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

@class HaciOSCoordinator;
static HaciOSCoordinator *HaciOSOrbit;
static BOOL HaciOSHiddenUntilRespring = NO;
// İlk frontDisplayDidChange gelene kadar home varsayılır; owner/view görünürlüğü ayrıca denetlenir.
static BOOL HaciOSFrontIsHome = YES;
static BOOL HaciOSScreenBlanked = NO;
static int HaciOSBlankToken = -1;

static void HaciOSReadBlankState(int token, NSString *source) {
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    // Özel hasBlankedScreen için beklenen durum: 0 = açık, 1 = ekran kapalı.
    // Cihazda doğrulanması gereken bu değer yalnız duraklatmayı etkiler, overlay'i gizlemez.
    // Okuma hatası/başka değer pil için temkinli biçimde duraklatır ve ham değer loglanır.
    HaciOSScreenBlanked = status != NOTIFY_STATUS_OK || state != 0;
    HaciOSLog(@"blank screen %@: status=%u rawState=%llu ScreenBlanked=%d (pause only; expected 0=on, 1=blanked)",
              source, status, (unsigned long long)state, HaciOSScreenBlanked);
    if (status == NOTIFY_STATUS_OK && state > 1) {
        HaciOSLog(@"unexpected blank screen state=%llu; treating as paused only", (unsigned long long)state);
    }
}

static BOOL HaciOSIsDisabled(void) {
    @try {
        // 0.0.1'deki kurtarma dosyasının yerini koru.
        return [[NSFileManager defaultManager] fileExistsAtPath:
                ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.yigit.hacios.disabled")];
    } @catch (NSException *exception) {
        HaciOSLog(@"disabled check failed: %@", exception.name);
        return YES;
    }
}

@interface HaciOSMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) HaciOSCoordinator *coordinator;
@end

@interface HaciOSOverlayView : UIView
@property (nonatomic, weak) HaciOSCoordinator *coordinator;
@end

@interface HaciOSCoordinator : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) HaciOSOverlayView *overlay;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, assign) BOOL ownerVisible;
@property (nonatomic, assign) BOOL pageReady;
@property (nonatomic, assign) BOOL pageReadyTimedOut;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, strong) WKNavigation *currentNavigation;
- (void)loadOrbitHTML;
- (void)attachToController:(UIViewController *)controller;
- (void)refreshVisibility;
- (void)syncPause:(BOOL)force;
- (void)handleMessage:(WKScriptMessage *)message;
- (void)toast:(NSString *)text;
@end

static BOOL HaciOSViewIsVisible(UIView *view) {
    if (!view || !view.window || view.window.hidden) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
    }
    return YES;
}

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

@implementation HaciOSMessageHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        HaciOSCoordinator *coordinator = self.coordinator;
        if (!coordinator || !message.frameInfo.isMainFrame || ![message.name isEqualToString:@"hacios"]) return;
        [coordinator handleMessage:message];
    } @catch (NSException *exception) {
        HaciOSLog(@"bridge failed: %@", exception.name);
    }
}
@end

@implementation HaciOSOverlayView
- (void)didMoveToWindow {
    [super didMoveToWindow];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { HaciOSLog(@"window visibility failed: %@", exception.name); }
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { HaciOSLog(@"parent visibility failed: %@", exception.name); }
}
- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { HaciOSLog(@"hidden state failed: %@", exception.name); }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { HaciOSLog(@"layout visibility failed: %@", exception.name); }
}
@end

@implementation HaciOSCoordinator
- (void)loadOrbitHTML {
    self.pageReady = NO;
    // Timeout yedeği bir kez açıldıktan sonra reload sırasında da görünürlüğü korur.
    self.currentNavigation = nil;
    self.webView.hidden = YES; // Hazır sinyali yoksa yalnız siyah native zemin gösterilir.
    NSUInteger generation = ++self.loadGeneration;
    __weak HaciOSCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HaciOSCoordinator *coordinator = weakSelf;
        // Yeniden başlayan WebContent süreçleri ilk 3 sn süresini sonsuza kadar uzatmasın.
        if (!coordinator || coordinator.pageReady || coordinator.pageReadyTimedOut) return;
        coordinator.pageReadyTimedOut = YES;
        HaciOSLog(@"page readiness timed out after 3s (startedLoad=%lu currentLoad=%lu); showing black fallback on home",
                  (unsigned long)generation, (unsigned long)coordinator.loadGeneration);
        [coordinator refreshVisibility];
    });
    @try {
        NSString *path = ROOT_PATH_NS(@"/Library/Application Support/HaciOS/orbit.html");
        NSError *error = nil;
        // WebContent sandbox'ına /var/jb okuma izni verme; belgeyi SpringBoard okur.
        // Orbit'in CSS, JS, shader ve SVG içeriği gömülüdür; harici dosya gerekmez.
        NSString *html = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if (!html.length) {
            HaciOSLog(@"orbit HTML read failed/empty: path=%@ error=%@; awaiting black fallback", path, error);
        } else {
            HaciOSLog(@"loading inline orbit HTML: path=%@ chars=%lu load=%lu", path,
                      (unsigned long)html.length, (unsigned long)generation);
            self.currentNavigation = [self.webView loadHTMLString:html baseURL:nil];
            if (!self.currentNavigation) HaciOSLog(@"loadHTMLString returned no navigation; awaiting black fallback");
        }
    } @catch (NSException *exception) {
        HaciOSLog(@"inline HTML load failed: %@; awaiting black fallback", exception);
    }
    [self refreshVisibility];
}

- (void)attachToController:(UIViewController *)controller {
    @try {
        BOOL disabled = HaciOSIsDisabled();
        HaciOSLog(@"attachToController: class=%@ hiddenUntilRespring=%d disabled=%d",
                  NSStringFromClass(controller.class), HaciOSHiddenUntilRespring, disabled);
        if (!controller || HaciOSHiddenUntilRespring || disabled) {
            HaciOSLog(@"attachment skipped: controller=%@ hiddenUntilRespring=%d disabled=%d",
                      controller, HaciOSHiddenUntilRespring, disabled);
            return;
        }
        UIView *homeView = controller.viewIfLoaded;
        // Aynı SpringBoard penceresinin en üst alt görünümü dock'u da örter.
        // Ayrı bir alert/key window oluşturma: uygulama ve sistem pencereleriyle yarışmaz.
        UIWindow *host = homeView.window;
        HaciOSLog(@"host: class=%@ frame=%@ bounds=%@ hidden=%d; home: class=%@ frame=%@ window=%@",
                  NSStringFromClass(host.class), NSStringFromCGRect(host.frame), NSStringFromCGRect(host.bounds),
                  host.hidden, NSStringFromClass(homeView.class), NSStringFromCGRect(homeView.frame), homeView.window);
        if (!host || CGRectIsEmpty(host.bounds)) {
            HaciOSLog(@"attachment deferred: host missing or empty; retry on home appearance");
            return;
        }
        self.owner = controller;
        self.ownerVisible = YES;
        if (!self.overlay) {
            WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
            HaciOSMessageHandler *handler = [[HaciOSMessageHandler alloc] init];
            handler.coordinator = self;
            [configuration.userContentController addScriptMessageHandler:handler name:@"hacios"];
            HaciOSOverlayView *overlay = [[HaciOSOverlayView alloc] initWithFrame:CGRectZero];
            overlay.coordinator = self;
            overlay.translatesAutoresizingMaskIntoConstraints = NO;
            overlay.backgroundColor = [UIColor blackColor];
            overlay.opaque = YES;
            overlay.hidden = YES;
            WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
            webView.translatesAutoresizingMaskIntoConstraints = NO;
            webView.backgroundColor = [UIColor blackColor];
            webView.opaque = YES;
            webView.scrollView.backgroundColor = [UIColor blackColor];
            webView.scrollView.scrollEnabled = NO;
            webView.scrollView.bounces = NO;
            webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
            webView.navigationDelegate = self;
            [overlay addSubview:webView];
            [NSLayoutConstraint activateConstraints:@[
                [webView.topAnchor constraintEqualToAnchor:overlay.topAnchor],
                [webView.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor],
                [webView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
                [webView.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor]
            ]];
            self.overlay = overlay;
            self.webView = webView;
            self.paused = YES;
            [self loadOrbitHTML];
        }
        if (self.overlay.superview != host) {
            [self.overlay removeFromSuperview];
            [host addSubview:self.overlay];
            [NSLayoutConstraint activateConstraints:@[
                [self.overlay.topAnchor constraintEqualToAnchor:host.topAnchor],
                [self.overlay.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
                [self.overlay.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
                [self.overlay.trailingAnchor constraintEqualToAnchor:host.trailingAnchor]
            ]];
            HaciOSLog(@"overlay added above dock (%@)", NSStringFromClass(controller.class));
        }
        [host bringSubviewToFront:self.overlay];
        [host layoutIfNeeded];
        HaciOSLog(@"overlay attached: class=%@ frame=%@ host=%@", NSStringFromClass(self.overlay.class),
                  NSStringFromCGRect(self.overlay.frame), NSStringFromClass(host.class));
        [self refreshVisibility];
    } @catch (NSException *exception) {
        self.ownerVisible = NO;
        @try {
            self.overlay.hidden = YES;
            [self syncPause:YES];
        } @catch (__unused NSException *cleanupException) {}
        HaciOSLog(@"overlay attachment failed: %@", exception.name);
    }
}

- (void)refreshVisibility {
    @try {
        BOOL disabled = HaciOSIsDisabled();
        BOOL viewVisible = HaciOSViewIsVisible(self.owner.viewIfLoaded);
        // Özel hasBlankedScreen bildirimi görünürlüğü engellemez; yalnız animasyonu duraklatır.
        BOOL visible = (self.pageReady || self.pageReadyTimedOut) && self.ownerVisible && HaciOSFrontIsHome &&
                       !HaciOSHiddenUntilRespring && !disabled && viewVisible;
        HaciOSLog(@"refreshVisibility: pageReady=%d timeout=%d ownerVisible=%d FrontIsHome=%d ScreenBlanked=%d "
                  @"hiddenUntilRespring=%d disabled=%d viewVisible=%d visible=%d",
                  self.pageReady, self.pageReadyTimedOut, self.ownerVisible, HaciOSFrontIsHome,
                  HaciOSScreenBlanked, HaciOSHiddenUntilRespring, disabled, viewVisible, visible);
        self.webView.hidden = !self.pageReady;
        self.overlay.hidden = !visible;
        if (visible) [self.overlay.superview bringSubviewToFront:self.overlay];
        [self syncPause:NO];
    } @catch (NSException *exception) {
        HaciOSLog(@"visibility failed: %@", exception.name);
    }
}

- (void)syncPause:(BOOL)force {
    @try {
        BOOL paused = HaciOSHiddenUntilRespring || HaciOSScreenBlanked || !HaciOSFrontIsHome ||
                      !self.ownerVisible || !HaciOSViewIsVisible(self.owner.viewIfLoaded) ||
                      !HaciOSViewIsVisible(self.overlay) || HaciOSIsDisabled();
        if (!force && self.paused == paused) return;
        self.paused = paused;
        HaciOSLog(@"pause: %@", paused ? @"true" : @"false");
        if (self.pageReady) {
            [self.webView evaluateJavaScript:paused ? @"window.haciPause && window.haciPause(true);" :
                                                    @"window.haciPause && window.haciPause(false);"
                          completionHandler:^(id result, NSError *error) {
                if (error) HaciOSLog(@"pause JS failed: %@", error.localizedDescription);
            }];
        }
    } @catch (NSException *exception) {
        HaciOSLog(@"pause failed: %@", exception.name);
    }
}

- (void)toast:(NSString *)text {
    @try {
        if (!self.pageReady || !text) return;
        NSData *json = [NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil];
        if (!json) return;
        NSString *arguments = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        NSString *script = [NSString stringWithFormat:@"window.haciToast && window.haciToast.apply(null,%@);", arguments];
        [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) HaciOSLog(@"toast JS failed: %@", error.localizedDescription);
        }];
    } @catch (NSException *exception) {
        HaciOSLog(@"toast failed: %@", exception.name);
    }
}

- (void)handleMessage:(WKScriptMessage *)message {
    if (![NSThread isMainThread]) {
        __weak HaciOSCoordinator *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleMessage:message]; });
        return;
    }
    @try {
        if (HaciOSHiddenUntilRespring || HaciOSIsDisabled()) return;
        if (![message.body isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *body = message.body;
        id command = body[@"cmd"];
        if (![command isKindOfClass:[NSString class]]) return;
        if ([command isEqualToString:@"hide"]) {
            HaciOSHiddenUntilRespring = YES;
            self.overlay.hidden = YES;
            [self syncPause:YES];
            HaciOSLog(@"overlay hidden until respring");
            return;
        }
        if (![command isEqualToString:@"open"] || self.overlay.hidden || !HaciOSFrontIsHome) return;
        id key = body[@"key"];
        if (![key isKindOfClass:[NSString class]]) return;
        if ([key isEqualToString:@"haci"]) {
            [self toast:@"YAKINDA"];
            return;
        }
        if ([key isEqualToString:@"claude"]) {
            NSURL *url = [NSURL URLWithString:@"https://claude.ai"];
            __weak HaciOSCoordinator *weakSelf = self;
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    HaciOSLog(@"open claude URL: %@", success ? @"accepted" : @"failed");
                    if (!success) [weakSelf toast:@"Açılamadı"];
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
        if (!bundleID || !HaciOSLaunchBundle(bundleID)) [self toast:@"Açılamadı"];
    } @catch (NSException *exception) {
        HaciOSLog(@"open command failed: %@", exception.name);
        [self toast:@"Açılamadı"];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    @try {
        if (webView != self.webView || navigation != self.currentNavigation) return;
        NSUInteger generation = self.loadGeneration;
        HaciOSLog(@"orbit navigation finished (load=%lu); checking readiness", (unsigned long)generation);
        __weak HaciOSCoordinator *weakSelf = self;
        [webView evaluateJavaScript:@"window.haciReady === true && typeof window.haciPause === 'function' && typeof window.haciToast === 'function'"
                 completionHandler:^(id result, NSError *error) {
            @try {
                HaciOSCoordinator *coordinator = weakSelf;
                if (!coordinator || webView != coordinator.webView || generation != coordinator.loadGeneration ||
                    navigation != coordinator.currentNavigation) return;
                coordinator.pageReady = !error && [result isKindOfClass:[NSNumber class]] && [result boolValue];
                HaciOSLog(@"orbit readiness: ready=%d result=%@ error=%@", coordinator.pageReady, result, error);
                [coordinator refreshVisibility];
                [coordinator syncPause:YES];
            } @catch (NSException *exception) {
                HaciOSLog(@"page readiness failed: %@", exception.name);
            }
        }];
    } @catch (NSException *exception) {
        HaciOSLog(@"page completion failed: %@", exception.name);
    }
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    @try {
        HaciOSLog(@"orbit navigation failed: domain=%@ code=%ld error=%@", error.domain, (long)error.code, error);
        if (webView != self.webView || navigation != self.currentNavigation) return;
        self.pageReady = NO;
        self.currentNavigation = nil; // Bekleyen eski readiness callback'i artık kabul edilmez.
        [self refreshVisibility];
    } @catch (NSException *exception) { HaciOSLog(@"navigation cleanup failed: %@", exception.name); }
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    HaciOSLog(@"orbit provisional navigation failed: domain=%@ code=%ld error=%@", error.domain, (long)error.code, error);
    [self webView:webView didFailNavigation:navigation withError:error];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    @try {
        if (webView != self.webView) return;
        self.pageReady = NO;
        self.currentNavigation = nil;
        [self refreshVisibility];
        BOOL disabled = HaciOSIsDisabled();
        HaciOSLog(@"web content process terminated: hiddenUntilRespring=%d disabled=%d; scheduling HTML reload",
                  HaciOSHiddenUntilRespring, disabled);
        if (HaciOSHiddenUntilRespring || disabled) {
            HaciOSLog(@"web content reload skipped: hiddenUntilRespring=%d disabled=%d", HaciOSHiddenUntilRespring, disabled);
            return;
        }
        // Tekrarlayan çökmede sıkı bir reload döngüsü kurma; ilk timeout yedeği geçerli kalır.
        NSUInteger generation = self.loadGeneration;
        __weak HaciOSCoordinator *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            HaciOSCoordinator *coordinator = weakSelf;
            if (!coordinator || generation != coordinator.loadGeneration) return;
            BOOL nowDisabled = HaciOSIsDisabled();
            if (HaciOSHiddenUntilRespring || nowDisabled) {
                HaciOSLog(@"scheduled web content reload skipped: hiddenUntilRespring=%d disabled=%d",
                          HaciOSHiddenUntilRespring, nowDisabled);
                return;
            }
            [coordinator loadOrbitHTML];
        });
    } @catch (NSException *exception) { HaciOSLog(@"web content recovery failed: %@", exception.name); }
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // loadHTMLString:baseURL:nil ana belgeyi about:blank olarak açar.
    // Yalnız programatik ana belge yüklemesine izin ver; dış URL native openURL'den gider.
    BOOL allowed = NO;
    @try {
        allowed = action.targetFrame.isMainFrame && action.navigationType == WKNavigationTypeOther &&
                  [action.request.URL.absoluteString isEqualToString:@"about:blank"];
        HaciOSLog(@"navigation policy: URL=%@ type=%ld mainFrame=%d allowed=%d", action.request.URL,
                  (long)action.navigationType, action.targetFrame.isMainFrame, allowed);
    } @catch (NSException *exception) { HaciOSLog(@"navigation policy failed: %@", exception.name); }
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
@end

static void HaciOSAttach(id candidate) {
    HaciOSLog(@"HaciOSAttach called: candidateClass=%@ mainThread=%d", NSStringFromClass([candidate class]), [NSThread isMainThread]);
    __weak id weakCandidate = candidate;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id controller = weakCandidate;
            BOOL compatible = [controller isKindOfClass:[UIViewController class]];
            BOOL disabled = HaciOSIsDisabled();
            HaciOSLog(@"HaciOSAttach on main: class=%@ compatible=%d hiddenUntilRespring=%d disabled=%d",
                      NSStringFromClass([controller class]), compatible, HaciOSHiddenUntilRespring, disabled);
            if (!compatible || HaciOSHiddenUntilRespring || disabled) {
                HaciOSLog(@"HaciOSAttach skipped: invalid/released controller, hidden or disabled");
                return;
            }
            if (!HaciOSOrbit) HaciOSOrbit = [[HaciOSCoordinator alloc] init];
            [HaciOSOrbit attachToController:controller];
        } @catch (NSException *exception) { HaciOSLog(@"attach scheduling failed: %@", exception.name); }
    });
}

%group HaciOSHome
// ctor iOS 16 sınıfını, yoksa SBIconController'ı bu hook adına bağlar.
%hook HaciOSHomeController
- (void)viewDidLoad {
    %orig;
    @try { HaciOSAttach(self); }
    @catch (NSException *exception) { HaciOSLog(@"home load failed: %@", exception.name); }
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try { HaciOSAttach(self); }
    @catch (NSException *exception) { HaciOSLog(@"home appearance failed: %@", exception.name); }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    @try {
        if (HaciOSOrbit.owner == (id)self) {
            HaciOSLog(@"home will disappear: class=%@", NSStringFromClass([self class]));
            HaciOSOrbit.ownerVisible = NO;
            [HaciOSOrbit refreshVisibility];
        }
    } @catch (NSException *exception) { HaciOSLog(@"home disappearance failed: %@", exception.name); }
}
%end
%end

%group HaciOSFrontDisplay
%hook SpringBoard
- (void)frontDisplayDidChange:(id)display {
    %orig;
    BOOL home = (display == nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            HaciOSFrontIsHome = home;
            HaciOSLog(@"frontDisplayDidChange: displayClass=%@ display=%@ FrontIsHome=%d",
                      NSStringFromClass([display class]), display, home);
            [HaciOSOrbit refreshVisibility];
        } @catch (NSException *exception) { HaciOSLog(@"front display failed: %@", exception.name); }
    });
}
%end
%end

static BOOL HaciOSCanHookHome(Class cls) {
    return cls && [cls isSubclassOfClass:[UIViewController class]] &&
           class_getInstanceMethod(cls, @selector(viewDidLoad)) &&
           class_getInstanceMethod(cls, @selector(viewDidAppear:)) &&
           class_getInstanceMethod(cls, @selector(viewWillDisappear:));
}

%ctor {
    @autoreleasepool {
        @try {
            HaciOSLog(@"initializing 0.1.1: process=%@ FrontIsHome=%d ScreenBlanked=%d hiddenUntilRespring=%d",
                      [NSProcessInfo processInfo].processName, HaciOSFrontIsHome, HaciOSScreenBlanked, HaciOSHiddenUntilRespring);
            if (HaciOSIsDisabled()) {
                HaciOSLog(@"initialization skipped: disabled sentinel present or disabled check failed");
                return;
            }
            Class homeClass = objc_getClass("SBHomeScreenViewController");
            if (!HaciOSCanHookHome(homeClass)) {
                HaciOSLog(@"SBHomeScreenViewController unavailable/incompatible; trying SBIconController");
                homeClass = objc_getClass("SBIconController");
            }
            if (!HaciOSCanHookHome(homeClass)) {
                HaciOSLog(@"no compatible home controller; skipped");
                return;
            }
            Class springBoardClass = objc_getClass("SpringBoard");
            if (!springBoardClass || !class_getInstanceMethod(springBoardClass, NSSelectorFromString(@"frontDisplayDidChange:"))) {
                // Uygulamalar üstünde kalma riski varsa overlay'i başlatma.
                HaciOSLog(@"front display hook unavailable; skipped");
                return;
            }
            uint32_t status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &HaciOSBlankToken,
                                                       dispatch_get_main_queue(), ^(int token) {
                @try {
                    HaciOSReadBlankState(token, @"notification");
                    [HaciOSOrbit refreshVisibility];
                } @catch (NSException *exception) { HaciOSLog(@"blank screen notification failed: %@", exception.name); }
            });
            if (status != NOTIFY_STATUS_OK) {
                HaciOSBlankToken = -1;
                HaciOSScreenBlanked = YES;
                HaciOSLog(@"blank screen notify registration failed: status=%u; continuing with animations paused", status);
            } else {
                HaciOSLog(@"blank screen notify registered: token=%d", HaciOSBlankToken);
                HaciOSReadBlankState(HaciOSBlankToken, @"initial");
            }
            %init(HaciOSFrontDisplay);
            %init(HaciOSHome, HaciOSHomeController = homeClass);
            HaciOSLog(@"loaded 0.1.1 (%@)", NSStringFromClass(homeClass));
        } @catch (NSException *exception) {
            HaciOSHiddenUntilRespring = YES;
            HaciOSLog(@"initialization failed: %@", exception.name);
        }
    }
}
