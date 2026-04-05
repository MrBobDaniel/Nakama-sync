import 'package:equatable/equatable.dart';

abstract class CommsEvent extends Equatable {
  const CommsEvent();

  @override
  List<Object?> get props => [];
}

class ConnectToRoomRequested extends CommsEvent {
  const ConnectToRoomRequested(this.roomId);

  final String roomId;

  @override
  List<Object?> get props => [roomId];
}

class DisconnectRequested extends CommsEvent {
  const DisconnectRequested();
}

class PushToTalkChanged extends CommsEvent {
  const PushToTalkChanged(this.isActive);

  final bool isActive;

  @override
  List<Object?> get props => [isActive];
}

class MicrophoneMuteChanged extends CommsEvent {
  const MicrophoneMuteChanged(this.isMuted);

  final bool isMuted;

  @override
  List<Object?> get props => [isMuted];
}

class TransportStatusChanged extends CommsEvent {
  const TransportStatusChanged(this.payload);

  final Map<String, dynamic> payload;

  @override
  List<Object?> get props => [payload];
}
