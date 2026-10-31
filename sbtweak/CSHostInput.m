// CSHostInput.m — DIAGNOSTIC ONLY. Runs in the CarPlay host processes ("CarPlay" =
// the DashBoard UI that owns the car screen, sidebar and focus engine;
// "CarPlayTemplateUIHost"/"CarPlayApp" = where stock template apps are drawn).
// Logs what the car's joystick and rotary dial deliver *there*, which window they
// go to, and where UIKit focus sits before and just after each press. Changes no
// behaviour. Read with: carsurf-logs | grep "hostinput/"

#define CS_TAG "hostinput"

#import "CSSystemInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>

static void (*orig_sendEvent)(UIApplication *, SEL, UIEvent *);
static void (*orig_handleHID)(UIApplication *, SEL, void *);
static int (*gGetType)(void *);
static int64_t (*gGetInt)(void *, uint32_t);
static NSMutableDictionary<NSString *, NSNumber *> *gCounts;
static NSObject *gLock;

static BOOL CSHostShouldLog(NSString *key, NSUInteger firstN, NSUInteger every) {
    @synchronized (gLock) {
        NSUInteger n = gCounts[key].unsignedIntegerValue + 1;
        gCounts[key] = @(n);
        return n <= firstN || (every > 0 && (n % every) == 0);
    }
}

static NSString *CSHostFocusDescription(UIWindow *window) {
    if (!window) return @"no-window";
    Class fs = NSClassFromString(@"UIFocusSystem");
    if (!fs || ![fs respondsToSelector:@selector(focusSystemForEnvironment:)]) return @"no-UIFocusSystem";
    id sys = ((id (*)(id, SEL, id))objc_msgSend)(fs, @selector(focusSystemForEnvironment:), window);
    if (!sys) return @"no-focus-system";
    id item = [sys respondsToSelector:@selector(focusedItem)]
        ? ((id (*)(id, SEL))objc_msgSend)(sys, @selector(focusedItem)) : nil;
    if (!item) return @"none";
    NSString *name = [NSString stringWithUTF8String:object_getClassName(item)];
    if ([item isKindOfClass:UIView.class]) {
        CGRect r = [(UIView *)item convertRect:((UIView *)item).bounds toView:nil];
        return [NSString stringWithFormat:@"%@@%.0f,%.0f %.0fx%.0f", name,
                r.origin.x, r.origin.y, r.size.width, r.size.height];
    }
    return name;
}

static NSString *CSHostWindowDescription(UIWindow *w) {
    if (!w) return @"nil";
    return [NSString stringWithFormat:@"%s(scene=%s level=%.0f key=%d)",
            object_getClassName(w), object_getClassName(w.windowScene),
            w.windowLevel, w.isKeyWindow];
}

static void cs_host_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    UIWindow *window = nil;
    NSString *detail = nil;
    if ([event isKindOfClass:UIPressesEvent.class]) {
        UIPress *p = ((UIPressesEvent *)event).allPresses.anyObject;
        window = p.window;
        detail = [NSString stringWithFormat:@"press type=%ld phase=%ld count=%lu",
                  (long)p.type, (long)p.phase, (unsigned long)((UIPressesEvent *)event).allPresses.count];
    } else if (event.type == UIEventTypeTouches) {
        orig_sendEvent(self, _cmd, event); // touches are not interesting
        return;
    } else {
        detail = [NSString stringWithFormat:@"event type=%ld subtype=%ld",
                  (long)event.type, (long)event.subtype];
    }
    NSString *key = [@"se:" stringByAppendingString:detail];
    BOOL log = CSHostShouldLog(key, 40, 100);
    if (log) {
        CSLog("%s window=%s focusBefore=%s", detail.UTF8String,
              CSHostWindowDescription(window).UTF8String,
              CSHostFocusDescription(window ?: self.keyWindow).UTF8String);
    }
    orig_sendEvent(self, _cmd, event);
    if (log && window) {
        __weak UIWindow *weakWindow = window;
        dispatch_async(dispatch_get_main_queue(), ^{
            CSLog("  after: focus=%s", CSHostFocusDescription(weakWindow).UTF8String);
        });
    }
}

static void cs_host_handleHID(UIApplication *self, SEL _cmd, void *hid) {
    if (hid && gGetType) {
        int type = gGetType(hid);
        // Skip digitizer (11) floods; everything else is interesting (keyboard 3,
        // button 2, rotation 5, scroll 6, vendor 1, pointer 17 ...).
        if (type != 11) {
            NSString *key = [NSString stringWithFormat:@"hid:%d", type];
            if (CSHostShouldLog(key, 40, 100)) {
                if (type == 3 && gGetInt) {
                    CSLog("HID keyboard page=0x%llx usage=0x%llx down=%lld",
                          (long long)gGetInt(hid, 0x30000), (long long)gGetInt(hid, 0x30001),
                          (long long)gGetInt(hid, 0x30002));
                } else {
                    CSLog("HID event type=%d", type);
                }
            }
        }
    }
    orig_handleHID(self, _cmd, hid);
}

static UIView *CSFindViewNamed(UIView *v, const char *cls, int depth) {
    if (depth > 40) return nil;
    if (!v.hidden && strstr(object_getClassName(v), cls)) return v;
    for (UIView *s in v.subviews) {
        UIView *r = CSFindViewNamed(s, cls, depth + 1);
        if (r) return r;
    }
    return nil;
}

/// Gives UIKit focus to the car's sidebar (dock), as happens when you leave a stock
/// app. Triggered by a Darwin notification posted from a bridged app (CSNav.m).
static void CSHostFocusDock(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIView *icon = nil;
    UIWindow *win = nil;
    for (int pass = 0; pass < 2 && !icon; pass++) {
        for (UIScene *sc in app.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (pass == 0 && !strstr(object_getClassName(w), "Dock")) continue;
                UIView *f = CSFindViewNamed(w, "DBIconView", 0);
                if (f) { icon = f; win = w; break; }
            }
            if (icon) break;
        }
    }
    Class fsClass = NSClassFromString(@"UIFocusSystem");
    id sys = (icon && fsClass) ? ((id (*)(id, SEL, id))objc_msgSend)(
                 fsClass, @selector(focusSystemForEnvironment:), win) : nil;
    if (!sys) { CSLog("dock focus: no icon/focus system (icon=%d)", icon != nil); return; }
    CSLog("dock focus: requesting focus on %s in %s", object_getClassName(icon), object_getClassName(win));
    ((void (*)(id, SEL, id))objc_msgSend)(sys, @selector(requestFocusUpdateToEnvironment:), icon);
    if ([sys respondsToSelector:@selector(updateFocusIfNeeded)]) {
        ((void (*)(id, SEL))objc_msgSend)(sys, @selector(updateFocusIfNeeded));
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        CSLog("dock focus: now %s", CSHostFocusDescription(win).UTF8String);
    });
}

static void CSHostDockNotification(CFNotificationCenterRef c, void *o, CFNotificationName n,
                                   const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ CSHostFocusDock(); });
}

static NSMapTable<UIWindow *, NSString *> *gLastFocus;

/// Logs whenever the focused item of any window changes. This is how a dial turn
/// shows up even when it is not delivered as a press.
static void CSHostPollFocus(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            NSString *now = CSHostFocusDescription(w);
            NSString *prev = [gLastFocus objectForKey:w];
            if ([now isEqualToString:prev ?: @""]) continue;
            [gLastFocus setObject:now forKey:w];
            if (!prev && ([now isEqualToString:@"none"] || [now isEqualToString:@"no-focus-system"])) continue;
            CSLog("focus change window=%s: %s -> %s", CSHostWindowDescription(w).UTF8String,
                  prev ? prev.UTF8String : "(start)", now.UTF8String);
        }
    }
}

void CSInstallHostInputDiagnostics(void) {
    NSString *proc = NSProcessInfo.processInfo.processName;
    if (![proc isEqualToString:@"CarPlay"] && ![proc isEqualToString:@"CarPlayApp"] &&
        ![proc isEqualToString:@"CarPlayTemplateUIHost"]) return;
    gCounts = [NSMutableDictionary dictionary];
    gLock = [NSObject new];
    gGetType = (int (*)(void *))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    gGetInt = (int64_t (*)(void *, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    BOOL se = CSSwizzleInstanceMethod(UIApplication.class, @selector(sendEvent:),
                                      (IMP)cs_host_sendEvent, (IMP *)&orig_sendEvent);
    BOOL hid = CSSwizzleInstanceMethod(UIApplication.class, sel_getUid("_handleHIDEvent:"),
                                       (IMP)cs_host_handleHID, (IMP *)&orig_handleHID);
    gLastFocus = [NSMapTable weakToStrongObjectsMapTable];
    if ([proc isEqualToString:@"CarPlay"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        CSHostDockNotification, CFSTR("com.carsurf.focusdock"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { CSHostPollFocus(); }];
    CSLog("host input diagnostics installed (sendEvent=%d hid=%d getType=%d getInt=%d)",
          se, hid, gGetType != NULL, gGetInt != NULL);
}
