package com.example.app

import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nearbyConnectionsBridge: NearbyConnectionsBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bridge = NearbyConnectionsBridge(this)
        nearbyConnectionsBridge = bridge

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nakama.local/nearby_connections",
        ).setMethodCallHandler(bridge)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nakama.local/nearby_connections/events",
        ).setStreamHandler(bridge)
    }

    override fun onDestroy() {
        nearbyConnectionsBridge?.dispose()
        nearbyConnectionsBridge = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        nearbyConnectionsBridge?.onRequestPermissionsResult(
            requestCode = requestCode,
            permissions = permissions,
            grantResults = grantResults,
        )
    }
}
