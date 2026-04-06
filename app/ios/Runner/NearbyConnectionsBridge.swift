import Flutter
import AVFoundation
import Foundation

#if canImport(NearbyConnections)
import NearbyConnections
#endif

final class NearbyConnectionsBridge: NSObject, FlutterStreamHandler {
  private let serviceID = "com.nakamasync.app.walkie"
  private var roomID: String?
  private var displayName = "Nakama Sync iPhone"
  private var eventSink: FlutterEventSink?

  #if canImport(NearbyConnections)
  private lazy var connectionManager = ConnectionManager(
    serviceID: serviceID,
    strategy: .cluster
  )
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var connectedEndpoints = Set<EndpointID>()
  private var endpointRoomMatches = [EndpointID: Bool]()
  private var endpointAudioConfigs = [EndpointID: NearbyAudioConfig]()
  private var peerSessions = [EndpointID: PeerSession]()
  private var isDiscovering = false
  private var isPushToTalkActive = false
  private var discoveryStopWorkItem: DispatchWorkItem?
  private lazy var audioController = NearbyAudioController(
    onError: { [weak self] message in
      self?.emit(event: "error", message: message)
    },
    onPeerSpeakingChanged: { [weak self] endpointID, isSpeaking in
      self?.updatePeerSpeaking(endpointID, isSpeaking: isSpeaking)
    }
  )
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
    emit(
      event: "session_started",
      message: "Opening room and starting Nearby advertising.",
      extra: ["isDiscovering": true]
    )

    let context = endpointContextData()

    let advertiser = Advertiser(connectionManager: connectionManager)
    advertiser.delegate = self
    advertiser.startAdvertising(using: context)
    self.advertiser = advertiser

    let discoverer = Discoverer(connectionManager: connectionManager)
    discoverer.delegate = self
    self.discoverer = discoverer
    startDiscoveryBurst(message: "Scanning briefly for nearby peers in this room.")

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

    if isActive {
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
          self.emit(event: "error", message: "Microphone permission is required for push-to-talk.")
          result(
            FlutterError(
              code: "microphone_permission_denied",
              message: "Microphone permission is required for push-to-talk.",
              details: nil
            )
          )
          return
        }

        do {
          self.isPushToTalkActive = true
          try self.audioController.syncTransmittingEndpoints(
            Set(validatedEndpoints),
            connectionManager: self.connectionManager
          )
          self.emit(
            event: "transmit_state",
            message: "Streaming microphone audio to \(validatedEndpoints.count) peer(s).",
            extra: [
              "isTransmitting": true,
              "audioSampleRate": NearbyAudioConfig.defaultStreamSampleRate
            ]
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
    isPushToTalkActive = false
    audioController.stopAll()
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    advertiser = nil
    discoverer = nil
    connectedEndpoints.removeAll()
    endpointRoomMatches.removeAll()
    endpointAudioConfigs.removeAll()
    peerSessions.removeAll()
    discoveryStopWorkItem?.cancel()
    discoveryStopWorkItem = nil
    isDiscovering = false
    #endif
  }

  private func emit(event: String, message: String, extra: [String: Any] = [:]) {
    var payload: [String: Any] = [
      "event": event,
      "message": message,
      "roomId": roomID as Any,
      "connectedPeers": connectedEndpoints.filter { endpointRoomMatches[$0] == true }.count,
      "isDiscovering": isDiscovering,
      "isReceivingAudio": peerSessions.values.contains { $0.isConnected && $0.isSpeaking },
      "isTransmitting": audioController.isTransmitting,
      "peers": peerSessions.values
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
          ]
        }
    ]
    extra.forEach { payload[$0.key] = $0.value }
    eventSink?(payload)
  }

  private func upsertPeer(
    endpointID: EndpointID,
    displayName: String?,
    isConnected: Bool? = nil,
    isSpeaking: Bool? = nil,
    streamSampleRate: Int? = nil
  ) {
    let existing = peerSessions[endpointID]
    peerSessions[endpointID] = PeerSession(
      endpointID: endpointID,
      displayName: (displayName?.isEmpty == false ? displayName : existing?.displayName) ?? "Nearby peer",
      isConnected: isConnected ?? existing?.isConnected ?? false,
      isSpeaking: isSpeaking ?? existing?.isSpeaking ?? false,
      streamSampleRate: streamSampleRate ?? existing?.streamSampleRate ?? NearbyAudioConfig.defaultStreamSampleRate
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
      endpointRoomMatches[endpointID] = false
      emit(event: "error", message: "Ignoring Nearby peer from a different room.")
      connectionRequestHandler(false)
      return
    }

    let remoteName = remoteEndpoint.displayName ?? "nearby peer"
    upsertPeer(endpointID: endpointID, displayName: remoteName)
    emit(event: "connection_initiated", message: "Connection initiated with \(remoteName).")
    connectionRequestHandler(true)
  }
}

extension NearbyConnectionsBridge: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    guard roomMatches(parseEndpointContext(context).roomID) else {
      return
    }
    guard !connectedEndpoints.contains(endpointID) else {
      return
    }

    let remoteEndpoint = parseEndpointContext(context)
    endpointAudioConfigs[endpointID] = remoteEndpoint.audioConfig
    let remoteName = remoteEndpoint.displayName ?? "nearby peer"
    upsertPeer(endpointID: endpointID, displayName: remoteName)
    emit(event: "peer_discovered", message: "Found nearby peer \(remoteName).")
    discoverer.requestConnection(to: endpointID, using: endpointContextData())
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    connectedEndpoints.remove(endpointID)
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
    startDiscoveryBurst(message: "Peer left range. Scanning briefly for reconnects.")
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
      endpointRoomMatches[endpointID] = true
      upsertPeer(
        endpointID: endpointID,
        displayName: peerSessions[endpointID]?.displayName,
        isConnected: true,
        streamSampleRate: NearbyAudioConfig.defaultStreamSampleRate
      )
      sendHandshake(to: endpointID)
      if isPushToTalkActive {
        try? audioController.syncTransmittingEndpoints(
          Set(connectedEndpoints.filter { endpointRoomMatches[$0] == true }),
          connectionManager: connectionManager
        )
      }
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
      emit(event: "disconnected", message: "Nearby peer disconnected. Room remains open for new connections.")
      startDiscoveryBurst(message: "Peer disconnected. Scanning briefly for another nearby peer.")
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
  func endpointContextData() -> Data {
    let localAudioConfig = buildLocalAudioConfig()
    let payload: [String: Any] = [
      "roomId": roomID as Any,
      "displayName": displayName,
      "preferredSampleRate": localAudioConfig.preferredSampleRate,
      "supportedSampleRates": localAudioConfig.supportedSampleRates,
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
      "roomId": roomID as Any,
      "displayName": displayName,
      "preferredSampleRate": localAudioConfig.preferredSampleRate,
      "supportedSampleRates": localAudioConfig.supportedSampleRates,
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

    let peerRoomID = (json["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRoomID = roomID?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let normalizedRoomID, !normalizedRoomID.isEmpty, peerRoomID != normalizedRoomID {
      endpointRoomMatches[endpointID] = false
      connectedEndpoints.remove(endpointID)
      audioController.handleEndpointDisconnected(endpointID)
      removePeer(endpointID)
      emit(event: "error", message: "Nearby peer is advertising a different room.")
      disconnect(endpointID)
      return true
    }

    endpointRoomMatches[endpointID] = true
    endpointAudioConfigs[endpointID] = parseAudioConfig(json)
    let remoteName = (json["displayName"] as? String) ?? peerSessions[endpointID]?.displayName ?? "Nearby peer"
    upsertPeer(
      endpointID: endpointID,
      displayName: remoteName,
      isConnected: connectedEndpoints.contains(endpointID),
      streamSampleRate: NearbyAudioConfig.defaultStreamSampleRate
    )
    emit(
      event: "bytes_received",
      message: "Nearby peer metadata received.",
      extra: [
        "peerId": endpointID,
        "peerDisplayName": remoteName,
        "audioSampleRate": NearbyAudioConfig.defaultStreamSampleRate
      ]
    )
    return true
  }

  func roomMatches(_ peerRoomID: String?) -> Bool {
    let normalizedRoomID = roomID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPeerRoomID = peerRoomID?.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedRoomID == nil || normalizedRoomID?.isEmpty == true || normalizedPeerRoomID == normalizedRoomID
  }

  func parseEndpointContext(_ context: Data) -> NearbyEndpointContext {
    guard
      let json = try? JSONSerialization.jsonObject(with: context) as? [String: Any]
    else {
      return NearbyEndpointContext(
        roomID: nil,
        displayName: String(data: context, encoding: .utf8),
        audioConfig: NearbyAudioConfig()
      )
    }

    return NearbyEndpointContext(
      roomID: (json["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      displayName: json["displayName"] as? String,
      audioConfig: parseAudioConfig(json)
    )
  }

  func startDiscoveryBurst(message: String) {
    discoveryStopWorkItem?.cancel()
    isDiscovering = true
    discoverer?.startDiscovery()
    emit(event: "session_started", message: message, extra: ["isDiscovering": true])
    scheduleDiscoveryStop()
  }

  func scheduleDiscoveryStop() {
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.stopDiscovery()
      self.emit(event: "discovery_idle", message: "Room is open. Listening for incoming connections.")
    }
    discoveryStopWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
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

  struct NearbyEndpointContext {
    let roomID: String?
    let displayName: String?
    let audioConfig: NearbyAudioConfig
  }

  struct NearbyAudioConfig {
    let preferredSampleRate: Int
    let supportedSampleRates: [Int]

    init(
      preferredSampleRate: Int = Self.defaultStreamSampleRate,
      supportedSampleRates: [Int] = [Self.defaultStreamSampleRate]
    ) {
      self.supportedSampleRates = supportedSampleRates.isEmpty ? [Self.defaultStreamSampleRate] : supportedSampleRates
      self.preferredSampleRate = preferredSampleRate
    }

    static let defaultStreamSampleRate = 16_000
  }

  struct PeerSession {
    let endpointID: EndpointID
    let displayName: String
    var isConnected: Bool
    var isSpeaking: Bool
    let streamSampleRate: Int
  }

  func parseAudioConfig(_ json: [String: Any]) -> NearbyAudioConfig {
    NearbyAudioConfig(
      preferredSampleRate: NearbyAudioConfig.defaultStreamSampleRate,
      supportedSampleRates: [NearbyAudioConfig.defaultStreamSampleRate]
    )
  }

  func buildLocalAudioConfig() -> NearbyAudioConfig {
    NearbyAudioConfig(
      preferredSampleRate: NearbyAudioConfig.defaultStreamSampleRate,
      supportedSampleRates: [NearbyAudioConfig.defaultStreamSampleRate]
    )
  }
}

private final class NearbyAudioController {
  private let onError: (String) -> Void
  private let onPeerSpeakingChanged: (EndpointID, Bool) -> Void
  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let transmitQueue = DispatchQueue(label: "nakama_sync.nearby.audio.tx")
  private let receiveQueue = DispatchQueue(label: "nakama_sync.nearby.audio.rx")
  private let playbackQueue = DispatchQueue(label: "nakama_sync.nearby.audio.playback")
  private let session = AVAudioSession.sharedInstance()
  private let streamSampleRate = Double(16_000)
  private let frameSamples = 320
  private let frameByteCount = 640

  private var captureConverter: AVAudioConverter?
  private var outboundStreams = [EndpointID: BoundOutputStream]()
  private var inboundReaders = [EndpointID: IncomingAudioStreamReader]()
  private var inboundBuffers = [EndpointID: PeerAudioBuffer]()
  private var isConfigured = false
  private var queuedPlaybackFrames: AVAudioFramePosition = 0
  private var teardownWorkItem: DispatchWorkItem?
  private var mixerTimer: DispatchSourceTimer?

  var isTransmitting: Bool {
    !outboundStreams.isEmpty
  }

  private var captureFormat: AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: streamSampleRate,
      channels: 1,
      interleaved: false
    )!
  }

  private var playbackFormat: AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: streamSampleRate,
      channels: 1,
      interleaved: false
    )!
  }

  init(
    onError: @escaping (String) -> Void,
    onPeerSpeakingChanged: @escaping (EndpointID, Bool) -> Void
  ) {
    self.onError = onError
    self.onPeerSpeakingChanged = onPeerSpeakingChanged
  }

  func syncTransmittingEndpoints(
    _ endpoints: Set<EndpointID>,
    connectionManager: ConnectionManager
  ) throws {
    cancelTeardown()
    try prepareAudioGraph()
    try configureAudioEngineIfNeeded()

    if endpoints.isEmpty {
      stopTransmitting()
      return
    }

    outboundStreams.keys
      .filter { !endpoints.contains($0) }
      .forEach(removeOutboundStream)
    for endpointID in endpoints where outboundStreams[endpointID] == nil {
      try addOutboundStream(endpointID, connectionManager: connectionManager)
    }

    try ensureCaptureTapRunning()
  }

  func stopTransmitting() {
    audioEngine.inputNode.removeTap(onBus: 0)
    outboundStreams.values.forEach { $0.close() }
    outboundStreams.removeAll()
    captureConverter = nil
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
      inboundReaders[endpointID]?.stop()
      inboundBuffers[endpointID] = PeerAudioBuffer(frameByteCount: frameByteCount)
      let reader = IncomingAudioStreamReader(
        stream: stream,
        bufferSize: frameByteCount,
        queue: receiveQueue,
        onAudioData: { [weak self] data in
          self?.inboundBuffers[endpointID]?.append(data)
          self?.onPeerSpeakingChanged(endpointID, true)
        },
        onFinished: { [weak self] in
          self?.stopIncomingAudio(from: endpointID)
        }
      )
      inboundReaders[endpointID] = reader
      try ensurePlaybackRunning()
      ensureMixerTimer()
      reader.start()
    } catch {
      onError(error.localizedDescription)
    }
  }

  func stopIncomingAudio(from endpointID: EndpointID) {
    inboundReaders.removeValue(forKey: endpointID)?.stop()
    inboundBuffers.removeValue(forKey: endpointID)
    onPeerSpeakingChanged(endpointID, false)
    tearDownAudioIfIdle()
  }

  func handleEndpointDisconnected(_ endpointID: EndpointID) {
    removeOutboundStream(endpointID)
    stopIncomingAudio(from: endpointID)
  }

  func stopAll() {
    stopTransmitting()
    inboundReaders.values.forEach { $0.stop() }
    inboundReaders.removeAll()
    inboundBuffers.removeAll()
    mixerTimer?.cancel()
    mixerTimer = nil
    queuedPlaybackFrames = 0
    tearDownAudioIfIdle(forceDeactivate: true)
  }

  private func addOutboundStream(
    _ endpointID: EndpointID,
    connectionManager: ConnectionManager
  ) throws {
    let streams = try makeBoundStreams()
    streams.input.open()
    streams.output.open()
    outboundStreams[endpointID] = BoundOutputStream(
      input: streams.input,
      output: streams.output
    )
    connectionManager.startStream(streams.input, to: [endpointID])
  }

  private func removeOutboundStream(_ endpointID: EndpointID) {
    outboundStreams.removeValue(forKey: endpointID)?.close()
    if outboundStreams.isEmpty {
      audioEngine.inputNode.removeTap(onBus: 0)
      captureConverter = nil
    }
  }

  private func configureAudioSession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [
        .defaultToSpeaker,
        .allowBluetooth,
        .duckOthers,
      ]
    )
    try session.setPreferredSampleRate(streamSampleRate)
    try session.setPreferredIOBufferDuration(0.01)
    try session.setActive(true)
    try? session.overrideOutputAudioPort(.speaker)
  }

  private func configureAudioEngineIfNeeded() throws {
    guard !isConfigured else {
      return
    }

    audioEngine.attach(playerNode)
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
    isConfigured = true
  }

  private func prepareAudioGraph() throws {
    try configureAudioSession()
  }

  private func ensureCaptureTapRunning() throws {
    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    if captureConverter == nil {
      guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
        throw NearbyAudioError.converterCreationFailed
      }
      captureConverter = converter
      inputNode.removeTap(onBus: 0)
      inputNode.installTap(
        onBus: 0,
        bufferSize: AVAudioFrameCount(frameSamples),
        format: inputFormat
      ) { [weak self] buffer, _ in
        self?.writeCapturedAudio(buffer)
      }
    }

    if !audioEngine.isRunning {
      audioEngine.prepare()
      try audioEngine.start()
    }
  }

  private func ensurePlaybackRunning() throws {
    if !audioEngine.isRunning {
      audioEngine.prepare()
      try audioEngine.start()
    }
    if !playerNode.isPlaying {
      playerNode.play()
    }
  }

  private func ensureMixerTimer() {
    guard mixerTimer == nil else {
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: playbackQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.mixAndSchedulePlayback()
    }
    mixerTimer = timer
    timer.resume()
  }

  private func writeCapturedAudio(_ buffer: AVAudioPCMBuffer) {
    guard !outboundStreams.isEmpty, let converter = captureConverter else {
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
      self?.broadcast(audioData)
    }
  }

  private func broadcast(_ data: Data) {
    for (endpointID, boundStream) in outboundStreams {
      let succeeded = writeToOutputStream(data, stream: boundStream.output)
      if !succeeded {
        removeOutboundStream(endpointID)
      }
    }
  }

  private func writeToOutputStream(_ data: Data, stream: OutputStream) -> Bool {
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return false
      }

      var totalWritten = 0
      while totalWritten < data.count {
        let bytesWritten = stream.write(
          baseAddress.advanced(by: totalWritten),
          maxLength: data.count - totalWritten
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
    let frames = inboundBuffers.compactMapValues { $0.drainFrame(frameByteCount: frameByteCount) }
    guard !frames.isEmpty else {
      return
    }

    guard
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

    if queuedPlaybackFrames >= AVAudioFramePosition(playbackFormat.sampleRate * 0.08) {
      playerNode.stop()
      queuedPlaybackFrames = 0
      playerNode.play()
    }

    let scheduledFrames = AVAudioFramePosition(playbackBuffer.frameLength)
    queuedPlaybackFrames += scheduledFrames
    playerNode.scheduleBuffer(playbackBuffer) { [weak self] in
      self?.playbackQueue.async {
        guard let self else { return }
        self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - scheduledFrames)
      }
    }
  }

  private func tearDownAudioIfIdle(forceDeactivate: Bool = false) {
    guard forceDeactivate || (outboundStreams.isEmpty && inboundReaders.isEmpty) else {
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
    teardownWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
  }

  private func cancelTeardown() {
    teardownWorkItem?.cancel()
    teardownWorkItem = nil
  }

  private func performTeardown() {
    cancelTeardown()
    guard outboundStreams.isEmpty && inboundReaders.isEmpty else {
      return
    }

    audioEngine.inputNode.removeTap(onBus: 0)
    playbackQueue.sync {
      playerNode.stop()
      queuedPlaybackFrames = 0
    }
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    mixerTimer?.cancel()
    mixerTimer = nil
    captureConverter = nil
    do {
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
      onError(error.localizedDescription)
    }
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
    guard !data.isEmpty else {
      return nil
    }

    let copyCount = min(frameByteCount, data.count)
    var frame = Data(count: frameByteCount)
    frame.replaceSubrange(0..<copyCount, with: data.prefix(copyCount))
    data.removeFirst(copyCount)
    return frame
  }
}

private final class IncomingAudioStreamReader {
  private let stream: InputStream
  private let bufferSize: Int
  private let queue: DispatchQueue
  private let onAudioData: (Data) -> Void
  private let onFinished: () -> Void
  private let stateLock = NSLock()
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
        onAudioData(Data(bytes: buffer, count: bytesRead))
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
}

private enum NearbyAudioError: LocalizedError {
  case converterCreationFailed
  case captureConversionFailed
  case streamCreationFailed

  var errorDescription: String? {
    switch self {
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
