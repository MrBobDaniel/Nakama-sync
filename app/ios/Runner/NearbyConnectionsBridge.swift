import Flutter
import Foundation

#if canImport(NearbyConnections)
import NearbyConnections
#endif

final class NearbyConnectionsBridge: NSObject, FlutterStreamHandler {
  private let serviceID = "com.example.app.walkie"
  private var roomID: String?
  private var displayName = "Nakama iPhone"
  private var eventSink: FlutterEventSink?

  #if canImport(NearbyConnections)
  private lazy var connectionManager = ConnectionManager(
    serviceID: serviceID,
    strategy: .pointToPoint
  )
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var connectedEndpoints = Set<EndpointID>()
  #endif

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startSession":
      guard
        let arguments = call.arguments as? [String: Any],
        let roomID = arguments["roomId"] as? String,
        let displayName = arguments["displayName"] as? String
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "roomId and displayName are required.",
            details: nil
          )
        )
        return
      }

      self.roomID = roomID
      self.displayName = displayName
      startSession(result: result)

    case "setPushToTalkActive":
      guard
        let arguments = call.arguments as? [String: Any],
        let isActive = arguments["isActive"] as? Bool
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "isActive is required.",
            details: nil
          )
        )
        return
      }

      setPushToTalkActive(isActive, result: result)

    case "stopSession":
      stopSession()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func startSession(result: @escaping FlutterResult) {
    #if canImport(NearbyConnections)
    stopSession()
    connectionManager.delegate = self
    emit(event: "session_started", message: "Starting Nearby Connections advertising and discovery.")

    let context = displayName.data(using: .utf8) ?? Data()

    let advertiser = Advertiser(connectionManager: connectionManager)
    advertiser.delegate = self
    advertiser.startAdvertising(using: context)
    self.advertiser = advertiser

    let discoverer = Discoverer(connectionManager: connectionManager)
    discoverer.delegate = self
    discoverer.startDiscovery()
    self.discoverer = discoverer

    result(nil)
    #else
    emit(
      event: "unsupported",
      message: "Nearby Connections Swift package is not linked into the iOS target yet."
    )
    result(
      FlutterError(
        code: "sdk_missing",
        message: "Nearby Connections Swift package is not linked into the iOS target yet.",
        details: nil
      )
    )
    #endif
  }

  private func setPushToTalkActive(_ isActive: Bool, result: @escaping FlutterResult) {
    #if canImport(NearbyConnections)
    guard connectedEndpoints.first != nil else {
      result(
        FlutterError(
          code: "no_endpoint",
          message: "No active Nearby peer is connected.",
          details: nil
        )
      )
      return
    }

    if isActive {
      emit(
        event: "error",
        message: "iOS microphone stream capture is not implemented yet."
      )
      result(
        FlutterError(
          code: "not_implemented",
          message: "iOS microphone stream capture is not implemented yet.",
          details: nil
        )
      )
    } else {
      emit(event: "transmit_state", message: "Push-to-talk stream is idle.", extra: [
        "isTransmitting": false
      ])
      result(nil)
    }
    #else
    result(
      FlutterError(
        code: "sdk_missing",
        message: "Nearby Connections Swift package is not linked into the iOS target yet.",
        details: nil
      )
    )
    #endif
  }

  private func stopSession() {
    #if canImport(NearbyConnections)
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    advertiser = nil
    discoverer = nil
    connectedEndpoints.removeAll()
    #endif
  }

  private func emit(event: String, message: String, extra: [String: Any] = [:]) {
    var payload: [String: Any] = [
      "event": event,
      "message": message,
      "roomId": roomID as Any,
    ]
    extra.forEach { payload[$0.key] = $0.value }
    eventSink?(payload)
  }
}

#if canImport(NearbyConnections)
extension NearbyConnectionsBridge: AdvertiserDelegate {
  func advertiser(
    _ advertiser: Advertiser,
    didReceiveConnectionRequestFrom endpointID: EndpointID,
    with context: Data,
    connectionRequestHandler: @escaping (Bool) -> Void
  ) {
    emit(event: "connection_initiated", message: "Connection initiated with nearby peer.")
    connectionRequestHandler(true)
  }
}

extension NearbyConnectionsBridge: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    if !shouldConnect(to: context) {
      return
    }

    emit(event: "peer_discovered", message: "Found nearby peer.")
    discoverer.requestConnection(to: endpointID, using: displayName.data(using: .utf8) ?? Data())
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    connectedEndpoints.remove(endpointID)
    emit(event: "disconnected", message: "Nearby peer left range. Searching again.")
  }
}

extension NearbyConnectionsBridge: ConnectionManagerDelegate {
  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive verificationCode: String,
    from endpointID: EndpointID,
    verificationHandler: @escaping (Bool) -> Void
  ) {
    verificationHandler(true)
  }

  func connectionManager(_ connectionManager: ConnectionManager, didChangeTo state: ConnectionState, for endpointID: EndpointID) {
    switch state {
    case .connected:
      connectedEndpoints.insert(endpointID)
      emit(event: "connected", message: "Connected to nearby peer over Nearby Connections.", extra: [
        "connectedPeers": connectedEndpoints.count
      ])
    case .disconnected:
      connectedEndpoints.remove(endpointID)
      emit(event: "disconnected", message: "Nearby peer disconnected.")
    default:
      break
    }
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive data: Data,
    withID payloadID: PayloadID,
    from endpointID: EndpointID
  ) {
    emit(event: "bytes_received", message: "Received control payload from nearby peer.")
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive stream: InputStream,
    withID payloadID: PayloadID,
    from endpointID: EndpointID,
    cancellationToken token: CancellationToken
  ) {
    emit(event: "stream_received", message: "Incoming audio stream received from nearby peer.")
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didStartReceivingResourceWithID payloadID: PayloadID,
    from endpointID: EndpointID,
    at localURL: URL,
    withName name: String,
    cancellationToken token: CancellationToken
  ) {
    emit(event: "file_received", message: "Receiving file payload from nearby peer.")
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceiveTransferUpdate update: TransferUpdate,
    from endpointID: EndpointID,
    forPayload payloadID: PayloadID
  ) {
    emit(event: "transfer_update", message: "Nearby payload transfer updated.")
  }
}

private extension NearbyConnectionsBridge {
  func shouldConnect(to context: Data) -> Bool {
    guard let remoteName = String(data: context, encoding: .utf8) else {
      return true
    }

    let normalizedRoom = roomID?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedRoom == nil || normalizedRoom?.isEmpty == true {
      return true
    }

    return !remoteName.isEmpty
  }
}
#endif
