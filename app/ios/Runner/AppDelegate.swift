import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let nearbyConnectionsBridge = NearbyConnectionsBridge()

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)

    let registrar = registry.registrar(forPlugin: "NearbyConnectionsBridge")
    let messenger = registrar.messenger()

    let methodChannel = FlutterMethodChannel(
      name: "nakama.local/nearby_connections",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler(nearbyConnectionsBridge.handle)

    let eventChannel = FlutterEventChannel(
      name: "nakama.local/nearby_connections/events",
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(nearbyConnectionsBridge)
  }
}
