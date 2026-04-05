import Flutter
import AVFoundation
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
  private var endpointRoomMatches = [EndpointID: Bool]()
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
    endpointRoomMatches.removeValue(forKey: endpointID)
    audioController.handleEndpointDisconnected(endpointID)
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
      sendHandshake(to: endpointID)
      emit(event: "connected", message: "Connected to nearby peer over Nearby Connections.", extra: [
        "connectedPeers": connectedEndpoints.count
      ])
    case .disconnected:
      connectedEndpoints.remove(endpointID)
      endpointRoomMatches.removeValue(forKey: endpointID)
      audioController.handleEndpointDisconnected(endpointID)
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
    if handleHandshakePayload(data, from: endpointID) {
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
  func sendHandshake(to endpointID: EndpointID) {
    let handshake: [String: Any] = [
      "type": "hello",
      "roomId": roomID as Any,
      "displayName": displayName,
    ]
    guard
      let handshakeData = try? JSONSerialization.data(
        withJSONObject: handshake
      )
    else {
      emit(event: "error", message: "Failed to encode Nearby peer metadata.")
      return
    }

    connectionManager.send(handshakeData, to: [endpointID])
  }

  func handleHandshakePayload(_ data: Data, from endpointID: EndpointID) -> Bool {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String,
      type == "hello"
    else {
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
    guard let remoteName = String(data: context, encoding: .utf8) else {
      return true
    }

    let normalizedRoom = roomID?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedRoom == nil || normalizedRoom?.isEmpty == true {
      return true
    }

    return !remoteName.isEmpty
  }

  func disconnect(_ endpointID: EndpointID) {
    connectionManager.disconnect(from: endpointID)
  }
}
#endif

#if canImport(NearbyConnections)
private final class NearbyAudioController {
  private let eventHandler: (String, String, [String: Any]) -> Void
  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let audioQueue = DispatchQueue(label: "nakama.nearby.audio")
  private let session = AVAudioSession.sharedInstance()
  private let captureFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  private var captureConverter: AVAudioConverter?
  private var outboundEndpoint: EndpointID?
  private var outboundInputStream: InputStream?
  private var outboundOutputStream: OutputStream?
  private var inboundReaders = [EndpointID: IncomingAudioStreamReader]()
  private var isConfigured = false
  private var isTransmitting = false

  init(eventHandler: @escaping (String, String, [String: Any]) -> Void) {
    self.eventHandler = eventHandler
  }

  func startTransmitting(to endpointID: EndpointID, connectionManager: ConnectionManager) throws {
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
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
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
      try configureAudioSession()
      try configureAudioEngineIfNeeded()
      let reader = IncomingAudioStreamReader(
        stream: stream,
        queue: audioQueue,
        onAudioData: { [weak self] data in
          self?.schedulePlayback(for: data)
        },
        onFinished: { [weak self] in
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
    tearDownAudioIfIdle()
  }

  func stopAll() {
    stopTransmitting()
    inboundReaders.values.forEach { $0.stop() }
    inboundReaders.removeAll()
    tearDownAudioIfIdle(forceDeactivate: true)
  }

  private func configureAudioSession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [
        .defaultToSpeaker,
        .allowBluetooth,
        .allowBluetoothA2DP,
      ]
    )
    try session.setPreferredSampleRate(16_000)
    try session.setPreferredInputNumberOfChannels(1)
    try session.setPreferredOutputNumberOfChannels(1)
    try session.setPreferredIOBufferDuration(0.02)
    try session.overrideOutputAudioPort(.speaker)
    try session.setActive(true)
  }

  private func configureAudioEngineIfNeeded() throws {
    guard !isConfigured else {
      return
    }

    audioEngine.attach(playerNode)
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: captureFormat)
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
    audioQueue.async { [weak self] in
      self?.writeToOutputStream(audioData, stream: outputStream)
    }
  }

  private func writeToOutputStream(_ data: Data, stream: OutputStream) {
    let result = data.withUnsafeBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return false
      }

      var totalWritten = 0
      while totalWritten < data.count {
        let bytesWritten = stream.write(baseAddress.advanced(by: totalWritten), maxLength: data.count - totalWritten)
        if bytesWritten <= 0 {
          return false
        }
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
        pcmFormat: captureFormat,
        frameCapacity: AVAudioFrameCount(sampleCount)
      ),
      let channelData = playbackBuffer.int16ChannelData
    else {
      return
    }

    playbackBuffer.frameLength = AVAudioFrameCount(sampleCount)
    data.copyBytes(to: UnsafeMutableBufferPointer(start: channelData[0], count: sampleCount))

    audioQueue.async { [weak self] in
      guard let self else {
        return
      }

      if !self.playerNode.isPlaying {
        self.playerNode.play()
      }
      self.playerNode.scheduleBuffer(playbackBuffer, completionHandler: nil)
    }
  }

  private func closeOutboundStreams() {
    outboundInputStream?.close()
    outboundOutputStream?.close()
    outboundInputStream = nil
    outboundOutputStream = nil
  }

  private func tearDownAudioIfIdle(forceDeactivate: Bool = false) {
    guard forceDeactivate || (!isTransmitting && inboundReaders.isEmpty) else {
      return
    }

    audioEngine.inputNode.removeTap(onBus: 0)
    playerNode.stop()
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
    let bufferSize = 2_048
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
