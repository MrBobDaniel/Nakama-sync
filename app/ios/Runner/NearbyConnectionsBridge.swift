import Flutter
import AVFoundation
import AudioToolbox
import Foundation
import os.log

#if canImport(NearbyConnections)
import NearbyConnections
#endif

final class NearbyConnectionsBridge: NSObject, FlutterStreamHandler {
  private let logger = Logger(subsystem: "com.nakamasync.app", category: "NearbyConnections")
  private let serviceID = "com.nakamasync.app.walkie"
  private lazy var commsSessionManager = IOSCommsSessionManager(
    onStateChanged: { [weak self] (message: String, extra: [String: Any]) in
      self?.emit(event: "os_session_state", message: message, extra: extra)
    },
    onSystemSessionEnded: { [weak self] (reason: String) in
      guard let self else { return }
      self.emit(event: "error", message: reason)
      self.stopSession()
    },
    onAudioSessionActivated: { [weak self] in
      self?.syncPendingTransmitStateAfterAudioActivation()
    }
  )
  private var roomID: String?
  private var displayName = "Nakama Sync iPhone"
  private var localPeerID = UUID().uuidString.lowercased()
  private var localAudioConfig = NearbyAudioConfig.defaultConfig
  private var eventSink: FlutterEventSink?

  #if canImport(NearbyConnections)
  private lazy var connectionManager = ConnectionManager(
    serviceID: serviceID,
    strategy: .cluster
  )
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var connectedEndpoints = Set<EndpointID>()
  private var pendingOutgoingConnections = Set<EndpointID>()
  private var pendingConnectionRequests = [EndpointID: DispatchWorkItem]()
  private var endpointRoomMatches = [EndpointID: Bool]()
  private var endpointAudioConfigs = [EndpointID: NearbyAudioConfig]()
  private var peerSessions = [EndpointID: PeerSession]()
  private var isDiscovering = false
  private var isPushToTalkActive = false
  private var isVoiceActivationEnabled = false
  private var voiceActivationSensitivity = 0.55
  private var isMicrophoneMuted = false
  private var discoveryStopWorkItem: DispatchWorkItem?
  private lazy var audioController = makeAudioController()
  #endif

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    NSLog("NEARBY_CALL method=%@", call.method)
    switch call.method {
    case "startSession":
      guard
        let arguments = call.arguments as? [String: Any],
        let roomID = (arguments["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        let displayName = (arguments["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !roomID.isEmpty,
        !displayName.isEmpty
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

      self.roomID = Self.normalizeRoomID(roomID)
      self.displayName = displayName
      localAudioConfig = parseAudioConfig(arguments)
      NSLog(
        "NEARBY_CALL startSession roomId=%@ displayName=%@ codec=%@ sampleRate=%d frameMs=%d transport=%d",
        self.roomID ?? "null",
        self.displayName,
        localAudioConfig.codec,
        localAudioConfig.preferredSampleRate,
        localAudioConfig.frameDurationMs,
        localAudioConfig.transportVersion
      )
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

    case "configureVoiceActivation":
      guard
        let arguments = call.arguments as? [String: Any]
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Voice activation arguments are required.",
            details: nil
          )
        )
        return
      }
      let isEnabled = arguments["isEnabled"] as? Bool ?? false
      let sensitivity = min(1.0, max(0.0, arguments["sensitivity"] as? Double ?? 0.55))
      configureVoiceActivation(isEnabled: isEnabled, sensitivity: sensitivity, result: result)

    case "setMicrophoneMuted":
      guard
        let arguments = call.arguments as? [String: Any],
        let isMuted = arguments["isMuted"] as? Bool
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "isMuted is required.",
            details: nil
          )
        )
        return
      }
      setMicrophoneMuted(isMuted, result: result)

    case "stopSession":
      stopSession()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    NSLog("NEARBY_STREAM onListen")
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NSLog("NEARBY_STREAM onCancel")
    eventSink = nil
    return nil
  }

  private func startSession(result: @escaping FlutterResult) {
    #if canImport(NearbyConnections)
    NSLog("NEARBY_START entering startSession")
    let requestedRoomID = roomID
    let requestedDisplayName = displayName
    let requestedPeerID = localPeerID
    let requestedAudioConfig = localAudioConfig
    stopSession()
    roomID = requestedRoomID
    displayName = requestedDisplayName
    localPeerID = requestedPeerID
    localAudioConfig = requestedAudioConfig
    audioController.stopAll()
    audioController = makeAudioController()
    let osSessionResult = commsSessionManager.startSession(
      roomID: roomID ?? "",
      displayName: displayName
    )
    emit(
      event: "os_session_state",
      message: osSessionResult.message,
      extra: [
        "isPersistentSessionActive": osSessionResult.isCallKitActive,
        "isCallKitActive": osSessionResult.isCallKitActive,
        "isAudioSessionConfigured": osSessionResult.isAudioSessionConfigured,
      ]
    )
    connectionManager.delegate = self
    emit(
      event: "session_started",
      message: "Opening room and starting Nearby advertising.",
      extra: ["isDiscovering": true]
    )

    let context = endpointContextData()

    let advertiser = Advertiser(connectionManager: connectionManager)
    advertiser.delegate = self
    NSLog("NEARBY_START advertiser_start")
    advertiser.startAdvertising(using: context)
    self.advertiser = advertiser

    let discoverer = Discoverer(connectionManager: connectionManager)
    discoverer.delegate = self
    self.discoverer = discoverer
    NSLog("NEARBY_START discoverer_created")
    startDiscoveryBurst(message: "Scanning for nearby peers in this room.")

    result(nil)
    #else
    NSLog("NEARBY_START sdk_missing")
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
    let validatedEndpoints = connectedEndpoints.filter { endpointRoomMatches[$0] == true }
    if isActive && validatedEndpoints.isEmpty {
      result(
        FlutterError(
          code: "no_endpoint",
          message: "No validated Nearby peers are connected.",
          details: nil
        )
      )
      return
    }

    if isActive && isMicrophoneMuted {
      result(
        FlutterError(
          code: "microphone_muted",
          message: "Microphone is muted on this device.",
          details: nil
        )
      )
      return
    }

    if isActive {
      isVoiceActivationEnabled = false
      audioController.setVoiceActivation(enabled: false, sensitivity: voiceActivationSensitivity)
      ensureMicrophonePermission { [weak self] granted in
        guard let self else {
          result(
            FlutterError(
              code: "bridge_unavailable",
              message: "Nearby bridge is no longer available.",
              details: nil
            )
          )
          return
        }

        guard granted else {
          self.emit(event: "error", message: "Microphone permission is required for Hold to Talk.")
          result(
            FlutterError(
              code: "microphone_permission_denied",
              message: "Microphone permission is required for Hold to Talk.",
              details: nil
            )
          )
          return
        }

        do {
          self.isPushToTalkActive = true
          guard self.commsSessionManager.isVoiceAudioSessionReady else {
            self.emit(
              event: "os_session_state",
              message: "Waiting for iOS audio session activation before transmitting."
            )
            result(nil)
            return
          }
          try self.audioController.syncTransmittingEndpoints(
            Set(validatedEndpoints),
            connectionManager: self.connectionManager
          )
          result(nil)
        } catch {
          let message = error.localizedDescription
          self.emit(event: "error", message: message)
          result(
            FlutterError(
              code: "audio_start_failed",
              message: message,
              details: nil
            )
          )
        }
      }
    } else {
      isPushToTalkActive = false
      validatedEndpoints.forEach { endpointID in
        sendControlPayload(type: "audio_stop", to: endpointID)
      }
      audioController.stopTransmitting()
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

  private func configureVoiceActivation(
    isEnabled: Bool,
    sensitivity: Double,
    result: @escaping FlutterResult
  ) {
    #if canImport(NearbyConnections)
    isVoiceActivationEnabled = isEnabled
    isPushToTalkActive = false
    voiceActivationSensitivity = sensitivity
    syncVoiceActivation()
    emit(
      event: "voice_activation_state",
      message: isEnabled ? "Voice activation configured." : "Voice activation disabled.",
      extra: ["isVoiceActivationArmed": audioController.isVoiceActivationArmed]
    )
    result(nil)
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

  private func setMicrophoneMuted(_ isMuted: Bool, result: @escaping FlutterResult) {
    #if canImport(NearbyConnections)
    isMicrophoneMuted = isMuted
    if isMuted {
      isPushToTalkActive = false
      connectedEndpoints.forEach { sendControlPayload(type: "audio_stop", to: $0) }
      audioController.stopTransmitting()
    }
    syncVoiceActivation()
    emit(
      event: "microphone_state",
      message: isMuted ? "Microphone muted on this device." : "Microphone unmuted on this device.",
      extra: ["isVoiceActivationArmed": audioController.isVoiceActivationArmed]
    )
    result(nil)
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
    isPushToTalkActive = false
    isVoiceActivationEnabled = false
    isMicrophoneMuted = false
    audioController.stopAll()
    connectedEndpoints.forEach { connectionManager.disconnect(from: $0) }
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    advertiser = nil
    discoverer = nil
    connectedEndpoints.removeAll()
    pendingOutgoingConnections.removeAll()
    pendingConnectionRequests.values.forEach { $0.cancel() }
    pendingConnectionRequests.removeAll()
    endpointRoomMatches.removeAll()
    endpointAudioConfigs.removeAll()
    peerSessions.removeAll()
    discoveryStopWorkItem?.cancel()
    discoveryStopWorkItem = nil
    isDiscovering = false
    commsSessionManager.stopSession()
    roomID = nil
    displayName = "Nakama Sync iPhone"
    localAudioConfig = NearbyAudioConfig.defaultConfig
    #endif
  }

  private func emit(event: String, message: String, extra: [String: Any] = [:]) {
    let logLine =
      "event=\(event) roomId=\(self.normalizedRoomID() ?? "null") connectedPeers=\(self.connectedEndpoints.filter { self.endpointRoomMatches[$0] == true }.count) discovering=\(self.isDiscovering) tx=\(self.audioController.isTransmitting) rx=\(self.peerSessions.values.contains { $0.isConnected && $0.isSpeaking }) message=\(message) extra=\(String(describing: extra))"
    logger.info(
      """
      \(logLine, privacy: .public)
      """
    )
    NSLog("%@", logLine)
    let deliver = { [weak self] in
      guard let self else { return }
      let currentRoomID = self.normalizedRoomID()
      var payload: [String: Any] = [
        "event": event,
        "message": message,
        "roomId": currentRoomID ?? NSNull(),
        "connectedPeers": self.connectedEndpoints.filter { self.endpointRoomMatches[$0] == true }.count,
        "isDiscovering": self.isDiscovering,
        "isReceivingAudio": self.peerSessions.values.contains { $0.isConnected && $0.isSpeaking },
        "isTransmitting": self.audioController.isTransmitting,
        "transmitMode": self.isVoiceActivationEnabled ? "voice_activated" : "push_to_talk",
        "isVoiceActivationArmed": self.audioController.isVoiceActivationArmed,
        "audioSampleRate": self.localAudioConfig.preferredSampleRate,
        "codec": self.localAudioConfig.codec,
        "frameDurationMs": self.localAudioConfig.frameDurationMs,
        "transportVersion": self.localAudioConfig.transportVersion,
        "peers": self.peerSessions.values
          .sorted {
            if $0.isConnected == $1.isConnected {
              return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.isConnected && !$1.isConnected
          }
          .map { peer in
            [
              "peerId": peer.endpointID,
              "displayName": peer.displayName,
              "isConnected": peer.isConnected,
              "isSpeaking": peer.isSpeaking,
              "streamSampleRate": peer.streamSampleRate,
              "codec": peer.codec,
            ]
          }
      ]
      extra.forEach { payload[$0.key] = $0.value }
      self.eventSink?(payload)
    }

    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  private func upsertPeer(
    endpointID: EndpointID,
    displayName: String?,
    isConnected: Bool? = nil,
    isSpeaking: Bool? = nil,
    streamSampleRate: Int? = nil,
    codec: String? = nil
  ) {
    let existing = peerSessions[endpointID]
    peerSessions[endpointID] = PeerSession(
      endpointID: endpointID,
      displayName: (displayName?.isEmpty == false ? displayName : existing?.displayName) ?? "Nearby peer",
      isConnected: isConnected ?? existing?.isConnected ?? false,
      isSpeaking: isSpeaking ?? existing?.isSpeaking ?? false,
      streamSampleRate: streamSampleRate ?? existing?.streamSampleRate ?? localAudioConfig.preferredSampleRate,
      codec: codec ?? existing?.codec ?? localAudioConfig.codec
    )
  }

  private func removePeer(_ endpointID: EndpointID) {
    peerSessions.removeValue(forKey: endpointID)
  }

  private func updatePeerSpeaking(_ endpointID: EndpointID, isSpeaking: Bool) {
    guard var peer = peerSessions[endpointID], peer.isSpeaking != isSpeaking else {
      return
    }
    peer.isSpeaking = isSpeaking
    peerSessions[endpointID] = peer
    syncOSAudioState()
    emit(
      event: "receive_state",
      message: isSpeaking ? "\(peer.displayName) is speaking." : "\(peer.displayName) stopped speaking.",
      extra: [
        "peerId": endpointID,
        "peerDisplayName": peer.displayName,
        "isReceivingAudio": peerSessions.values.contains { $0.isConnected && $0.isSpeaking }
      ]
    )
  }

  private func ensureMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted:
      completion(true)
    case .denied:
      completion(false)
    case .undetermined:
      session.requestRecordPermission { granted in
        DispatchQueue.main.async {
          completion(granted)
        }
      }
    @unknown default:
      completion(false)
    }
  }

  private func syncOSAudioState() {
    commsSessionManager.updateAudioState(
      isReceivingAudio: peerSessions.values.contains { $0.isConnected && $0.isSpeaking },
      isTransmitting: audioController.isTransmitting
    )
  }

  private func syncVoiceActivation() {
    guard isVoiceActivationEnabled, !isMicrophoneMuted else {
      audioController.setVoiceActivation(enabled: false, sensitivity: voiceActivationSensitivity)
      return
    }

    let validatedEndpoints = Set(connectedEndpoints.filter { endpointRoomMatches[$0] == true })
    audioController.setVoiceActivation(
      enabled: !validatedEndpoints.isEmpty,
      sensitivity: voiceActivationSensitivity
    )
    if !validatedEndpoints.isEmpty, commsSessionManager.isVoiceAudioSessionReady {
      try? audioController.syncTransmittingEndpoints(
        validatedEndpoints,
        connectionManager: connectionManager
      )
    }
  }

  private func syncPendingTransmitStateAfterAudioActivation() {
    let validatedEndpoints = Set(connectedEndpoints.filter { endpointRoomMatches[$0] == true })
    guard !isMicrophoneMuted else {
      return
    }

    if isPushToTalkActive, !validatedEndpoints.isEmpty {
      do {
        try audioController.syncTransmittingEndpoints(
          validatedEndpoints,
          connectionManager: connectionManager
        )
      } catch {
        emit(event: "error", message: error.localizedDescription)
      }
      return
    }

    if isVoiceActivationEnabled {
      syncVoiceActivation()
    }
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
    let remoteEndpoint = parseEndpointContext(context)
    endpointAudioConfigs[endpointID] = remoteEndpoint.audioConfig
    guard roomMatches(remoteEndpoint.roomID) else {
      cancelPendingConnectionRequest(for: endpointID)
      endpointRoomMatches[endpointID] = false
      emit(event: "error", message: "Ignoring Nearby peer from a different room.")
      connectionRequestHandler(false)
      return
    }
    cancelPendingConnectionRequest(for: endpointID)
    let remoteName = remoteEndpoint.displayName ?? "nearby peer"
    upsertPeer(endpointID: endpointID, displayName: remoteName)
    emit(event: "connection_initiated", message: "Connection initiated with \(remoteName).")
    connectionRequestHandler(true)
  }
}

extension NearbyConnectionsBridge: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    let remoteEndpoint = parseEndpointContext(context)
    guard roomMatches(remoteEndpoint.roomID) else {
      return
    }
    guard !connectedEndpoints.contains(endpointID) else {
      return
    }
    guard !pendingOutgoingConnections.contains(endpointID) else {
      return
    }

    endpointAudioConfigs[endpointID] = remoteEndpoint.audioConfig
    let remoteName = remoteEndpoint.displayName ?? "nearby peer"
    upsertPeer(endpointID: endpointID, displayName: remoteName)
    if shouldInitiateConnection(to: remoteEndpoint.peerID, endpointID: endpointID) {
      emit(event: "peer_discovered", message: "Found nearby peer \(remoteName).")
      scheduleConnectionRequest(for: endpointID, remoteName: remoteName)
    } else {
      emit(event: "peer_discovered", message: "Found nearby peer \(remoteName). Waiting for inbound connection.")
    }
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    cancelPendingConnectionRequest(for: endpointID)
    connectedEndpoints.remove(endpointID)
    pendingOutgoingConnections.remove(endpointID)
    endpointRoomMatches.removeValue(forKey: endpointID)
    endpointAudioConfigs.removeValue(forKey: endpointID)
    audioController.handleEndpointDisconnected(endpointID)
    removePeer(endpointID)
    emit(event: "disconnected", message: "Nearby peer left range. Room remains open for reconnects.")
    if isPushToTalkActive {
      try? audioController.syncTransmittingEndpoints(
        Set(connectedEndpoints.filter { endpointRoomMatches[$0] == true }),
        connectionManager: connectionManager
      )
    }
    syncVoiceActivation()
    startDiscoveryBurst(message: "Peer left range. Continuing Nearby scan for reconnects.")
  }
}

extension NearbyConnectionsBridge: ConnectionManagerDelegate {
  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive verificationCode: String,
    from endpointID: EndpointID,
    verificationHandler: @escaping (Bool) -> Void
  ) {
    cancelPendingConnectionRequest(for: endpointID)
    verificationHandler(true)
  }

  func connectionManager(_ connectionManager: ConnectionManager, didChangeTo state: ConnectionState, for endpointID: EndpointID) {
    cancelPendingConnectionRequest(for: endpointID)
    pendingOutgoingConnections.remove(endpointID)
    switch state {
    case .connected:
      connectedEndpoints.insert(endpointID)
      endpointRoomMatches[endpointID] = true
      upsertPeer(
        endpointID: endpointID,
        displayName: peerSessions[endpointID]?.displayName,
        isConnected: true,
        streamSampleRate: agreedSampleRate(with: endpointID),
        codec: agreedCodec(with: endpointID)
      )
      sendHandshake(to: endpointID)
      if isPushToTalkActive {
        try? audioController.syncTransmittingEndpoints(
          Set(connectedEndpoints.filter { endpointRoomMatches[$0] == true }),
          connectionManager: connectionManager
        )
      }
      syncVoiceActivation()
      emit(event: "connected", message: "Connected to \(peerSessions[endpointID]?.displayName ?? "nearby peer") over Nearby Connections.")
    case .disconnected:
      connectedEndpoints.remove(endpointID)
      endpointRoomMatches.removeValue(forKey: endpointID)
      endpointAudioConfigs.removeValue(forKey: endpointID)
      audioController.handleEndpointDisconnected(endpointID)
      removePeer(endpointID)
      if isPushToTalkActive {
        try? audioController.syncTransmittingEndpoints(
          Set(connectedEndpoints.filter { endpointRoomMatches[$0] == true }),
          connectionManager: connectionManager
        )
      }
      syncVoiceActivation()
      emit(event: "disconnected", message: "Nearby peer disconnected. Room remains open for new connections.")
      startDiscoveryBurst(message: "Peer disconnected. Continuing Nearby scan for another nearby peer.")
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
    if handleControlPayload(data, from: endpointID) {
      return
    }

    emit(event: "bytes_received", message: "Received control payload from nearby peer.")
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive stream: InputStream,
    withID payloadID: PayloadID,
    from endpointID: EndpointID,
    cancellationToken token: CancellationToken
  ) {
    guard endpointRoomMatches[endpointID] == true else {
      emit(event: "error", message: "Ignoring audio stream from unverified nearby peer.")
      token.cancel()
      return
    }

    audioController.handleIncomingStream(stream, from: endpointID)
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
  func normalizedRoomID() -> String? {
    Self.normalizeRoomID(roomID)
  }

  func endpointContextData() -> Data {
    let localAudioConfig = buildLocalAudioConfig()
    let payload: [String: Any] = [
      "roomId": normalizedRoomID() ?? NSNull(),
      "displayName": displayName,
      "peerId": localPeerID,
      "preferredCodec": localAudioConfig.codec,
      "supportedCodecs": localAudioConfig.supportedCodecs,
      "preferredSampleRate": localAudioConfig.preferredSampleRate,
      "supportedSampleRates": localAudioConfig.supportedSampleRates,
      "frameDurationMs": localAudioConfig.frameDurationMs,
      "transportVersion": localAudioConfig.transportVersion,
    ]

    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }

  func sendHandshake(to endpointID: EndpointID) {
    sendControlPayload(type: "hello", to: endpointID)
  }

  func sendControlPayload(type: String, to endpointID: EndpointID) {
    let localAudioConfig = buildLocalAudioConfig()
    let payload: [String: Any] = [
      "type": type,
      "roomId": normalizedRoomID() ?? NSNull(),
      "displayName": displayName,
      "peerId": localPeerID,
      "preferredCodec": localAudioConfig.codec,
      "supportedCodecs": localAudioConfig.supportedCodecs,
      "preferredSampleRate": localAudioConfig.preferredSampleRate,
      "supportedSampleRates": localAudioConfig.supportedSampleRates,
      "frameDurationMs": localAudioConfig.frameDurationMs,
      "transportVersion": localAudioConfig.transportVersion,
    ]
    guard
      let payloadData = try? JSONSerialization.data(
        withJSONObject: payload
      )
    else {
      emit(event: "error", message: "Failed to encode Nearby peer metadata.")
      return
    }

    connectionManager.send(payloadData, to: [endpointID])
  }

  func handleControlPayload(_ data: Data, from endpointID: EndpointID) -> Bool {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String
    else {
      return false
    }

    if type == "audio_stop" {
      audioController.stopIncomingAudio(from: endpointID)
      return true
    }

    guard type == "hello" else {
      return false
    }

    let peerRoomID = Self.normalizeRoomID(json["roomId"] as? String)
    let normalizedRoomID = normalizedRoomID()

    if let normalizedRoomID, !normalizedRoomID.isEmpty, peerRoomID != normalizedRoomID {
      endpointRoomMatches[endpointID] = false
      connectedEndpoints.remove(endpointID)
      cancelPendingConnectionRequest(for: endpointID)
      pendingOutgoingConnections.remove(endpointID)
      audioController.handleEndpointDisconnected(endpointID)
      removePeer(endpointID)
      emit(event: "error", message: "Nearby peer is advertising a different room.")
      disconnect(endpointID)
      return true
    }

    let remoteAudioConfig = parseAudioConfig(json)
    if let mismatchReason = audioConfigMismatchReason(remoteAudioConfig) {
      endpointRoomMatches[endpointID] = false
      connectedEndpoints.remove(endpointID)
      cancelPendingConnectionRequest(for: endpointID)
      pendingOutgoingConnections.remove(endpointID)
      audioController.handleEndpointDisconnected(endpointID)
      removePeer(endpointID)
      emit(event: "error", message: "Nearby peer in this room is incompatible: \(mismatchReason).")
      disconnect(endpointID)
      return true
    }

    endpointRoomMatches[endpointID] = true
    endpointAudioConfigs[endpointID] = remoteAudioConfig
    let remoteName = (json["displayName"] as? String) ?? peerSessions[endpointID]?.displayName ?? "Nearby peer"
    upsertPeer(
      endpointID: endpointID,
      displayName: remoteName,
      isConnected: connectedEndpoints.contains(endpointID),
      streamSampleRate: agreedSampleRate(with: endpointID),
      codec: agreedCodec(with: endpointID)
    )
    emit(
      event: "bytes_received",
      message: "Nearby peer metadata received.",
      extra: [
        "peerId": endpointID,
        "peerDisplayName": remoteName,
        "audioSampleRate": agreedSampleRate(with: endpointID),
        "codec": agreedCodec(with: endpointID)
      ]
    )
    return true
  }

  func roomMatches(_ peerRoomID: String?) -> Bool {
    let normalizedPeerRoomID = Self.normalizeRoomID(peerRoomID)
    guard let normalizedRoomID = normalizedRoomID() else {
      return true
    }
    return normalizedPeerRoomID == normalizedRoomID
  }

  func parseEndpointContext(_ context: Data) -> NearbyEndpointContext {
    guard
      let json = try? JSONSerialization.jsonObject(with: context) as? [String: Any]
    else {
      return NearbyEndpointContext(
        roomID: nil,
        displayName: String(data: context, encoding: .utf8),
        peerID: nil,
        audioConfig: NearbyAudioConfig()
      )
    }

    return NearbyEndpointContext(
      roomID: Self.normalizeRoomID(json["roomId"] as? String),
      displayName: json["displayName"] as? String,
      peerID: json["peerId"] as? String,
      audioConfig: parseAudioConfig(json)
    )
  }

  static func normalizeRoomID(_ value: String?) -> String? {
    let normalized = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized?.isEmpty == false ? normalized : nil
  }

  func shouldInitiateConnection(to remotePeerID: String?, endpointID: EndpointID) -> Bool {
    let normalizedLocalPeerID = localPeerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedRemotePeerID = remotePeerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let normalizedRemotePeerID, !normalizedRemotePeerID.isEmpty {
      return normalizedLocalPeerID < normalizedRemotePeerID
    }
    return endpointID.lowercased() >= normalizedLocalPeerID
  }

  func startDiscoveryBurst(message: String) {
    discoveryStopWorkItem?.cancel()
    if isDiscovering {
      emit(event: "session_started", message: message, extra: ["isDiscovering": true])
      return
    }
    isDiscovering = true
    discoverer?.startDiscovery()
    emit(event: "session_started", message: message, extra: ["isDiscovering": true])
  }

  func stopDiscovery() {
    discoveryStopWorkItem?.cancel()
    discoveryStopWorkItem = nil
    guard isDiscovering else { return }
    isDiscovering = false
    discoverer?.stopDiscovery()
  }

  func disconnect(_ endpointID: EndpointID) {
    connectionManager.disconnect(from: endpointID)
  }

  func scheduleConnectionRequest(for endpointID: EndpointID, remoteName: String) {
    guard !connectedEndpoints.contains(endpointID) else { return }
    guard !pendingOutgoingConnections.contains(endpointID) else { return }

    cancelPendingConnectionRequest(for: endpointID)
    let delayMillis = outboundConnectionDelayMillis(for: endpointID)
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingConnectionRequests.removeValue(forKey: endpointID)
      guard !self.connectedEndpoints.contains(endpointID) else { return }

      self.pendingOutgoingConnections.insert(endpointID)
      self.discoverer?.requestConnection(to: endpointID, using: self.endpointContextData())
      self.emit(
        event: "session_started",
        message: "Requesting a Nearby connection to \(remoteName).",
        extra: ["isDiscovering": self.isDiscovering]
      )
    }

    pendingConnectionRequests[endpointID] = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMillis), execute: workItem)
  }

  func cancelPendingConnectionRequest(for endpointID: EndpointID) {
    pendingConnectionRequests.removeValue(forKey: endpointID)?.cancel()
  }

  func outboundConnectionDelayMillis(for endpointID: EndpointID) -> Int {
    let baseDelay = 600
    let jitter = abs(endpointID.hashValue % 250)
    return baseDelay + jitter
  }

  struct NearbyEndpointContext {
    let roomID: String?
    let displayName: String?
    let peerID: String?
    let audioConfig: NearbyAudioConfig
  }

  struct NearbyAudioConfig {
    let codec: String
    let supportedCodecs: [String]
    let preferredSampleRate: Int
    let supportedSampleRates: [Int]
    let frameDurationMs: Int
    let transportVersion: Int

    init(
      codec: String = Self.defaultCodec,
      supportedCodecs: [String] = [Self.defaultCodec],
      preferredSampleRate: Int = Self.defaultStreamSampleRate,
      supportedSampleRates: [Int] = [Self.defaultStreamSampleRate],
      frameDurationMs: Int = Self.defaultFrameDurationMs,
      transportVersion: Int = Self.currentTransportVersion
    ) {
      self.codec = codec.isEmpty ? Self.defaultCodec : codec
      self.supportedCodecs = supportedCodecs.isEmpty ? [Self.defaultCodec] : supportedCodecs
      self.supportedSampleRates = supportedSampleRates.isEmpty ? [Self.defaultStreamSampleRate] : supportedSampleRates
      self.preferredSampleRate = preferredSampleRate
      self.frameDurationMs = max(1, frameDurationMs)
      self.transportVersion = max(1, transportVersion)
    }

    static let defaultCodec = "pcm16"
    static let defaultStreamSampleRate = 16_000
    static let defaultFrameDurationMs = 20
    static let currentTransportVersion = 1
    static let defaultConfig = NearbyAudioConfig()
  }

  struct PeerSession {
    let endpointID: EndpointID
    let displayName: String
    var isConnected: Bool
    var isSpeaking: Bool
    let streamSampleRate: Int
    let codec: String
  }

  func parseAudioConfig(_ json: [String: Any]) -> NearbyAudioConfig {
    let preferredCodec =
      (json["preferredCodec"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackCodec =
      (json["codec"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let codec =
      !(preferredCodec?.isEmpty ?? true) ? preferredCodec!
      : (!(fallbackCodec?.isEmpty ?? true) ? fallbackCodec! : NearbyAudioConfig.defaultCodec)

    let supportedCodecs = {
      var values = (json["supportedCodecs"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if !values.contains(codec) {
        values.insert(codec, at: 0)
      }
      return values.isEmpty ? [codec] : values
    }()

    let preferredSampleRate =
      (json["preferredSampleRate"] as? Int).flatMap { $0 > 0 ? $0 : nil }
      ?? NearbyAudioConfig.defaultStreamSampleRate

    let supportedSampleRates = {
      var values = (json["supportedSampleRates"] as? [Int] ?? []).filter { $0 > 0 }
      if !values.contains(preferredSampleRate) {
        values.insert(preferredSampleRate, at: 0)
      }
      return values.isEmpty ? [preferredSampleRate] : values
    }()

    return NearbyAudioConfig(
      codec: codec,
      supportedCodecs: supportedCodecs,
      preferredSampleRate: preferredSampleRate,
      supportedSampleRates: supportedSampleRates,
      frameDurationMs: max(1, json["frameDurationMs"] as? Int ?? NearbyAudioConfig.defaultFrameDurationMs),
      transportVersion: max(1, json["transportVersion"] as? Int ?? NearbyAudioConfig.currentTransportVersion)
    )
  }

  func buildLocalAudioConfig() -> NearbyAudioConfig {
    localAudioConfig
  }

  func audioConfigMismatchReason(_ remoteConfig: NearbyAudioConfig) -> String? {
    if remoteConfig.transportVersion != localAudioConfig.transportVersion {
      return "transport v\(remoteConfig.transportVersion) does not match room transport v\(localAudioConfig.transportVersion)"
    }
    if remoteConfig.codec != localAudioConfig.codec {
      return "codec \(remoteConfig.codec) does not match room codec \(localAudioConfig.codec)"
    }
    if remoteConfig.preferredSampleRate != localAudioConfig.preferredSampleRate {
      return "sample rate \(remoteConfig.preferredSampleRate) does not match room rate \(localAudioConfig.preferredSampleRate)"
    }
    if remoteConfig.frameDurationMs != localAudioConfig.frameDurationMs {
      return "frame duration \(remoteConfig.frameDurationMs)ms does not match room frame duration \(localAudioConfig.frameDurationMs)ms"
    }
    return nil
  }

  func agreedSampleRate(with endpointID: EndpointID) -> Int {
    // Keep one transport format per room until codec negotiation is fully room-wide.
    localAudioConfig.preferredSampleRate
  }

  func agreedCodec(with endpointID: EndpointID) -> String {
    // Avoid per-peer codec drift in the live transport. The local room profile
    // defines the active transport until Opus is reintroduced as a true room mode.
    localAudioConfig.codec
  }

  func makeAudioController() -> NearbyAudioController {
    NearbyAudioController(
      streamSampleRate: Double(localAudioConfig.preferredSampleRate),
      codecForEndpoint: { [weak self] endpointID in
        self?.agreedCodec(with: endpointID) ?? NearbyAudioConfig.defaultCodec
      },
      prepareAudioSession: { [weak self] in
        guard let self else { return }
        try self.commsSessionManager.prepareForVoiceAudio()
      },
      deactivateAudioSession: { [weak self] in
        self?.commsSessionManager.deactivateVoiceAudio()
      },
      onError: { [weak self] message in
        DispatchQueue.main.async {
          self?.emit(event: "error", message: message)
        }
      },
      onTransmitStateChanged: { [weak self] isTransmitting, message in
        DispatchQueue.main.async {
          guard let self else { return }
          self.syncOSAudioState()
          self.emit(
            event: "transmit_state",
            message: message,
            extra: [
              "isTransmitting": isTransmitting,
              "audioSampleRate": self.localAudioConfig.preferredSampleRate,
              "codec": self.localAudioConfig.codec,
            ]
          )
        }
      },
      onPeerSpeakingChanged: { [weak self] endpointID, isSpeaking in
        DispatchQueue.main.async {
          self?.updatePeerSpeaking(endpointID, isSpeaking: isSpeaking)
        }
      }
    )
  }
}

private final class NearbyAudioController {
  private let streamSampleRate: Double
  private let frameSamples: Int
  private let frameByteCount: Int
  private let codecForEndpoint: (EndpointID) -> String
  private let prepareAudioSession: () throws -> Void
  private let deactivateAudioSession: () -> Void
  private let onError: (String) -> Void
  private let onTransmitStateChanged: (Bool, String) -> Void
  private let onPeerSpeakingChanged: (EndpointID, Bool) -> Void
  private let stateLock = NSLock()
  private let transmitQueueKey = DispatchSpecificKey<Void>()
  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let transmitQueue = DispatchQueue(label: "nakama_sync.nearby.audio.tx")
  private let receiveQueue = DispatchQueue(label: "nakama_sync.nearby.audio.rx")
  private let playbackQueue = DispatchQueue(label: "nakama_sync.nearby.audio.playback")
  private let audioGraphQueue = DispatchQueue(label: "nakama_sync.nearby.audio.graph")
  private let voiceActivationProcessor = VoiceActivationProcessor(
    frameMillis: 20,
    sensitivity: 0.55
  )

  private var captureConverter: AVAudioConverter?
  private var captureInputFormatDescription: String?
  private var opusEncoder: AVAudioConverter?
  private var opusDecoderCache = [String: AVAudioConverter]()
  private var activeConnectionManager: ConnectionManager?
  private var outboundStreams = [EndpointID: BoundOutputStream]()
  private var transmitEndpointIDs = Set<EndpointID>()
  private var inboundReaders = [EndpointID: IncomingAudioStreamReader]()
  private var inboundBuffers = [EndpointID: PeerAudioBuffer]()
  private var inboundSpeechActivity = [EndpointID: SpeechActivityTracker]()
  private var pendingCaptureData = Data()
  private var preRollFrames = [Data]()
  private var isConfigured = false
  private var queuedPlaybackFrames: AVAudioFramePosition = 0
  private var teardownWorkItem: DispatchWorkItem?
  private var mixerTimer: DispatchSourceTimer?
  private var transmissionMode = TransmissionMode.manual
  private var isVoiceActivationEnabled = false
  private var isVoiceActivationArmedState = false
  private var lastReportedTransmitState: Bool?
  private let audioGraphQueueKey = DispatchSpecificKey<Void>()

  var isTransmitting: Bool {
    withStateLock { !outboundStreams.isEmpty }
  }

  var isVoiceActivationArmed: Bool {
    withStateLock { isVoiceActivationArmedState }
  }

  private lazy var captureFormat: AVAudioFormat? = Self.makeAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: streamSampleRate,
    channels: 1
  )

  private lazy var playbackFormat: AVAudioFormat? = Self.makeAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: streamSampleRate,
    channels: 1
  )

  private lazy var opusFormat: AVAudioFormat? = Self.makeOpusFormat(
    sampleRate: streamSampleRate,
    channels: 1,
    framesPerPacket: frameSamples
  )

  init(
    streamSampleRate: Double,
    codecForEndpoint: @escaping (EndpointID) -> String,
    prepareAudioSession: @escaping () throws -> Void,
    deactivateAudioSession: @escaping () -> Void,
    onError: @escaping (String) -> Void,
    onTransmitStateChanged: @escaping (Bool, String) -> Void,
    onPeerSpeakingChanged: @escaping (EndpointID, Bool) -> Void
  ) {
    self.streamSampleRate = streamSampleRate
    self.frameSamples = Int((streamSampleRate * 0.02).rounded())
    self.frameByteCount = self.frameSamples * MemoryLayout<Int16>.stride
    self.codecForEndpoint = codecForEndpoint
    self.prepareAudioSession = prepareAudioSession
    self.deactivateAudioSession = deactivateAudioSession
    self.onError = onError
    self.onTransmitStateChanged = onTransmitStateChanged
    self.onPeerSpeakingChanged = onPeerSpeakingChanged
    transmitQueue.setSpecific(key: transmitQueueKey, value: ())
    audioGraphQueue.setSpecific(key: audioGraphQueueKey, value: ())
  }

  func syncTransmittingEndpoints(
    _ endpoints: Set<EndpointID>,
    connectionManager: ConnectionManager
  ) throws {
    cancelTeardown()
    try prepareAudioGraph()
    try configureAudioEngineIfNeeded()
    withStateLock {
      activeConnectionManager = connectionManager
      transmitEndpointIDs = endpoints
    }

    if endpoints.isEmpty && transmissionMode == .manual {
      stopTransmitting()
      return
    }

    let endpointsToRemove = withStateLock {
      outboundStreams.keys.filter { !endpoints.contains($0) }
    }
    endpointsToRemove.forEach(removeOutboundStream)

    let shouldOpenStreams = transmissionMode == .manual || isTransmitting
    if shouldOpenStreams {
      let endpointsToAdd = withStateLock {
        endpoints.filter { outboundStreams[$0] == nil }
      }
      for endpointID in endpointsToAdd {
        try addOutboundStream(endpointID, connectionManager: connectionManager)
      }
    }

    try ensureCaptureTapRunning()
  }

  func setVoiceActivation(enabled: Bool, sensitivity: Double) {
    withStateLock {
      isVoiceActivationEnabled = enabled
      transmissionMode = enabled ? .voiceActivated : .manual
      voiceActivationProcessor.updateSensitivity(sensitivity)
      isVoiceActivationArmedState = enabled
      if !enabled {
        voiceActivationProcessor.resetSpeechState()
        preRollFrames.removeAll(keepingCapacity: false)
      }
    }
    if !enabled {
      stopTransmitting()
    }
  }

  func stopTransmitting() {
    if !isVoiceActivationEnabled {
      syncOnAudioGraphQueue {
        audioEngine.inputNode.removeTap(onBus: 0)
      }
    }
    let streamsToClose = withStateLock {
      let streams = Array(outboundStreams.values)
      outboundStreams.removeAll()
      if !isVoiceActivationEnabled {
        transmitEndpointIDs.removeAll()
        captureConverter = nil
        opusEncoder = nil
      }
      return streams
    }
    streamsToClose.forEach { $0.close() }
    updateTransmitStateIfNeeded(
      activeMessage: "Streaming microphone audio to \(transmitEndpointIDs.count) peer(s).",
      inactiveMessage: "Transmit is idle."
    )
    clearPendingCaptureData()
    tearDownAudioIfIdle()
  }

  func handleIncomingStream(
    _ stream: InputStream,
    from endpointID: EndpointID
  ) {
    do {
      cancelTeardown()
      try prepareAudioGraph()
      try configureAudioEngineIfNeeded()

      let previousReader = withStateLock { inboundReaders[endpointID] }
      previousReader?.stop()

      let buffer = PeerAudioBuffer(frameByteCount: frameByteCount)
      let reader = IncomingAudioStreamReader(
        stream: stream,
        bufferSize: frameByteCount,
        queue: receiveQueue,
        onAudioData: { [weak self] data in
          guard let self else { return }
          let codec = self.codecForEndpoint(endpointID)
          let decodedData = self.decodeIncomingPacket(data, codec: codec, endpointID: endpointID)
          guard let decodedData else { return }
          self.withStateLock {
            self.inboundBuffers[endpointID]?.append(decodedData)
            if let isSpeaking = self.inboundSpeechActivity[endpointID]?.process(decodedData) {
              self.onPeerSpeakingChanged(endpointID, isSpeaking)
            }
          }
        },
        onFinished: { [weak self] in
          self?.stopIncomingAudio(from: endpointID)
        }
      )
      withStateLock {
        inboundBuffers[endpointID] = buffer
        inboundSpeechActivity[endpointID] = SpeechActivityTracker(
          frameMillis: 20,
          sensitivity: 0.55
        )
        inboundReaders[endpointID] = reader
      }
      try ensurePlaybackRunning()
      ensureMixerTimer()
      reader.start()
    } catch {
      onError(error.localizedDescription)
    }
  }

  func stopIncomingAudio(from endpointID: EndpointID) {
    let readerToStop = withStateLock {
      let reader = inboundReaders.removeValue(forKey: endpointID)
      inboundBuffers.removeValue(forKey: endpointID)
      inboundSpeechActivity.removeValue(forKey: endpointID)
      return reader
    }
    readerToStop?.stop()
    onPeerSpeakingChanged(endpointID, false)
    tearDownAudioIfIdle()
  }

  func handleEndpointDisconnected(_ endpointID: EndpointID) {
    removeOutboundStream(endpointID)
    stopIncomingAudio(from: endpointID)
  }

  func stopAll() {
    stopTransmitting()
    let state = withStateLock {
      let readers = Array(inboundReaders.values)
      inboundReaders.removeAll()
      inboundBuffers.removeAll()
      inboundSpeechActivity.removeAll()
      let timer = mixerTimer
      mixerTimer = nil
      queuedPlaybackFrames = 0
      return (readers, timer)
    }
    state.0.forEach { $0.stop() }
    state.1?.cancel()
    tearDownAudioIfIdle(forceDeactivate: true)
  }

  private func addOutboundStream(
    _ endpointID: EndpointID,
    connectionManager: ConnectionManager
  ) throws {
    let streams = try makeBoundStreams()
    streams.input.open()
    streams.output.open()
    withStateLock {
      outboundStreams[endpointID] = BoundOutputStream(
        input: streams.input,
        output: streams.output
      )
    }
    updateTransmitStateIfNeeded(
      activeMessage: "Streaming microphone audio to \(transmitEndpointIDs.count) peer(s).",
      inactiveMessage: "Transmit is idle."
    )
    connectionManager.startStream(streams.input, to: [endpointID])
  }

  private func removeOutboundStream(_ endpointID: EndpointID) {
    let result = withStateLock {
      let stream = outboundStreams.removeValue(forKey: endpointID)
      let isEmpty = outboundStreams.isEmpty && !isVoiceActivationEnabled
      if isEmpty {
        captureConverter = nil
      }
      return (stream, isEmpty)
    }
    result.0?.close()
    if result.1 {
      syncOnAudioGraphQueue {
        audioEngine.inputNode.removeTap(onBus: 0)
      }
      clearPendingCaptureData()
    }
    updateTransmitStateIfNeeded(
      activeMessage: "Streaming microphone audio to \(transmitEndpointIDs.count) peer(s).",
      inactiveMessage: "Transmit is idle."
    )
  }

  private func configureAudioEngineIfNeeded() throws {
    let shouldConfigure = withStateLock {
      if isConfigured {
        return false
      }
      isConfigured = true
      return true
    }
    guard shouldConfigure else {
      return
    }

    try syncOnAudioGraphQueue {
      audioEngine.attach(playerNode)
      guard let playbackFormat else {
        throw NearbyAudioError.playbackFormatCreationFailed
      }
      audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
    }
  }

  private func prepareAudioGraph() throws {
    try prepareAudioSession()
  }

  private func ensureCaptureTapRunning() throws {
    try syncOnAudioGraphQueue {
      let inputNode = audioEngine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard let captureFormat else {
        throw NearbyAudioError.captureFormatCreationFailed
      }
      let formatDescription = Self.describeAudioFormat(inputFormat)
      let needsConverter = withStateLock {
        captureConverter == nil || captureInputFormatDescription != formatDescription
      }
      if needsConverter {
        guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
          throw NearbyAudioError.converterCreationFailed
        }
        withStateLock {
          captureConverter = converter
          captureInputFormatDescription = formatDescription
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
          onBus: 0,
          bufferSize: AVAudioFrameCount(frameSamples),
          format: nil
        ) { [weak self] buffer, _ in
          self?.writeCapturedAudio(buffer)
        }
      }

      if !audioEngine.isRunning {
        audioEngine.prepare()
        try audioEngine.start()
      }
    }
  }

  private func ensurePlaybackRunning() throws {
    try syncOnAudioGraphQueue {
      if !audioEngine.isRunning {
        audioEngine.prepare()
        try audioEngine.start()
      }
      if !playerNode.isPlaying {
        playerNode.play()
      }
    }
  }

  private func ensureMixerTimer() {
    let shouldCreateTimer = withStateLock { mixerTimer == nil }
    guard shouldCreateTimer else {
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: playbackQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.mixAndSchedulePlayback()
    }
    withStateLock {
      mixerTimer = timer
    }
    timer.resume()
  }

  private func writeCapturedAudio(_ buffer: AVAudioPCMBuffer) {
    let converter = withStateLock { captureConverter }
    guard let captureFormat else {
      onError(NearbyAudioError.captureFormatCreationFailed.localizedDescription)
      return
    }
    let shouldCapture = withStateLock {
      transmissionMode == .voiceActivated || !outboundStreams.isEmpty
    }
    guard shouldCapture, let converter else {
      return
    }

    let outputCapacity = AVAudioFrameCount(
      (Double(buffer.frameLength) * captureFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
    )
    guard
      outputCapacity > 0,
      let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: captureFormat,
        frameCapacity: max(outputCapacity, 1)
      )
    else {
      return
    }

    var error: NSError?
    var hasProvidedInput = false
    let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
      if hasProvidedInput {
        outStatus.pointee = .noDataNow
        return nil
      }

      hasProvidedInput = true
      outStatus.pointee = .haveData
      return buffer
    }

    guard error == nil, status != .error, convertedBuffer.frameLength > 0 else {
      onError(
        error?.localizedDescription ?? NearbyAudioError.captureConversionFailed.localizedDescription
      )
      return
    }

    guard let channelData = convertedBuffer.int16ChannelData else {
      return
    }

    let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.stride
    let audioData = Data(bytes: channelData[0], count: byteCount)
    transmitQueue.async { [weak self] in
      self?.appendAndBroadcastCapturedAudio(audioData)
    }
  }

  private func appendAndBroadcastCapturedAudio(_ data: Data) {
    guard !data.isEmpty else {
      return
    }

    let frames = withStateLock { () -> [Data] in
      pendingCaptureData.append(data)
      var frames = [Data]()
      while pendingCaptureData.count >= frameByteCount {
        let frame = pendingCaptureData.prefix(frameByteCount)
        frames.append(Data(frame))
        pendingCaptureData.removeFirst(frameByteCount)
      }
      return frames
    }
    frames.forEach(handleCapturedFrame)
  }

  private func clearPendingCaptureData() {
    withStateLock {
      pendingCaptureData.removeAll(keepingCapacity: false)
    }
  }

  private func handleCapturedFrame(_ data: Data) {
    if transmissionMode == .manual {
      if isTransmitting {
        broadcast(data)
      }
      return
    }

    let decision = withStateLock { () -> VoiceActivationDecision in
      preRollFrames.append(data)
      if preRollFrames.count > 10 {
        preRollFrames.removeFirst(preRollFrames.count - 10)
      }
      return voiceActivationProcessor.process(data)
    }

    if decision.shouldStartTransmitting {
      let state = withStateLock {
        (transmitEndpointIDs, activeConnectionManager, preRollFrames)
      }
      if !state.0.isEmpty, let connectionManager = state.1 {
        do {
          try openVoiceActivationStreams(state.0, connectionManager: connectionManager)
        } catch {
          onError(error.localizedDescription)
        }
        state.2.forEach(broadcast)
      }
    }

    if isTransmitting {
      broadcast(data)
    }

    if decision.shouldStopTransmitting {
      stopTransmitting()
    }
  }

  private func broadcast(_ data: Data) {
    let streams = withStateLock {
      Array(outboundStreams.map { ($0.key, $0.value) })
    }
    for (endpointID, boundStream) in streams {
      let codec = codecForEndpoint(endpointID)
      guard let payload = encodeOutgoingFrame(data, codec: codec) else {
        continue
      }
      let succeeded = writeToOutputStream(payload, stream: boundStream.output)
      if !succeeded {
        removeOutboundStream(endpointID)
      }
    }
  }

  private func openVoiceActivationStreams(
    _ endpoints: Set<EndpointID>,
    connectionManager: ConnectionManager
  ) throws {
    let endpointsToAdd = withStateLock {
      endpoints.filter { outboundStreams[$0] == nil }
    }
    for endpointID in endpointsToAdd {
      try addOutboundStream(endpointID, connectionManager: connectionManager)
    }
    updateTransmitStateIfNeeded(
      activeMessage: "Voice activation opened transmit to \(endpoints.count) peer(s).",
      inactiveMessage: "Transmit is idle."
    )
  }

  private func updateTransmitStateIfNeeded(
    activeMessage: String,
    inactiveMessage: String
  ) {
    let isTransmittingNow = isTransmitting
    if lastReportedTransmitState == isTransmittingNow {
      return
    }
    lastReportedTransmitState = isTransmittingNow
    onTransmitStateChanged(
      isTransmittingNow,
      isTransmittingNow ? activeMessage : inactiveMessage
    )
  }

  private func writeToOutputStream(_ data: Data, stream: OutputStream) -> Bool {
    var packetLength = UInt32(data.count).bigEndian
    let packet = Data(bytes: &packetLength, count: MemoryLayout<UInt32>.size) + data
    return packet.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return false
      }

      var totalWritten = 0
      while totalWritten < packet.count {
        let bytesWritten = stream.write(
          baseAddress.advanced(by: totalWritten),
          maxLength: packet.count - totalWritten
        )
        if bytesWritten <= 0 {
          return false
        }
        totalWritten += bytesWritten
      }
      return true
    }
  }

  private func mixAndSchedulePlayback() {
    let buffers = withStateLock { Array(inboundBuffers) }
    var frames = [EndpointID: Data]()
    for (endpointID, buffer) in buffers {
      guard let frame = buffer.drainFrame(frameByteCount: frameByteCount) else {
        continue
      }
      frames[endpointID] = frame
    }
    guard !frames.isEmpty else {
      return
    }

    guard
      let playbackFormat,
      let playbackBuffer = AVAudioPCMBuffer(
        pcmFormat: playbackFormat,
        frameCapacity: AVAudioFrameCount(frameSamples)
      ),
      let channelData = playbackBuffer.floatChannelData
    else {
      return
    }

    playbackBuffer.frameLength = AVAudioFrameCount(frameSamples)
    let output = channelData[0]
    for index in 0..<frameSamples {
      var mixedValue: Float = 0
      for frame in frames.values {
        let sampleOffset = index * 2
        if sampleOffset + 1 < frame.count {
          let lower = UInt16(frame[frame.index(frame.startIndex, offsetBy: sampleOffset)])
          let upper = UInt16(frame[frame.index(frame.startIndex, offsetBy: sampleOffset + 1)])
          let sample = Int16(bitPattern: lower | (upper << 8))
          mixedValue += Float(sample) / Float(Int16.max)
        }
      }
      output[index] = max(-1, min(1, mixedValue))
    }

    let scheduledFrames = AVAudioFramePosition(playbackBuffer.frameLength)
    withStateLock {
      queuedPlaybackFrames += scheduledFrames
    }
    playerNode.scheduleBuffer(playbackBuffer) { [weak self] in
      self?.playbackQueue.async {
        guard let self else { return }
        self.withStateLock {
          self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - scheduledFrames)
        }
      }
    }
  }

  private func tearDownAudioIfIdle(forceDeactivate: Bool = false) {
    let isIdle = withStateLock { outboundStreams.isEmpty && inboundReaders.isEmpty }
    guard forceDeactivate || isIdle else {
      return
    }

    if !forceDeactivate {
      scheduleTeardown()
      return
    }

    performTeardown()
  }

  private func scheduleTeardown() {
    cancelTeardown()
    let workItem = DispatchWorkItem { [weak self] in
      self?.performTeardown()
    }
    withStateLock {
      teardownWorkItem = workItem
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
  }

  private func cancelTeardown() {
    let workItem = withStateLock {
      let existing = teardownWorkItem
      teardownWorkItem = nil
      return existing
    }
    workItem?.cancel()
  }

  private func performTeardown() {
    cancelTeardown()
    let isIdle = withStateLock { outboundStreams.isEmpty && inboundReaders.isEmpty }
    guard isIdle else {
      return
    }

    syncOnAudioGraphQueue {
      audioEngine.inputNode.removeTap(onBus: 0)
      playerNode.stop()
      if audioEngine.isRunning {
        audioEngine.stop()
      }
    }
    withStateLock {
      queuedPlaybackFrames = 0
    }
    let timer = withStateLock {
      let timer = mixerTimer
      mixerTimer = nil
      captureConverter = nil
      captureInputFormatDescription = nil
      opusEncoder = nil
      opusDecoderCache.removeAll()
      return timer
    }
    timer?.cancel()
    clearPendingCaptureData()
    deactivateAudioSession()
  }

  private func withStateLock<T>(_ body: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body()
  }

  private func syncOnAudioGraphQueue<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: audioGraphQueueKey) != nil {
      return try body()
    }
    return try audioGraphQueue.sync(execute: body)
  }

  private func makeBoundStreams() throws -> (input: InputStream, output: OutputStream) {
    var readStream: Unmanaged<CFReadStream>?
    var writeStream: Unmanaged<CFWriteStream>?
    CFStreamCreateBoundPair(nil, &readStream, &writeStream, 8_192)

    guard
      let inputStream = readStream?.takeRetainedValue(),
      let outputStream = writeStream?.takeRetainedValue()
    else {
      throw NearbyAudioError.streamCreationFailed
    }

    return (inputStream as InputStream, outputStream as OutputStream)
  }

  private static func makeAudioFormat(
    commonFormat: AVAudioCommonFormat,
    sampleRate: Double,
    channels: AVAudioChannelCount
  ) -> AVAudioFormat? {
    AVAudioFormat(
      commonFormat: commonFormat,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: false
    )
  }

  private static func makeOpusFormat(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    framesPerPacket: Int
  ) -> AVAudioFormat? {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatOpus,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: UInt32(framesPerPacket),
      mBytesPerFrame: 0,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 0,
      mReserved: 0
    )
    return AVAudioFormat(streamDescription: &streamDescription)
  }

  private static func describeAudioFormat(_ format: AVAudioFormat) -> String {
    "\(format.commonFormat.rawValue)|\(format.sampleRate)|\(format.channelCount)|\(format.isInterleaved)"
  }

  private func encodeOutgoingFrame(_ data: Data, codec: String) -> Data? {
    guard codec == "opus" else {
      return data
    }
    return encodeOpusFrame(data)
  }

  private func decodeIncomingPacket(_ data: Data, codec: String, endpointID: EndpointID) -> Data? {
    guard codec == "opus" else {
      return data
    }
    return decodeOpusPacket(data, endpointID: endpointID)
  }

  private func encodeOpusFrame(_ data: Data) -> Data? {
    guard
      let captureFormat,
      let opusFormat,
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: captureFormat,
        frameCapacity: AVAudioFrameCount(frameSamples)
      ),
      let channelData = pcmBuffer.int16ChannelData
    else {
      return nil
    }
    pcmBuffer.frameLength = AVAudioFrameCount(frameSamples)
    data.copyBytes(
      to: UnsafeMutableBufferPointer(
        start: channelData[0],
        count: min(frameSamples, data.count / MemoryLayout<Int16>.stride)
      )
    )

    if opusEncoder == nil {
      opusEncoder = AVAudioConverter(from: captureFormat, to: opusFormat)
    }
    guard let opusEncoder else { return nil }
    let maximumPacketSize = max(Int(opusEncoder.maximumOutputPacketSize), 512)
    let compressedBuffer = AVAudioCompressedBuffer(
      format: opusFormat,
      packetCapacity: 1,
      maximumPacketSize: maximumPacketSize
    )

    var error: NSError?
    var hasProvidedInput = false
    let status = opusEncoder.convert(to: compressedBuffer, error: &error) { _, outStatus in
      if hasProvidedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasProvidedInput = true
      outStatus.pointee = .haveData
      return pcmBuffer
    }
    guard error == nil, status != .error, compressedBuffer.byteLength > 0 else {
      onError("Opus encode failed on iOS: \(error?.localizedDescription ?? "converter returned no packets")")
      return nil
    }
    return Data(
      bytes: compressedBuffer.data.assumingMemoryBound(to: UInt8.self),
      count: Int(compressedBuffer.byteLength)
    )
  }

  private func decodeOpusPacket(_ data: Data, endpointID: EndpointID) -> Data? {
    guard
      let captureFormat,
      let opusFormat
    else {
      return nil
    }

    let cacheKey = endpointID
    if opusDecoderCache[cacheKey] == nil {
      opusDecoderCache[cacheKey] = AVAudioConverter(from: opusFormat, to: captureFormat)
    }
    guard let decoder = opusDecoderCache[cacheKey] else { return nil }
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: captureFormat,
        frameCapacity: AVAudioFrameCount(frameSamples * 2)
      )
    else {
      return nil
    }
    let compressedBuffer = AVAudioCompressedBuffer(
      format: opusFormat,
      packetCapacity: 1,
      maximumPacketSize: data.count
    )

    compressedBuffer.byteLength = UInt32(data.count)
    compressedBuffer.packetCount = 1
    if let packetDescriptions = compressedBuffer.packetDescriptions {
      packetDescriptions.pointee.mDataByteSize = UInt32(data.count)
      packetDescriptions.pointee.mStartOffset = 0
      packetDescriptions.pointee.mVariableFramesInPacket = UInt32(frameSamples)
    }
    data.copyBytes(
      to: UnsafeMutableBufferPointer(
        start: compressedBuffer.data.assumingMemoryBound(to: UInt8.self),
        count: data.count
      )
    )

    var error: NSError?
    var hasProvidedInput = false
    let status = decoder.convert(to: outputBuffer, error: &error) { _, outStatus in
      if hasProvidedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasProvidedInput = true
      outStatus.pointee = .haveData
      return compressedBuffer
    }
    guard error == nil, status != .error, outputBuffer.frameLength > 0 else {
      onError("Opus decode failed on iOS: \(error?.localizedDescription ?? "converter returned no PCM frames")")
      return nil
    }
    guard let channelData = outputBuffer.int16ChannelData else {
      return nil
    }
    let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.stride
    return Data(bytes: channelData[0], count: byteCount)
  }
}

private final class BoundOutputStream {
  let input: InputStream
  let output: OutputStream

  init(input: InputStream, output: OutputStream) {
    self.input = input
    self.output = output
  }

  func close() {
    input.close()
    output.close()
  }
}

private final class PeerAudioBuffer {
  private let frameByteCount: Int
  private let lock = NSLock()
  private var data = Data()

  init(frameByteCount: Int) {
    self.frameByteCount = frameByteCount
  }

  func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    let maxBufferBytes = frameByteCount * 6
    if data.count > maxBufferBytes {
      data.removeFirst(data.count - maxBufferBytes)
    }
    lock.unlock()
  }

  func drainFrame(frameByteCount: Int) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard data.count >= frameByteCount else {
      return nil
    }

    let frame = data.prefix(frameByteCount)
    data.removeFirst(frameByteCount)
    return Data(frame)
  }
}

private final class IncomingAudioStreamReader {
  private let stream: InputStream
  private let bufferSize: Int
  private let queue: DispatchQueue
  private let onAudioData: (Data) -> Void
  private let onFinished: () -> Void
  private let stateLock = NSLock()
  private var pendingData = Data()
  private var stopped = false

  init(
    stream: InputStream,
    bufferSize: Int,
    queue: DispatchQueue,
    onAudioData: @escaping (Data) -> Void,
    onFinished: @escaping () -> Void
  ) {
    self.stream = stream
    self.bufferSize = max(bufferSize, 1)
    self.queue = queue
    self.onAudioData = onAudioData
    self.onFinished = onFinished
  }

  func start() {
    queue.async { [weak self] in
      self?.readLoop()
    }
  }

  func stop() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()
    stream.close()
  }

  private func readLoop() {
    stream.open()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

    defer {
      buffer.deallocate()
      stream.close()
      onFinished()
    }

    while !isStopped {
      let bytesRead = stream.read(buffer, maxLength: bufferSize)
      if bytesRead > 0 {
        appendIncomingData(Data(bytes: buffer, count: bytesRead))
        continue
      }

      if bytesRead == 0 {
        break
      }

      break
    }
  }

  private var isStopped: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }

  private func appendIncomingData(_ chunk: Data) {
    stateLock.lock()
    pendingData.append(chunk)
    var packets = [Data]()
    while pendingData.count >= MemoryLayout<UInt32>.size {
      let packetLength =
        (Int(pendingData[pendingData.startIndex]) << 24)
        | (Int(pendingData[pendingData.startIndex + 1]) << 16)
        | (Int(pendingData[pendingData.startIndex + 2]) << 8)
        | Int(pendingData[pendingData.startIndex + 3])
      if packetLength <= 0 || packetLength > 64_000 {
        pendingData.removeAll(keepingCapacity: false)
        break
      }
      let totalLength = MemoryLayout<UInt32>.size + packetLength
      if pendingData.count < totalLength {
        break
      }
      let packet = pendingData.subdata(in: MemoryLayout<UInt32>.size..<totalLength)
      packets.append(packet)
      pendingData.removeFirst(totalLength)
    }
    stateLock.unlock()
    packets.forEach(onAudioData)
  }
}

private enum TransmissionMode {
  case manual
  case voiceActivated
}

private struct VoiceActivationDecision {
  let shouldStartTransmitting: Bool
  let shouldStopTransmitting: Bool
}

private final class SpeechActivityTracker {
  private let processor: VoiceActivationProcessor
  private var isSpeaking = false

  init(frameMillis: Int, sensitivity: Double) {
    processor = VoiceActivationProcessor(frameMillis: frameMillis, sensitivity: sensitivity)
  }

  func process(_ frame: Data) -> Bool {
    let decision = processor.process(frame)
    if decision.shouldStartTransmitting {
      isSpeaking = true
    }
    if decision.shouldStopTransmitting {
      isSpeaking = false
    }
    return isSpeaking
  }
}

private final class VoiceActivationProcessor {
  private let frameMillis: Int
  private var dynamicFloor: Double = 0.008
  private var attackFrames = 0
  private var releaseFrames = 0
  private var isSpeechActive = false
  private var sensitivity: Double

  init(frameMillis: Int, sensitivity: Double) {
    self.frameMillis = frameMillis
    self.sensitivity = sensitivity
  }

  func updateSensitivity(_ sensitivity: Double) {
    self.sensitivity = min(1.0, max(0.0, sensitivity))
  }

  func resetSpeechState() {
    attackFrames = 0
    releaseFrames = 0
    isSpeechActive = false
  }

  func process(_ frame: Data) -> VoiceActivationDecision {
    let rms = frameRms(frame)
    let attackBoost = 0.02 - (sensitivity * 0.012)
    let releaseBoost = attackBoost * 0.55
    let startThreshold = max(dynamicFloor * 2.1, dynamicFloor + attackBoost)
    let stopThreshold = max(dynamicFloor * 1.45, dynamicFloor + releaseBoost)

    if !isSpeechActive || rms < stopThreshold {
      dynamicFloor = (dynamicFloor * 0.985) + (rms * 0.015)
    } else {
      dynamicFloor = (dynamicFloor * 0.998) + (rms * 0.002)
    }

    var shouldStart = false
    var shouldStop = false
    if !isSpeechActive {
      if rms >= startThreshold {
        attackFrames += 1
        if attackFrames >= 3 {
          attackFrames = 0
          releaseFrames = 0
          isSpeechActive = true
          shouldStart = true
        }
      } else {
        attackFrames = 0
      }
    } else {
      if rms < stopThreshold {
        releaseFrames += 1
        if releaseFrames * frameMillis >= 700 {
          releaseFrames = 0
          attackFrames = 0
          isSpeechActive = false
          shouldStop = true
        }
      } else {
        releaseFrames = 0
      }
    }

    return VoiceActivationDecision(
      shouldStartTransmitting: shouldStart,
      shouldStopTransmitting: shouldStop
    )
  }

  private func frameRms(_ frame: Data) -> Double {
    guard !frame.isEmpty else {
      return 0
    }

    var sumSquares = 0.0
    var sampleCount = 0
    frame.withUnsafeBytes { rawBuffer in
      guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
        return
      }
      let count = rawBuffer.count / MemoryLayout<Int16>.stride
      sampleCount = count
      for index in 0..<count {
        let normalized = Double(samples[index]) / 32768.0
        sumSquares += normalized * normalized
      }
    }
    guard sampleCount > 0 else {
      return 0
    }
    return Foundation.sqrt(sumSquares / Double(sampleCount))
  }
}

private enum NearbyAudioError: LocalizedError {
  case captureFormatCreationFailed
  case playbackFormatCreationFailed
  case converterCreationFailed
  case captureConversionFailed
  case streamCreationFailed

  var errorDescription: String? {
    switch self {
    case .captureFormatCreationFailed:
      return "Unable to prepare the iOS microphone capture format for Nearby audio."
    case .playbackFormatCreationFailed:
      return "Unable to prepare the iOS playback format for Nearby audio."
    case .converterCreationFailed:
      return "Unable to prepare the iOS audio format converter for Nearby audio."
    case .captureConversionFailed:
      return "Failed to convert microphone audio into Nearby PCM frames."
    case .streamCreationFailed:
      return "Failed to create a local audio stream for Nearby transmission."
    }
  }
}
#endif
