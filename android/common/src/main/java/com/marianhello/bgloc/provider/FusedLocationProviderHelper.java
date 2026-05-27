package com.marianhello.bgloc.provider;

import android.content.Context;
import android.location.Location;
import android.os.Looper;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.location.FusedLocationProviderClient;
import com.google.android.gms.location.LocationCallback;
import com.google.android.gms.location.LocationRequest;
import com.google.android.gms.location.LocationResult;
import com.google.android.gms.location.LocationServices;

import com.marianhello.logging.LoggerManager;

/**
 * v2.9.0 — Architecture D (Raw-primary with Fused fallback).
 *
 * Thin wrapper around {@link FusedLocationProviderClient} owned by
 * {@link RawLocationProvider}. The Fused stream runs in parallel to the raw
 * {@code LocationManager} stream; its deliveries are passed back to the
 * parent's dedupe state machine which decides whether to forward them to JS
 * (Raw stale) or suppress (Raw fresh).
 *
 * Battery cost is accepted by design — the show's loan-phone fleet starts at
 * ≥60% and is on a charge cradle between visitors. Survivability under Doze
 * and aggressive OEM kills is the priority.
 *
 * Fail-soft on no-GMS devices: if Google Play Services is missing or
 * out-of-date, {@link #start} no-ops and {@link #isAvailable} returns false.
 * The parent provider continues to deliver raw-only.
 *
 * Uses the legacy {@code LocationRequest.create()} API (deprecated since
 * play-services-location 21.0 but still functional) so the helper compiles
 * against every version in the {@code 17+} range the plugin declares.
 */
public class FusedLocationProviderHelper {
    private static final org.slf4j.Logger logger =
        LoggerManager.getLogger(FusedLocationProviderHelper.class);

    public interface Listener {
        void onFusedLocation(Location location);
    }

    private final Context mContext;
    private final Listener mListener;

    private FusedLocationProviderClient mClient;
    private LocationCallback mCallback;
    private boolean mStarted = false;
    private boolean mAvailable = false;

    public FusedLocationProviderHelper(Context context, Listener listener) {
        this.mContext = context;
        this.mListener = listener;
        this.mAvailable = isGmsAvailable(context);
    }

    public boolean isAvailable() {
        return mAvailable;
    }

    public boolean isStarted() {
        return mStarted;
    }

    private static boolean isGmsAvailable(Context context) {
        try {
            int code = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context);
            return code == ConnectionResult.SUCCESS;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Register a high-accuracy LocationRequest with FLP. Cadence hint is 5 s
     * with a 2 s floor; FLP may deliver faster or slower depending on system
     * conditions. Battery is intentionally not optimised — Fused is the
     * survivability layer.
     */
    public void start() {
        if (mStarted) return;
        if (!mAvailable) {
            logger.info("Fused: GMS not available — skipping FLP registration");
            return;
        }
        try {
            mClient = LocationServices.getFusedLocationProviderClient(mContext);
            @SuppressWarnings("deprecation")
            LocationRequest request = LocationRequest.create()
                    .setPriority(LocationRequest.PRIORITY_HIGH_ACCURACY)
                    .setInterval(5000L)
                    .setFastestInterval(2000L);
            mCallback = new LocationCallback() {
                @Override
                public void onLocationResult(LocationResult result) {
                    if (result == null) return;
                    Location loc = result.getLastLocation();
                    if (loc == null) return;
                    try {
                        mListener.onFusedLocation(loc);
                    } catch (Throwable t) {
                        logger.error("Fused: listener threw {}", t.getMessage());
                    }
                }
            };
            mClient.requestLocationUpdates(request, mCallback, Looper.getMainLooper());
            mStarted = true;
            logger.info("Fused: FLP started (PRIORITY_HIGH_ACCURACY, 5s/2s)");
        } catch (SecurityException e) {
            logger.warn("Fused: SecurityException — {}", e.getMessage());
            mStarted = false;
        } catch (Throwable t) {
            logger.warn("Fused: start failed — {}", t.getMessage());
            mStarted = false;
        }
    }

    public void stop() {
        if (!mStarted) return;
        try {
            if (mClient != null && mCallback != null) {
                mClient.removeLocationUpdates(mCallback);
            }
        } catch (Throwable t) {
            logger.warn("Fused: stop failed — {}", t.getMessage());
        } finally {
            mClient = null;
            mCallback = null;
            mStarted = false;
        }
    }
}
