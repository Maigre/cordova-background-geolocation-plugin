package com.marianhello.bgloc.provider;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.location.Criteria;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.Manifest;
import android.app.Notification;
import android.app.NotificationManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.View;
import android.webkit.ValueCallback;
import android.webkit.WebView;
import java.lang.ref.WeakReference;

import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;

import com.google.android.gms.location.ActivityRecognition;
import com.google.android.gms.location.ActivityRecognitionResult;
import com.google.android.gms.location.DetectedActivity;
import com.marianhello.bgloc.Config;
import com.marianhello.bgloc.data.BackgroundActivity;
import com.marianhello.bgloc.sync.NotificationHelper;
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

    // ───────── v2.15.0 — D1 JS-liveness watchdog ─────────
    // The whole walk (zone-trigger math + audio selection + telemetry flush)
    // runs in the WebView's JS event loop. On Android, a locked-pocket walk can
    // get that loop frozen by Chromium (field 2026-06-09: 40+ min frozen on
    // every Android in the bag while this native service kept delivering fixes
    // underneath — keepalive levers may not hold on every OEM). When that
    // happens nothing on the device notices: the local-notification chain is
    // disabled AND re-arms via a JS timer, so it dies with the loop too. This
    // watchdog rides the BG-5 AlarmManager (proven alive during the freeze) as
    // a dead-man's-switch: JS calls ackAlive() on every processed real fix; if
    // no ack for JS_STALL_MS during an active walk, we nudge the renderer and,
    // if still stalled, post an OS-level heads-up notification + vibration so
    // the walker can tap to foreground (→ renderer un-freezes → walk resumes).
    private static final long JS_STALL_MS               = 90_000;
    private static final long WATCHDOG_NOTIFY_MIN_GAP_MS = 180_000;
    private static final int  WATCHDOG_NOTIFICATION_ID   = 9101;
    // v2.15.1 — cap consecutive tier-2 notifications without an intervening JS
    // ack: after this many unanswered nudges more vibration won't help (and a
    // deliberately abandoned walk must not harass the walker every 3 min).
    private static final int  WATCHDOG_MAX_NOTIFY_PER_STALL = 3;
    public static volatile boolean sWalkActive          = false;
    public static volatile long    sLastJsAckMs         = 0;
    private static volatile long   sWatchdogPendingSince = 0;
    public static volatile long    sWatchdogNotifyCount = 0;
    public static volatile long    sLastWatchdogNotifyMs = 0;
    public static volatile long    sRendererNudgeCount  = 0;
    public static volatile int     sNotifySinceAck      = 0;

    // v2.15.1 — walk-active gate persisted to SharedPreferences so the watchdog
    // survives a process kill mid-walk (OEM "put to sleep" / OOM). The statics
    // above die with the process; the START_STICKY service restart re-runs the
    // provider's onStart, which restores the gate from prefs — without this the
    // watchdog is disarmed in exactly the failure mode it exists to report.
    private static final String WATCHDOG_PREFS   = "bgloc_watchdog";
    private static final String PREF_WALK_ACTIVE = "walkActive";
    public static volatile boolean sWalkActiveRestored = false;

    // v2.15.1 — direct renderer-liveness probe: evaluateJavascript("1") with a
    // callback. An answer proves the renderer runs JS (so a stale GPS-fix ack is
    // a blackout, not a freeze — don't notify); a previous probe left unanswered
    // for a full alarm cycle confirms the freeze. GPS-independent, unlike acks.
    public static volatile long sProbeSentCount    = 0;
    public static volatile long sProbeAnswerCount  = 0;
    public static volatile long sLastProbeSentMs   = 0;
    public static volatile long sLastProbeAnswerMs = 0;

    // v2.15.1 — tier-1.5 auto-foreground recovery (loan fleet). With the
    // "Display over other apps" grant a background activity start is legal
    // (FGS alone stopped being enough on Android 10): WatchdogRecoveryActivity
    // briefly turns the screen on over the keyguard, the process leaves the
    // cached tier, the renderer thaws — no walker interaction. Tried before
    // the notification, capped per stall so a pathological OEM can't strobe
    // the pocket; the notification stays as the human fallback.
    private static final int  WATCHDOG_MAX_AUTOFG_PER_STALL = 2;
    public static volatile long sAutoFgCount          = 0;
    public static volatile long sLastAutoFgMs         = 0;
    public static volatile int  sAutoFgSinceAck       = 0;
    public static volatile long sAutoFgLastRecoveryMs = 0;   // >0 ms-to-ack; -1 attempted, no recovery

    // Static logger for the watchdog's static entry points (instance `logger`
    // comes from AbstractLocationProvider and isn't reachable from them).
    private static final org.slf4j.Logger sLog = LoggerManager.getLogger(RawLocationProvider.class);

    // ───────── v2.15.0 — D2 Android geofence wake-rail ─────────
    public static volatile long    sRailWakeCount       = 0;
    public static volatile long    sLastRailWakeMs      = 0;
    public static volatile String  sLastRailRegionId    = null;
    public static volatile int     sLastRailTransition  = 0;

    // Cached WebView handle (set by the CDV layer in pluginInitialize) so the
    // background receivers — which only have a Context — can re-assert the
    // renderer priority that keeps the JS loop schedulable when the screen is
    // off. Best-effort: a no-op if the handle is gone or the API is too old.
    private static volatile WeakReference<View> sWebViewRef = null;

    // Live instance handle so the static rail-wake entry point can deliver a
    // cached fix through the running provider's dispatch. Set in onStart,
    // cleared in onStop.
    private static volatile RawLocationProvider sActive = null;

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
            // D1 — the alarm is proven to keep firing during a JS freeze, so it
            // is the right place to check JS liveness and escalate if needed.
            maybeFireWatchdog(context);
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

    // ───────── v2.15.0 D1/D2 — renderer nudge + JS-liveness watchdog ─────────

    /** Cache the Cordova WebView so background receivers can re-assert its
     *  renderer priority. Called once from the CDV plugin's pluginInitialize. */
    public static void setWebView(View v) {
        sWebViewRef = (v != null) ? new WeakReference<>(v) : null;
    }

    /** Best-effort: keep the WebView renderer at IMPORTANT priority (un-frozen)
     *  even while the screen is off. Mirrors power-opt PO-10 but callable from a
     *  background Context with no plugin reference. No-op below API 24 or if the
     *  handle is gone. Runs on the UI thread.
     *  v2.15.1: also onResume() + resumeTimers() — legal anytime, no-ops when
     *  already resumed, and cover any path that left the Cordova/WebView pause
     *  layer engaged (the priority re-assert alone can't undo that). */
    public static void nudgeRenderer() {
        final WeakReference<View> ref = sWebViewRef;
        if (ref == null) return;
        final View v = ref.get();
        if (!(v instanceof WebView)) return;
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() {
                try {
                    WebView wv = (WebView) v;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        wv.setRendererPriorityPolicy(
                            WebView.RENDERER_PRIORITY_IMPORTANT, false);
                    }
                    wv.onResume();
                    wv.resumeTimers();
                    sRendererNudgeCount++;
                } catch (Throwable ignored) {}
            }
        });
    }

    /** v2.15.1 — send a renderer-liveness probe. The callback landing updates
     *  sLastProbeAnswerMs; on a frozen renderer the evaluate queues silently and
     *  only answers at thaw, so "previous probe unanswered" = freeze confirmed.
     *  Posted to the UI thread (evaluateJavascript requirement). */
    public static void sendRendererProbe() {
        final WeakReference<View> ref = sWebViewRef;
        if (ref == null) return;
        final View v = ref.get();
        if (!(v instanceof WebView)) return;
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() {
                try {
                    sProbeSentCount++;
                    sLastProbeSentMs = System.currentTimeMillis();
                    ((WebView) v).evaluateJavascript("1", new ValueCallback<String>() {
                        @Override public void onReceiveValue(String value) {
                            sProbeAnswerCount++;
                            sLastProbeAnswerMs = System.currentTimeMillis();
                        }
                    });
                } catch (Throwable ignored) {}
            }
        });
    }

    private static void persistWalkActive(Context ctx, boolean active) {
        try {
            SharedPreferences prefs = ctx.getApplicationContext()
                .getSharedPreferences(WATCHDOG_PREFS, Context.MODE_PRIVATE);
            prefs.edit().putBoolean(PREF_WALK_ACTIVE, active).apply();
        } catch (Throwable ignored) {}
    }

    /** v2.15.1 — re-arm the watchdog after a process restart mid-walk. Primes
     *  the ack clock to "now": if JS is actually alive its acks keep the clock
     *  fresh and nothing fires; if the renderer died with the old process, the
     *  clock stalls and the normal tier-1/tier-2 escalation reaches the walker.
     *  Returns true only when a persisted active walk was restored. */
    public static boolean restoreWalkStateIfNeeded(Context ctx) {
        if (sWalkActive) return false;
        boolean persisted = false;
        try {
            persisted = ctx.getApplicationContext()
                .getSharedPreferences(WATCHDOG_PREFS, Context.MODE_PRIVATE)
                .getBoolean(PREF_WALK_ACTIVE, false);
        } catch (Throwable ignored) {}
        if (!persisted) return false;
        sWalkActive = true;
        sLastJsAckMs = System.currentTimeMillis();
        sWatchdogPendingSince = 0;
        sWalkActiveRestored = true;
        sLog.info("Watchdog: restored active-walk gate from prefs (process restarted mid-walk)");
        return true;
    }

    /** JS calls this on every processed real fix AND on a ~25 s timer (v2.15.1
     *  #2 — so a GPS blackout with a live JS loop doesn't read as a freeze).
     *  Resets the stall clock; clears any pending watchdog + dismisses a
     *  recovery notification if JS came back on its own. */
    public static void ackAlive(Context ctx) {
        sLastJsAckMs = System.currentTimeMillis();
        sNotifySinceAck = 0;
        sAutoFgSinceAck = 0;
        if (sWatchdogPendingSince != 0) {
            sWatchdogPendingSince = 0;
            cancelWatchdogNotification(ctx);
        }
    }

    /** Walk lifecycle gate — the watchdog only escalates while a walk is active.
     *  Starting a walk primes the ack clock so we don't false-fire before the
     *  first fix; ending a walk dismisses any pending notification.
     *  v2.15.1: persisted, so a process kill mid-walk doesn't disarm the
     *  watchdog (see restoreWalkStateIfNeeded). */
    public static void setWalkActive(Context ctx, boolean active) {
        sWalkActive = active;
        sWalkActiveRestored = false;
        sNotifySinceAck = 0;
        sAutoFgSinceAck = 0;
        persistWalkActive(ctx, active);
        if (active) {
            sLastJsAckMs = System.currentTimeMillis();
            sWatchdogPendingSince = 0;
        } else {
            sWatchdogPendingSince = 0;
            cancelWatchdogNotification(ctx);
        }
    }

    private static void cancelWatchdogNotification(Context ctx) {
        try {
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) nm.cancel(WATCHDOG_NOTIFICATION_ID);
        } catch (Throwable ignored) {}
    }

    /** Two-tier escalation. Tier 1 (first detection): nudge the renderer, send
     *  a liveness probe, and wait one cycle — a soft-throttled loop recovers
     *  silently. Tier 2 (sustained stall, throttled + capped): vibrate +
     *  heads-up notification so the walker brings the app to the foreground.
     *  v2.15.1: static (callable from receivers on a reborn process) and gated
     *  on the probe — if the previous probe was answered, the renderer
     *  demonstrably runs JS (GPS blackout, not a freeze): keep nudging, don't
     *  ring. An unanswered previous probe — or no WebView to probe at all —
     *  confirms the freeze. */
    private static void maybeFireWatchdog(Context ctx) {
        if (!sWalkActive) return;
        long now = System.currentTimeMillis();
        long ack = sLastJsAckMs;
        if (ack == 0) return;                       // walk just started, no ack yet
        long stall = now - ack;
        if (stall < JS_STALL_MS) {                  // JS alive — clear any pending
            sWatchdogPendingSince = 0;
            return;
        }
        // JS appears stalled. Capture the previous probe state BEFORE sending a
        // new one (both this check and the answer callback run on the main
        // thread, so neither can land mid-method).
        long prevProbeSent = sLastProbeSentMs;
        boolean prevProbeAnswered = prevProbeSent > 0 && sLastProbeAnswerMs >= prevProbeSent;
        nudgeRenderer();
        sendRendererProbe();
        if (sWatchdogPendingSince == 0) {           // tier 1 — give the nudge a cycle
            sWatchdogPendingSince = now;
            return;
        }
        if (prevProbeAnswered) return;              // renderer alive — ack stall is GPS-side
        // tier 1.5 — silent auto-recovery (loan fleet): launch the black
        // over-keyguard recovery activity instead of ringing. NOT throttled by
        // the notification gap — if it doesn't bring acks back by the next
        // alarm cycle we retry once, then fall through to the notification.
        if (tryAutoForeground(ctx)) return;
        if (now - sLastWatchdogNotifyMs < WATCHDOG_NOTIFY_MIN_GAP_MS) return; // throttle
        if (sNotifySinceAck >= WATCHDOG_MAX_NOTIFY_PER_STALL) return;         // cap
        postWatchdogNotification(ctx, stall);       // tier 2
        sWatchdogNotifyCount++;
        sNotifySinceAck++;
        sLastWatchdogNotifyMs = now;
    }

    /** v2.15.1 tier 1.5 — background-launch the recovery activity. Requires the
     *  "Display over other apps" grant (the documented BAL exemption; granted
     *  per-device on the loan fleet via the devmode flow / provisioning).
     *  Returns false when ungranted, capped, or the launch failed — the caller
     *  then escalates to the notification. */
    private static boolean tryAutoForeground(Context ctx) {
        if (sAutoFgSinceAck >= WATCHDOG_MAX_AUTOFG_PER_STALL) return false;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                    && !android.provider.Settings.canDrawOverlays(ctx)) {
                return false;
            }
            Context app = ctx.getApplicationContext();
            Intent intent = new Intent(app, WatchdogRecoveryActivity.class);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
            app.startActivity(intent);
            sAutoFgCount++;
            sAutoFgSinceAck++;
            sLastAutoFgMs = System.currentTimeMillis();
            sLog.warn("Watchdog: auto-foreground recovery launched (attempt {} this stall)", sAutoFgSinceAck);
            return true;
        } catch (Throwable t) {
            sLog.error("Watchdog auto-foreground failed: {}", t.getMessage());
            return false;
        }
    }

    private static void postWatchdogNotification(Context ctx, long stallMs) {
        Context app = ctx.getApplicationContext();
        // Vibrate directly (no permission needed) so the cue lands even if
        // POST_NOTIFICATIONS was denied on Android 13+.
        try {
            Vibrator vib = (Vibrator) app.getSystemService(Context.VIBRATOR_SERVICE);
            if (vib != null) {
                long[] pattern = {0, 400, 200, 400};
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vib.vibrate(VibrationEffect.createWaveform(pattern, -1));
                } else {
                    vib.vibrate(pattern, -1);
                }
            }
        } catch (Throwable ignored) {}

        try {
            NotificationManager nm = (NotificationManager) app.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            NotificationHelper.registerWatchdogChannel(app);
            NotificationCompat.Builder b = new NotificationCompat.Builder(app, NotificationHelper.WATCHDOG_CHANNEL_ID)
                .setContentTitle("Flânerie en pause")
                .setContentText("Touchez pour reprendre votre promenade")
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .setOngoing(false);
            String pkg = app.getPackageName();
            Intent launch = app.getPackageManager().getLaunchIntentForPackage(pkg);
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                    ? PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
                    : PendingIntent.FLAG_UPDATE_CURRENT;
                b.setContentIntent(PendingIntent.getActivity(app, 9102, launch, flags));
            }
            nm.notify(WATCHDOG_NOTIFICATION_ID, b.build());
            sLog.warn("Watchdog: JS stalled {}ms during active walk — posted recovery notification", stallMs);
        } catch (Throwable t) {
            sLog.error("Watchdog notification failed: {}", t.getMessage());
        }
    }

    /** D2 — entry point from the geofence rail receiver. The crossing wakes the
     *  process; we re-assert renderer priority so a soft-throttled renderer
     *  resumes (the native raw stream is already alive, so the next REAL fix —
     *  not a stale cached one — flows into the now-running JS for the polygon
     *  trigger), record telemetry, and run the watchdog check immediately rather
     *  than waiting for the slow Doze alarm. Strictly wakeup-only: the rail never
     *  delivers a fix and never triggers audio (Decisions 1.D / 2.B). */
    public static void onRailWake(Context ctx, String regionId, int transition) {
        sRailWakeCount++;
        sLastRailWakeMs = System.currentTimeMillis();
        sLastRailRegionId = regionId;
        sLastRailTransition = transition;
        // v2.15.1 #1 — this manifest receiver may be what reanimates a process
        // the OS killed mid-walk. Restore the persisted walk gate; if the
        // provider isn't even running yet, the old process (and its WebView) is
        // gone for certain — JS cannot come back on its own, so post the
        // recovery notification right away. The crossing is also the best
        // moment for it: the walker is at a zone boundary, missing audio NOW.
        boolean reborn = restoreWalkStateIfNeeded(ctx) && sActive == null;
        if (reborn) {
            postWatchdogNotification(ctx, -1);
            sWatchdogNotifyCount++;
            sNotifySinceAck++;
            sLastWatchdogNotifyMs = System.currentTimeMillis();
        }
        nudgeRenderer();
        RawLocationProvider self = sActive;
        if (self != null && self.isStarted) {
            maybeFireWatchdog(ctx);
        }
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
            sActive = this;   // D2 rail-wake entry point delivers fixes through this instance
            // v2.15.1 #1 — if the service was START_STICKY-restarted after a
            // process kill mid-walk, the in-memory walk gate is gone: re-arm
            // the watchdog from prefs so the kill doesn't end the walk silently.
            restoreWalkStateIfNeeded(mContext);
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
        // v2.15.0 D2 — defensive backup clear of the geofence wake-rail (the
        // webapp clears it on parcours-page exit; this catches a bgGeo.stop()
        // that races ahead). Geofences are OS-global, so leaving them registered
        // after the walk would wake the app needlessly.
        try { GeofenceRailReceiver.clear(mContext); } catch (Throwable ignored) {}
        try {
            locationManager.removeUpdates(this);
        } catch (SecurityException e) {
            logger.error("Security exception: {}", e.getMessage());
            this.handleSecurityException(e);
        } finally {
            isStarted = false;
            if (sActive == this) sActive = null;
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
