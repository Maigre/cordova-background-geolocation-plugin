package com.marianhello.bgloc.provider;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingClient;
import com.google.android.gms.location.GeofencingEvent;
import com.google.android.gms.location.GeofencingRequest;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.tasks.OnFailureListener;
import com.google.android.gms.tasks.OnSuccessListener;
import com.marianhello.logging.LoggerManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * v2.15.0 — D2 Android GPS wake-rail.
 *
 * The Android analog of the iOS CLCircularRegion rail (BG-11). A coarse circular
 * geofence sits at each transition midpoint of the parcours (same geometry the
 * webapp's {@code computeGpsRail()} builds for iOS). Crossing one fires this
 * manifest-registered receiver — which wakes the app process even from a frozen
 * / cached state — and hands off to {@link RawLocationProvider#onRailWake} to
 * re-assert renderer priority + deliver a fix so the JS event loop resumes and
 * runs the precise polygon trigger.
 *
 * WAKEUP-ONLY (audit Decisions 1.D / 2.B): a rail crossing NEVER starts audio.
 * Audio only ever fires from a fresh real fix through the existing JS zone check.
 *
 * Fail-soft: if Google Play Services / the geofencing API is unavailable, or the
 * location permission is missing, {@link #configure} no-ops — the walk falls back
 * to the AlarmManager keepalive + D1 watchdog.
 */
public class GeofenceRailReceiver extends BroadcastReceiver {
    private static final org.slf4j.Logger logger = LoggerManager.getLogger(GeofenceRailReceiver.class);
    private static final String ACTION = "com.marianhello.bgloc.GEOFENCE_RAIL";
    private static final int    REQUEST_CODE = 9201;

    // Request IDs currently registered, so clear() can remove them by id.
    private static final List<String> sActiveIds = new ArrayList<>();

    private static PendingIntent getPendingIntent(Context ctx) {
        Intent intent = new Intent(ctx, GeofenceRailReceiver.class);
        intent.setAction(ACTION);
        intent.setPackage(ctx.getPackageName());
        int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            ? PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE
            : PendingIntent.FLAG_UPDATE_CURRENT;
        return PendingIntent.getBroadcast(ctx.getApplicationContext(), REQUEST_CODE, intent, flags);
    }

    /**
     * Register the rail. {@code regions} is the JSON array the webapp passes:
     * each entry {@code {id, lat, lon, radius}}. Returns the count actually
     * registered (0 = no-op / failure, handled fail-soft by the caller).
     */
    public static int configure(Context ctx, JSONArray regions) {
        if (regions == null || regions.length() == 0) return 0;
        Context app = ctx.getApplicationContext();
        List<Geofence> fences = new ArrayList<>();
        List<String> ids = new ArrayList<>();
        for (int i = 0; i < regions.length(); i++) {
            JSONObject r = regions.optJSONObject(i);
            if (r == null) continue;
            String id = r.optString("id", "rail_" + i);
            double lat = r.optDouble("lat", Double.NaN);
            double lon = r.optDouble("lon", Double.NaN);
            double radius = r.optDouble("radius", 100);
            if (Double.isNaN(lat) || Double.isNaN(lon)) continue;
            fences.add(new Geofence.Builder()
                .setRequestId(id)
                .setCircularRegion(lat, lon, (float) radius)
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER | Geofence.GEOFENCE_TRANSITION_EXIT)
                .setNotificationResponsiveness(0)   // fastest delivery, even in Doze
                .build());
            ids.add(id);
        }
        if (fences.isEmpty()) return 0;

        GeofencingRequest req = new GeofencingRequest.Builder()
            .setInitialTrigger(0)   // do NOT fire just for being inside at registration
            .addGeofences(fences)
            .build();
        try {
            final int registered = fences.size();
            GeofencingClient client = LocationServices.getGeofencingClient(app);
            client.addGeofences(req, getPendingIntent(app))
                .addOnSuccessListener(new OnSuccessListener<Void>() {
                    @Override public void onSuccess(Void unused) {
                        logger.info("Rail: registered {} geofences", registered);
                    }
                })
                .addOnFailureListener(new OnFailureListener() {
                    @Override public void onFailure(Exception e) {
                        logger.error("Rail: addGeofences failed: {}", e.getMessage());
                    }
                });
        } catch (SecurityException e) {
            logger.error("Rail: missing location permission for geofences: {}", e.getMessage());
            return 0;
        } catch (Throwable t) {
            logger.error("Rail: geofence registration error: {}", t.getMessage());
            return 0;
        }
        synchronized (sActiveIds) { sActiveIds.clear(); sActiveIds.addAll(ids); }
        return fences.size();
    }

    public static void clear(Context ctx) {
        Context app = ctx.getApplicationContext();
        List<String> ids;
        synchronized (sActiveIds) { ids = new ArrayList<>(sActiveIds); sActiveIds.clear(); }
        try {
            GeofencingClient client = LocationServices.getGeofencingClient(app);
            if (!ids.isEmpty()) client.removeGeofences(ids);
            else client.removeGeofences(getPendingIntent(app));
        } catch (Throwable t) {
            logger.error("Rail: clear error: {}", t.getMessage());
        }
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        GeofencingEvent event = GeofencingEvent.fromIntent(intent);
        if (event == null || event.hasError()) {
            if (event != null) logger.error("Rail: geofence event error {}", event.getErrorCode());
            return;
        }
        int transition = event.getGeofenceTransition();
        List<Geofence> triggering = event.getTriggeringGeofences();
        String id = (triggering != null && !triggering.isEmpty()) ? triggering.get(0).getRequestId() : null;
        logger.debug("Rail: wake region={} transition={}", id, transition);
        RawLocationProvider.onRailWake(context, id, transition);
    }
}
