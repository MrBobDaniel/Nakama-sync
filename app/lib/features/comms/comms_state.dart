import 'package:equatable/equatable.dart';

abstract class CommsState extends Equatable {
  const CommsState();

  @override
  List<Object?> get props => [];
}

class CommsInitial extends CommsState {
  const CommsInitial();
}

class CommsConnecting extends CommsState {
  const CommsConnecting(this.roomId);

  final String roomId;

  @override
  List<Object?> get props => [roomId];
}

class CommsConnected extends CommsState {
  const CommsConnected(
    this.roomId, {
    this.isTransmitting = false,
  });

  final String roomId;
  final bool isTransmitting;

  CommsConnected copyWith({
    String? roomId,
    bool? isTransmitting,
  }) {
    return CommsConnected(
      roomId ?? this.roomId,
      isTransmitting: isTransmitting ?? this.isTransmitting,
    );
  }

  @override
  List<Object?> get props => [roomId, isTransmitting];
}

class CommsFailure extends CommsState {
  const CommsFailure(this.message);

  final String message;

  @override
  List<Object?> get props => [message];
}
