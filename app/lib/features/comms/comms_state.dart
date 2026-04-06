import 'package:equatable/equatable.dart';

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
    this.recentEvents = const <CommsDiagnosticEntry>[],
  });

  final String lastEvent;
  final String lastMessage;
  final int connectedPeers;
  final bool isDiscovering;
  final bool isTransmitting;
  final bool isReceivingAudio;
  final List<CommsDiagnosticEntry> recentEvents;

  CommsDiagnostics copyWith({
    String? lastEvent,
    String? lastMessage,
    int? connectedPeers,
    bool? isDiscovering,
    bool? isTransmitting,
    bool? isReceivingAudio,
    List<CommsDiagnosticEntry>? recentEvents,
  }) {
    return CommsDiagnostics(
      lastEvent: lastEvent ?? this.lastEvent,
      lastMessage: lastMessage ?? this.lastMessage,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      isTransmitting: isTransmitting ?? this.isTransmitting,
      isReceivingAudio: isReceivingAudio ?? this.isReceivingAudio,
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
    recentEvents,
  ];
}

abstract class CommsState extends Equatable {
  const CommsState();

  CommsDiagnostics get diagnostics;
  bool get isMicrophoneMuted;
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
  });

  final String statusMessage;
  @override
  final CommsDiagnostics diagnostics;
  @override
  final bool isMicrophoneMuted;

  @override
  List<Object?> get props => [statusMessage, diagnostics, isMicrophoneMuted];
}

class CommsSessionOpen extends CommsState {
  const CommsSessionOpen(
    this.roomId, {
    this.statusMessage = 'Room is open for nearby connections.',
    this.isDiscovering = true,
    this.peers = const <CommsPeer>[],
    this.diagnostics = const CommsDiagnostics(),
    this.isMicrophoneMuted = false,
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

  CommsSessionOpen copyWith({
    String? roomId,
    String? statusMessage,
    bool? isDiscovering,
    List<CommsPeer>? peers,
    CommsDiagnostics? diagnostics,
    bool? isMicrophoneMuted,
  }) {
    return CommsSessionOpen(
      roomId ?? this.roomId,
      statusMessage: statusMessage ?? this.statusMessage,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      peers: peers ?? this.peers,
      diagnostics: diagnostics ?? this.diagnostics,
      isMicrophoneMuted: isMicrophoneMuted ?? this.isMicrophoneMuted,
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
  bool get isSpeechActive => isTransmitting || isReceivingAudio;

  CommsConnected copyWith({
    String? roomId,
    bool? isTransmitting,
    bool? isReceivingAudio,
    int? connectedPeers,
    String? statusMessage,
    List<CommsPeer>? peers,
    CommsDiagnostics? diagnostics,
    bool? isMicrophoneMuted,
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
  ];
}

class CommsFailure extends CommsState {
  const CommsFailure(
    this.message, {
    this.roomId,
    this.diagnostics = const CommsDiagnostics(),
    this.isMicrophoneMuted = false,
  });

  final String message;
  final String? roomId;
  @override
  final CommsDiagnostics diagnostics;
  @override
  final bool isMicrophoneMuted;

  @override
  List<Object?> get props => [message, roomId, diagnostics, isMicrophoneMuted];
}
