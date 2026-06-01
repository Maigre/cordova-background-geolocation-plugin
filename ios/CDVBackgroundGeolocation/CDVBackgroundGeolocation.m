//
//  CDVBackgroundGeolocation.h
//
//  Created by Marian Hello on 04/06/16.
//  Version 2.0.0
//
//  According to apache license
//
//  This is class is using code from christocracy cordova-plugin-background-geolocation plugin
//  https://github.com/christocracy/cordova-plugin-background-geolocation

#import "CDVBackgroundGeolocation.h"
#import <WebKit/WebKit.h>
#import <CoreMotion/CoreMotion.h>
#import "MAURConfig.h"
#import "MAURBackgroundGeolocationFacade.h"
#import "MAURBackgroundTaskManager.h"
#import "MAURLocationManager.h"

static NSString * const TAG = @"CDVBackgroundGeolocation";

@implementation CDVBackgroundGeolocation {
    NSString *callbackId;
    MAURConfig *config;
    MAURBackgroundGeolocationFacade* facade;
    BOOL pendingMotionUpdates;

    API_AVAILABLE(ios(10.0))
    __weak id<UNUserNotificationCenterDelegate> prevNotificationDelegate;
}

- (void)pluginInitialize
{
    if (@available(iOS 17.4, *)) {
        WKWebView *wv = (WKWebView *)self.webViewEngine.engineWebView;
        if ([wv respondsToSelector:NSSelectorFromString(@"setAllowsBackgroundTimeExtension:")]) {
            [wv setValue:@YES forKey:@"allowsBackgroundTimeExtension"];
        }
    }

    facade = [[MAURBackgroundGeolocationFacade alloc] init];
    facade.delegate = self;

    // Warm the CLLocationManager singleton here, on the main thread. pluginInitialize
    // runs on the main thread before any JS command, so this guarantees the manager
    // (and thus its delegate run loop) is created on main — even though the first
    // JS-driven access is usually a worker-thread checkStatus probe. Without this,
    // that probe would build the manager off-main and strand its location callbacks.
    [MAURLocationManager sharedInstance];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppPause:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppResume:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppBecameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onFinishLaunching:) name:UIApplicationDidFinishLaunchingNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppTerminate:) name:UIApplicationWillTerminateNotification object:nil];

    // BG-4: enable battery monitoring once so getPowerState can read batteryLevel/batteryState.
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
}

- (void)requestMotionUpdatesWhenAppActive:(NSString *)reason
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if (app.applicationState != UIApplicationStateActive) {
            self->pendingMotionUpdates = YES;
            NSLog(@"%@ queued motion prompt until active (%@)", TAG, reason);
            return;
        }

        self->pendingMotionUpdates = NO;
        NSLog(@"%@ flushing motion prompt (%@)", TAG, reason);
        [self->facade startMotionUpdates];
    });
}

/*
 * configure plugin
 * @param stationaryRadius
 * @param distanceFilter
 * @param locationTimeout
 */
- (void) configure:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"configure");
    [self.commandDelegate runInBackground:^{
        self->config = [MAURConfig fromDictionary:[command.arguments objectAtIndex:0]];

        NSError *error = nil;
        CDVPluginResult* result = nil;
        if ([self->facade configure:self->config error:&error]) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * Turn on background geolocation
 * in case of failure it calls error callback from configure method
 * may fire two callback when location services are disabled and when authorization failed
 */
- (void) start:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"start");
    [self.commandDelegate runInBackground:^{
        __block NSError *error = nil;

        // CLLocationManager must be called from the main thread (requestAlwaysAuthorization,
        // startUpdatingLocation). dispatch_sync is safe here since we are already on a
        // background thread (runInBackground dispatches to a global queue).
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->facade start:&error];
        });

        // Report the actual start outcome. (Previously this re-ran configure: and
        // returned THAT result, so a start failure could be masked behind a config
        // success. facade start already applies the full config via onConfigure, so
        // the extra configure: call was redundant as well as misleading.)
        CDVPluginResult* result = nil;
        if (error == nil) {
            [self sendEvent:@"start"];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            [self sendError:error];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * Turn it off
 */
- (void) stop:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"stop");
    [self.commandDelegate runInBackground:^{
        NSError *error = nil;

        [self->facade stop:&error];

        // Report the actual stop outcome (previously returned a redundant configure: result).
        CDVPluginResult* result = nil;
        if (error == nil) {
            [self sendEvent:@"stop"];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            [self sendError:error];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * Change
 * @param {Number} operation mode BACKGROUND/FOREGROUND
 */
- (void) switchMode:(CDVInvokedUrlCommand *)command
{
    NSLog(@"%@ #%@", TAG, @"switchMode");
    [self.commandDelegate runInBackground:^{
        MAUROperationalMode mode = [[command.arguments objectAtIndex: 0] intValue];
        [facade switchMode:mode];
    }];
}

- (void) getConfig:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getConfig");
    [self.commandDelegate runInBackground:^{
        MAURConfig *config = [facade getConfig];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[config toDictionary]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) checkStatus:(CDVInvokedUrlCommand *)command
{
    NSLog(@"%@ #%@", TAG, @"checkStatus");
    [self.commandDelegate runInBackground:^{
        BOOL isRunning = [facade isStarted];
        BOOL locationServicesEnabled = [facade locationServicesEnabled];
        NSInteger authorizationStatus = [facade authorizationStatus];

        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:3];
        [dict setObject:[NSNumber numberWithBool:isRunning] forKey:@"isRunning"];
        [dict setObject:[NSNumber numberWithBool:locationServicesEnabled] forKey:@"hasPermissions"]; // @deprecated
        [dict setObject:[NSNumber numberWithBool:locationServicesEnabled] forKey:@"locationServicesEnabled"];
        [dict setObject:[NSNumber numberWithInteger:authorizationStatus] forKey:@"authorization"];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dict];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * Fetches current stationaryLocation
 */
- (void) getStationaryLocation:(CDVInvokedUrlCommand *)command
{
    NSLog(@"%@ #%@", TAG, @"getStationaryLocation");
    [self.commandDelegate runInBackground:^{
        CDVPluginResult* result = nil;

        MAURLocation* stationaryLocation = [facade getStationaryLocation];
        if (stationaryLocation) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[stationaryLocation toDictionary]];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:NO];
        }

        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) isLocationEnabled:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"isLocationEnabled");
    [self.commandDelegate runInBackground:^{
        BOOL isLocationEnabled = [facade locationServicesEnabled];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:isLocationEnabled];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) showAppSettings:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"showAppSettings");
    [self.commandDelegate runInBackground:^{
        [facade showAppSettings];
    }];
}

- (void) showLocationSettings:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"showLocationSettings");
    [self.commandDelegate runInBackground:^{
        [facade showLocationSettings];
    }];
}

- (void) getLocations:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getLocations");
    [self.commandDelegate runInBackground:^{
        NSArray *locations = [facade getLocations];
        NSMutableArray* dictionaryLocations = [[NSMutableArray alloc] initWithCapacity:[locations count]];
        for (MAURLocation* location in locations) {
            [dictionaryLocations addObject:[location toDictionaryWithId]];
        }
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:dictionaryLocations];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) getValidLocations:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getValidLocations");
    [self.commandDelegate runInBackground:^{
        NSArray *locations = [facade getValidLocations];
        NSMutableArray* dictionaryLocations = [[NSMutableArray alloc] initWithCapacity:[locations count]];
        for (MAURLocation* location in locations) {
            [dictionaryLocations addObject:[location toDictionaryWithId]];
        }
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:dictionaryLocations];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) getValidLocationsAndDelete:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getValidLocationsAndDelete");
    [self.commandDelegate runInBackground:^{
        NSArray *locations = [facade getValidLocationsAndDelete];
        NSMutableArray* dictionaryLocations = [[NSMutableArray alloc] initWithCapacity:[locations count]];
        for (MAURLocation* location in locations) {
            [dictionaryLocations addObject:[location toDictionaryWithId]];
        }
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:dictionaryLocations];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) deleteLocation:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"deleteLocation");
    [self.commandDelegate runInBackground:^{
        NSError *error = nil;
        int locationId = [[command.arguments objectAtIndex: 0] intValue];
        BOOL success = [facade deleteLocation:[[NSNumber alloc] initWithInt:locationId] error:&error];
        CDVPluginResult* result;
        if (success) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) deleteAllLocations:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"deleteAllLocations");
    [self.commandDelegate runInBackground:^{
        NSError *error = nil;
        BOOL success = [facade deleteAllLocations:&error];
        CDVPluginResult* result;
        if (success) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) getCurrentLocation:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getCurrentLocation");
    [self.commandDelegate runInBackground:^{
        NSError *error = nil;
        NSArray *args = command.arguments;
        int timeout = [args objectAtIndex: 0] == [NSNull null] ? INT_MAX : [[args objectAtIndex: 0] intValue];
        long maximumAge = [args objectAtIndex: 1] == [NSNull null] ? LONG_MAX : [[args objectAtIndex: 1] longValue];
        BOOL enableHighAccuracy = [args objectAtIndex: 2] == [NSNull null] ? NO : [[args objectAtIndex: 2] boolValue];

        MAURLocation *location = [facade getCurrentLocation:timeout maximumAge:maximumAge enableHighAccuracy:enableHighAccuracy error:&error];
        CDVPluginResult* result;
        if (location != nil) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[location toDictionary]];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
        }
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) getLogEntries:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getLogEntries");
    [self.commandDelegate runInBackground:^{
        NSArray *args = command.arguments;
        NSInteger limit = [args objectAtIndex: 0] == [NSNull null]
            ? 0 : [[args objectAtIndex: 0] integerValue];
        NSInteger entryId = [args objectAtIndex: 1] == [NSNull null]
            ? 0 : [[args objectAtIndex: 1] integerValue];
        NSString *minLogLevel = [args objectAtIndex: 2] == [NSNull null]
            ? @"DEBUG" : [args objectAtIndex: 2];

        NSArray *logs = [facade getLogEntries:limit fromLogEntryId:entryId minLogLevelFromString:minLogLevel];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:logs];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) startTask:(CDVInvokedUrlCommand*)command
{
    NSUInteger taskKey = [[MAURBackgroundTaskManager sharedTasks] beginTask];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsNSUInteger:taskKey];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void) endTask:(CDVInvokedUrlCommand*)command
{
    int taskKey = [[command.arguments objectAtIndex: 0] intValue];
    [[MAURBackgroundTaskManager sharedTasks] endTaskWithKey:taskKey];
}

- (void) forceSync:(CDVInvokedUrlCommand*)command
{
    [facade forceSync];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/**
 * BG-2: D3 — force CLLocationManager stop/restart to recover from iOS 26.3.x callback stall.
 * Throttling (max 3/session) is enforced in MAURRawLocationProvider._keepaliveTick auto-trigger.
 * When called directly from JS the caller is responsible for rate-limiting.
 */
- (void) forceReacquire:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"forceReacquire");
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *clm = [MAURLocationManager sharedInstance].locationManager;
        [clm stopUpdatingLocation];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            clm.allowsBackgroundLocationUpdates = YES;
            clm.pausesLocationUpdatesAutomatically = NO;
            clm.showsBackgroundLocationIndicator = YES;
            [clm startUpdatingLocation];
            NSLog(@"%@ forceReacquire: CLLocationManager restarted", TAG);
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        });
    });
}

/**
 * BG-3: F-G1 diagnostic — CLLocationManager state snapshot.
 * Returns hasLocation, locationTimestampAgeMs, allowsBackgroundLocationUpdates,
 * pausesLocationUpdatesAutomatically, showsBackgroundLocationIndicator,
 * authorizationStatus, locationServicesEnabled.
 *
 * v2.8.0: schema clarified — age now reported in ms (NSTimeInterval is seconds
 * natively, multiplied by 1000); has_location surfaced as a separate bool so
 * a missing CL location is unambiguous (previously the age field was -1).
 * locationTimestampAge (seconds, raw NSTimeInterval) is kept for backwards
 * compatibility with any v2.5.0..v2.7.0 telemetry consumers.
 */
- (void) getCLState:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getCLState");
    [self.commandDelegate runInBackground:^{
        __block NSDictionary *state = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            CLLocationManager *clm = [MAURLocationManager sharedInstance].locationManager;
            CLAuthorizationStatus authStatus = [CLLocationManager authorizationStatus];
            BOOL hasLocation = (clm.location != nil);
            NSTimeInterval locationAge = -1;
            double locationAgeMs = -1;
            if (hasLocation) {
                locationAge = [[NSDate date] timeIntervalSinceDate:clm.location.timestamp];
                locationAgeMs = locationAge * 1000.0;
            }
            state = @{
                @"hasLocation":                        @(hasLocation),
                @"locationTimestampAgeMs":             @(locationAgeMs),
                @"locationTimestampAge":               @(locationAge),
                @"allowsBackgroundLocationUpdates":    @(clm.allowsBackgroundLocationUpdates),
                @"pausesLocationUpdatesAutomatically": @(clm.pausesLocationUpdatesAutomatically),
                @"showsBackgroundLocationIndicator":   @(clm.showsBackgroundLocationIndicator),
                @"authorizationStatus":                @(authStatus),
                @"locationServicesEnabled":            @([CLLocationManager locationServicesEnabled]),
            };
        });
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:state];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * BG-4: Power state snapshot — low-power mode, battery level and state.
 */
- (void) getPowerState:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getPowerState");
    UIDevice *device = [UIDevice currentDevice];
    NSDictionary *state = @{
        @"lowPowerMode": @([[NSProcessInfo processInfo] isLowPowerModeEnabled]),
        @"batteryLevel": @(device.batteryLevel),
        @"batteryState": @((NSInteger)device.batteryState),
    };
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:state];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/**
 * BG-13: iOS native stream-health snapshot.
 * Returns Raw provider counters so JS telemetry can distinguish real CLLocation
 * deliveries from keepalive/SLC/rail wake activity and audit the shared
 * CLLocationManager creation thread.
 */
- (void) getIOSStreamHealth:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"getIOSStreamHealth");
    [self.commandDelegate runInBackground:^{
        NSDictionary *state = [self->facade iosStreamHealth];
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:state ?: @{}];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * BG-11 (v2.10.0): configure the GPS rail of wake-up CLCircularRegions.
 * Accepts an array of {id, lat, lon, radius} dictionaries. Replaces any
 * previously-registered set. Called from JS at parcours entry once the
 * rail is computed from step centroid midpoints.
 */
- (void) configureRail:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"configureRail");
    NSArray *regions = (command.arguments.count > 0 && [command.arguments[0] isKindOfClass:[NSArray class]])
        ? command.arguments[0] : @[];
    [self.commandDelegate runInBackground:^{
        NSInteger count = [self->facade configureRail:regions];
        CDVPluginResult *result = (count >= 0)
            ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(int)count]
            : [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                messageAsString:@"region monitoring unavailable"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * BG-11: stop monitoring all rail regions. Called from JS at parcours
 * cleanup (page exit, walk end, rearm).
 */
- (void) clearRail:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"clearRail");
    [self.commandDelegate runInBackground:^{
        [self->facade clearRail];
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

/**
 * Start CMMotionActivityManager updates (and the iOS Motion & Fitness prompt).
 * Called from the JS checkmotion screen so the prompt no longer collides with the
 * Location prompt at start(). Idempotent at the provider layer.
 */
- (void) startMotionUpdates:(CDVInvokedUrlCommand*)command
{
    NSLog(@"%@ #%@", TAG, @"startMotionUpdates");
    [self.commandDelegate runInBackground:^{
        [self requestMotionUpdatesWhenAppActive:@"js_command"];

        // Diagnostic: report what the native side actually sees back to JS so the
        // checkmotion telemetry carries the ground truth. l5bi (iOS 26.4.2, apk 21)
        // showed 41 JS retries, all visible=true, yet the prompt never appeared and
        // motion never granted — with no way to tell an implicit Denied from a
        // NotDetermined whose prompt opportunity was consumed during the post-Settings
        // settling window. authStatus: 0=NotDetermined 1=Restricted 2=Denied 3=Authorized.
        NSInteger authStatus = -1;
        if ([CMMotionActivityManager respondsToSelector:@selector(authorizationStatus)]) {
            authStatus = (NSInteger)[CMMotionActivityManager authorizationStatus];
        }
        BOOL available = [CMMotionActivityManager isActivityAvailable];
        __block NSInteger appState = -1;
        dispatch_sync(dispatch_get_main_queue(), ^{
            appState = (NSInteger)[UIApplication sharedApplication].applicationState; // 0=Active 1=Inactive 2=Background
        });

        NSDictionary *info = @{
            @"authStatus": @(authStatus),
            @"appState": @(appState),
            @"activityAvailable": @(available),
            @"pendingUntilActive": @(self->pendingMotionUpdates),
        };
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:info];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void) addEventListener:(CDVInvokedUrlCommand*)command
{
    callbackId = command.callbackId;
}

- (void) removeEventListener:(CDVInvokedUrlCommand*)command
{
    callbackId = nil;
}

-(void) sendEvent:(NSString*)name
{
    if (callbackId == nil) {
        return;
    }

    NSDictionary *message = [[NSDictionary alloc] initWithObjectsAndKeys:[NSString stringWithFormat:@"%@", name], @"name", nil];
    CDVPluginResult* cordovaResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [cordovaResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:cordovaResult callbackId:callbackId];
}

-(void) sendEvent:(NSString*)name resultAsNumber:(NSNumber*)result
{
    if (callbackId == nil) {
        return;
    }

    NSDictionary *message = [[NSDictionary alloc] initWithObjectsAndKeys:
                           [NSString stringWithFormat:@"%@", name], @"name",
                           result, @"payload",
                           nil];
    CDVPluginResult* cordovaResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [cordovaResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:cordovaResult callbackId:callbackId];
}

-(void) sendEvent:(NSString*)name result:(id)result
{
    if (callbackId == nil) {
        return;
    }

    NSDictionary *message = [[NSDictionary alloc] initWithObjectsAndKeys:
                           [NSString stringWithFormat:@"%@", name], @"name",
                           result, @"payload",
                           nil];
    CDVPluginResult* cordovaResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [cordovaResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:cordovaResult callbackId:callbackId];
}

- (void) sendError:(NSError*)error
{
    NSLog(@"%@ #%@", TAG, @"onError");
    if (callbackId == nil) {
        return;
    }

    CDVPluginResult* cordovaResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self errorToDictionary:error]];
    [cordovaResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:cordovaResult callbackId:callbackId];
}

- (NSDictionary*) errorToDictionary:(NSError*)error
{
    NSDictionary *userInfo = [error userInfo];
    NSString *errorMessage = [error localizedDescription];
    if (errorMessage == nil) {
        errorMessage = [[userInfo objectForKey:NSUnderlyingErrorKey] localizedDescription];
    }
    return @{ @"code": [NSNumber numberWithLong:error.code], @"message": errorMessage};
}

- (void) onAuthorizationChanged:(MAURLocationAuthorizationStatus)authStatus
{
    NSLog(@"%@ #%@", TAG, @"onAuthorizationChanged");
    [self sendEvent:@"authorization" resultAsNumber:[NSNumber numberWithInt:authStatus]];
}

- (void) onLocationChanged:(MAURLocation*)location
{
    NSLog(@"%@ #%@", TAG, @"onLocationChanged");
    [self sendEvent:@"location" result:[location toDictionaryWithId]];
}

- (void) onStationaryChanged:(MAURLocation*)location
{
    NSLog(@"%@ #%@", TAG, @"onStationaryChanged");
    [self sendEvent:@"stationary" result:[location toDictionaryWithId]];
}

- (void) onLocationPause
{
    NSLog(@"%@ %@", TAG, @"location updates paused");
    [self sendEvent:@"stop"];
}

- (void) onLocationResume
{
    NSLog(@"%@ %@", TAG, @"location updates resumed");
    [self sendEvent:@"start"];
}

- (void) onActivityChanged:(MAURActivity *)activity
{
    NSLog(@"%@ #%@", TAG, @"onActivityChanged");
    [self sendEvent:@"activity" result:[activity toDictionary]];
}

// BG-11 (v2.10.0): rail of wake-up regions fired. Forwarded to JS through
// the existing addEventListener channel as a `region_wake` event so the
// webapp can log it to telemetry without any new bridge plumbing.
- (void) onRegionWake:(NSDictionary*)payload
{
    NSLog(@"%@ #%@ %@", TAG, @"onRegionWake", payload[@"event"]);
    [self sendEvent:@"region_wake" result:payload];
}

// BG-12 (v2.11.0): iOS CLVisit fired. Forwarded to JS as `visit` event for
// observation-only telemetry — never triggers step audio.
- (void) onVisit:(NSDictionary*)payload
{
    NSLog(@"%@ #%@ acc=%@m", TAG, @"onVisit", payload[@"horizontal_accuracy_m"]);
    [self sendEvent:@"visit" result:payload];
}

// BG-11: CLLocationManager rejected a rail region post-registration.
// Forwarded to JS as `region_monitor_fail` so the webapp can log it to
// telemetry — makes gps_rail_configured.region_count auditable against the
// count of regions the OS actually rejected after the fact.
- (void) onRegionMonitorFail:(NSDictionary*)payload
{
    NSLog(@"%@ #%@ %@", TAG, @"onRegionMonitorFail", payload[@"region_id"]);
    [self sendEvent:@"region_monitor_fail" result:payload];
}

- (void) onError:(NSError*)error
{
    NSLog(@"%@ #%@", TAG, @"onError");
    [self sendError:error];
}

-(void) onAppResume:(NSNotification *)notification
{
    NSLog(@"%@ %@", TAG, @"resumed");
    [facade switchMode:MAURForegroundMode];
}

-(void) onAppBecameActive:(NSNotification *)notification
{
    if (!pendingMotionUpdates) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self requestMotionUpdatesWhenAppActive:@"did_become_active"];
    });
}

-(void) onAppPause:(NSNotification *)notification
{
    NSLog(@"%@ %@", TAG, @"paused");
    [facade switchMode:MAURBackgroundMode];
}

-(void) onAbortRequested
{
    NSLog(@"%@ %@", TAG, @"abort requested by the server");
    [self sendEvent:@"abort_requested"];
}

- (void) onHttpAuthorization {
    NSLog(@"%@ %@", TAG, @"http authorization requested by the server");
    [self sendEvent:@"http_authorization"];
}

/**@
 * on UIApplicationDidFinishLaunchingNotification
 */
-(void) onFinishLaunching:(NSNotification *)notification
{
    NSDictionary *dict = [notification userInfo];
    MAURConfig *config = [facade getConfig];

    if (config.isDebugging)
    {
        if (@available(iOS 10, *))
        {
            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            prevNotificationDelegate = center.delegate;
            center.delegate = self;
        }
    }

    if ([dict objectForKey:UIApplicationLaunchOptionsLocationKey]) {
        NSLog(@"%@ %@", TAG, @"started by system on location event.");
        if (![config stopOnTerminate]) {
            [facade start:nil];
            [facade switchMode:MAURBackgroundMode];
        }
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    if (prevNotificationDelegate && [prevNotificationDelegate respondsToSelector:@selector(userNotificationCenter:willPresentNotification:withCompletionHandler:)])
    {
        // Give other delegates (like FCM) the chance to process this notification

        [prevNotificationDelegate userNotificationCenter:center willPresentNotification:notification withCompletionHandler:^(UNNotificationPresentationOptions options) {
            completionHandler(UNNotificationPresentationOptionAlert);
        }];
    }
    else
    {
        completionHandler(UNNotificationPresentationOptionAlert);
    }
}

-(void) onAppTerminate:(NSNotification *)notification
{
    NSLog(@"%@ %@", TAG, @"appTerminate");
    [facade onAppTerminate];
}

@end
