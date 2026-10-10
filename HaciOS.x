#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<rootless.h>)
#import <rootless.h>
#endif

// Theos rootless.h varsa jbroot dönüşümünü ona bırak; eski Theos için Dopamine yolu.
#ifndef ROOT_PATH_NS
#define ROOT_PATH_NS(path) (@"/var/jb" path)
#endif

static UIWindow *HaciOSBadgeWindow = nil;
static BOOL HaciOSBadgeShown = NO;

static BOOL HaciOSIsDisabled(void) {
    @try {
        NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.yigit.hacios.disabled");
        return [[NSFileManager defaultManager] fileExistsAtPath:path];
    } @catch (__unused NSException *exception) {
        // Kurtarma kontrolü başarısızsa arayüze müdahale etme.
        return YES;
    }
}

static UIWindowScene *HaciOSWindowScene(UIApplication *application) {
    if (!application) {
        return nil;
    }

    UIWindowScene *firstScene = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (!firstScene) {
            firstScene = windowScene;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    return firstScene;
}

static void HaciOSShowBadge(void) {
    // Bu fonksiyon yalnızca ana dispatch kuyruğundan çağrılır.
    if (HaciOSIsDisabled() || HaciOSBadgeShown || HaciOSBadgeWindow) {
        return;
    }

    @try {
        UIWindowScene *scene = HaciOSWindowScene([UIApplication sharedApplication]);
        if (!scene || CGRectIsEmpty(scene.coordinateSpace.bounds)) {
            return;
        }

        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        if (!window) {
            return;
        }
        // ARC altında, görünür olduğu sürece pencereyi güçlü referansla tut.
        HaciOSBadgeWindow = window;
        window.frame = scene.coordinateSpace.bounds;
        window.backgroundColor = [UIColor clearColor];
        window.opaque = NO;
        window.windowLevel = UIWindowLevelAlert + 1.0;
        window.userInteractionEnabled = NO;
        window.accessibilityElementsHidden = YES;

        UIViewController *controller = [[UIViewController alloc] init];
        if (!controller) {
            HaciOSBadgeWindow = nil;
            return;
        }
        window.rootViewController = controller;
        UIView *view = controller.view;
        if (!view) {
            HaciOSBadgeWindow = nil;
            return;
        }
        view.backgroundColor = [UIColor clearColor];
        view.opaque = NO;
        view.userInteractionEnabled = NO;

        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
        if (!badge) {
            HaciOSBadgeWindow = nil;
            return;
        }
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.text = @"HACI OS 0.0.1";
        badge.textColor = [UIColor whiteColor];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        badge.backgroundColor = [UIColor blackColor];
        badge.layer.cornerRadius = 16.0;
        badge.layer.borderWidth = 0.75;
        badge.layer.borderColor = [UIColor whiteColor].CGColor;
        badge.clipsToBounds = YES;
        badge.userInteractionEnabled = NO;

        [view addSubview:badge];
        [NSLayoutConstraint activateConstraints:@[
            [badge.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
            [badge.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:8.0],
            [badge.widthAnchor constraintEqualToConstant:180.0],
            [badge.heightAnchor constraintEqualToConstant:32.0]
        ]];

        // Anahtar pencereyi değiştirme; dokunmalar mevcut SpringBoard penceresine gider.
        window.hidden = NO;
        HaciOSBadgeShown = YES;
        NSLog(@"[HaciOS] badge shown");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                window.hidden = YES;
                window.rootViewController = nil;
            } @catch (__unused NSException *exception) {
                // Pencereyi serbest bırakma işlemi aşağıda her durumda yapılır.
            }
            if (HaciOSBadgeWindow == window) {
                HaciOSBadgeWindow = nil;
            }
        });
    } @catch (NSException *exception) {
        @try {
            HaciOSBadgeWindow.hidden = YES;
        } @catch (__unused NSException *cleanupException) {
        }
        HaciOSBadgeWindow = nil;
        NSLog(@"[HaciOS] badge skipped: %@", exception.name);
    }
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    if (HaciOSIsDisabled()) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HaciOSShowBadge();
    });
}

%end

%ctor {
    @autoreleasepool {
        // Dosya yükleme anında varsa hook ve loaded günlüğü bile etkinleşmez.
        if (!HaciOSIsDisabled()) {
            NSLog(@"[HaciOS] loaded");
            %init;
        }
    }
}
