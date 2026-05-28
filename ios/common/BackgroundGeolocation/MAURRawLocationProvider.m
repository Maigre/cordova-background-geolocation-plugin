//
//  MAURRawLocationProvider.m
//  BackgroundGeolocation
//
//  Created by Marian Hello on 06/11/2017.
//  Copyright © 2017 mauron85. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import "MAURRawLocationProvider.h"
#import "MAURLocationManager.h"
#import "MAURActivity.h"
#import "MAURLogging.h"

static NSString * const TAG = @"RawLocationProvider";
static NSString * const Domain = @"com.marianhello";

// BG-10: CLLocationManagerDelegate conformance for the dedicated SLC monitor instance.
@interface MAURRawLocationProvider () <CLLocationManagerDelegate>
@end

@implementation MAURRawLocationProvider {

    BOOL isStarted;
    MAURLocationManager *locationManager;

    MAURConfig *_config;
    NSTimer *_keepaliveTimer;
    NSDate  *_lastRealLocationTime;
    CMMotionActivityManager *_motionActivityManager;
    BOOL _deviceIsStationary;

    // BG-10: separate CLLocationManager for SLC — tracks delivery independently from standard updates.
    CLLocationManager *_slcManager;
    NSDate            *_lastSLCLocationTime;
    NSInteger          _forceReacquireCount; // throttle: max FORCE_REACQUIRE_CAP auto-reacquires per session
    NSDate            *_lastForceReacquireTime; // for the 30 s stall gate

    // BG-11 (v2.10.0): rail of CLCircularRegion wake-up triggers. Separate
    // CLLocationManager from `locationManager` and `_slcManager` so region
    // delegate callbacks land here with a known sender identity.
    CLLocationManager           *_railManager;
    NSMutableArray<CLCircularRegion*> *_railRegions;
}

// BG-11: max auto-triggered CLLocationManager restarts per parcours session.
// Raised from 3 → 10 to accommodate a rail of 16 transition midpoints — a
// hostile iOS 26.3.x walk could legitimately trip several per kilometre.
// The 30 s stall gate (_lastRealLocationTime age > 30 s before any new
// reacquire fires) prevents thrashing on transient signal loss.
static NSInteger const FORCE_REACQUIRE_CAP        = 10;
static NSTimeInterval const FORCE_REACQUIRE_GATE_S = 30.0;

- (instancetype) init
{
    self = [super init];

    if (self) {
        isStarted = NO;
    }

    return self;
}

- (void) onCreate {
    locationManager = [MAURLocationManager sharedInstance];
    locationManager.delegate = self;
}

- (BOOL) onConfigure:(MAURConfig*)config error:(NSError * __autoreleasing *)outError
{
    DDLogVerbose(@"%@ configure", TAG);
    _config = config;

    locationManager.pausesLocationUpdatesAutomatically = [config pauseLocationUpdates];
    locationManager.activityType = [config decodeActivityType];
    locationManager.distanceFilter = config.distanceFilter.integerValue; // meters
    locationManager.desiredAccuracy = [config decodeDesiredAccuracy];

    return YES;
}

- (BOOL) onStart:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ will start", TAG);

    if (!isStarted) {
        isStarted = [locationManager start:outError];
        if (isStarted) {
            [locationManager setShowsBackgroundLocationIndicator:YES];
            _lastRealLocationTime = [NSDate date];
            _forceReacquireCount = 0;
            [_keepaliveTimer invalidate];
            _keepaliveTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                               target:self
                                                             selector:@selector(_keepaliveTick:)
                                                             userInfo:nil
                                                              repeats:YES];
        }
    }

    // BG-10: start SLC as a parallel monitor to detect when standard callbacks stall.
    if (isStarted && _slcManager == nil) {
        _slcManager = [[CLLocationManager alloc] init];
        _slcManager.delegate = self;
        if (@available(iOS 9.0, *)) {
            _slcManager.allowsBackgroundLocationUpdates = YES;
        }
        [_slcManager startMonitoringSignificantLocationChanges];
        DDLogDebug(@"%@ SLC monitor started", TAG);
    }

    // Always (re-)start motion updates when the manager is not yet running.
    // On first install the motion dialog can appear while the location dialog
    // is still visible, causing the user to miss it. Re-triggering on every
    // start() call ensures the dialog (re-)appears when the user reaches the
    // checkmotion screen after granting location permission.
    if (isStarted && _motionActivityManager == nil) {
        [self startMotionActivityUpdates];
    }

    return isStarted;
}

- (BOOL) onStop:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ will stop", TAG);

    if (!isStarted) {
        return YES;
    }

    [_keepaliveTimer invalidate];
    _keepaliveTimer = nil;

    // BG-10: stop the SLC parallel monitor.
    if (_slcManager) {
        [_slcManager stopMonitoringSignificantLocationChanges];
        _slcManager.delegate = nil;
        _slcManager = nil;
        _lastSLCLocationTime = nil;
    }

    // BG-11: tear down the rail of wake-up regions on full provider stop.
    // (The JS layer also calls clearRail explicitly at parcours cleanup, but
    // a hard onStop must not leave orphan region monitors behind either.)
    [self clearRail];
    if (_railManager) {
        _railManager.delegate = nil;
        _railManager = nil;
    }

    [_motionActivityManager stopActivityUpdates];
    _motionActivityManager = nil;

    [locationManager stopMonitoringSignificantLocationChanges];
    if ([locationManager stop:outError]) {
        isStarted = NO;
        return YES;
    }

    return NO;
}

- (void) onTerminate
{
    if (isStarted && !_config.stopOnTerminate) {
        [locationManager startMonitoringSignificantLocationChanges];
    }
}

- (void) onAuthorizationChanged:(MAURLocationAuthorizationStatus)authStatus
{
    [self.delegate onAuthorizationChanged:authStatus];
}

- (void) onLocationsChanged:(NSArray*)locations
{
    _lastRealLocationTime = [NSDate date];
    for (CLLocation *location in locations) {
        MAURLocation *bgloc = [MAURLocation fromCLLocation:location];
        [self.delegate onLocationChanged:bgloc];
    }
}

- (void) _keepaliveTick:(NSTimer *)timer
{
    if (!isStarted) return;
    if (-[_lastRealLocationTime timeIntervalSinceNow] < 15.0) return;

    CLLocation *cached = [MAURLocationManager sharedInstance].locationManager.location;
    if (cached == nil) return;

    DDLogDebug(@"%@ keepalive: %.0fs gap, device %@",
               TAG, -[_lastRealLocationTime timeIntervalSinceNow],
               _deviceIsStationary ? @"stationary (expected)" : @"moving (GPS signal loss)");
    MAURLocation *bgloc = [MAURLocation fromCLLocation:cached];
    // F-G4: tag this as a keepalive tick (NSTimer source, not a real CLLocationManager callback).
    bgloc.isKeepalive = YES;
    // F-G3: start a short background task and include its ID so post-hoc telemetry
    //        can correlate keepalive firings with task-expiry events.
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"flanerie.keepalive"
                                                          expirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    bgloc.bgTaskId = (bgTask != UIBackgroundTaskInvalid) ? @(bgTask) : nil;
    [self.delegate onLocationChanged:bgloc];
    // End the background task shortly after dispatching — we only need it to cover the callback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        }
    });

    // BG-7: D4 defensive re-assertion — iOS can silently flip these flags under memory pressure.
    CLLocationManager *clm = locationManager.locationManager;
    if (clm) {
        clm.allowsBackgroundLocationUpdates = YES;
        clm.pausesLocationUpdatesAutomatically = NO;
    }

    // BG-10: D5 — if real callbacks stalled >90 s but SLC is fresh (<30 s), auto-reacquire.
    NSTimeInterval realAge = -[_lastRealLocationTime timeIntervalSinceNow];
    NSTimeInterval slcAge  = _lastSLCLocationTime
        ? -[_lastSLCLocationTime timeIntervalSinceNow] : 9999.0;
    if (realAge > 90.0 && slcAge < 30.0 && _forceReacquireCount < FORCE_REACQUIRE_CAP) {
        _forceReacquireCount++;
        _lastForceReacquireTime = [NSDate date];
        DDLogInfo(@"%@ BG-10: real stalled %.0fs, SLC fresh %.0fs — auto-reacquire #%ld/%ld",
                  TAG, realAge, slcAge, (long)_forceReacquireCount, (long)FORCE_REACQUIRE_CAP);
        [self _doForceReacquire];
    }
}

/**
 * BG-10: private CLLocationManager restart used by auto-reacquire trigger.
 * Also called indirectly via the forceReacquire Cordova action (BG-2),
 * which duplicates this logic at the CDVBackgroundGeolocation layer.
 */
- (void) _doForceReacquire
{
    CLLocationManager *clm = locationManager.locationManager;
    if (!clm) return;
    [clm stopUpdatingLocation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (!isStarted) return;
        clm.allowsBackgroundLocationUpdates = YES;
        clm.pausesLocationUpdatesAutomatically = NO;
        clm.showsBackgroundLocationIndicator = YES;
        [clm startUpdatingLocation];
        DDLogInfo(@"%@ _doForceReacquire: CLLocationManager restarted", TAG);
    });
}

/**
 * BG-10: CLLocationManagerDelegate for _slcManager. Tracks SLC delivery independently
 * from standard startUpdatingLocation callbacks — allows detecting when standard
 * callbacks stall while SLC still delivers (P1.34 iOS background-GPS blackout).
 */
- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations
{
    if (manager == _slcManager && locations.lastObject) {
        _lastSLCLocationTime = [NSDate date];
        DDLogDebug(@"%@ SLC delivered (age %.0fs)",
                   TAG, -[locations.lastObject.timestamp timeIntervalSinceNow]);
    }
}

#pragma mark - BG-11 rail of wake-up regions

/**
 * BG-11: configure the GPS rail. Replaces any previously-registered set with
 * the new one. Called from CDVBackgroundGeolocation.configureRail (which
 * forwards from JS at parcours entry).
 */
- (BOOL) configureRail:(NSArray<NSDictionary*>*)regions
{
    if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]]) {
        DDLogWarn(@"%@ BG-11: region monitoring not available on this device", TAG);
        return NO;
    }

    dispatch_block_t work = ^{
        // Lazy-init the rail-dedicated CLLocationManager. Separate from the
        // standard-updates and SLC managers so its delegate callbacks land
        // here with a known sender identity.
        if (self->_railManager == nil) {
            self->_railManager = [[CLLocationManager alloc] init];
            self->_railManager.delegate = self;
            if (@available(iOS 9.0, *)) {
                self->_railManager.allowsBackgroundLocationUpdates = YES;
            }
            self->_railManager.pausesLocationUpdatesAutomatically = NO;
        }

        // Wipe previously-monitored rail regions before re-registering.
        for (CLCircularRegion *r in self->_railRegions) {
            [self->_railManager stopMonitoringForRegion:r];
        }
        self->_railRegions = [NSMutableArray arrayWithCapacity:regions.count];

        for (NSDictionary *spec in regions) {
            NSString *rid     = spec[@"id"];
            NSNumber *lat     = spec[@"lat"];
            NSNumber *lon     = spec[@"lon"];
            NSNumber *radius  = spec[@"radius"];
            if (![rid isKindOfClass:[NSString class]] || rid.length == 0) continue;
            if (![lat isKindOfClass:[NSNumber class]] || ![lon isKindOfClass:[NSNumber class]]) continue;
            if (![radius isKindOfClass:[NSNumber class]] || [radius doubleValue] <= 0) continue;

            CLLocationCoordinate2D center = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
            CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:center
                                                                         radius:[radius doubleValue]
                                                                     identifier:rid];
            region.notifyOnEntry = YES;
            region.notifyOnExit  = YES;

            [self->_railManager startMonitoringForRegion:region];
            [self->_railRegions addObject:region];
        }
        DDLogInfo(@"%@ BG-11: rail configured with %lu regions", TAG, (unsigned long)self->_railRegions.count);
    };
    if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    return YES;
}

- (void) clearRail
{
    dispatch_block_t work = ^{
        if (self->_railManager == nil) return;
        for (CLCircularRegion *r in self->_railRegions) {
            [self->_railManager stopMonitoringForRegion:r];
        }
        [self->_railRegions removeAllObjects];
        DDLogInfo(@"%@ BG-11: rail cleared", TAG);
    };
    if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

/**
 * BG-11: CLLocationManagerDelegate for _railManager. Region entry/exit is the
 * pure wake-up signal. We never trigger audio from here — JS-side polygon
 * zone-check still owns step firing. What we do:
 *   1. If real CLLocationManager callbacks have stalled >30 s and we are
 *      under the FORCE_REACQUIRE_CAP, restart standard updates (D3 path).
 *   2. Emit `region_wake` to the JS delegate channel for telemetry.
 *   3. Open a short background task so the WebView can resume and the next
 *      real callback can reach JS before iOS suspends us again.
 */
- (void)locationManager:(CLLocationManager *)manager
         didEnterRegion:(CLRegion *)region
{
    if (manager != _railManager) return;
    [self _handleRailEvent:@"enter" region:region];
}

- (void)locationManager:(CLLocationManager *)manager
          didExitRegion:(CLRegion *)region
{
    if (manager != _railManager) return;
    [self _handleRailEvent:@"exit" region:region];
}

- (void)locationManager:(CLLocationManager *)manager
monitoringDidFailForRegion:(nullable CLRegion *)region
              withError:(NSError *)error
{
    if (manager != _railManager) return;
    DDLogWarn(@"%@ BG-11: rail region %@ monitoring failed: %@",
              TAG, region.identifier, error.localizedDescription);
}

- (void) _handleRailEvent:(NSString*)event region:(CLRegion*)region
{
    NSTimeInterval realAge = _lastRealLocationTime
        ? -[_lastRealLocationTime timeIntervalSinceNow] : 9999.0;
    NSTimeInterval reacqAge = _lastForceReacquireTime
        ? -[_lastForceReacquireTime timeIntervalSinceNow] : 9999.0;

    BOOL didReacquire = NO;
    if (realAge > FORCE_REACQUIRE_GATE_S
        && _forceReacquireCount < FORCE_REACQUIRE_CAP
        && reacqAge > FORCE_REACQUIRE_GATE_S) {
        _forceReacquireCount++;
        _lastForceReacquireTime = [NSDate date];
        DDLogInfo(@"%@ BG-11: rail %@ for %@ — real stalled %.0fs, reacquire #%ld/%ld",
                  TAG, event, region.identifier, realAge,
                  (long)_forceReacquireCount, (long)FORCE_REACQUIRE_CAP);
        [self _doForceReacquire];
        didReacquire = YES;
    } else {
        DDLogDebug(@"%@ BG-11: rail %@ for %@ — realAge %.0fs (gate %.0fs), reacqCount %ld",
                   TAG, event, region.identifier, realAge, FORCE_REACQUIRE_GATE_S, (long)_forceReacquireCount);
    }

    // Hold a short background task so the WebView has time to resume and
    // process the JS-side region_wake event before iOS re-suspends us.
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"flanerie.railwake"
                                                          expirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    NSString *appStateStr = (appState == UIApplicationStateActive)     ? @"foreground"
                          : (appState == UIApplicationStateBackground) ? @"background"
                                                                       : @"inactive";

    NSDictionary *payload = @{
        @"region_id":                 region.identifier ?: @"",
        @"event":                     event,
        @"last_real_callback_age_ms": @((long long)(realAge * 1000.0)),
        @"did_force_reacquire":       @(didReacquire),
        @"force_reacquire_count":     @(_forceReacquireCount),
        @"app_state":                 appStateStr,
        @"bg_task_id":                (bgTask != UIBackgroundTaskInvalid) ? @(bgTask) : [NSNull null],
    };

    if (self.delegate && [self.delegate respondsToSelector:@selector(onRegionWake:)]) {
        [self.delegate onRegionWake:payload];
    }

    // End the wake-keepalive task after a short delay — long enough for the
    // JS event to land and the next real CLLocationManager callback to fire.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        }
    });
}

/**
 * F-G1: CLLocationManagerDelegate for _slcManager — fires when iOS changes the
 * location authorization status during an active walk.  The main CLLocationManager's
 * auth changes are handled upstream by MAURLocationManager; this catches any change
 * reported to _slcManager (same process, same permission — fires in parallel).
 * We forward to the delegation chain and also log the raw CLAuthorizationStatus
 * so post-hoc telemetry analysis gets the full iOS value (not just the simplified enum).
 */
- (void)locationManager:(CLLocationManager *)manager
    didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (manager != _slcManager) return; // main manager handled by MAURLocationManager
    DDLogInfo(@"%@ F-G1: SLC manager auth changed: %d", TAG, (int)status);
    MAURLocationAuthorizationStatus mappedStatus;
    switch (status) {
        case kCLAuthorizationStatusRestricted:
        case kCLAuthorizationStatusDenied:
            mappedStatus = MAURLocationAuthorizationDenied;
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
            mappedStatus = MAURLocationAuthorizationAllowed;
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            mappedStatus = MAURLocationAuthorizationForeground;
            break;
        default:
            mappedStatus = MAURLocationAuthorizationNotDetermined;
            break;
    }
    [self.delegate onAuthorizationChanged:mappedStatus];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager
    API_AVAILABLE(ios(14.0))
{
    if (manager == _slcManager) {
        [self locationManager:manager didChangeAuthorizationStatus:manager.authorizationStatus];
    }
}

- (void) onError:(NSError*)error
{
    [self.delegate onError:error];
}

- (void) onPause:(CLLocationManager*)manager
{
    [self.delegate onLocationPause];
}

- (void) onResume:(CLLocationManager*)manager
{
    [self.delegate onLocationResume];
}

- (void) onDestroy {
    DDLogInfo(@"Destroying %@ ", TAG);
    [self onStop:nil];
}

- (void) startMotionActivityUpdates
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (![CMMotionActivityManager isActivityAvailable]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!isStarted || _motionActivityManager != nil) {
                return;
            }

            _motionActivityManager = [[CMMotionActivityManager alloc] init];
            [_motionActivityManager startActivityUpdatesToQueue:[NSOperationQueue mainQueue]
                                                   withHandler:^(CMMotionActivity *activity) {
                _deviceIsStationary = activity.stationary;
                MAURActivity *act = [[MAURActivity alloc] init];
                act.type = activity.stationary ? @"STILL" : activity.walking ? @"WALKING" : @"UNKNOWN";
                act.confidence = @(activity.confidence);
                [self.delegate onActivityChanged:act];
            }];
        });
    });
}

- (void) dealloc
{
    //    locationController.delegate = nil;
}

@end

