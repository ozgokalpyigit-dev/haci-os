#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdint.h>
#import <string.h>

#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#ifndef ROOT_PATH_NS
#define ROOT_PATH_NS(path) (@"/var/jb" path)
#endif

@class HaciOSCoordinator;
static HaciOSCoordinator *HaciOSOrbit;
static BOOL HaciOSHiddenUntilRespring = NO;
static BOOL HaciOSFrontIsHome = YES;
static BOOL HaciOSScreenBlanked = NO;
static int HaciOSBlankToken = -1;

static BOOL HaciOSIsDisabled(void) {
    @try {
        // 0.0.1'deki kurtarma dosyasının yerini koru.
        return [[NSFileManager defaultManager] fileExistsAtPath:
                ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.yigit.hacios.disabled")];
    } @catch (NSException *exception) {
        NSLog(@"[HaciOS] disabled check failed: %@", exception.name);
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
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL webRecoveryAttempted;
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
        NSLog(@"[HaciOS] launch API failed (%@): %@", bundleID, exception.name);
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
            NSLog(@"[HaciOS] workspace failed: %@", exception.name);
        }
    }
    NSLog(@"[HaciOS] open %@: %@", bundleID, opened ? @"accepted" : @"failed");
    return opened;
}

@implementation HaciOSMessageHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        HaciOSCoordinator *coordinator = self.coordinator;
        if (!coordinator || !message.frameInfo.isMainFrame || ![message.name isEqualToString:@"hacios"]) return;
        [coordinator handleMessage:message];
    } @catch (NSException *exception) {
        NSLog(@"[HaciOS] bridge failed: %@", exception.name);
    }
}
@end

@implementation HaciOSOverlayView
- (void)didMoveToWindow {
    [super didMoveToWindow];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { NSLog(@"[HaciOS] window visibility failed: %@", exception.name); }
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { NSLog(@"[HaciOS] parent visibility failed: %@", exception.name); }
}
- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { NSLog(@"[HaciOS] hidden state failed: %@", exception.name); }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    @try { [self.coordinator syncPause:NO]; }
    @catch (NSException *exception) { NSLog(@"[HaciOS] layout visibility failed: %@", exception.name); }
}
@end

@implementation HaciOSCoordinator
- (void)attachToController:(UIViewController *)controller {
    @try {
        if (!controller || HaciOSHiddenUntilRespring || HaciOSIsDisabled()) return;
        UIView *homeView = controller.viewIfLoaded;
        // Aynı SpringBoard penceresinin en üst alt görünümü dock'u da örter.
        // Ayrı bir alert/key window oluşturma: uygulama ve sistem pencereleriyle yarışmaz.
        UIWindow *host = homeView.window;
        if (!host || CGRectIsEmpty(host.bounds)) return;
        self.owner = controller;
        self.ownerVisible = YES;
        if (!self.overlay) {
            NSString *path = ROOT_PATH_NS(@"/Library/Application Support/HaciOS/orbit.html");
            if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
                NSLog(@"[HaciOS] orbit file missing: %@", path);
                return;
            }
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
            NSURL *fileURL = [NSURL fileURLWithPath:path];
            [webView loadFileURL:fileURL allowingReadAccessToURL:[fileURL URLByDeletingLastPathComponent]];
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
            NSLog(@"[HaciOS] overlay added above dock (%@)", NSStringFromClass(controller.class));
        }
        [host bringSubviewToFront:self.overlay];
        [self refreshVisibility];
    } @catch (NSException *exception) {
        self.ownerVisible = NO;
        @try {
            self.overlay.hidden = YES;
            [self syncPause:YES];
        } @catch (__unused NSException *cleanupException) {}
        NSLog(@"[HaciOS] overlay attachment failed: %@", exception.name);
    }
}

- (void)refreshVisibility {
    @try {
        BOOL visible = self.pageReady && self.ownerVisible && HaciOSFrontIsHome &&
                       !HaciOSScreenBlanked && !HaciOSHiddenUntilRespring && !HaciOSIsDisabled() &&
                       HaciOSViewIsVisible(self.owner.viewIfLoaded);
        self.overlay.hidden = !visible;
        if (visible) [self.overlay.superview bringSubviewToFront:self.overlay];
        [self syncPause:NO];
    } @catch (NSException *exception) {
        NSLog(@"[HaciOS] visibility failed: %@", exception.name);
    }
}

- (void)syncPause:(BOOL)force {
    @try {
        BOOL paused = HaciOSHiddenUntilRespring || HaciOSScreenBlanked || !HaciOSFrontIsHome ||
                      !self.ownerVisible || !HaciOSViewIsVisible(self.owner.viewIfLoaded) ||
                      !HaciOSViewIsVisible(self.overlay) || HaciOSIsDisabled();
        if (!force && self.paused == paused) return;
        self.paused = paused;
        NSLog(@"[HaciOS] pause: %@", paused ? @"true" : @"false");
        if (self.pageReady) {
            [self.webView evaluateJavaScript:paused ? @"window.haciPause && window.haciPause(true);" :
                                                    @"window.haciPause && window.haciPause(false);"
                          completionHandler:^(id result, NSError *error) {
                if (error) NSLog(@"[HaciOS] pause JS failed: %@", error.localizedDescription);
            }];
        }
    } @catch (NSException *exception) {
        NSLog(@"[HaciOS] pause failed: %@", exception.name);
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
            if (error) NSLog(@"[HaciOS] toast JS failed: %@", error.localizedDescription);
        }];
    } @catch (NSException *exception) {
        NSLog(@"[HaciOS] toast failed: %@", exception.name);
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
            NSLog(@"[HaciOS] overlay hidden until respring");
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
                    NSLog(@"[HaciOS] open claude URL: %@", success ? @"accepted" : @"failed");
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
        NSLog(@"[HaciOS] open command failed: %@", exception.name);
        [self toast:@"Açılamadı"];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    @try {
        if (webView != self.webView) return;
        __weak HaciOSCoordinator *weakSelf = self;
        [webView evaluateJavaScript:@"window.haciReady === true && typeof window.haciPause === 'function' && typeof window.haciToast === 'function'"
                 completionHandler:^(id result, NSError *error) {
            @try {
                HaciOSCoordinator *coordinator = weakSelf;
                if (!coordinator || webView != coordinator.webView) return;
                coordinator.pageReady = !error && [result isKindOfClass:[NSNumber class]] && [result boolValue];
                if (!coordinator.pageReady) NSLog(@"[HaciOS] orbit script unavailable; normal icons retained");
                [coordinator refreshVisibility];
                [coordinator syncPause:YES];
            } @catch (NSException *exception) {
                NSLog(@"[HaciOS] page readiness failed: %@", exception.name);
            }
        }];
    } @catch (NSException *exception) {
        NSLog(@"[HaciOS] page completion failed: %@", exception.name);
    }
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    @try {
        self.pageReady = NO;
        [self refreshVisibility];
        NSLog(@"[HaciOS] orbit navigation failed: %@", error.localizedDescription);
    } @catch (NSException *exception) { NSLog(@"[HaciOS] navigation cleanup failed: %@", exception.name); }
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    @try {
        self.pageReady = NO;
        [self refreshVisibility];
        // Kurtarma sonrasında veya tekrarlayan bir WebKit çökmesinde yeniden başlatma.
        if (!self.webRecoveryAttempted && !HaciOSHiddenUntilRespring && !HaciOSIsDisabled()) {
            self.webRecoveryAttempted = YES;
            [webView reload];
        }
        NSLog(@"[HaciOS] web content process terminated");
    } @catch (NSException *exception) { NSLog(@"[HaciOS] web content recovery failed: %@", exception.name); }
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // Yerel köprü yalnız paketlenmiş ana belgeye açık; dış URL native openURL'den gider.
    BOOL allowed = NO;
    @try {
        NSURL *expected = [NSURL fileURLWithPath:ROOT_PATH_NS(@"/Library/Application Support/HaciOS/orbit.html")];
        allowed = action.request.URL.isFileURL &&
                  [action.request.URL.URLByStandardizingPath.path isEqualToString:expected.URLByStandardizingPath.path];
    } @catch (NSException *exception) { NSLog(@"[HaciOS] navigation policy failed: %@", exception.name); }
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
@end

static void HaciOSAttach(id candidate) {
    __weak id weakCandidate = candidate;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id controller = weakCandidate;
            if (![controller isKindOfClass:[UIViewController class]] || HaciOSHiddenUntilRespring || HaciOSIsDisabled()) return;
            if (!HaciOSOrbit) HaciOSOrbit = [[HaciOSCoordinator alloc] init];
            [HaciOSOrbit attachToController:controller];
        } @catch (NSException *exception) { NSLog(@"[HaciOS] attach scheduling failed: %@", exception.name); }
    });
}

%group HaciOSHome
// ctor iOS 16 sınıfını, yoksa SBIconController'ı bu hook adına bağlar.
%hook HaciOSHomeController
- (void)viewDidLoad {
    %orig;
    @try { HaciOSAttach(self); }
    @catch (NSException *exception) { NSLog(@"[HaciOS] home load failed: %@", exception.name); }
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try { HaciOSAttach(self); }
    @catch (NSException *exception) { NSLog(@"[HaciOS] home appearance failed: %@", exception.name); }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    @try {
        if (HaciOSOrbit.owner == (id)self) {
            HaciOSOrbit.ownerVisible = NO;
            [HaciOSOrbit refreshVisibility];
        }
    } @catch (NSException *exception) { NSLog(@"[HaciOS] home disappearance failed: %@", exception.name); }
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
            [HaciOSOrbit refreshVisibility];
        } @catch (NSException *exception) { NSLog(@"[HaciOS] front display failed: %@", exception.name); }
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
            if (HaciOSIsDisabled()) return;
            Class homeClass = objc_getClass("SBHomeScreenViewController");
            if (!HaciOSCanHookHome(homeClass)) homeClass = objc_getClass("SBIconController");
            if (!HaciOSCanHookHome(homeClass)) {
                NSLog(@"[HaciOS] no compatible home controller; skipped");
                return;
            }
            Class springBoardClass = objc_getClass("SpringBoard");
            if (!springBoardClass || !class_getInstanceMethod(springBoardClass, NSSelectorFromString(@"frontDisplayDidChange:"))) {
                // Uygulamalar üstünde kalma riski varsa overlay'i başlatma.
                NSLog(@"[HaciOS] front display hook unavailable; skipped");
                return;
            }
            uint32_t status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &HaciOSBlankToken,
                                                       dispatch_get_main_queue(), ^(int token) {
                @try {
                    uint64_t state = 0;
                    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) {
                        HaciOSScreenBlanked = YES;
                        NSLog(@"[HaciOS] blank screen state unavailable; paused");
                    } else {
                        HaciOSScreenBlanked = (state != 0);
                    }
                    [HaciOSOrbit refreshVisibility];
                } @catch (NSException *exception) { NSLog(@"[HaciOS] blank screen notification failed: %@", exception.name); }
            });
            uint64_t initialState = 0;
            if (status != NOTIFY_STATUS_OK || notify_get_state(HaciOSBlankToken, &initialState) != NOTIFY_STATUS_OK) {
                if (status == NOTIFY_STATUS_OK) notify_cancel(HaciOSBlankToken);
                NSLog(@"[HaciOS] blank screen observer unavailable; skipped");
                return;
            }
            HaciOSScreenBlanked = (initialState != 0);
            %init(HaciOSFrontDisplay);
            %init(HaciOSHome, HaciOSHomeController = homeClass);
            NSLog(@"[HaciOS] loaded 0.1.0 (%@)", NSStringFromClass(homeClass));
        } @catch (NSException *exception) {
            HaciOSHiddenUntilRespring = YES;
            NSLog(@"[HaciOS] initialization failed: %@", exception.name);
        }
    }
}
