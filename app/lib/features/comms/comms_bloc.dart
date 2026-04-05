import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'comms_event.dart';
import 'comms_state.dart';
import 'data/repositories/comms_transport_service.dart';

class CommsBloc extends Bloc<CommsEvent, CommsState> {
  CommsBloc({required CommsTransportService transportService})
    : _transportService = transportService,
      super(const CommsInitial()) {
    on<ConnectToRoomRequested>(_onConnectToRoomRequested);
    on<DisconnectRequested>(_onDisconnectRequested);
    on<PushToTalkChanged>(_onPushToTalkChanged);
    on<MicrophoneMuteChanged>(_onMicrophoneMuteChanged);
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
    final diagnostics = _appendDiagnostic(
      state.diagnostics,
      const CommsDiagnosticEntry(
        event: 'open_room_requested',
        message: 'Opening room for nearby connections.',
      ),
      connectedPeers: 0,
      isDiscovering: true,
      isTransmitting: false,
      isReceivingAudio: false,
    );
    emit(
      CommsSessionOpen(
        event.roomId,
        statusMessage: 'Opening room for nearby connections.',
        diagnostics: diagnostics,
        isMicrophoneMuted: state.isMicrophoneMuted,
      ),
    );

    try {
      await _transportService.initialize(event.roomId);
    } catch (error) {
      emit(
        CommsFailure(
          error.toString(),
          roomId: event.roomId,
          diagnostics: _appendDiagnostic(
            diagnostics,
            CommsDiagnosticEntry(
              event: 'initialize_error',
              message: error.toString(),
            ),
            connectedPeers: 0,
            isDiscovering: false,
            isTransmitting: false,
            isReceivingAudio: false,
          ),
          isMicrophoneMuted: state.isMicrophoneMuted,
        ),
      );
    }
  }

  Future<void> _onDisconnectRequested(
    DisconnectRequested event,
    Emitter<CommsState> emit,
  ) async {
    await _transportService.dispose();
    emit(
      CommsInitial(
        diagnostics: _appendDiagnostic(
          state.diagnostics,
          const CommsDiagnosticEntry(
            event: 'session_closed',
            message: 'Room closed locally.',
          ),
          connectedPeers: 0,
          isDiscovering: false,
          isTransmitting: false,
          isReceivingAudio: false,
        ),
        isMicrophoneMuted: state.isMicrophoneMuted,
      ),
    );
  }

  Future<void> _onPushToTalkChanged(
    PushToTalkChanged event,
    Emitter<CommsState> emit,
  ) async {
    final currentState = state;
    if (currentState is! CommsConnected) {
      return;
    }

    if (currentState.isMicrophoneMuted && event.isActive) {
      emit(
        currentState.copyWith(
          isTransmitting: false,
          statusMessage: 'Microphone is muted on this device.',
          diagnostics: _appendDiagnostic(
            currentState.diagnostics,
            const CommsDiagnosticEntry(
              event: 'push_to_talk_blocked',
              message: 'Push-to-talk ignored because the microphone is muted.',
            ),
            connectedPeers: currentState.connectedPeers,
            isDiscovering: false,
            isTransmitting: false,
            isReceivingAudio: currentState.isReceivingAudio,
          ),
        ),
      );
      return;
    }

    try {
      await _transportService.setPushToTalkActive(event.isActive);
      emit(
        currentState.copyWith(
          isTransmitting: event.isActive,
          diagnostics: _appendDiagnostic(
            currentState.diagnostics,
            CommsDiagnosticEntry(
              event: event.isActive ? 'push_to_talk_down' : 'push_to_talk_up',
              message: event.isActive
                  ? 'Push-to-talk pressed.'
                  : 'Push-to-talk released.',
            ),
            connectedPeers: currentState.connectedPeers,
            isDiscovering: false,
            isTransmitting: event.isActive,
            isReceivingAudio: currentState.isReceivingAudio,
          ),
        ),
      );
    } catch (error) {
      emit(
        currentState.copyWith(
          isTransmitting: false,
          statusMessage: error.toString(),
          diagnostics: _appendDiagnostic(
            currentState.diagnostics,
            CommsDiagnosticEntry(
              event: 'push_to_talk_error',
              message: error.toString(),
            ),
            connectedPeers: currentState.connectedPeers,
            isDiscovering: false,
            isTransmitting: false,
            isReceivingAudio: currentState.isReceivingAudio,
          ),
        ),
      );
    }
  }

  Future<void> _onMicrophoneMuteChanged(
    MicrophoneMuteChanged event,
    Emitter<CommsState> emit,
  ) async {
    final diagnostics = _appendDiagnostic(
      state.diagnostics,
      CommsDiagnosticEntry(
        event: event.isMuted ? 'microphone_muted' : 'microphone_unmuted',
        message: event.isMuted
            ? 'Microphone muted on this device.'
            : 'Microphone unmuted on this device.',
      ),
      connectedPeers: state.diagnostics.connectedPeers,
      isDiscovering: state.diagnostics.isDiscovering,
      isTransmitting: false,
      isReceivingAudio: state.diagnostics.isReceivingAudio,
    );

    if (event.isMuted &&
        state is CommsConnected &&
        state.diagnostics.isTransmitting) {
      try {
        await _transportService.setPushToTalkActive(false);
      } catch (_) {}
    }

    switch (state) {
      case CommsConnected currentState:
        emit(
          currentState.copyWith(
            isTransmitting: false,
            statusMessage: event.isMuted
                ? 'Microphone muted on this device.'
                : currentState.statusMessage,
            diagnostics: diagnostics,
            isMicrophoneMuted: event.isMuted,
          ),
        );
      case CommsSessionOpen currentState:
        emit(
          currentState.copyWith(
            diagnostics: diagnostics,
            isMicrophoneMuted: event.isMuted,
          ),
        );
      case CommsFailure currentState:
        emit(
          CommsFailure(
            currentState.message,
            roomId: currentState.roomId,
            diagnostics: diagnostics,
            isMicrophoneMuted: event.isMuted,
          ),
        );
      case CommsInitial currentState:
        emit(
          CommsInitial(
            statusMessage: currentState.statusMessage,
            diagnostics: diagnostics,
            isMicrophoneMuted: event.isMuted,
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
    final diagnostics = _diagnosticsFromPayload(
      payload,
      fallback: state.diagnostics,
    );

    switch (eventType) {
      case 'session_started':
        if (roomId != null) {
          emit(
            CommsSessionOpen(
              roomId,
              statusMessage:
                  payload['message'] as String? ??
                  'Room is open and Nearby discovery is active.',
              isDiscovering: payload['isDiscovering'] as bool? ?? true,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
            ),
          );
        }
      case 'discovery_idle':
        final currentState = state;
        if (currentState is CommsSessionOpen) {
          emit(
            currentState.copyWith(
              statusMessage:
                  payload['message'] as String? ??
                  'Room is open. Listening for incoming connections.',
              isDiscovering: false,
              diagnostics: diagnostics,
            ),
          );
        }
      case 'peer_discovered':
      case 'connection_initiated':
        if (roomId != null) {
          emit(
            CommsSessionOpen(
              roomId,
              statusMessage:
                  payload['message'] as String? ?? 'Nearby peer found.',
              isDiscovering: payload['isDiscovering'] as bool? ?? true,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
            ),
          );
        }
      case 'connected':
        if (roomId != null) {
          emit(
            CommsConnected(
              roomId,
              connectedPeers: payload['connectedPeers'] as int? ?? 1,
              statusMessage:
                  payload['message'] as String? ??
                  'Connected over Nearby Connections.',
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
            ),
          );
        }
      case 'transmit_state':
        final currentState = state;
        if (currentState is CommsConnected) {
          emit(
            currentState.copyWith(
              isTransmitting: payload['isTransmitting'] as bool? ?? false,
              statusMessage:
                  payload['message'] as String? ?? currentState.statusMessage,
              diagnostics: diagnostics,
            ),
          );
        }
      case 'receive_state':
        final currentState = state;
        if (currentState is CommsConnected) {
          emit(
            currentState.copyWith(
              isReceivingAudio: payload['isReceivingAudio'] as bool? ?? false,
              statusMessage:
                  payload['message'] as String? ?? currentState.statusMessage,
              diagnostics: diagnostics,
            ),
          );
        }
      case 'disconnected':
        if (roomId != null) {
          emit(
            CommsSessionOpen(
              roomId,
              statusMessage:
                  payload['message'] as String? ??
                  'Peer disconnected. Room remains open for new connections.',
              isDiscovering: payload['isDiscovering'] as bool? ?? false,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
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
            diagnostics: diagnostics,
            isMicrophoneMuted: state.isMicrophoneMuted,
          ),
        );
    }
  }

  CommsDiagnostics _diagnosticsFromPayload(
    Map<String, dynamic> payload, {
    required CommsDiagnostics fallback,
  }) {
    final event = payload['event'] as String? ?? 'unknown';
    final message = payload['message'] as String? ?? 'No transport message.';
    final details = <String>[
      if (payload['peerDisplayName'] case final String peerDisplayName
          when peerDisplayName.isNotEmpty)
        'Peer: $peerDisplayName',
      if (payload['roomId'] case final String roomId when roomId.isNotEmpty)
        'Room: $roomId',
    ];

    return _appendDiagnostic(
      fallback,
      CommsDiagnosticEntry(event: event, message: message, details: details),
      connectedPeers:
          payload['connectedPeers'] as int? ?? fallback.connectedPeers,
      isDiscovering:
          payload['isDiscovering'] as bool? ?? fallback.isDiscovering,
      isTransmitting:
          payload['isTransmitting'] as bool? ?? fallback.isTransmitting,
      isReceivingAudio:
          payload['isReceivingAudio'] as bool? ?? fallback.isReceivingAudio,
    );
  }

  CommsDiagnostics _appendDiagnostic(
    CommsDiagnostics current,
    CommsDiagnosticEntry entry, {
    required int connectedPeers,
    required bool isDiscovering,
    required bool isTransmitting,
    required bool isReceivingAudio,
  }) {
    final recentEvents = <CommsDiagnosticEntry>[
      entry,
      ...current.recentEvents,
    ].take(6).toList(growable: false);

    return current.copyWith(
      lastEvent: entry.event,
      lastMessage: entry.message,
      connectedPeers: connectedPeers,
      isDiscovering: isDiscovering,
      isTransmitting: isTransmitting,
      isReceivingAudio: isReceivingAudio,
      recentEvents: recentEvents,
    );
  }

  @override
  Future<void> close() async {
    await _transportSubscription.cancel();
    await _transportService.dispose();
    return super.close();
  }
}
