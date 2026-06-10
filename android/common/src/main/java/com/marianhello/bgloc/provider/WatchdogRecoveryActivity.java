package com.marianhello.bgloc.provider;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.WindowManager;

import com.marianhello.logging.LoggerManager;

/**
 * v2.15.1 — D1 tier-1.5 auto-foreground recovery (loan fleet).
 *
 * Launched by the watchdog when the renderer is confirmed frozen and the
 * "Display over other apps" grant makes a background activity start legal.
 * Becoming the top visible activity lifts the app process out of the cached
 * tier, which un-freezes the WebView renderer binding (the Android 11+
 * cached-apps freezer is the observed freeze mechanism) — no walker
 * interaction needed. The window is fullscreen black at minimum brightness,
 * shown OVER the keyguard without dismissing it, so pocket touches reach
 * nothing. We finish as soon as JS acks (walk recovered) or after a hard
 * timeout, and the screen goes back to sleep.
 *
 * This only helps the frozen-renderer-with-live-process case: on a reborn
 * (headless) process the WebView is gone and only the notification tap can
 * relaunch the app — the watchdog never routes that case here.
 */
public class WatchdogRecoveryActivity extends Activity {
    private static final org.slf4j.Logger logger = LoggerManager.getLogger(WatchdogRecoveryActivity.class);
    private static final long MAX_SHOW_MS = 12_000;
    private static final long ACK_POLL_MS = 500;

    private Handler mHandler;
    private long mShownAt;
    private boolean mRecovered = false;

    private final Runnable mPoll = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            if (RawLocationProvider.sLastJsAckMs > mShownAt) {
                mRecovered = true;
                RawLocationProvider.sAutoFgLastRecoveryMs = now - mShownAt;
                logger.info("Recovery: JS acked {}ms after auto-foreground — done", now - mShownAt);
                finish();
            } else if (now - mShownAt > MAX_SHOW_MS) {
                logger.warn("Recovery: no JS ack within {}ms — giving up (notification net follows)", MAX_SHOW_MS);
                finish();
            } else {
                mHandler.postDelayed(this, ACK_POLL_MS);
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Over the keyguard (never dismissed) + wake the display: visibility is
        // what raises the process importance and thaws the renderer.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        } else {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = 0.01f;   // pocket: as dark as the panel allows
        getWindow().setAttributes(lp);

        View black = new View(this);
        black.setBackgroundColor(Color.BLACK);
        setContentView(black);         // consumes touches; nothing to press

        mShownAt = System.currentTimeMillis();
        mHandler = new Handler(Looper.getMainLooper());
        mHandler.postDelayed(mPoll, ACK_POLL_MS);

        // Belt-and-braces while we're visible anyway.
        RawLocationProvider.nudgeRenderer();
    }

    @Override
    protected void onDestroy() {
        if (mHandler != null) mHandler.removeCallbacks(mPoll);
        if (!mRecovered && RawLocationProvider.sAutoFgLastRecoveryMs == 0) {
            RawLocationProvider.sAutoFgLastRecoveryMs = -1;  // attempted, no recovery
        }
        super.onDestroy();
    }
}
