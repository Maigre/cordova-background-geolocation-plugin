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
// Returns NO if rail monitoring is unavailable on this device.
- (BOOL) configureRail:(NSArray<NSDictionary*>*)regions;

// BG-11: stop monitoring every rail region. Called from the parcours-cleanup
// JS path. Safe to call multiple times.
- (void) clearRail;

@end

#endif /* MAURRawLocationProvider_h */
