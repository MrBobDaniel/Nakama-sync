import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let nearbyConnectionsBridge = NearbyConnectionsBridge()

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)

    guard let registrar = registry.registrar(forPlugin: "NearbyConnectionsBridge") else {
      assertionFailure("NearbyConnectionsBridge registrar is unavailable.")
      return
    }
    let messenger = registrar.messenger()

    let methodChannel = FlutterMethodChannel(
      name: "nakama_sync.local/nearby_connections",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler(nearbyConnectionsBridge.handle)

    let eventChannel = FlutterEventChannel(
      name: "nakama_sync.local/nearby_connections/events",
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(nearbyConnectionsBridge)
  }
}
