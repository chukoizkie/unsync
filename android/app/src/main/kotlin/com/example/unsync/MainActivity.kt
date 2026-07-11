package com.example.unsync

import android.net.Uri
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var launchPayload: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.i(
            "StartupLatency",
            "[STARTUP_LATENCY] ${System.currentTimeMillis()} android_activity_creation"
        )
        launchPayload = notificationPayloadFromIntent()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "uk.unsync.messenger/launch_intent"
        ).setMethodCallHandler { call, result ->
            if (call.method == "initialNotificationPayload") {
                result.success(launchPayload)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun getInitialRoute(): String {
        val payload = notificationPayloadFromIntent()
        return if (payload != null) {
            "/incoming-call?payload=${Uri.encode(payload)}"
        } else {
            super.getInitialRoute() ?: "/"
        }
    }

    private fun notificationPayloadFromIntent(): String? {
        val currentIntent = intent ?: return null
        if (currentIntent.action != "SELECT_NOTIFICATION") return null
        return currentIntent.getStringExtra("payload")
    }
}
