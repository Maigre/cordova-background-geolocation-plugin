//
//  MAURRawLocationProvider.m
//  BackgroundGeolocation
//
//  Created by Marian Hello on 06/11/2017.
//  Copyright © 2017 mauron85. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import "MAURRawLocationProvider.h"
#import "MAURLocationManager.h"
#import "MAURActivity.h"
#import "MAURLogging.h"

static NSString * const TAG = @"RawLocationProvider";
static NSString * const Domain = @"com.marianhello";

@implementation MAURRawLocationProvider {

    BOOL isStarted;
    MAURLocationManager *locationManager;

    MAURConfig *_config;
    NSTimer *_keepaliveTimer;
    NSDate  *_lastRealLocationTime;
    CMMotionActivityManager *_motionActivityManager;
    BOOL _deviceIsStationary;
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
            [_keepaliveTimer invalidate];
            _keepaliveTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                               target:self
                                                             selector:@selector(_keepaliveTick:)
                                                             userInfo:nil
                                                              repeats:YES];
            [self startMotionActivityUpdates];
        }
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
    [self.delegate onLocationChanged:bgloc];
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

