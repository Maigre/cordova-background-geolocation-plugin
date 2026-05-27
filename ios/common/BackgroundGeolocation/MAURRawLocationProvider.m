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
    NSInteger          _forceReacquireCount; // throttle: max 3 auto-reacquires per session
}

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
    if (realAge > 90.0 && slcAge < 30.0 && _forceReacquireCount < 3) {
        _forceReacquireCount++;
        DDLogInfo(@"%@ BG-10: real stalled %.0fs, SLC fresh %.0fs — auto-reacquire #%ld",
                  TAG, realAge, slcAge, (long)_forceReacquireCount);
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

