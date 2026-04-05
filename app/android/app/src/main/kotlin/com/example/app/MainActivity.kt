package com.example.app

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
}
