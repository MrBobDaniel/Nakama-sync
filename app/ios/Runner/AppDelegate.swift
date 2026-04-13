import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let nearbyConnectionsBridge = NearbyConnectionsBridge()

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    NSLog("NEARBY_BOOT didInitializeImplicitFlutterEngine")

    guard let registrar = registry.registrar(forPlugin: "NearbyConnectionsBridge") else {
      NSLog("NEARBY_BOOT registrar_unavailable")
      assertionFailure("NearbyConnectionsBridge registrar is unavailable.")
      return
    }
    let messenger = registrar.messenger()

    let methodChannel = FlutterMethodChannel(
      name: "nakama_sync.local/nearby_connections",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler(nearbyConnectionsBridge.handle)
    NSLog("NEARBY_BOOT method_channel_registered")

    let eventChannel = FlutterEventChannel(
      name: "nakama_sync.local/nearby_connections/events",
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(nearbyConnectionsBridge)
    NSLog("NEARBY_BOOT event_channel_registered")
  }
}
