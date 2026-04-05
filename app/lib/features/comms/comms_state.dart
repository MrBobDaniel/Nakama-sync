import 'package:equatable/equatable.dart';

abstract class CommsState extends Equatable {
  const CommsState();

  @override
  List<Object?> get props => [];
}

class CommsInitial extends CommsState {
  const CommsInitial({
    this.statusMessage = 'Ready to search for nearby peers.',
  });

  final String statusMessage;

  @override
  List<Object?> get props => [statusMessage];
}

class CommsSessionOpen extends CommsState {
  const CommsSessionOpen(
    this.roomId, {
    this.statusMessage = 'Room is open for nearby connections.',
    this.isDiscovering = true,
  });

  final String roomId;
  final String statusMessage;
  final bool isDiscovering;

  CommsSessionOpen copyWith({
    String? roomId,
    String? statusMessage,
    bool? isDiscovering,
  }) {
    return CommsSessionOpen(
      roomId ?? this.roomId,
      statusMessage: statusMessage ?? this.statusMessage,
      isDiscovering: isDiscovering ?? this.isDiscovering,
    );
  }

  @override
  List<Object?> get props => [roomId, statusMessage, isDiscovering];
}

class CommsConnected extends CommsState {
  const CommsConnected(
    this.roomId, {
    this.isTransmitting = false,
    this.connectedPeers = 1,
    this.statusMessage = 'Connected over Nearby Connections.',
  });

  final String roomId;
  final bool isTransmitting;
  final int connectedPeers;
  final String statusMessage;

  CommsConnected copyWith({
    String? roomId,
    bool? isTransmitting,
    int? connectedPeers,
    String? statusMessage,
  }) {
    return CommsConnected(
      roomId ?? this.roomId,
      isTransmitting: isTransmitting ?? this.isTransmitting,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      statusMessage: statusMessage ?? this.statusMessage,
    );
  }

  @override
  List<Object?> get props => [
        roomId,
        isTransmitting,
        connectedPeers,
        statusMessage,
      ];
}

class CommsFailure extends CommsState {
  const CommsFailure(
    this.message, {
    this.roomId,
  });

  final String message;
  final String? roomId;

  @override
  List<Object?> get props => [message, roomId];
}
