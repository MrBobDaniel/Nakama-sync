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
    emit(
      CommsSessionOpen(
        event.roomId,
        statusMessage: 'Opening room for nearby connections.',
      ),
    );

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

    try {
      await _transportService.setPushToTalkActive(event.isActive);
      emit(currentState.copyWith(isTransmitting: event.isActive));
    } catch (error) {
      emit(
        currentState.copyWith(
          isTransmitting: false,
          statusMessage: error.toString(),
        ),
      );
    }
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
          CommsSessionOpen(:final roomId) => roomId,
          CommsConnected(:final roomId) => roomId,
          CommsFailure(:final roomId) => roomId,
          _ => null,
        };

    switch (eventType) {
      case 'session_started':
        if (roomId != null) {
          emit(
            CommsSessionOpen(
              roomId,
              statusMessage: payload['message'] as String? ??
                  'Room is open and Nearby discovery is active.',
              isDiscovering: payload['isDiscovering'] as bool? ?? true,
            ),
          );
        }
      case 'discovery_idle':
        final currentState = state;
        if (currentState is CommsSessionOpen) {
          emit(
            currentState.copyWith(
              statusMessage: payload['message'] as String? ??
                  'Room is open. Listening for incoming connections.',
              isDiscovering: false,
            ),
          );
        }
      case 'peer_discovered':
      case 'connection_initiated':
        if (roomId != null) {
          emit(
            CommsSessionOpen(
              roomId,
              statusMessage: payload['message'] as String? ?? 'Nearby peer found.',
              isDiscovering: payload['isDiscovering'] as bool? ?? true,
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
            CommsSessionOpen(
              roomId,
              statusMessage: payload['message'] as String? ??
                  'Peer disconnected. Room remains open for new connections.',
              isDiscovering: payload['isDiscovering'] as bool? ?? false,
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
