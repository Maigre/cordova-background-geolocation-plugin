//
//  MAURRawLocationProvider.h
//  BackgroundGeolocation
//
//  Created by Marian Hello on 06/11/2017.
//  Copyright © 2017 mauron85. All rights reserved.
//

#ifndef MAURRawLocationProvider_h
#define MAURRawLocationProvider_h

#import "MAURAbstractLocationProvider.h"

@interface MAURRawLocationProvider : MAURAbstractLocationProvider<MAURLocationProvider>

// BG-11 (v2.10.0): configure the GPS wake-up rail of CLCircularRegions.
// `regions` is an array of dictionaries: {@"id": NSString, @"lat": NSNumber,
// @"lon": NSNumber, @"radius": NSNumber (metres)}. Any previously-registered
// rail regions are stopped before the new set is registered. Idempotent.
// Synchronous on the main thread — returns the count of regions that
// actually passed validation and were submitted to
// startMonitoringForRegion:, or -1 if rail monitoring is unavailable on
// this device. Individual region-monitor failures (registered but later
// rejected by the OS) are surfaced asynchronously via
// MAURProviderDelegate#onRegionMonitorFail:.
- (NSInteger) configureRail:(NSArray<NSDictionary*>*)regions;

// BG-11: stop monitoring every rail region. Called from the parcours-cleanup
// JS path. Safe to call multiple times.
- (void) clearRail;

@end

#endif /* MAURRawLocationProvider_h */
