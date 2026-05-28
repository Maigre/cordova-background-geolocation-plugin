//
//  MAURProviderDelegate.h
//  BackgroundGeolocation
//
//  Created by Marian Hello on 14/09/2016.
//  Copyright © 2016 mauron85. All rights reserved.
//

#ifndef MAURProviderDelegate_h
#define MAURProviderDelegate_h

#import "MAURLocation.h"
#import "MAURActivity.h"
//#import "MAURLocationController.h"

typedef NS_ENUM(NSInteger, MAURBGErrorCode) {
    MAURBGPermissionDenied = 1000,
    MAURBGSettingsError    = 1001,
    MAURBGConfigureError   = 1002,
    MAURBGServiceError     = 1003,
    MAURBGJsonError        = 1004,
    MAURBGNotImplemented   = 9999
};

typedef NS_ENUM(NSInteger, MAURLocationAuthorizationStatus) {
    MAURLocationAuthorizationDenied = 0,
    MAURLocationAuthorizationAllowed = 1,
    MAURLocationAuthorizationAlways = MAURLocationAuthorizationAllowed,
    MAURLocationAuthorizationForeground = 2,
    MAURLocationAuthorizationNotDetermined = 99,
};

typedef NS_ENUM(NSInteger, MAUROperationalMode) {
    MAURBackgroundMode = 0,
    MAURForegroundMode = 1
};

@protocol MAURProviderDelegate <NSObject>

- (void) onAuthorizationChanged:(MAURLocationAuthorizationStatus)authStatus;
- (void) onLocationChanged:(MAURLocation*)location;
- (void) onStationaryChanged:(MAURLocation*)location;
- (void) onLocationPause;
- (void) onLocationResume;
- (void) onActivityChanged:(MAURActivity*)activity;
- (void) onAbortRequested;
- (void) onHttpAuthorization;
- (void) onError:(NSError*)error;

@optional
// BG-11 (v2.10.0): GPS rail wake-up. Fired when a CLCircularRegion in the
// transition-midpoint rail is entered/exited. Payload carries region_id,
// event ("enter"/"exit"), last_real_callback_age_ms, did_force_reacquire,
// app_state. Telemetry-only on the JS side — fine-grained step triggering
// remains owned by the polygon-based zone check.
- (void) onRegionWake:(NSDictionary*)payload;

// BG-11 (v2.10.0+): iOS CLLocationManager rejected a rail region after it
// was submitted to startMonitoringForRegion: — e.g. exceeded the 20-region
// system cap, or revoked entitlements mid-walk. Payload carries region_id,
// error_code, error_domain, error. Telemetry-only on the JS side.
- (void) onRegionMonitorFail:(NSDictionary*)payload;

// BG-12 (v2.11.0): iOS CLVisit fired. Payload carries latitude, longitude,
// horizontal_accuracy_m, arrival_date, departure_date (ISO 8601, may be
// null while still at the visited place), arrival_age_ms, departure_known.
// Telemetry-only — observation of "user stopped" inference; never triggers
// step audio.
- (void) onVisit:(NSDictionary*)payload;

@end

#endif /* MAURProviderDelegate_h */
