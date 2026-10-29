// CSInput.m — DIAGNOSTIC ONLY (v0). Logs what input reaches a bridged app so we
// can see whether a car's rotary dial / joystick events arrive at all, and in
// what form. It changes no behaviour: every hook calls the original first/last
// and only writes to the CarSurf log (Verbose Logging must be on).
//
// Look for lines tagged [input/<App>] in `carsurf-logs`.

#define CS_TAG "input"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <objc/message.h>
#import <dlfcn.h>

static void (*orig_sendEvent)(UIApplication *, SEL, UIEvent *);
static void (*orig_handleHIDEvent)(UIApplication *, SEL, void *);
static int (*gHIDEventGetType)(void *);

static NSMutableDictionary<NSString *, NSNumber *> *gCounts;
static NSObject *gLock;
static BOOL gDumpedState;

/// Logs the first `firstN` occurrences of `key`, then every `every`-th.
static BOOL CSInputShouldLog(NSString *key, NSUInteger firstN, NSUInteger every) {
    @synchronized (gLock) {
        NSUInteger n = gCounts[key].unsignedIntegerValue + 1;
        gCounts[key] = @(n);
        return n <= firstN || (every > 0 && (n % every) == 0);
    }
}

static void CSInputDumpState(void) {
    if (gDumpedState) return;
    gDumpedState = YES;
    Class focusSystemClass = NSClassFromString(@"UIFocusSystem");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        BOOL bridged = CSIsBridgedCarScene(scene);
        UIWindow *key = nil;
        for (UIWindow *w in ws.windows) { if (w.isKeyWindow) key = w; }
        if (!key) key = ws.windows.firstObject;
        const char *focused = "n/a";
        if (key && focusSystemClass &&
            [focusSystemClass respondsToSelector:@selector(focusSystemForEnvironment:)]) {
            id system = ((id (*)(id, SEL, id))objc_msgSend)(
                focusSystemClass, @selector(focusSystemForEnvironment:), key);
            id item = [system respondsToSelector:@selector(focusedItem)]
                ? ((id (*)(id, SEL))objc_msgSend)(system, @selector(focusedItem)) : nil;
            focused = system ? (item ? object_getClassName(item) : "none") : "no-focus-system";
        }
        CSLog("state: scene=%s bridged=%d role=%s windows=%lu key=%s focusedItem=%s",
              object_getClassName(scene), bridged, scene.session.role.UTF8String ?: "nil",
              (unsigned long)ws.windows.count,
              key ? object_getClassName(key) : "nil", focused);
    }
}

static void cs_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (CSHasActiveCarScene()) {
        UIWindow *window = nil;
        NSString *detail = @"";
        if ([event isKindOfClass:UIPressesEvent.class]) {
            UIPress *press = ((UIPressesEvent *)event).allPresses.anyObject;
            window = press.window;
            detail = [NSString stringWithFormat:@" pressType=%ld phase=%ld key=%ld",
                      (long)press.type, (long)press.phase, (long)press.key.keyCode];
        } else {
            window = event.allTouches.anyObject.window;
        }
        BOOL onCar = CSIsBridgedCarScene(window.windowScene);
        NSString *key = [NSString stringWithFormat:@"se:%ld:%ld:%d",
                         (long)event.type, (long)event.subtype, onCar];
        if (CSInputShouldLog(key, 30, 200)) {
            CSLog("sendEvent type=%ld subtype=%ld onCarScene=%d%s",
                  (long)event.type, (long)event.subtype, onCar, detail.UTF8String);
        }
        CSInputDumpState();
        if (onCar && window && [event isKindOfClass:UIPressesEvent.class] &&
            CSNavHandlePresses((UIPressesEvent *)event, window)) {
            return; // joystick press handled by CSNav
        }
    }
    orig_sendEvent(self, _cmd, event);
}

static void cs_handleHIDEvent(UIApplication *self, SEL _cmd, void *hidEvent) {
    if (CSHasActiveCarScene() && hidEvent) {
        int type = gHIDEventGetType ? gHIDEventGetType(hidEvent) : -1;
        // IOHIDEventType: 3=keyboard 6=scroll 11=digitizer 17=pointer etc.
        NSString *key = [NSString stringWithFormat:@"hid:%d", type];
        if (CSInputShouldLog(key, 30, 200)) {
            CSLog("HID event type=%d", type);
        }
    }
    orig_handleHIDEvent(self, _cmd, hidEvent);
}

void CSInstallInputDiagnostics(void) {
    gCounts = [NSMutableDictionary dictionary];
    gLock = [NSObject new];
    gHIDEventGetType = (int (*)(void *))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");

    BOOL se = CSSwizzleInstanceMethod(UIApplication.class, @selector(sendEvent:),
                                      (IMP)cs_sendEvent, (IMP *)&orig_sendEvent);
    BOOL hid = CSSwizzleInstanceMethod(UIApplication.class, sel_getUid("_handleHIDEvent:"),
                                       (IMP)cs_handleHIDEvent, (IMP *)&orig_handleHIDEvent);
    CSLog("input diagnostics installed (sendEvent=%d hid=%d hidGetType=%d)",
          se, hid, gHIDEventGetType != NULL);
}
