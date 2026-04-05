import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'comms_event.dart';
import 'comms_state.dart';
import 'data/repositories/comms_transport_service.dart';

class CommsBloc extends Bloc<CommsEvent, CommsState> {
  CommsBloc({
    required CommsTransportService transportService,
  })  : _transportService = transportService,
        super(const CommsInitial()) {
    on<ConnectToRoomRequested>(_onConnectToRoomRequested);
    on<DisconnectRequested>(_onDisconnectRequested);
    on<PushToTalkChanged>(_onPushToTalkChanged);
    on<TransportStatusChanged>(_onTransportStatusChanged);

    _transportSubscription = _transportService.events.listen(
      (payload) => add(TransportStatusChanged(payload)),
    );
  }

  final CommsTransportService _transportService;
  late final StreamSubscription<Map<String, dynamic>> _transportSubscription;

  Future<void> _onConnectToRoomRequested(
    ConnectToRoomRequested event,
    Emitter<CommsState> emit,
  ) async {
    emit(CommsConnecting(event.roomId));

    try {
      await _transportService.initialize(event.roomId);
    } catch (error) {
      emit(CommsFailure(error.toString(), roomId: event.roomId));
    }
  }

  Future<void> _onDisconnectRequested(
    DisconnectRequested event,
    Emitter<CommsState> emit,
  ) async {
    await _transportService.dispose();
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

    await _transportService.setPushToTalkActive(event.isActive);
    emit(currentState.copyWith(isTransmitting: event.isActive));
  }

  Future<void> _onTransportStatusChanged(
    TransportStatusChanged event,
    Emitter<CommsState> emit,
  ) async {
    final payload = event.payload;
    final eventType = payload['event'] as String? ?? 'unknown';
    final roomId =
        (payload['roomId'] as String?) ??
        switch (state) {
          CommsConnecting(:final roomId) => roomId,
          CommsConnected(:final roomId) => roomId,
          CommsFailure(:final roomId) => roomId,
          _ => null,
        };

    switch (eventType) {
      case 'session_started':
        if (roomId != null) {
          emit(
            CommsConnecting(
              roomId,
              statusMessage: payload['message'] as String? ??
                  'Advertising and discovering via Nearby Connections.',
            ),
          );
        }
      case 'peer_discovered':
      case 'connection_initiated':
        if (roomId != null) {
          emit(
            CommsConnecting(
              roomId,
              statusMessage: payload['message'] as String? ?? 'Nearby peer found.',
            ),
          );
        }
      case 'connected':
        if (roomId != null) {
          emit(
            CommsConnected(
              roomId,
              connectedPeers: payload['connectedPeers'] as int? ?? 1,
              statusMessage: payload['message'] as String? ??
                  'Connected over Nearby Connections.',
            ),
          );
        }
      case 'transmit_state':
        final currentState = state;
        if (currentState is CommsConnected) {
          emit(
            currentState.copyWith(
              isTransmitting: payload['isTransmitting'] as bool? ?? false,
              statusMessage: payload['message'] as String? ??
                  currentState.statusMessage,
            ),
          );
        }
      case 'disconnected':
        if (roomId != null) {
          emit(
            CommsConnecting(
              roomId,
              statusMessage: payload['message'] as String? ??
                  'Peer disconnected. Searching again.',
            ),
          );
        }
      case 'unsupported':
      case 'error':
        emit(
          CommsFailure(
            payload['message'] as String? ??
                'Nearby Connections is unavailable on this device.',
            roomId: roomId,
          ),
        );
    }
  }

  @override
  Future<void> close() async {
    await _transportSubscription.cancel();
    await _transportService.dispose();
    return super.close();
  }
}
