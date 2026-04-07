import 'package:equatable/equatable.dart';

enum CommsTransmitMode {
  pushToTalk,
  voiceActivated;

  String get diagnosticValue => switch (this) {
    CommsTransmitMode.pushToTalk => 'push_to_talk',
    CommsTransmitMode.voiceActivated => 'voice_activated',
  };
}

class CommsPeer extends Equatable {
  const CommsPeer({
    required this.peerId,
    required this.displayName,
    this.isConnected = false,
    this.isSpeaking = false,
    this.streamSampleRate,
  });

  final String peerId;
  final String displayName;
  final bool isConnected;
  final bool isSpeaking;
  final int? streamSampleRate;

  CommsPeer copyWith({
    String? peerId,
    String? displayName,
    bool? isConnected,
    bool? isSpeaking,
    int? streamSampleRate,
  }) {
    return CommsPeer(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      isConnected: isConnected ?? this.isConnected,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      streamSampleRate: streamSampleRate ?? this.streamSampleRate,
    );
  }

  @override
  List<Object?> get props => [
    peerId,
    displayName,
    isConnected,
    isSpeaking,
    streamSampleRate,
  ];
}

class CommsDiagnosticEntry extends Equatable {
  const CommsDiagnosticEntry({
    required this.event,
    required this.message,
    this.details = const <String>[],
  });

  final String event;
  final String message;
  final List<String> details;

  @override
  List<Object?> get props => [event, message, details];
}

class CommsDiagnostics extends Equatable {
  const CommsDiagnostics({
    this.lastEvent = 'idle',
    this.lastMessage = 'No transport activity yet.',
    this.connectedPeers = 0,
    this.isDiscovering = false,
    this.isTransmitting = false,
    this.isReceivingAudio = false,
    this.isVoiceActivationArmed = false,
    this.transmitMode = CommsTransmitMode.pushToTalk,
    this.recentEvents = const <CommsDiagnosticEntry>[],
  });

  final String lastEvent;
  final String lastMessage;
  final int connectedPeers;
  final bool isDiscovering;
  final bool isTransmitting;
  final bool isReceivingAudio;
  final bool isVoiceActivationArmed;
  final CommsTransmitMode transmitMode;
  final List<CommsDiagnosticEntry> recentEvents;

  CommsDiagnostics copyWith({
    String? lastEvent,
    String? lastMessage,
    int? connectedPeers,
    bool? isDiscovering,
    bool? isTransmitting,
    bool? isReceivingAudio,
    bool? isVoiceActivationArmed,
    CommsTransmitMode? transmitMode,
    List<CommsDiagnosticEntry>? recentEvents,
  }) {
    return CommsDiagnostics(
      lastEvent: lastEvent ?? this.lastEvent,
      lastMessage: lastMessage ?? this.lastMessage,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      isTransmitting: isTransmitting ?? this.isTransmitting,
      isReceivingAudio: isReceivingAudio ?? this.isReceivingAudio,
      isVoiceActivationArmed:
          isVoiceActivationArmed ?? this.isVoiceActivationArmed,
      transmitMode: transmitMode ?? this.transmitMode,
      recentEvents: recentEvents ?? this.recentEvents,
    );
  }

  @override
  List<Object?> get props => [
    lastEvent,
    lastMessage,
    connectedPeers,
    isDiscovering,
    isTransmitting,
    isReceivingAudio,
    isVoiceActivationArmed,
    transmitMode,
    recentEvents,
  ];
}

abstract class CommsState extends Equatable {
  const CommsState();

  CommsDiagnostics get diagnostics;
  bool get isMicrophoneMuted;
  CommsTransmitMode get transmitMode => CommsTransmitMode.pushToTalk;
  double get voiceActivationSensitivity => 0.55;
  bool get isVoiceActivationArmed => false;
  List<CommsPeer> get peers => const <CommsPeer>[];
  bool get isSpeechActive => false;

  @override
  List<Object?> get props => [];
}

class CommsInitial extends CommsState {
  const CommsInitial({
    this.statusMessage = 'Ready to search for nearby peers.',
    this.diagnostics = const CommsDiagnostics(),
    this.isMicrophoneMuted = false,
    this.transmitMode = CommsTransmitMode.pushToTalk,
    this.voiceActivationSensitivity = 0.55,
  });

  final String statusMessage;
  @override
  final CommsDiagnostics diagnostics;
  @override
  final bool isMicrophoneMuted;
  @override
  final CommsTransmitMode transmitMode;
  @override
  final double voiceActivationSensitivity;

  @override
  List<Object?> get props => [
    statusMessage,
    diagnostics,
    isMicrophoneMuted,
    transmitMode,
    voiceActivationSensitivity,
  ];
}

class CommsSessionOpen extends CommsState {
  const CommsSessionOpen(
    this.roomId, {
    this.statusMessage = 'Room is open for nearby connections.',
    this.isDiscovering = true,
    this.peers = const <CommsPeer>[],
    this.diagnostics = const CommsDiagnostics(),
    this.isMicrophoneMuted = false,
    this.transmitMode = CommsTransmitMode.pushToTalk,
    this.voiceActivationSensitivity = 0.55,
    this.isVoiceActivationArmed = false,
  });

  final String roomId;
  final String statusMessage;
  final bool isDiscovering;
  @override
  final List<CommsPeer> peers;
  @override
  final CommsDiagnostics diagnostics;
  @override
  final bool isMicrophoneMuted;
  @override
  final CommsTransmitMode transmitMode;
  @override
  final double voiceActivationSensitivity;
  @override
  final bool isVoiceActivationArmed;

  CommsSessionOpen copyWith({
    String? roomId,
    String? statusMessage,
    bool? isDiscovering,
    List<CommsPeer>? peers,
    CommsDiagnostics? diagnostics,
    bool? isMicrophoneMuted,
    CommsTransmitMode? transmitMode,
    double? voiceActivationSensitivity,
    bool? isVoiceActivationArmed,
  }) {
    return CommsSessionOpen(
      roomId ?? this.roomId,
      statusMessage: statusMessage ?? this.statusMessage,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      peers: peers ?? this.peers,
      diagnostics: diagnostics ?? this.diagnostics,
      isMicrophoneMuted: isMicrophoneMuted ?? this.isMicrophoneMuted,
      transmitMode: transmitMode ?? this.transmitMode,
      voiceActivationSensitivity:
          voiceActivationSensitivity ?? this.voiceActivationSensitivity,
      isVoiceActivationArmed:
          isVoiceActivationArmed ?? this.isVoiceActivationArmed,
    );
  }

  @override
  List<Object?> get props => [
    roomId,
    statusMessage,
    isDiscovering,
    peers,
    diagnostics,
    isMicrophoneMuted,
    transmitMode,
    voiceActivationSensitivity,
    isVoiceActivationArmed,
  ];
}

class CommsConnected extends CommsState {
  const CommsConnected(
    this.roomId, {
    this.isTransmitting = false,
    this.isReceivingAudio = false,
    this.connectedPeers = 1,
    this.statusMessage = 'Connected over Nearby Connections.',
    this.peers = const <CommsPeer>[],
    this.diagnostics = const CommsDiagnostics(),
    this.isMicrophoneMuted = false,
    this.transmitMode = CommsTransmitMode.pushToTalk,
    this.voiceActivationSensitivity = 0.55,
    this.isVoiceActivationArmed = false,
  });

  final String roomId;
  final bool isTransmitting;
  final bool isReceivingAudio;
  final int connectedPeers;
  final String statusMessage;
  @override
  final List<CommsPeer> peers;
  @override
  final CommsDiagnostics diagnostics;
  @override
  final bool isMicrophoneMuted;
  @override
  final CommsTransmitMode transmitMode;
  @override
  final double voiceActivationSensitivity;
  @override
  final bool isVoiceActivationArmed;

  @override
  bool get isSpeechActive => isTransmitting || isReceivingAudio;

  bool get isDuplexActive => isTransmitting && isReceivingAudio;

  CommsConnected copyWith({
    String? roomId,
    bool? isTransmitting,
    bool? isReceivingAudio,
    int? connectedPeers,
    String? statusMessage,
    List<CommsPeer>? peers,
    CommsDiagnostics? diagnostics,
    bool? isMicrophoneMuted,
    CommsTransmitMode? transmitMode,
    double? voiceActivationSensitivity,
    bool? isVoiceActivationArmed,
  }) {
    return CommsConnected(
      roomId ?? this.roomId,
      isTransmitting: isTransmitting ?? this.isTransmitting,
      isReceivingAudio: isReceivingAudio ?? this.isReceivingAudio,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      statusMessage: statusMessage ?? this.statusMessage,
      peers: peers ?? this.peers,
      diagnostics: diagnostics ?? this.diagnostics,
      isMicrophoneMuted: isMicrophoneMuted ?? this.isMicrophoneMuted,
      transmitMode: transmitMode ?? this.transmitMode,
      voiceActivationSensitivity:
          voiceActivationSensitivity ?? this.voiceActivationSensitivity,
      isVoiceActivationArmed:
          isVoiceActivationArmed ?? this.isVoiceActivationArmed,
    );
  }

  @override
  List<Object?> get props => [
    roomId,
    isTransmitting,
    isReceivingAudio,
    connectedPeers,
    statusMessage,
    peers,
    diagnostics,
    isMicrophoneMuted,
    transmitMode,
    voiceActivationSensitivity,
    isVoiceActivationArmed,
  ];
}

class CommsFailure extends CommsState {
  const CommsFailure(
    this.message, {
    this.roomId,
    this.diagnostics = const CommsDiagnostics(),
    this.isMicrophoneMuted = false,
    this.transmitMode = CommsTransmitMode.pushToTalk,
    this.voiceActivationSensitivity = 0.55,
  });

  final String message;
  final String? roomId;
  @override
  final CommsDiagnostics diagnostics;
  @override
  final bool isMicrophoneMuted;
  @override
  final CommsTransmitMode transmitMode;
  @override
  final double voiceActivationSensitivity;

  @override
  List<Object?> get props => [
    message,
    roomId,
    diagnostics,
    isMicrophoneMuted,
    transmitMode,
    voiceActivationSensitivity,
  ];
}
