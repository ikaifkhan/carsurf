// CSNav.m — joystick / key-press navigation for bridged apps on head units with
// no touchscreen. Builds on what CSInput.m's diagnostics showed: the car's
// joystick reaches the app as ordinary UIPress events (0 up, 1 down, 2 left,
// 3 right, 4 select) and its Back button as press type 7. UIKit's own focus
// system is not running on the car scene, so this keeps its own "current item",
// draws a highlight box over it, moves it spatially, and activates it directly.
//
// Rotary rotation is NOT handled: it never reaches the app as a press.

#define CS_TAG "nav"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <objc/message.h>

enum { CSDirUp = 0, CSDirDown = 1, CSDirLeft = 2, CSDirRight = 3 };

static UIView *gHighlight;
static __weak UIView *gCurrent;
static __weak UIWindow *gWindow;
static NSTimer *gTimer;

#pragma mark - Helpers

static UIResponder *CSResponderOfClass(UIResponder *r, Class cls) {
    while (r) {
        if ([r isKindOfClass:cls]) return r;
        r = r.nextResponder;
    }
    return nil;
}

static UIView *CSAncestorOfClass(UIView *v, Class cls) {
    for (UIView *a = v; a; a = a.superview) {
        if ([a isKindOfClass:cls]) return a;
    }
    return nil;
}

static CGPoint CSMid(CGRect r) {
    return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
}

/// The part of `v` actually visible on screen, in window coordinates, after
/// clipping by scroll views and clipping ancestors. CGRectNull if none.
static CGRect CSVisibleRect(UIView *v, UIWindow *w) {
    CGRect r = [v convertRect:v.bounds toView:w];
    for (UIView *a = v.superview; a && a != w; a = a.superview) {
        if (a.clipsToBounds || [a isKindOfClass:UIScrollView.class]) {
            r = CGRectIntersection(r, [a convertRect:a.bounds toView:w]);
            if (CGRectIsNull(r)) return CGRectNull;
        }
    }
    return CGRectIntersection(r, w.bounds);
}

static UIViewController *CSTopVC(UIWindow *w) {
    UIViewController *vc = w.rootViewController;
    for (int i = 0; vc && i < 30; i++) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *t = ((UINavigationController *)vc).topViewController;
            if (!t || t == vc) break;
            vc = t;
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *s = ((UITabBarController *)vc).selectedViewController;
            if (!s || s == vc) break;
            vc = s;
        } else {
            break;
        }
    }
    return vc;
}

static UIAlertController *CSTopAlert(UIWindow *w) {
    UIViewController *t = CSTopVC(w);
    return [t isKindOfClass:UIAlertController.class] ? (UIAlertController *)t : nil;
}

#pragma mark - Finding things to focus

static BOOL CSHasTap(UIView *v) {
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        if ([g isKindOfClass:UITapGestureRecognizer.class] && g.enabled) return YES;
    }
    return NO;
}

static void CSCollect(UIView *v, UIWindow *w, NSMutableArray<UIView *> *out, int depth) {
    if (depth > 80 || v.hidden || v.alpha < 0.05 || v == gHighlight) return;
    if (v != w && !v.userInteractionEnabled) return;

    CGRect full = [v convertRect:v.bounds toView:w];
    CGFloat winArea = w.bounds.size.width * w.bounds.size.height;
    BOOL isCell = [v isKindOfClass:UITableViewCell.class] ||
                  [v isKindOfClass:UICollectionViewCell.class];
    BOOL big = (full.size.width * full.size.height) >= 0.6 * winArea;
    BOOL cand = NO;

    if (isCell) {
        cand = YES;
    } else if ([v isKindOfClass:UIControl.class]) {
        cand = ((UIControl *)v).enabled && !big;
    } else if (CSHasTap(v)) {
        cand = !big;
    }

    if (cand) {
        CGRect vr = CSVisibleRect(v, w);
        if (!CGRectIsNull(vr) && vr.size.width >= 8 && vr.size.height >= 8 &&
            vr.size.width * vr.size.height >= 0.3 * full.size.width * full.size.height) {
            [out addObject:v];
            return; // treat as a single target; don't list its insides
        }
    }
    for (UIView *s in v.subviews) CSCollect(s, w, out, depth + 1);
}

static UIView *CSFirstCandidate(NSArray<UIView *> *cands, UIWindow *w) {
    NSArray *sorted = [cands sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGRect ra = CSVisibleRect(a, w), rb = CSVisibleRect(b, w);
        if (fabs(ra.origin.y - rb.origin.y) > 12) {
            return ra.origin.y < rb.origin.y ? NSOrderedAscending : NSOrderedDescending;
        }
        return ra.origin.x < rb.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    return sorted.firstObject;
}

static UIView *CSPick(NSArray<UIView *> *cands, UIView *cur, int dir, UIWindow *w) {
    CGRect rc = CSVisibleRect(cur, w);
    if (CGRectIsNull(rc)) return nil;
    CGPoint cc = CSMid(rc);
    BOOL vertical = (dir == CSDirUp || dir == CSDirDown);
    UIView *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (UIView *c in cands) {
        if (c == cur) continue;
        CGRect rr = CSVisibleRect(c, w);
        if (CGRectIsNull(rr)) continue;
        CGPoint cr = CSMid(rr);
        CGFloat dx = cr.x - cc.x, dy = cr.y - cc.y, primary;
        if (dir == CSDirUp)         { if (dy > -2) continue; primary = -dy; }
        else if (dir == CSDirDown)  { if (dy < 2)  continue; primary = dy; }
        else if (dir == CSDirLeft)  { if (dx > -2) continue; primary = -dx; }
        else                        { if (dx < 2)  continue; primary = dx; }
        CGFloat lo1, hi1, lo2, hi2;
        if (vertical) {
            lo1 = CGRectGetMinX(rc); hi1 = CGRectGetMaxX(rc);
            lo2 = CGRectGetMinX(rr); hi2 = CGRectGetMaxX(rr);
        } else {
            lo1 = CGRectGetMinY(rc); hi1 = CGRectGetMaxY(rc);
            lo2 = CGRectGetMinY(rr); hi2 = CGRectGetMaxY(rr);
        }
        CGFloat gap = MAX(0, MAX(lo2 - hi1, lo1 - hi2));
        CGFloat secondary = gap > 0 ? gap : fabs(vertical ? dx : dy) * 0.2;
        CGFloat score = primary + secondary * 3;
        if (score < bestScore) { bestScore = score; best = c; }
    }
    return best;
}

#pragma mark - Highlight

static void CSUpdateHighlight(void) {
    UIView *cur = gCurrent;
    UIWindow *w = gWindow;
    if (!cur || !w || cur.window != w || CSTopAlert(w)) {
        gHighlight.hidden = YES;
        return;
    }
    CGRect r = CSVisibleRect(cur, w);
    if (CGRectIsNull(r)) { gHighlight.hidden = YES; return; }
    if (!gHighlight) {
        UIColor *blue = [UIColor colorWithRed:0.10 green:0.60 blue:1.0 alpha:1.0];
        gHighlight = [[UIView alloc] init];
        gHighlight.userInteractionEnabled = NO;
        gHighlight.layer.borderWidth = 6;
        gHighlight.layer.cornerRadius = 10;
        gHighlight.layer.borderColor = blue.CGColor;
        gHighlight.layer.zPosition = 10000;
        gHighlight.backgroundColor = [blue colorWithAlphaComponent:0.12];
    }
    if (gHighlight.superview != w) [w addSubview:gHighlight];
    [w bringSubviewToFront:gHighlight];
    gHighlight.hidden = NO;
    gHighlight.frame = CGRectInset(r, -4, -4);
}

static void CSRefreshSoon(void) {
    for (NSNumber *delay in @[@0.12, @0.3, @0.6]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CSUpdateHighlight(); });
    }
}

static void CSEnsureTimer(void) {
    if (gTimer) return;
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES
                                               block:^(NSTimer *t) { CSUpdateHighlight(); }];
}

#pragma mark - Moving

static void CSEnsureVisible(UIView *v) {
    for (UIView *a = v.superview; a; a = a.superview) {
        if (![a isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *sv = (UIScrollView *)a;
        CGRect r = [sv convertRect:v.bounds fromView:v];
        if (!CGRectContainsRect(sv.bounds, r)) {
            [sv scrollRectToVisible:CGRectInset(r, -8, -8) animated:YES];
        }
    }
}

/// Scrolls the nearest scrollable ancestor one page toward `dir`. YES if it moved.
static BOOL CSScrollToward(UIView *cur, int dir) {
    BOOL vertical = (dir == CSDirUp || dir == CSDirDown);
    for (UIView *a = cur.superview; a; a = a.superview) {
        if (![a isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *sv = (UIScrollView *)a;
        UIEdgeInsets in = sv.adjustedContentInset;
        CGPoint off = sv.contentOffset;
        if (vertical) {
            CGFloat minY = -in.top;
            CGFloat maxY = MAX(minY, sv.contentSize.height - sv.bounds.size.height + in.bottom);
            CGFloat step = sv.bounds.size.height * 0.8;
            CGFloat ny = (dir == CSDirDown) ? MIN(maxY, off.y + step) : MAX(minY, off.y - step);
            if (fabs(ny - off.y) < 1) continue;
            off.y = ny;
        } else {
            CGFloat minX = -in.left;
            CGFloat maxX = MAX(minX, sv.contentSize.width - sv.bounds.size.width + in.right);
            CGFloat step = sv.bounds.size.width * 0.8;
            CGFloat nx = (dir == CSDirRight) ? MIN(maxX, off.x + step) : MAX(minX, off.x - step);
            if (fabs(nx - off.x) < 1) continue;
            off.x = nx;
        }
        [sv setContentOffset:off animated:YES];
        return YES;
    }
    return NO;
}

static BOOL CSFocusIsValid(UIWindow *w) {
    UIView *cur = gCurrent;
    return cur && cur.window == w && !CGRectIsNull(CSVisibleRect(cur, w));
}

static void CSAutoFocusSoon(UIWindow *w) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (CSFocusIsValid(w) || CSTopAlert(w)) { CSUpdateHighlight(); return; }
        NSMutableArray<UIView *> *cands = [NSMutableArray array];
        CSCollect(w, w, cands, 0);
        gCurrent = CSFirstCandidate(cands, w);
        CSUpdateHighlight();
    });
}

static void CSMove(int dir, UIWindow *w, BOOL allowScroll) {
    if (CSTopAlert(w)) return;
    NSMutableArray<UIView *> *cands = [NSMutableArray array];
    CSCollect(w, w, cands, 0);
    CSLog("move dir=%d candidates=%lu", dir, (unsigned long)cands.count);

    if (!CSFocusIsValid(w)) {
        gCurrent = CSFirstCandidate(cands, w);
        CSLog("initial focus -> %s", gCurrent ? object_getClassName(gCurrent) : "none");
        CSUpdateHighlight();
        return;
    }
    UIView *cur = gCurrent;
    UIView *next = CSPick(cands, cur, dir, w);
    if (next) {
        gCurrent = next;
        CSLog("focus -> %s", object_getClassName(next));
        CSEnsureVisible(next);
        CSUpdateHighlight();
        CSRefreshSoon();
        return;
    }
    if (allowScroll && CSScrollToward(cur, dir)) {
        CSLog("nothing in direction %d; scrolled, retrying", dir);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CSMove(dir, w, NO); });
    }
}

#pragma mark - Activating

static void CSRunAlertAction(UIAlertController *alert, UIAlertAction *action) {
    id raw = nil;
    @try { raw = [action valueForKey:@"handler"]; } @catch (NSException *e) { raw = nil; }
    void (^handler)(UIAlertAction *) = (void (^)(UIAlertAction *))raw;
    [alert dismissViewControllerAnimated:YES completion:^{
        if (handler) handler(action);
    }];
}

static BOOL CSActivateTap(UIView *v) {
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        if (![g isKindOfClass:UITapGestureRecognizer.class] || !g.enabled) continue;
        BOOL fired = NO;
        @try {
            NSArray *targets = [g valueForKey:@"targets"];
            for (id t in targets) {
                id target = [t valueForKey:@"target"];
                NSValue *av = [t valueForKey:@"action"];
                SEL action = NULL;
                if ([av isKindOfClass:NSValue.class]) [av getValue:&action size:sizeof(SEL)];
                if (target && action && [target respondsToSelector:action]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(target, action, g);
                    fired = YES;
                }
            }
        } @catch (NSException *e) {
            CSLog("tap activation failed: %s", e.reason.UTF8String);
        }
        if (fired) return YES;
    }
    return NO;
}

static BOOL CSActivateTabBarItem(UIView *v) {
    UITabBar *tb = (UITabBar *)CSAncestorOfClass(v, UITabBar.class);
    if (!tb) return NO;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *s in tb.subviews) {
        if ([s isKindOfClass:UIControl.class]) [buttons addObject:s];
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSUInteger idx = NSNotFound;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIView *b = buttons[i];
        if (v == b || [v isDescendantOfView:b]) { idx = i; break; }
    }
    NSArray<UITabBarItem *> *items = tb.items;
    if (idx == NSNotFound || idx >= items.count) return NO;

    UITabBarController *tbc = (UITabBarController *)CSResponderOfClass(tb, UITabBarController.class);
    if (tbc && idx < tbc.viewControllers.count) {
        UIViewController *target = tbc.viewControllers[idx];
        id<UITabBarControllerDelegate> d = tbc.delegate;
        if ([d respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
            ![d tabBarController:tbc shouldSelectViewController:target]) {
            return YES;
        }
        tbc.selectedIndex = idx;
        if ([d respondsToSelector:@selector(tabBarController:didSelectViewController:)]) {
            [d tabBarController:tbc didSelectViewController:target];
        }
        CSLog("tab bar -> index %lu", (unsigned long)idx);
        return YES;
    }
    tb.selectedItem = items[idx];
    if ([tb.delegate respondsToSelector:@selector(tabBar:didSelectItem:)]) {
        [tb.delegate tabBar:tb didSelectItem:items[idx]];
    }
    return YES;
}

static BOOL CSIsNavBackButton(UIView *v) {
    for (UIView *a = v; a && ![a isKindOfClass:UINavigationBar.class]; a = a.superview) {
        const char *n = object_getClassName(a);
        if (strstr(n, "Back")) return YES;
    }
    return NO;
}

static void CSBack(UIWindow *w);

static void CSSelect(UIWindow *w) {
    UIAlertController *alert = CSTopAlert(w);
    if (alert) {
        UIAlertAction *pick = alert.preferredAction;
        if (!pick) {
            for (UIAlertAction *a in alert.actions) {
                if (a.style == UIAlertActionStyleDefault) { pick = a; break; }
            }
        }
        if (!pick) pick = alert.actions.firstObject;
        if (pick) CSRunAlertAction(alert, pick); else [alert dismissViewControllerAnimated:YES completion:nil];
        CSAutoFocusSoon(w);
        return;
    }
    UIView *v = gCurrent;
    if (!CSFocusIsValid(w)) { CSMove(CSDirDown, w, NO); return; }
    CSLog("select on %s", object_getClassName(v));

    if (CSActivateTabBarItem(v)) { CSAutoFocusSoon(w); return; }

    if ([v isKindOfClass:UITableViewCell.class]) {
        UITableView *tv = (UITableView *)CSAncestorOfClass(v, UITableView.class);
        NSIndexPath *ip = [tv indexPathForCell:(UITableViewCell *)v];
        if (tv && ip) {
            [tv selectRowAtIndexPath:ip animated:YES scrollPosition:UITableViewScrollPositionNone];
            if ([tv.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                [tv.delegate tableView:tv didSelectRowAtIndexPath:ip];
            }
        }
    } else if ([v isKindOfClass:UICollectionViewCell.class]) {
        UICollectionView *cv = (UICollectionView *)CSAncestorOfClass(v, UICollectionView.class);
        NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)v];
        if (cv && ip) {
            [cv selectItemAtIndexPath:ip animated:YES scrollPosition:UICollectionViewScrollPositionNone];
            if ([cv.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                [cv.delegate collectionView:cv didSelectItemAtIndexPath:ip];
            }
        }
    } else if ([v isKindOfClass:UISwitch.class]) {
        UISwitch *s = (UISwitch *)v;
        [s setOn:!s.isOn animated:YES];
        [s sendActionsForControlEvents:UIControlEventValueChanged];
    } else if ([v isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *sc = (UISegmentedControl *)v;
        if (sc.numberOfSegments > 0) {
            sc.selectedSegmentIndex = (sc.selectedSegmentIndex + 1) % sc.numberOfSegments;
            [sc sendActionsForControlEvents:UIControlEventValueChanged];
        }
    } else if ([v isKindOfClass:UITextField.class]) {
        [v becomeFirstResponder];
    } else if (CSAncestorOfClass(v, UINavigationBar.class) && CSIsNavBackButton(v)) {
        CSBack(w);
        return;
    } else if ([v isKindOfClass:UIControl.class]) {
        UIControl *c = (UIControl *)v;
        // Fire what a real tap would: TouchUpInside, plus the primary action if
        // the control registered one (UIAction-based buttons).
        UIControlEvents registered = c.allControlEvents;
        [c sendActionsForControlEvents:UIControlEventTouchUpInside];
        if (registered & UIControlEventPrimaryActionTriggered) {
            [c sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        }
    } else if (!CSActivateTap(v)) {
        [v accessibilityActivate];
    }
    CSAutoFocusSoon(w);
}

static void CSBack(UIWindow *w) {
    UIViewController *top = CSTopVC(w);
    CSLog("back; top=%s", top ? object_getClassName(top) : "nil");
    if ([top isKindOfClass:UIAlertController.class]) {
        UIAlertController *alert = (UIAlertController *)top;
        UIAlertAction *cancel = nil;
        for (UIAlertAction *a in alert.actions) {
            if (a.style == UIAlertActionStyleCancel) { cancel = a; break; }
        }
        if (cancel) CSRunAlertAction(alert, cancel);
        else [alert dismissViewControllerAnimated:YES completion:nil];
    } else if (top.navigationController && top.navigationController.viewControllers.count > 1) {
        [top.navigationController popViewControllerAnimated:YES];
    } else if (top.presentingViewController) {
        [top dismissViewControllerAnimated:YES completion:nil];
    } else {
        return;
    }
    gCurrent = nil;
    CSUpdateHighlight();
    CSAutoFocusSoon(w);
}

#pragma mark - Entry point

/// Returns YES if every press in the event was one this navigator consumed.
BOOL CSNavHandlePresses(UIPressesEvent *event, UIWindow *w) {
    BOOL any = NO, all = YES;
    for (UIPress *p in event.allPresses) {
        NSInteger t = (NSInteger)p.type;
        BOOL mine = (t >= 0 && t <= 5) || t == 7;
        if (!mine) { all = NO; continue; }
        any = YES;
        if (p.phase != UIPressPhaseBegan) continue;

        gWindow = w;
        CSEnsureTimer();
        switch (t) {
            case 0: CSMove(CSDirUp, w, YES); break;
            case 1: CSMove(CSDirDown, w, YES); break;
            case 2: CSMove(CSDirLeft, w, YES); break;
            case 3: CSMove(CSDirRight, w, YES); break;
            case 4: CSSelect(w); break;
            case 5:
            case 7: CSBack(w); break;
            default: break;
        }
    }
    return any && all;
}
