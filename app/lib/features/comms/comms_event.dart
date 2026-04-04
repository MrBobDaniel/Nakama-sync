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
