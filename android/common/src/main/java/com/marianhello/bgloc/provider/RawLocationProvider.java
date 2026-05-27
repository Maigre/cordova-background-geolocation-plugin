package com.marianhello.bgloc.provider;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.location.Criteria;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.Manifest;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import androidx.core.app.ActivityCompat;

import com.google.android.gms.location.ActivityRecognition;
import com.google.android.gms.location.ActivityRecognitionResult;
import com.google.android.gms.location.DetectedActivity;
import com.marianhello.bgloc.Config;
import com.marianhello.bgloc.data.BackgroundActivity;
import com.marianhello.logging.LoggerManager;

/**
 * Created by finch on 7.11.2017.
 */

public class RawLocationProvider extends AbstractLocationProvider implements LocationListener {
    private static final long KEEPALIVE_INTERVAL_MS = 15_000;
    private static final long ACTIVITY_INTERVAL_MS  = 5_000;
    private static final long ALARM_INTERVAL_MS     = 30_000;
    private static final String ACTIVITY_ACTION  = "com.marianhello.bgloc.RAW_ACTIVITY_UPDATE";
    // BG-5: AlarmManager action — wakes the provider even in Doze.
    private static final String ALARM_WAKE_ACTION = "com.marianhello.bgloc.RAW_LOCATION_WAKE";

    // v2.9.0 — Architecture D dedupe state machine.
    // STALE_RAW_MS: if no fresh (non-keepalive) Raw fix in this window, Fused
    //   deliveries are no longer suppressed. 20 s is comfortably above the
    //   BG-5 keepalive cadence (15 s) so the keepalive replay itself is not
    //   relied on as the dedupe primary signal.
    // MAX_FUSED_AGE_MS: ignore Fused fixes whose location.time is older than
    //   this (1 min). FLP can return cached fixes via getLastLocation that are
    //   minutes old; delivering them as "current position" would be wrong.
    private static final long STALE_RAW_MS     = 20_000;
    private static final long MAX_FUSED_AGE_MS = 60_000;

    // P0.5 Fix 1e (v2.8.0) — diagnostic counters readable from JS via the
    // CDV action getAlarmWakeStats. Lets the webapp tell whether the
    // AlarmManager wake-receiver is firing during Doze while JS appears
    // suspended (i.e. the JS-side real_callback_freshness shows no fresh
    // callbacks but these counters keep growing).
    public static volatile long sAlarmFireCount = 0;
    public static volatile long sLastAlarmFireMs = 0;
    public static volatile long sLastCachedDeliveredMs = 0;

    // v2.9.0 — Architecture D dispatch counters.
    public static volatile long sRawDeliveredCount        = 0;
    public static volatile long sRawKeepaliveCount        = 0;
    public static volatile long sFusedDeliveredCount      = 0;
    public static volatile long sFusedSuppressedCount     = 0;
    public static volatile long sFusedStaleIgnoredCount   = 0;
    public static volatile long sLastDeliveredMs          = 0;
    public static volatile String sLastDeliveredSource    = null;
    public static volatile boolean sFusedAvailable        = false;

    private LocationManager locationManager;
    private String provider;
    private boolean isStarted = false;

    private Handler  _keepaliveHandler;
    private Runnable _keepaliveTick;
    private long     _lastRealLocationTime;

    private PendingIntent    _activityPI;
    private ActivityUpdateReceiver _activityReceiver;
    private boolean          _deviceIsStationary = false;

    private PendingIntent       _alarmPI;
    private LocationWakeReceiver _alarmReceiver;

    // v2.9.0 — Architecture D Fused parallel stream. Owned by this provider
    // so the dedupe state machine has direct access to _lastRealLocationTime.
    private FusedLocationProviderHelper _fused;
    private long _lastRawFreshMs = 0;

    /**
     * BG-5: AlarmManager keepalive receiver — fires via setExactAndAllowWhileIdle even in Doze.
     * Re-delivers last known location if real callbacks have been silent for >= KEEPALIVE_INTERVAL_MS.
     * Effective Doze cadence is ~9 min on Android 9+; non-Doze cadence is ALARM_INTERVAL_MS (30 s).
     *
     * v2.8.0: also bumps diagnostic counters (sAlarmFireCount, sLastAlarmFireMs,
     * sLastCachedDeliveredMs) so the webapp can detect a JS-suspended-despite-
     * alarm pattern via the getAlarmWakeStats CDV action.
     */
    private class LocationWakeReceiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (!isStarted) return;
            sAlarmFireCount++;
            sLastAlarmFireMs = System.currentTimeMillis();
            scheduleNextAlarm();
            long elapsed = SystemClock.elapsedRealtime() - _lastRealLocationTime;
            if (elapsed >= KEEPALIVE_INTERVAL_MS) {
                Location cached = locationManager.getLastKnownLocation(provider);
                if (cached != null) {
                    logger.debug("AlarmWake: {}ms gap, device {} — delivering cached position",
                        elapsed, _deviceIsStationary ? "stationary" : "moving");
                    sLastCachedDeliveredMs = System.currentTimeMillis();
                    deliverRawKeepalive(cached);
                }
            }
        }
    }

    private void scheduleNextAlarm() {
        AlarmManager am = (AlarmManager) mContext.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent intent = new Intent(ALARM_WAKE_ACTION);
        intent.setPackage(mContext.getPackageName());
        int piFlags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            ? PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE
            : PendingIntent.FLAG_UPDATE_CURRENT;
        _alarmPI = PendingIntent.getBroadcast(mContext, 9004, intent, piFlags);
        am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + ALARM_INTERVAL_MS, _alarmPI);
    }

    private class ActivityUpdateReceiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (!ActivityRecognitionResult.hasResult(intent)) return;
            ActivityRecognitionResult result = ActivityRecognitionResult.extractResult(intent);
            DetectedActivity activity = mostConfident(result.getProbableActivities());
            _deviceIsStationary = (activity.getType() == DetectedActivity.STILL);
            logger.debug("Motion: {} confidence={} stationary={}",
                BackgroundActivity.getActivityString(activity.getType()),
                activity.getConfidence(), _deviceIsStationary);
            handleActivity(activity);
        }
    }

    private DetectedActivity mostConfident(java.util.List<DetectedActivity> list) {
        DetectedActivity best = new DetectedActivity(DetectedActivity.UNKNOWN, 0);
        for (DetectedActivity a : list) {
            if (a.getConfidence() > best.getConfidence()) best = a;
        }
        return best;
    }

    private boolean activityRecognitionPermitted() {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ActivityCompat.checkSelfPermission(mContext, Manifest.permission.ACTIVITY_RECOGNITION)
                == PackageManager.PERMISSION_GRANTED;
    }

    public RawLocationProvider(Context context) {
        super(context);
        PROVIDER_ID = Config.RAW_PROVIDER;
    }

    @Override
    public void onCreate() {
        super.onCreate();

        locationManager = (LocationManager) mContext.getSystemService(Context.LOCATION_SERVICE);
    }

    @Override
    public void onStart() {
        if (isStarted) {
            return;
        }
        provider = LocationManager.GPS_PROVIDER;
        if (!locationManager.getAllProviders().contains(LocationManager.GPS_PROVIDER) ||
                Build.VERSION.SDK_INT <= 30) {
            Criteria criteria = new Criteria();
            criteria.setAltitudeRequired(false);
            criteria.setBearingRequired(false);
            criteria.setSpeedRequired(true);
            criteria.setCostAllowed(true);
            criteria.setAccuracy(Criteria.ACCURACY_FINE);
            criteria.setHorizontalAccuracy(translateDesiredAccuracy(mConfig.getDesiredAccuracy()));
            criteria.setPowerRequirement(Criteria.POWER_HIGH);
            provider = locationManager.getBestProvider(criteria, true);
        }
        try {
            logger.info("Requesting location updates from provider {}", provider);
            locationManager.requestLocationUpdates(provider, mConfig.getInterval(), mConfig.getDistanceFilter(), this);
            isStarted = true;
            _lastRealLocationTime = SystemClock.elapsedRealtime();
            _keepaliveHandler = new Handler(Looper.getMainLooper());
            _keepaliveTick = new Runnable() {
                @Override public void run() {
                    if (!isStarted) return;
                    long elapsed = SystemClock.elapsedRealtime() - _lastRealLocationTime;
                    if (elapsed >= KEEPALIVE_INTERVAL_MS) {
                        Location cached = locationManager.getLastKnownLocation(provider);
                        if (cached != null) {
                            logger.debug("Keepalive: {}ms gap, device {} — delivering cached position",
                                elapsed, _deviceIsStationary ? "stationary" : "moving");
                            deliverRawKeepalive(cached);
                        }
                    }
                    _keepaliveHandler.postDelayed(this, KEEPALIVE_INTERVAL_MS);
                }
            };
            _keepaliveHandler.postDelayed(_keepaliveTick, KEEPALIVE_INTERVAL_MS);

            // BG-5: Register AlarmManager keepalive receiver and fire first alarm.
            _alarmReceiver = new LocationWakeReceiver();
            mContext.registerReceiver(_alarmReceiver, new IntentFilter(ALARM_WAKE_ACTION));
            scheduleNextAlarm();

            // v2.9.0 Architecture D — start the Fused parallel stream. Fail-soft
            // if GMS is unavailable (handled inside the helper). The helper calls
            // back via the Listener interface into onFusedLocation below.
            _fused = new FusedLocationProviderHelper(mContext, new FusedLocationProviderHelper.Listener() {
                @Override public void onFusedLocation(Location location) {
                    RawLocationProvider.this.onFusedLocation(location);
                }
            });
            _fused.start();
            sFusedAvailable = _fused.isAvailable() && _fused.isStarted();

            if (activityRecognitionPermitted()) {
                _activityReceiver = new ActivityUpdateReceiver();
                mContext.registerReceiver(_activityReceiver, new IntentFilter(ACTIVITY_ACTION));
                Intent activityIntent = new Intent(ACTIVITY_ACTION);
                activityIntent.setPackage(mContext.getPackageName());
                int piFlags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                    ? PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE
                    : PendingIntent.FLAG_UPDATE_CURRENT;
                _activityPI = PendingIntent.getBroadcast(mContext, 9003, activityIntent, piFlags);
                ActivityRecognition.getClient(mContext)
                    .requestActivityUpdates(ACTIVITY_INTERVAL_MS, _activityPI);
            }
        } catch (SecurityException e) {
            logger.error("Security exception: {}", e.getMessage());
            this.handleSecurityException(e);
        }
    }

    @Override
    public void onStop() {
        if (!isStarted) {
            return;
        }
        if (_keepaliveHandler != null) {
            _keepaliveHandler.removeCallbacks(_keepaliveTick);
            _keepaliveHandler = null;
        }
        if (_alarmPI != null) {
            AlarmManager am = (AlarmManager) mContext.getSystemService(Context.ALARM_SERVICE);
            if (am != null) am.cancel(_alarmPI);
            _alarmPI = null;
        }
        if (_alarmReceiver != null) {
            try { mContext.unregisterReceiver(_alarmReceiver); } catch (Exception ignored) {}
            _alarmReceiver = null;
        }
        if (_activityPI != null) {
            ActivityRecognition.getClient(mContext).removeActivityUpdates(_activityPI);
            _activityPI = null;
        }
        if (_activityReceiver != null) {
            try { mContext.unregisterReceiver(_activityReceiver); } catch (Exception ignored) {}
            _activityReceiver = null;
        }
        // v2.9.0 Architecture D — tear down Fused parallel stream.
        if (_fused != null) {
            try { _fused.stop(); } catch (Throwable ignored) {}
            _fused = null;
            sFusedAvailable = false;
        }
        try {
            locationManager.removeUpdates(this);
        } catch (SecurityException e) {
            logger.error("Security exception: {}", e.getMessage());
            this.handleSecurityException(e);
        } finally {
            isStarted = false;
        }
    }

    @Override
    public void onConfigure(Config config) {
        super.onConfigure(config);
        if (isStarted) {
            onStop();
            onStart();
        }
    }

    @Override
    public boolean isStarted() {
        return isStarted;
    }

    @Override
    public void onLocationChanged(Location location) {
        _lastRealLocationTime = SystemClock.elapsedRealtime();
        logger.debug("Location change: {}", location.toString());

        showDebugToast("acy:" + location.getAccuracy() + ",v:" + location.getSpeed());
        deliverRaw(location);
    }

    // ───────── v2.9.0 Architecture D dispatch helpers ─────────

    /**
     * Real Raw fix (LocationManager onLocationChanged). Updates the dedupe
     * fresh-marker and delivers tagged as "raw".
     */
    private void deliverRaw(Location location) {
        _lastRawFreshMs = System.currentTimeMillis();
        sRawDeliveredCount++;
        sLastDeliveredMs = _lastRawFreshMs;
        sLastDeliveredSource = "raw";
        handleLocation(location, "raw", false);
    }

    /**
     * Cached Raw replay from the BG-5 AlarmManager receiver or the 15 s
     * Handler keepalive tick. Tagged "raw-keepalive" with isKeepalive=true.
     * Does NOT update _lastRawFreshMs — keepalive replay must not prevent
     * Fused fallback when real GPS is silent.
     */
    private void deliverRawKeepalive(Location location) {
        sRawKeepaliveCount++;
        sLastDeliveredMs = System.currentTimeMillis();
        sLastDeliveredSource = "raw-keepalive";
        handleLocation(location, "raw-keepalive", true);
    }

    /**
     * Fused fix from FusedLocationProviderClient. Dedupe policy:
     *   1. Drop if location.time is older than MAX_FUSED_AGE_MS (FLP can
     *      return cached fixes via getLastLocation that are minutes old).
     *   2. Suppress if Raw is still fresh (within STALE_RAW_MS) — Raw is the
     *      authoritative source for accuracy / cadence.
     *   3. Otherwise deliver tagged "fused".
     */
    private void onFusedLocation(Location location) {
        long now = System.currentTimeMillis();
        long fusedAge = now - location.getTime();
        if (fusedAge > MAX_FUSED_AGE_MS) {
            sFusedStaleIgnoredCount++;
            return;
        }
        long rawAge = now - _lastRawFreshMs;
        if (_lastRawFreshMs > 0 && rawAge < STALE_RAW_MS) {
            sFusedSuppressedCount++;
            return;
        }
        sFusedDeliveredCount++;
        sLastDeliveredMs = now;
        sLastDeliveredSource = "fused";
        logger.debug("Fused: delivering (rawAge={}ms, fusedAge={}ms)", rawAge, fusedAge);
        handleLocation(location, "fused", false);
    }

    @Override
    public void onStatusChanged(String provider, int status, Bundle bundle) {
        logger.debug("Provider {} status changed: {}", provider, status);
    }

    @Override
    public void onProviderEnabled(String provider) {
        logger.debug("Provider {} was enabled", provider);
    }

    @Override
    public void onProviderDisabled(String provider) {
        logger.debug("Provider {} was disabled", provider);
    }

    /**
     * Translates a number representing desired accuracy of Geolocation system from set [0, 10, 100, 1000].
     * 0:  most aggressive, most accurate, worst battery drain
     * 1000:  least aggressive, least accurate, best for battery.
     */
    private Integer translateDesiredAccuracy(Integer accuracy) {
        if (accuracy >= 1000) {
            return Criteria.ACCURACY_LOW;
        }
        if (accuracy >= 100) {
            return Criteria.ACCURACY_MEDIUM;
        }
        if (accuracy >= 10) {
            return Criteria.ACCURACY_HIGH;
        }
        if (accuracy >= 0) {
            return Criteria.ACCURACY_HIGH;
        }

        return Criteria.ACCURACY_MEDIUM;
    }

    @Override
    public void onDestroy() {
        logger.debug("Destroying RawLocationProvider");
        this.onStop();
        super.onDestroy();
    }
}
