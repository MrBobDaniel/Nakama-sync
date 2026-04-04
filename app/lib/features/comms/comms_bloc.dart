import 'package:flutter_bloc/flutter_bloc.dart';

import 'data/repositories/webrtc_service.dart';
import 'comms_event.dart';
import 'comms_state.dart';

class CommsBloc extends Bloc<CommsEvent, CommsState> {
  CommsBloc({
    required WebRtcService webRtcService,
  })  : _webRtcService = webRtcService,
        super(const CommsInitial()) {
    on<ConnectToRoomRequested>(_onConnectToRoomRequested);
    on<DisconnectRequested>(_onDisconnectRequested);
    on<PushToTalkChanged>(_onPushToTalkChanged);
  }

  final WebRtcService _webRtcService;

  Future<void> _onConnectToRoomRequested(
    ConnectToRoomRequested event,
    Emitter<CommsState> emit,
  ) async {
    emit(CommsConnecting(event.roomId));

    try {
      await _webRtcService.initialize(event.roomId);
      emit(CommsConnected(event.roomId));
    } catch (error) {
      emit(CommsFailure(error.toString()));
    }
  }

  Future<void> _onDisconnectRequested(
    DisconnectRequested event,
    Emitter<CommsState> emit,
  ) async {
    await _webRtcService.dispose();
    emit(const CommsInitial());
  }

  Future<void> _onPushToTalkChanged(
    PushToTalkChanged event,
    Emitter<CommsState> emit,
  ) async {
    final currentState = state;
    if (currentState is! CommsConnected) {
      return;
    }

    await _webRtcService.setPushToTalkActive(event.isActive);
    emit(currentState.copyWith(isTransmitting: event.isActive));
  }

  @override
  Future<void> close() async {
    await _webRtcService.dispose();
    return super.close();
  }
}
