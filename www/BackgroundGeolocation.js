/*
 According to apache license

 This is fork of christocracy cordova-plugin-background-geolocation plugin
 https://github.com/christocracy/cordova-plugin-background-geolocation

 Differences to original version:

 1. new method isLocationEnabled
 */

var exec = require('cordova/exec');
var channel = require('cordova/channel');
var radio = require('./radio');
var TAG = 'CDVBackgroundGeolocation';

// Flanerie keeps the upstream JS API stable and carries its walk-specific
// behavior mainly in native providers and platform wiring.

var assert = function (condition, msgArray) {
  if (!condition) {
      throw new Error(msgArray.join('') || 'Assertion failed');
  }
}

var eventHandler = function (event) {
  radio(event.name).broadcast(event.payload);
};

var errorHandler = function (error) {
  radio('error').broadcast(error);
};

var unsubscribeAll = function (channels) {
  channels.forEach(function(channel) {
    var topic = radio(channel);
    var callbacks = [].concat.apply([], topic.channels[channel]); // flatten array
    topic.unsubscribe.apply(topic, callbacks);
  });
}

var execWithPromise = function (suceess, failure, method, data) {
  if (!suceess && !failure) {
    return new Promise(function (resolve, reject) {
      exec(resolve, reject, 'BackgroundGeolocation', method, data);    
    });
  }
  exec(suceess || function() {}, failure || function() {}, 'BackgroundGeolocation', method, data || []);
}

var BackgroundGeolocation = {
  events: [
    'location',
    'stationary',
    'activity',
    'start',
    'stop',
    'error',
    'authorization',
    'foreground',
    'background',
    'abort_requested',
    'http_authorization',
    // BG-11 (v2.10.0, iOS): rail of CLCircularRegion wake-ups fired the
    // listener — payload {region_id, event, last_real_callback_age_ms,
    // did_force_reacquire, force_reacquire_count, app_state, bg_task_id}.
    'region_wake',
    // BG-11 (iOS): CLLocationManager rejected a rail region after it was
    // submitted to startMonitoringForRegion: (e.g. 20-region system cap
    // exceeded, or entitlements revoked mid-walk). Payload {region_id,
    // error_code, error_domain, error}. Telemetry-only.
    'region_monitor_fail',
    // BG-12 (v2.11.0, iOS): CLVisit fired — payload {latitude, longitude,
    // horizontal_accuracy_m, arrival_date, departure_date, arrival_age_ms,
    // departure_known}. Observation-only telemetry of iOS "user stopped"
    // inference; never triggers step audio.
    'visit'
  ],

  DISTANCE_FILTER_PROVIDER: 0,
  ACTIVITY_PROVIDER: 1,
  RAW_PROVIDER: 2,

  BACKGROUND_MODE: 0,
  FOREGROUND_MODE: 1,

  NOT_AUTHORIZED: 0,
  AUTHORIZED: 1,
  AUTHORIZED_FOREGROUND: 2,

  HIGH_ACCURACY: 0,
  MEDIUM_ACCURACY: 100,
  LOW_ACCURACY: 1000,
  PASSIVE_ACCURACY: 10000,

  LOG_ERROR: 'ERROR',
  LOG_WARN: 'WARN',
  LOG_INFO: 'INFO',
  LOG_DEBUG: 'DEBUG',
  LOG_TRACE: 'TRACE',

  PERMISSION_DENIED: 1,
  LOCATION_UNAVAILABLE: 2,
  TIMEOUT: 3,

  configure: function (config, success, failure) {
    return execWithPromise(success,
      failure,
      'configure',
      [config]
    );
  },

  start: function () {
    return execWithPromise(null, null, 'start');
  },

  stop: function () {
    return execWithPromise(null, null, 'stop');
  },

  switchMode: function (mode, success, failure) {
    return execWithPromise(success,
      failure,
      'switchMode', [mode]);
  },

  getConfig: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getConfig');
  },

  /**
   * Returns current stationaryLocation if available.  null if not
   */
  getStationaryLocation: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getStationaryLocation');
  },

  showAppSettings: function () {
    return execWithPromise(null,
      null,
      'showAppSettings');
  },

  showLocationSettings: function () {
    return execWithPromise(null,
      null,
      'showLocationSettings');
  },

  getLocations: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getLocations');
  },

  getValidLocations: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getValidLocations');
  },

  getValidLocationsAndDelete: function (success, failure) {
    return execWithPromise(success, 
      failure,
      'getValidLocationsAndDelete');
  },

  deleteLocation: function (locationId, success, failure) {
    return execWithPromise(success,
      failure,
      'deleteLocation', [locationId]);
  },

  deleteAllLocations: function (success, failure) {
    return execWithPromise(success,
      failure,
      'deleteAllLocations');
  },

  getCurrentLocation: function(success, failure, options) {
    options = options || {};
    return execWithPromise(success,
      failure,
      'getCurrentLocation', [options.timeout, options.maximumAge, options.enableHighAccuracy]);
  },

  getLogEntries: function(limit, offset = 0, minLevel = "DEBUG", success, failure) {
    return execWithPromise(success,
      failure,
      'getLogEntries', [limit, offset, minLevel]);
  },

  checkStatus: function (success, failure) {
    return execWithPromise(success,
      failure,
      'checkStatus')
  },

  startTask: function (success, failure) {
    return execWithPromise(success,
      failure,
      'startTask');
  },

  endTask: function (taskKey, success, failure) {
    return execWithPromise(success,
      failure,
      'endTask', [taskKey]);
  },

  headlessTask: function (func, success, failure) {
    return execWithPromise(success,
      failure,
      'registerHeadlessTask', [func.toString()]);
  },

  forceSync: function (success, failure) {
    return execWithPromise(success,
      failure,
      'forceSync');
  },

  // BG-3: F-G1 diagnostic — CLLocationManager state snapshot (iOS only).
  getCLState: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getCLState');
  },

  // BG-4: Power state snapshot — lowPowerMode, batteryLevel, batteryState (iOS only).
  getPowerState: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getPowerState');
  },

  // BG-2: D3 — force CLLocationManager stop/restart when real callbacks stall (iOS only).
  // Throttle to max 3 calls/session from JS; native auto-trigger (BG-10) also observes this limit.
  forceReacquire: function (success, failure) {
    return execWithPromise(success,
      failure,
      'forceReacquire');
  },

  // P0.5 Fix 1e (v2.8.0) — Android-only diagnostic. Returns the BG-5
  // AlarmManager wake-receiver counters: {count, lastFireMs, lastFireAgeMs,
  // lastCachedDeliveredMs, lastCachedDeliveredAgeMs}. iOS returns 0s.
  // Poll periodically and compare against real_callback_freshness to detect
  // "alarm fired but JS got no fresh callback" (WebView Doze suspension).
  getAlarmWakeStats: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getAlarmWakeStats');
  },

  // v2.9.0 Architecture D (Android) — returns the Raw/Fused dedupe dispatch
  // counters: {fusedAvailable, rawDelivered, rawKeepalive, fusedDelivered,
  // fusedSuppressed, fusedStaleIgnored, lastDeliveredMs, lastDeliveredAgeMs,
  // lastDeliveredSource}. lastDeliveredSource ∈ {"raw", "raw-keepalive",
  // "fused"} echoes the dispatchSource field on the most recent location
  // delivered to JS. iOS returns nothing meaningful.
  getLocationDispatchStats: function (success, failure) {
    return execWithPromise(success,
      failure,
      'getLocationDispatchStats');
  },

  // BG-11 (v2.10.0, iOS): register a rail of CLCircularRegion wake-up
  // triggers. `regions` is an array of {id, lat, lon, radius} objects. The
  // rail's only purpose is to wake the app (and restart standard
  // CLLocationManager updates if they have stalled >30 s) — it never
  // triggers step audio. JS-side polygon zone-check stays in charge of
  // fine-grained step firing. Subscribe to the 'region_wake' event for
  // telemetry. Android returns errback (action not implemented); callers
  // should gate this on PLATFORM === 'ios'.
  configureRail: function (regions, success, failure) {
    return execWithPromise(success,
      failure,
      'configureRail', [regions || []]);
  },

  // BG-11 (v2.10.0, iOS): stop monitoring every rail region. Called from
  // the parcours-cleanup path. Android returns errback (action not
  // implemented); callers should gate on PLATFORM === 'ios'.
  clearRail: function (success, failure) {
    return execWithPromise(success,
      failure,
      'clearRail');
  },

  on: function (event, callbackFn) {
    assert(this.events.indexOf(event) > -1, [TAG, '#on unknown event "' + event + '"']);
    if (!callbackFn) {
      return radio(event);
    }
    radio(event).subscribe(callbackFn);
    return {
      remove: function () {
        radio(event).unsubscribe(callbackFn);
      }
    };
  },

  removeAllListeners: function (event) {
    if (!event) {
      unsubscribeAll(this.events);
      return void 0;
    }
    if (this.events.indexOf(event) < 0) {
      console.log('[WARN] ' + TAG + '#removeAllListeners for unknown event "' + event + '"');
      return void 0;
    }
    unsubscribeAll([event]);
  }
};

channel.deviceready.subscribe(function () {
  // register app global listeners
  exec(eventHandler,
    errorHandler,
    'BackgroundGeolocation',
    'addEventListener'
  );
});


module.exports = BackgroundGeolocation;
