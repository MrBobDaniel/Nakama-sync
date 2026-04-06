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
    strategy: .pointToPoint
  )
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var connectedEndpoints = Set<EndpointID>()
  private var endpointRoomMatches = [EndpointID: Bool]()
  private var isDiscovering = false
  private var discoveryStopWorkItem: DispatchWorkItem?
  private lazy var audioController = NearbyAudioController { [weak self] event, message, extra in
    self?.emit(event: event, message: message, extra: extra)
  }
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
    guard let endpointID = connectedEndpoints.first(where: { endpointRoomMatches[$0] == true }) else {
      result(
        FlutterError(
          code: "no_endpoint",
          message: "No validated Nearby peer is connected.",
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
          try self.audioController.startTransmitting(
            to: endpointID,
            connectionManager: self.connectionManager
          )
          self.emit(event: "transmit_state", message: "Streaming microphone audio over Nearby Connections.", extra: [
            "isTransmitting": true
          ])
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
      sendControlPayload(type: "audio_stop", to: endpointID)
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
    audioController.stopAll()
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    advertiser = nil
    discoverer = nil
    connectedEndpoints.removeAll()
    endpointRoomMatches.removeAll()
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
      "isDiscovering": isDiscovering,
    ]
    extra.forEach { payload[$0.key] = $0.value }
    eventSink?(payload)
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
    guard roomMatches(remoteEndpoint.roomID) else {
      endpointRoomMatches[endpointID] = false
      emit(event: "error", message: "Ignoring Nearby peer from a different room.")
      connectionRequestHandler(false)
      return
    }

    let remoteName = remoteEndpoint.displayName ?? "nearby peer"
    emit(event: "connection_initiated", message: "Connection initiated with \(remoteName).")
    connectionRequestHandler(true)
  }
}

extension NearbyConnectionsBridge: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    if !connectedEndpoints.isEmpty {
      return
    }

    if !shouldConnect(to: context) {
      return
    }

    let remoteEndpoint = parseEndpointContext(context)
    let remoteName = remoteEndpoint.displayName ?? "nearby peer"
    emit(event: "peer_discovered", message: "Found nearby peer \(remoteName).")
    discoverer.requestConnection(to: endpointID, using: endpointContextData())
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    connectedEndpoints.remove(endpointID)
    endpointRoomMatches.removeValue(forKey: endpointID)
    audioController.handleEndpointDisconnected(endpointID)
    emit(event: "disconnected", message: "Nearby peer left range. Room remains open for reconnects.")
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
      stopDiscovery()
      sendHandshake(to: endpointID)
      emit(event: "connected", message: "Connected to nearby peer over Nearby Connections.", extra: [
        "connectedPeers": connectedEndpoints.count
      ])
    case .disconnected:
      connectedEndpoints.remove(endpointID)
      endpointRoomMatches.removeValue(forKey: endpointID)
      audioController.handleEndpointDisconnected(endpointID)
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
    let payload: [String: Any] = [
      "roomId": roomID as Any,
      "displayName": displayName,
    ]

    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }

  func sendHandshake(to endpointID: EndpointID) {
    sendControlPayload(type: "hello", to: endpointID)
  }

  func sendControlPayload(type: String, to endpointID: EndpointID) {
    let payload: [String: Any] = [
      "type": type,
      "roomId": roomID as Any,
      "displayName": displayName,
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
      emit(
        event: "receive_state",
        message: "Incoming voice audio is idle.",
        extra: ["isReceivingAudio": false]
      )
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
      emit(event: "error", message: "Nearby peer is advertising a different room.")
      disconnect(endpointID)
      return true
    }

    endpointRoomMatches[endpointID] = true
    var extra: [String: Any] = [:]
    if let peerDisplayName = json["displayName"] as? String {
      extra["peerDisplayName"] = peerDisplayName
    }
    emit(
      event: "bytes_received",
      message: "Nearby peer metadata received.",
      extra: extra
    )
    return true
  }

  func shouldConnect(to context: Data) -> Bool {
    roomMatches(parseEndpointContext(context).roomID)
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
        displayName: String(data: context, encoding: .utf8)
      )
    }

    return NearbyEndpointContext(
      roomID: (json["roomId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      displayName: json["displayName"] as? String
    )
  }

  func startDiscoveryBurst(message: String) {
    guard connectedEndpoints.isEmpty else {
      return
    }

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
  }
}
#endif

#if canImport(NearbyConnections)
private final class NearbyAudioController {
  private let eventHandler: (String, String, [String: Any]) -> Void
  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let transmitQueue = DispatchQueue(label: "nakama.nearby.audio.tx")
  private let receiveQueue = DispatchQueue(label: "nakama.nearby.audio.rx")
  private let playbackQueue = DispatchQueue(label: "nakama.nearby.audio.playback")
  private let session = AVAudioSession.sharedInstance()
  private let captureFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!
  private let maxStalledOutputWrites = 4
  private let stalledOutputRetryInterval = 0.001

  private var captureConverter: AVAudioConverter?
  private var outboundEndpoint: EndpointID?
  private var outboundInputStream: InputStream?
  private var outboundOutputStream: OutputStream?
  private var inboundReaders = [EndpointID: IncomingAudioStreamReader]()
  private var isConfigured = false
  private var isTransmitting = false
  private var queuedPlaybackFrames: AVAudioFramePosition = 0
  private var teardownWorkItem: DispatchWorkItem?

  init(eventHandler: @escaping (String, String, [String: Any]) -> Void) {
    self.eventHandler = eventHandler
  }

  func startTransmitting(to endpointID: EndpointID, connectionManager: ConnectionManager) throws {
    cancelTeardown()
    try configureAudioSession()
    try configureAudioEngineIfNeeded()

    if isTransmitting, outboundEndpoint == endpointID {
      return
    }

    stopTransmitting()

    let streams = try makeBoundStreams()
    outboundInputStream = streams.input
    outboundOutputStream = streams.output
    outboundEndpoint = endpointID
    outboundInputStream?.open()
    outboundOutputStream?.open()

    connectionManager.startStream(streams.input, to: [endpointID])

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
      throw NearbyAudioError.converterCreationFailed
    }
    captureConverter = converter

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 320, format: inputFormat) { [weak self] buffer, _ in
      self?.writeCapturedAudio(buffer)
    }

    if !audioEngine.isRunning {
      audioEngine.prepare()
      try audioEngine.start()
    }
    if !playerNode.isPlaying {
      playerNode.play()
    }

    isTransmitting = true
  }

  func stopTransmitting() {
    guard isTransmitting else {
      closeOutboundStreams()
      return
    }

    audioEngine.inputNode.removeTap(onBus: 0)
    isTransmitting = false
    outboundEndpoint = nil
    captureConverter = nil
    closeOutboundStreams()
    tearDownAudioIfIdle()
  }

  func handleIncomingStream(_ stream: InputStream, from endpointID: EndpointID) {
    do {
      cancelTeardown()
      try configureAudioSession()
      try configureAudioEngineIfNeeded()
      let reader = IncomingAudioStreamReader(
        stream: stream,
        queue: receiveQueue,
        onAudioData: { [weak self] data in
          self?.schedulePlayback(for: data)
        },
        onFinished: { [weak self] in
          self?.eventHandler(
            "receive_state",
            "Incoming voice audio is idle.",
            ["isReceivingAudio": false]
          )
          self?.inboundReaders.removeValue(forKey: endpointID)
          self?.tearDownAudioIfIdle()
        }
      )

      inboundReaders[endpointID]?.stop()
      inboundReaders[endpointID] = reader

      if !audioEngine.isRunning {
        audioEngine.prepare()
        try audioEngine.start()
      }
      if !playerNode.isPlaying {
        playerNode.play()
      }

      eventHandler(
        "receive_state",
        "Receiving nearby voice audio.",
        ["isReceivingAudio": true]
      )
      reader.start()
    } catch {
      eventHandler("error", error.localizedDescription, [:])
    }
  }

  func handleEndpointDisconnected(_ endpointID: EndpointID) {
    if outboundEndpoint == endpointID {
      stopTransmitting()
    }

    inboundReaders.removeValue(forKey: endpointID)?.stop()
    flushPlayback()
    tearDownAudioIfIdle()
  }

  func stopAll() {
    stopTransmitting()
    inboundReaders.values.forEach { $0.stop() }
    inboundReaders.removeAll()
    tearDownAudioIfIdle(forceDeactivate: true)
  }

  func stopIncomingAudio(from endpointID: EndpointID) {
    inboundReaders.removeValue(forKey: endpointID)?.stop()
    flushPlayback()
    tearDownAudioIfIdle()
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
    try session.setPreferredSampleRate(16_000)
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

  private func writeCapturedAudio(_ buffer: AVAudioPCMBuffer) {
    guard
      isTransmitting,
      let outputStream = outboundOutputStream,
      let converter = captureConverter
    else {
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
      eventHandler(
        "error",
        error?.localizedDescription ?? NearbyAudioError.captureConversionFailed.localizedDescription,
        [:]
      )
      return
    }

    guard let channelData = convertedBuffer.int16ChannelData else {
      return
    }

    let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.stride
    let audioData = Data(bytes: channelData[0], count: byteCount)
    transmitQueue.async { [weak self] in
      self?.writeToOutputStream(audioData, stream: outputStream)
    }
  }

  private func writeToOutputStream(_ data: Data, stream: OutputStream) {
    let result = data.withUnsafeBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return false
      }

      var totalWritten = 0
      var stalledWrites = 0
      while totalWritten < data.count {
        if !stream.hasSpaceAvailable {
          stalledWrites += 1
          guard stalledWrites <= maxStalledOutputWrites else {
            return true
          }
          Thread.sleep(forTimeInterval: stalledOutputRetryInterval)
          continue
        }

        let bytesWritten = stream.write(baseAddress.advanced(by: totalWritten), maxLength: data.count - totalWritten)
        if bytesWritten < 0 {
          return false
        }
        if bytesWritten == 0 {
          stalledWrites += 1
          guard stalledWrites <= maxStalledOutputWrites else {
            return true
          }
          Thread.sleep(forTimeInterval: stalledOutputRetryInterval)
          continue
        }

        stalledWrites = 0
        totalWritten += bytesWritten
      }
      return true
    }

    if !result {
      eventHandler("error", NearbyAudioError.outputWriteFailed.localizedDescription, [:])
    }
  }

  private func schedulePlayback(for data: Data) {
    let sampleCount = data.count / MemoryLayout<Int16>.stride
    guard
      sampleCount > 0,
      let playbackBuffer = AVAudioPCMBuffer(
        pcmFormat: playbackFormat,
        frameCapacity: AVAudioFrameCount(sampleCount)
      ),
      let channelData = playbackBuffer.floatChannelData
    else {
      return
    }

    playbackBuffer.frameLength = AVAudioFrameCount(sampleCount)
    data.withUnsafeBytes { rawBuffer in
      guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
        return
      }

      let output = channelData[0]
      for index in 0..<sampleCount {
        output[index] = Float(samples[index]) / Float(Int16.max)
      }
    }

    playbackQueue.async { [weak self] in
      guard let self else {
        return
      }

      if self.queuedPlaybackFrames >= self.maximumQueuedPlaybackFrames {
        self.playerNode.stop()
        self.queuedPlaybackFrames = 0
      }
      if !self.playerNode.isPlaying {
        self.playerNode.play()
      }
      let scheduledFrames = AVAudioFramePosition(playbackBuffer.frameLength)
      self.queuedPlaybackFrames += scheduledFrames
      self.playerNode.scheduleBuffer(playbackBuffer) { [weak self] in
        guard let self else {
          return
        }
        self.playbackQueue.async {
          self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - scheduledFrames)
        }
      }
    }
  }

  private func closeOutboundStreams() {
    outboundInputStream?.close()
    outboundOutputStream?.close()
    outboundInputStream = nil
    outboundOutputStream = nil
  }

  private func flushPlayback() {
    playbackQueue.async { [weak self] in
      guard let self else {
        return
      }
      self.playerNode.stop()
      self.queuedPlaybackFrames = 0
    }
  }

  private func tearDownAudioIfIdle(forceDeactivate: Bool = false) {
    guard forceDeactivate || (!isTransmitting && inboundReaders.isEmpty) else {
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
    DispatchQueue.main.asyncAfter(deadline: .now() + warmAudioHoldDuration, execute: workItem)
  }

  private func cancelTeardown() {
    teardownWorkItem?.cancel()
    teardownWorkItem = nil
  }

  private func performTeardown() {
    cancelTeardown()
    guard !isTransmitting && inboundReaders.isEmpty else {
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
    captureConverter = nil
    closeOutboundStreams()

    do {
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
      eventHandler("error", error.localizedDescription, [:])
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

  private var maximumQueuedPlaybackFrames: AVAudioFramePosition {
    AVAudioFramePosition(playbackFormat.sampleRate * 0.04)
  }

  private let warmAudioHoldDuration: TimeInterval = 1.5
}

private final class IncomingAudioStreamReader {
  private let stream: InputStream
  private let queue: DispatchQueue
  private let onAudioData: (Data) -> Void
  private let onFinished: () -> Void
  private let isRunning = NSLock()
  private var stopped = false

  init(
    stream: InputStream,
    queue: DispatchQueue,
    onAudioData: @escaping (Data) -> Void,
    onFinished: @escaping () -> Void
  ) {
    self.stream = stream
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
    isRunning.lock()
    stopped = true
    isRunning.unlock()
    stream.close()
  }

  private func readLoop() {
    stream.open()
    let bufferSize = 640
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

      if let streamError = stream.streamError {
        print("Nearby input stream error: \(streamError)")
      }
      break
    }
  }

  private var isStopped: Bool {
    isRunning.lock()
    defer { isRunning.unlock() }
    return stopped
  }
}

private enum NearbyAudioError: LocalizedError {
  case converterCreationFailed
  case captureConversionFailed
  case outputWriteFailed
  case streamCreationFailed

  var errorDescription: String? {
    switch self {
    case .converterCreationFailed:
      return "Unable to prepare the iOS audio format converter for Nearby audio."
    case .captureConversionFailed:
      return "Failed to convert microphone audio into Nearby PCM frames."
    case .outputWriteFailed:
      return "Failed to write microphone audio into the Nearby stream."
    case .streamCreationFailed:
      return "Failed to create a local audio stream for Nearby transmission."
    }
  }
}
#endif
