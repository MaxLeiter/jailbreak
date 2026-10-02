#import "server.h"

#import "apps.h"
#import "capture.h"
#import "display.h"
#import "hid.h"
#import "log.h"
#import "token.h"

#include <unistd.h>

// All of this state is touched only from the serial work queue.
static ipc_capturer *gCap;
static ipc_geometry gCapGeom;

static NSString *snake_orientation(long o) {
    switch (o) {
    case 1: return @"portrait";
    case 2: return @"portrait_upside_down";
    case 3: return @"landscape_right";
    case 4: return @"landscape_left";
    default: return @"portrait";
    }
}

static NSDictionary *errd(NSString *code, NSString *msg, NSDictionary *details) {
    NSMutableDictionary *e = [@{@"code" : code, @"message" : msg} mutableCopy];
    if (details) e[@"details"] = details;
    return e;
}

static ipc_capturer *ensure_capturer(const ipc_geometry *g) {
    if (gCap && gCapGeom.orientation == g->orientation && gCapGeom.panel_px_w == g->panel_px_w &&
        gCapGeom.panel_px_h == g->panel_px_h)
        return gCap;
    if (gCap) ipc_capturer_destroy(gCap);
    gCap = ipc_capturer_create(g, true);
    gCapGeom = *g;
    return gCap;
}

// ---- self-test -----------------------------------------------------------

NSDictionary *ipc_selftest(void) {
    ipc_geometry g;
    ipc_geometry_get(&g);
    ipc_foreground f;
    ipc_foreground_get(&f);
    bool screen_known = (f.blanked >= 0);
    bool screen_on = (f.blanked == 0);

    ipc_capturer *c = ensure_capturer(&g);
    if (!c)
        return @{@"capture_ok" : @NO, @"screen_on" : screen_known ? @(screen_on) : (id)[NSNull null],
                 @"detail" : @"capture surfaces could not be allocated"};

    ipc_shot_stats st;
    NSString *err = nil;
    NSData *jpeg = ipc_capture_jpeg(c, 0.4, &st, &err);
    if (!jpeg)
        return @{@"capture_ok" : @NO, @"screen_on" : screen_known ? @(screen_on) : (id)[NSNull null],
                 @"detail" : err ?: @"capture failed"};

    id capture_ok;
    NSString *detail;
    if (!screen_known) {
        capture_ok = st.blank ? (id)[NSNull null] : @YES;
        detail = st.blank ? @"screen state unknown and frame is black; cannot confirm capture"
                          : @"captured a non-black frame";
    } else if (!screen_on) {
        capture_ok = [NSNull null];
        detail = @"screen is off; capture not verified (a black frame is expected)";
    } else {
        capture_ok = st.blank ? @NO : @YES;
        detail = st.blank ? @"frame is all black while the screen is on; capture is likely denied "
                            @"(missing com.apple.QuartzCore.global-capture entitlement)"
                          : @"captured a non-black frame while the screen is on";
    }
    return @{@"capture_ok" : capture_ok, @"screen_on" : screen_known ? @(screen_on) : (id)[NSNull null],
             @"detail" : detail};
}

// ---- helpers --------------------------------------------------------------

static NSString *frontmost_bundle(const ipc_foreground *f) {
    return f->frontmost_ok ? @(f->frontmost) : @"com.apple.springboard";
}

static bool app_matches(NSString *claimed, NSString *frontmost) {
    claimed = [claimed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([claimed caseInsensitiveCompare:frontmost] == NSOrderedSame) return true;
    NSString *name = ipc_app_name(frontmost);
    if (name && [claimed caseInsensitiveCompare:name] == NSOrderedSame) return true;
    if ([frontmost isEqualToString:@"com.apple.springboard"]) {
        if ([claimed caseInsensitiveCompare:@"SpringBoard"] == NSOrderedSame) return true;
        if ([claimed caseInsensitiveCompare:@"Home Screen"] == NSOrderedSame) return true;
    }
    return false;
}

static bool num(id v, double *out) {
    if (![v isKindOfClass:NSNumber.class]) return false;
    *out = [v doubleValue];
    return true;
}

static bool nonempty(id v, NSString **out) {
    if (![v isKindOfClass:NSString.class]) return false;
    NSString *s = v;
    if ([s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) return false;
    if (out) *out = s;
    return true;
}

// ---- action execution -----------------------------------------------------

// Returns an error dict (code/message/details) or nil on success. Logs the
// outcome. All per-action checks live here.
static NSDictionary *run_action(NSDictionary *a) {
    if (![a isKindOfClass:NSDictionary.class]) return errd(@"invalid", @"action must be an object", nil);
    NSString *type = nil;
    if (!nonempty(a[@"type"], &type)) return errd(@"invalid", @"action is missing `type`", nil);

    // `wait` carries no intent and no device checks.
    if ([type isEqualToString:@"wait"]) {
        double ms;
        if (!num(a[@"ms"], &ms) || ms < 0) return errd(@"invalid", @"wait needs a non-negative `ms`", nil);
        if (ms > 10000) ms = 10000;
        ipc_log_action(type, [NSString stringWithFormat:@"ms=%d", (int)ms], nil, nil, nil, @"ok");
        usleep((useconds_t)(ms * 1000));
        return nil;
    }

    NSString *app = nil, *target = nil, *why = nil;
    if (!nonempty(a[@"app"], &app) || !nonempty(a[@"target"], &target) || !nonempty(a[@"why"], &why))
        return errd(@"invalid", [NSString stringWithFormat:@"%@ requires non-empty app, target and why", type], nil);

    ipc_geometry g;
    bool orient_ok = ipc_geometry_get(&g);
    ipc_foreground f;
    ipc_foreground_get(&f);
    NSString *fm = frontmost_bundle(&f);

    // Validate shape + coordinates. `detail` is the log column for this action.
    NSString *detail = @"-";
    bool is_pointer = false;
    double x = 0, y = 0, x2 = 0, y2 = 0;

    NSDictionary *(^logret)(NSString *, NSDictionary *) = ^(NSString *result, NSDictionary *e) {
        ipc_log_action(type, detail, app, target, why, result);
        return e;
    };

    if ([type isEqualToString:@"tap"] || [type isEqualToString:@"double_tap"] ||
        [type isEqualToString:@"long_press"] || [type isEqualToString:@"scroll"]) {
        is_pointer = true;
        if (!num(a[@"x"], &x) || !num(a[@"y"], &y)) return logret(@"invalid", errd(@"invalid", @"needs x,y", nil));
        if (x < 0 || y < 0 || x >= g.view_pt_w || y >= g.view_pt_h)
            return logret(@"invalid", errd(@"invalid", [NSString stringWithFormat:@"(%g,%g) is outside the %gx%g screen", x, y, g.view_pt_w, g.view_pt_h], nil));
        if ([type isEqualToString:@"scroll"]) {
            NSString *dir = a[@"direction"];
            if (![dir isKindOfClass:NSString.class] || !([dir isEqualToString:@"up"] || [dir isEqualToString:@"down"] || [dir isEqualToString:@"left"] || [dir isEqualToString:@"right"]))
                return logret(@"invalid", errd(@"invalid", @"scroll needs direction up|down|left|right", nil));
            detail = [NSString stringWithFormat:@"(%g,%g) %@", x, y, dir];
        } else {
            detail = [NSString stringWithFormat:@"(%g,%g)", x, y];
        }
    } else if ([type isEqualToString:@"swipe"]) {
        is_pointer = true;
        if (!num(a[@"x"], &x) || !num(a[@"y"], &y) || !num(a[@"x2"], &x2) || !num(a[@"y2"], &y2))
            return logret(@"invalid", errd(@"invalid", @"swipe needs x,y,x2,y2", nil));
        if (x < 0 || y < 0 || x2 < 0 || y2 < 0 || x >= g.view_pt_w || y >= g.view_pt_h || x2 >= g.view_pt_w || y2 >= g.view_pt_h)
            return logret(@"invalid", errd(@"invalid", @"swipe endpoint is off screen", nil));
        detail = [NSString stringWithFormat:@"(%g,%g)->(%g,%g)", x, y, x2, y2];
    } else if ([type isEqualToString:@"type"]) {
        NSString *text = nil;
        if (!nonempty(a[@"text"], &text)) return logret(@"invalid", errd(@"invalid", @"type needs text", nil));
        detail = [NSString stringWithFormat:@"chars=%lu", (unsigned long)text.length];
    } else if ([type isEqualToString:@"key"]) {
        NSString *key = nil;
        if (!nonempty(a[@"key"], &key)) return logret(@"invalid", errd(@"invalid", @"key needs key", nil));
        detail = [NSString stringWithFormat:@"key=%@", key];
    } else if ([type isEqualToString:@"button"]) {
        NSString *bn = a[@"name"];
        if (![bn isKindOfClass:NSString.class] || !([bn isEqualToString:@"home"] || [bn isEqualToString:@"volume_up"] || [bn isEqualToString:@"volume_down"]))
            return logret(@"invalid", errd(@"invalid", @"button name must be home, volume_up or volume_down (no lock button)", nil));
        detail = [NSString stringWithFormat:@"button=%@", bn];
    } else if ([type isEqualToString:@"open_app"]) {
        NSString *bid = nil;
        if (!nonempty(a[@"bundle_id"], &bid)) return logret(@"invalid", errd(@"invalid", @"open_app needs bundle_id", nil));
        detail = [NSString stringWithFormat:@"bundle=%@", bid];
    } else if ([type isEqualToString:@"open_url"]) {
        NSString *url = nil;
        if (!nonempty(a[@"url"], &url)) return logret(@"invalid", errd(@"invalid", @"open_url needs url", nil));
        detail = [NSString stringWithFormat:@"url=%@", url];
    } else {
        return logret(@"invalid", errd(@"invalid", [NSString stringWithFormat:@"unknown action type '%@'", type], nil));
    }

    // Device checks (same order as the contract): locked, then app match.
    if (f.lockstate != 0 || f.blanked == 1)
        return logret(@"locked", errd(@"locked", @"device is locked or the screen is off", nil));
    if (is_pointer && !orient_ok)
        return logret(@"internal", errd(@"internal", @"interface orientation unknown; refusing to map the touch", nil));
    if (!app_matches(app, fm))
        return logret(@"app_mismatch", errd(@"app_mismatch", [NSString stringWithFormat:@"expected %@ but frontmost is %@", app, fm], @{@"expected" : app, @"actual" : fm}));
    // No app_blocked policy in phase 1: nothing is blocked yet (TODO: policy tiers, phase 2).
    // `target` is recorded but NOT verified yet (TODO: OCR at (x,y) -> target_mismatch, phase 2).

    // Execute.
    if ([type isEqualToString:@"tap"]) {
        ipc_hid_tap(&g, CGPointMake(x, y));
    } else if ([type isEqualToString:@"double_tap"]) {
        ipc_hid_tap(&g, CGPointMake(x, y));
        usleep(120 * 1000);
        ipc_hid_tap(&g, CGPointMake(x, y));
    } else if ([type isEqualToString:@"long_press"]) {
        double ms = 800;
        num(a[@"duration_ms"], &ms);
        ipc_hid_longpress(&g, CGPointMake(x, y), (int)ms);
    } else if ([type isEqualToString:@"swipe"]) {
        double ms = 300;
        num(a[@"duration_ms"], &ms);
        ipc_hid_swipe(&g, CGPointMake(x, y), CGPointMake(x2, y2), (int)ms);
    } else if ([type isEqualToString:@"scroll"]) {
        double amount = 5;
        num(a[@"amount"], &amount);
        if (amount < 1) amount = 1;
        NSString *dir = a[@"direction"];
        double dist = amount * 120;
        double maxspan = ([dir isEqualToString:@"left"] || [dir isEqualToString:@"right"]) ? g.view_pt_w * 0.8 : g.view_pt_h * 0.8;
        if (dist > maxspan) dist = maxspan;
        double half = dist / 2;
        CGPoint from = CGPointMake(x, y), to = CGPointMake(x, y);
        // direction = where content moves (wheel); finger swipes the opposite way.
        if ([dir isEqualToString:@"down"]) { from.y = y + half; to.y = y - half; }
        else if ([dir isEqualToString:@"up"]) { from.y = y - half; to.y = y + half; }
        else if ([dir isEqualToString:@"right"]) { from.x = x + half; to.x = x - half; }
        else { from.x = x - half; to.x = x + half; }
        int dur = (int)(250 + amount * 40);
        if (dur > 1200) dur = 1200;
        ipc_hid_swipe(&g, from, to, dur);
    } else if ([type isEqualToString:@"type"]) {
        int bad = -1;
        if (!ipc_hid_type([a[@"text"] UTF8String], &bad))
            return logret(@"invalid", errd(@"invalid", @"text has a non-ASCII or unsupported character; only ASCII is typed via HID (pasteboard path not enabled to avoid extra entitlements)", @{@"bad_index" : @(bad)}));
    } else if ([type isEqualToString:@"key"]) {
        if (!ipc_hid_key([a[@"key"] UTF8String]))
            return logret(@"invalid", errd(@"invalid", [NSString stringWithFormat:@"unknown key '%@'", a[@"key"]], nil));
    } else if ([type isEqualToString:@"button"]) {
        NSString *bn = a[@"name"];
        ipc_button b = [bn isEqualToString:@"home"] ? IPC_BUTTON_HOME : [bn isEqualToString:@"volume_up"] ? IPC_BUTTON_VOLUP : IPC_BUTTON_VOLDOWN;
        ipc_hid_button(b);
    } else if ([type isEqualToString:@"open_app"]) {
        NSString *e = nil;
        if (!ipc_app_open(a[@"bundle_id"], &e))
            return logret(@"invalid", errd(@"invalid", e ?: @"could not open app", nil));
    } else if ([type isEqualToString:@"open_url"]) {
        NSString *e = nil;
        if (!ipc_url_open(a[@"url"], &e))
            return logret(@"invalid", errd(@"invalid", e ?: @"could not open url", nil));
    }

    return logret(@"ok", nil);
}

// ---- route handlers -------------------------------------------------------

static IPCHTTPResponse *handle_info(void) {
    ipc_geometry g;
    ipc_geometry_get(&g);
    ipc_foreground f;
    ipc_foreground_get(&f);
    bool locked = (f.lockstate != 0);
    NSString *fm = frontmost_bundle(&f);

    id frontmost = [NSNull null];
    if (!locked) {
        NSString *name = ipc_app_name(fm) ?: ([fm isEqualToString:@"com.apple.springboard"] ? @"SpringBoard" : fm);
        frontmost = @{@"bundle_id" : fm, @"name" : name};
    }

    NSDictionary *info = @{
        @"screen" : @{
            @"width" : @((int)lround(g.view_pt_w)),
            @"height" : @((int)lround(g.view_pt_h)),
            @"scale" : @(g.scale),
            @"orientation" : snake_orientation(g.orientation),
        },
        @"frontmost" : frontmost,
        @"locked" : locked ? @YES : @NO,
        @"asleep" : (f.blanked == 1) ? @YES : @NO,
        @"daemon_version" : @IPC_DAEMON_VERSION,
        @"selftest" : ipc_selftest(),
    };
    return [IPCHTTPResponse json:info status:200];
}

static IPCHTTPResponse *handle_apps(void) {
    return [IPCHTTPResponse json:@{@"apps" : ipc_apps_list()} status:200];
}

static IPCHTTPResponse *handle_screenshot(IPCHTTPRequest *req) {
    NSDictionary *body = @{};
    if (req.body.length) {
        id j = [NSJSONSerialization JSONObjectWithData:req.body options:0 error:nil];
        if ([j isKindOfClass:NSDictionary.class]) body = j;
    }
    double q = 70;
    num(body[@"quality"], &q);
    if (q < 10) q = 10;
    if (q > 95) q = 95;

    ipc_geometry g;
    ipc_geometry_get(&g);
    ipc_foreground f;
    ipc_foreground_get(&f);
    ipc_capturer *c = ensure_capturer(&g);
    if (!c) return [IPCHTTPResponse json:@{@"error" : errd(@"internal", @"capture surfaces unavailable", nil)} status:500];

    ipc_shot_stats st;
    NSString *err = nil;
    NSData *jpeg;
    id region = body[@"region"];
    if (region && region != [NSNull null]) {
        double rx, ry, rw, rh;
        if (![region isKindOfClass:NSDictionary.class] || !num(((NSDictionary *)region)[@"x"], &rx) ||
            !num(((NSDictionary *)region)[@"y"], &ry) || !num(((NSDictionary *)region)[@"w"], &rw) ||
            !num(((NSDictionary *)region)[@"h"], &rh) || rx < 0 || ry < 0 || rw <= 0 || rh <= 0)
            return [IPCHTTPResponse json:@{@"error" : errd(@"invalid", @"region needs x>=0, y>=0, w>0, h>0", nil)} status:400];
        jpeg = ipc_capture_region_jpeg(c, CGRectMake(rx, ry, rw, rh), q / 100.0, &st, &err);
    } else {
        jpeg = ipc_capture_jpeg(c, q / 100.0, &st, &err);
    }
    if (!jpeg) return [IPCHTTPResponse json:@{@"error" : errd(@"internal", err ?: @"capture failed", nil)} status:500];

    NSDictionary *headers = @{
        @"X-Ipad-Width" : @(st.out_w).stringValue,
        @"X-Ipad-Height" : @(st.out_h).stringValue,
        @"X-Ipad-Scale" : @((int)lround(g.scale)).stringValue,
        @"X-Ipad-Orientation" : snake_orientation(g.orientation),
        @"X-Ipad-Frontmost" : frontmost_bundle(&f),
        @"X-Ipad-Locked" : (f.lockstate != 0) ? @"true" : @"false",
    };
    return [IPCHTTPResponse jpeg:jpeg headers:headers];
}

static IPCHTTPResponse *handle_actions(IPCHTTPRequest *req) {
    id body = req.body.length ? [NSJSONSerialization JSONObjectWithData:req.body options:0 error:nil] : nil;
    if (![body isKindOfClass:NSDictionary.class])
        return [IPCHTTPResponse json:@{@"error" : errd(@"invalid", @"body must be a JSON object", nil)} status:400];
    id actions = ((NSDictionary *)body)[@"actions"];
    if (![actions isKindOfClass:NSArray.class] || ((NSArray *)actions).count == 0)
        return [IPCHTTPResponse json:@{@"error" : errd(@"invalid", @"actions must be a non-empty array", nil)} status:400];

    NSMutableArray *results = [NSMutableArray array];
    bool failed = false;
    NSUInteger i = 0;
    for (id a in (NSArray *)actions) {
        if (failed) {
            [results addObject:@{@"index" : @(i), @"status" : @"skipped"}];
        } else {
            NSDictionary *e = run_action(a);
            if (e) {
                failed = true;
                [results addObject:@{@"index" : @(i), @"status" : @"failed", @"error" : e}];
            } else {
                [results addObject:@{@"index" : @(i), @"status" : @"ok"}];
            }
        }
        i++;
    }

    ipc_foreground f;
    ipc_foreground_get(&f);
    NSMutableDictionary *out = [@{@"ok" : failed ? @NO : @YES, @"results" : results, @"frontmost" : frontmost_bundle(&f)} mutableCopy];

    id shot = ((NSDictionary *)body)[@"screenshot"];
    if (shot && shot != [NSNull null]) {
        double q = 70;
        if ([shot isKindOfClass:NSDictionary.class]) num(((NSDictionary *)shot)[@"quality"], &q);
        if (q < 10) q = 10;
        if (q > 95) q = 95;
        usleep(350 * 1000);  // settle before the post-action frame
        ipc_geometry g;
        ipc_geometry_get(&g);
        ipc_foreground f2;
        ipc_foreground_get(&f2);
        ipc_capturer *c = ensure_capturer(&g);
        ipc_shot_stats st;
        NSString *err = nil;
        NSData *jpeg = c ? ipc_capture_jpeg(c, q / 100.0, &st, &err) : nil;
        if (jpeg) {
            out[@"screenshot"] = @{
                @"jpeg_base64" : [jpeg base64EncodedStringWithOptions:0],
                @"width" : @(st.out_w),
                @"height" : @(st.out_h),
                @"scale" : @((int)lround(g.scale)),
                @"orientation" : snake_orientation(g.orientation),
                @"frontmost" : frontmost_bundle(&f2),
                @"locked" : (f2.lockstate != 0) ? @YES : @NO,
            };
        }
    }
    return [IPCHTTPResponse json:out status:200];
}

// ---- dispatch -------------------------------------------------------------

IPCHTTPHandler ipc_server_handler(NSString *token) {
    NSString *tok = [token copy];
    return ^IPCHTTPResponse *(IPCHTTPRequest *req) {
        NSString *auth = [req header:@"authorization"];
        NSString *bearer = [auth hasPrefix:@"Bearer "] ? [auth substringFromIndex:7] : @"";
        if (!ipc_ct_equal(bearer, tok))
            return [IPCHTTPResponse json:@{@"error" : errd(@"unauthorized", @"missing or invalid bearer token", nil)} status:401];

        NSString *p = req.path, *m = req.method;
        if ([p isEqualToString:@"/v1/info"] && [m isEqualToString:@"GET"]) return handle_info();
        if ([p isEqualToString:@"/v1/apps"] && [m isEqualToString:@"GET"]) return handle_apps();
        if ([p isEqualToString:@"/v1/screenshot"] && [m isEqualToString:@"POST"]) return handle_screenshot(req);
        if ([p isEqualToString:@"/v1/actions"] && [m isEqualToString:@"POST"]) return handle_actions(req);
        return [IPCHTTPResponse json:@{@"error" : errd(@"invalid", [NSString stringWithFormat:@"no route %@ %@", m, p], nil)} status:404];
    };
}
