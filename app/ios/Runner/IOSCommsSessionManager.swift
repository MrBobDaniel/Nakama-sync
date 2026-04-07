import AVFoundation
import CallKit
import Foundation

final class IOSCommsSessionManager: NSObject {
  struct StartResult {
    let isCallKitActive: Bool
    let isAudioSessionConfigured: Bool
    let message: String
  }

  private let provider: CXProvider
  private let callController = CXCallController()
  private let session = AVAudioSession.sharedInstance()
  private let onStateChanged: (String, [String: Any]) -> Void
  private let onSystemSessionEnded: (String) -> Void

  private var activeCallUUID: UUID?
  private var roomID: String?
  private var displayName = "Nakama Sync iPhone"
  private var isStoppingLocally = false
  private var isCallKitActivated = false
  private var isAudioSessionConfigured = false
  private var isReceivingAudio = false
  private var isTransmitting = false

  override init() {
    fatalError("Use init(onStateChanged:onSystemSessionEnded:)")
  }

  init(
    onStateChanged: @escaping (String, [String: Any]) -> Void,
    onSystemSessionEnded: @escaping (String) -> Void
  ) {
    self.onStateChanged = onStateChanged
    self.onSystemSessionEnded = onSystemSessionEnded

    let configuration = CXProviderConfiguration(localizedName: "Nakama Sync")
    configuration.supportsVideo = false
    configuration.supportedHandleTypes = [.generic]
    configuration.maximumCallsPerCallGroup = 1
    configuration.maximumCallGroups = 1
    configuration.includesCallsInRecents = false

    provider = CXProvider(configuration: configuration)

    super.init()

    provider.setDelegate(self, queue: nil)
    observeAudioSessionNotifications()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func startSession(roomID: String, displayName: String) -> StartResult {
    self.roomID = roomID
    self.displayName = displayName
    isStoppingLocally = false

    do {
      try configureAudioSession(activate: false)
    } catch {
      return StartResult(
        isCallKitActive: false,
        isAudioSessionConfigured: false,
        message: "CallKit audio session setup failed: \(error.localizedDescription)"
      )
    }

    let callUUID = UUID()
    activeCallUUID = callUUID

    let handleValue = roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "nakama-sync" : roomID
    let handle = CXHandle(type: .generic, value: handleValue)
    let action = CXStartCallAction(call: callUUID, handle: handle)
    let transaction = CXTransaction(action: action)

    callController.request(transaction) { [weak self] error in
      guard let self else { return }

      if let error {
        self.activeCallUUID = nil
        self.emitState(
          message: "CallKit could not start the comms session: \(error.localizedDescription)"
        )
        self.onSystemSessionEnded("CallKit could not start the comms session: \(error.localizedDescription)")
        return
      }

      self.provider.reportOutgoingCall(with: callUUID, startedConnectingAt: Date())
      self.emitState(
        message: "iOS CallKit walkie-talkie session is active."
      )
    }

    return StartResult(
      isCallKitActive: true,
      isAudioSessionConfigured: isAudioSessionConfigured,
      message: "Requested an iOS CallKit comms session."
    )
  }

  func stopSession() {
    isStoppingLocally = true
    isReceivingAudio = false
    isTransmitting = false

    guard let activeCallUUID else {
      deactivateAudioSession()
      emitState(message: "iOS CallKit comms session stopped.")
      return
    }

    let action = CXEndCallAction(call: activeCallUUID)
    let transaction = CXTransaction(action: action)
    callController.request(transaction) { [weak self] error in
      guard let self else { return }
      if error != nil {
        self.provider.reportCall(with: activeCallUUID, endedAt: Date(), reason: .remoteEnded)
        self.finishStoppingSession(reason: "iOS CallKit comms session stopped.")
      }
    }
  }

  func prepareForVoiceAudio() throws {
    try configureAudioSession(activate: true)
  }

  func deactivateVoiceAudio() {
    deactivateAudioSession()
  }

  func updateAudioState(isReceivingAudio: Bool, isTransmitting: Bool) {
    self.isReceivingAudio = isReceivingAudio
    self.isTransmitting = isTransmitting

    do {
      try configureAudioSession(activate: isReceivingAudio || isTransmitting || activeCallUUID != nil)
      emitState(message: audioStatusMessage())
    } catch {
      emitState(
        message: "iOS audio session update failed: \(error.localizedDescription)"
      )
    }
  }

  private func observeAudioSessionNotifications() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: session
    )
    center.addObserver(
      self,
      selector: #selector(handleMediaServicesReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: session
    )
  }

  private func configureAudioSession(activate: Bool) throws {
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
    if activate {
      try session.setActive(true)
      try? session.overrideOutputAudioPort(.speaker)
    }
    isAudioSessionConfigured = true
  }

  private func deactivateAudioSession() {
    try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    isCallKitActivated = false
    isAudioSessionConfigured = false
  }

  private func finishStoppingSession(reason: String) {
    activeCallUUID = nil
    deactivateAudioSession()
    emitState(message: reason)
  }

  private func audioStatusMessage() -> String {
    if isTransmitting && isReceivingAudio {
      return "iOS CallKit session is sending and receiving voice audio."
    }
    if isTransmitting {
      return "iOS CallKit session is transmitting voice audio."
    }
    if isReceivingAudio {
      return "iOS CallKit session is receiving voice audio."
    }
    return "iOS CallKit session is standing by for walkie-talkie audio."
  }

  private func emitState(message: String) {
    onStateChanged(
      message,
      [
        "isPersistentSessionActive": activeCallUUID != nil,
        "isCallKitActive": activeCallUUID != nil,
        "isAudioSessionActive": isCallKitActivated,
        "isAudioSessionConfigured": isAudioSessionConfigured,
      ]
    )
  }

  @objc
  private func handleAudioSessionInterruption(_ notification: Notification) {
    guard
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else {
      return
    }

    switch type {
    case .began:
      emitState(message: "iOS audio session was interrupted.")
    case .ended:
      do {
        try configureAudioSession(activate: activeCallUUID != nil)
        emitState(message: audioStatusMessage())
      } catch {
        emitState(message: "iOS audio session failed to recover after interruption.")
      }
    @unknown default:
      break
    }
  }

  @objc
  private func handleMediaServicesReset(_ notification: Notification) {
    guard activeCallUUID != nil else { return }

    do {
      try configureAudioSession(activate: true)
      emitState(message: "iOS audio session was restored after a media services reset.")
    } catch {
      emitState(message: "iOS audio session failed after a media services reset.")
    }
  }
}

extension IOSCommsSessionManager: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    let endedRemotely = !isStoppingLocally && activeCallUUID != nil
    finishStoppingSession(reason: "CallKit reset the comms session.")
    if endedRemotely {
      onSystemSessionEnded("CallKit reset the comms session.")
    }
    isStoppingLocally = false
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    do {
      try configureAudioSession(activate: true)
      provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
      action.fulfill()
      emitState(message: "iOS CallKit walkie-talkie session is active.")
    } catch {
      action.fail()
      activeCallUUID = nil
      emitState(message: "CallKit failed to activate the audio session.")
      onSystemSessionEnded("CallKit failed to activate the audio session.")
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .remoteEnded)
    action.fulfill()

    let endedRemotely = !isStoppingLocally
    finishStoppingSession(reason: "iOS CallKit comms session stopped.")
    if endedRemotely {
      onSystemSessionEnded("CallKit ended the comms session.")
    }
    isStoppingLocally = false
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    isCallKitActivated = true
    emitState(message: audioStatusMessage())
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    isCallKitActivated = false
    emitState(message: "iOS audio session was deactivated by CallKit.")
  }
}
