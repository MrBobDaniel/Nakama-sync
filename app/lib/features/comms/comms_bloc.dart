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
    on<RoomAudioProfileChanged>(_onRoomAudioProfileChanged);
    on<DisconnectRequested>(_onDisconnectRequested);
    on<PushToTalkChanged>(_onPushToTalkChanged);
    on<MicrophoneMuteChanged>(_onMicrophoneMuteChanged);
    on<TransmitModeChanged>(_onTransmitModeChanged);
    on<VoiceActivationSensitivityChanged>(_onVoiceActivationSensitivityChanged);
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
    final normalizedRoomId = event.roomId.trim().toLowerCase();
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
      isVoiceActivationArmed: false,
      transmitMode: state.transmitMode,
    );
    emit(
      CommsSessionOpen(
        normalizedRoomId,
        statusMessage: 'Opening room for nearby connections.',
        diagnostics: diagnostics,
        isMicrophoneMuted: state.isMicrophoneMuted,
        transmitMode: state.transmitMode,
        voiceActivationSensitivity: state.voiceActivationSensitivity,
        audioProfile: event.audioProfile,
        peers: state.peers,
      ),
    );

    try {
      await _transportService.initialize(normalizedRoomId, event.audioProfile);
    } catch (error) {
      emit(
        CommsFailure(
          error.toString(),
          roomId: normalizedRoomId,
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
            isVoiceActivationArmed: false,
            transmitMode: state.transmitMode,
          ),
          isMicrophoneMuted: state.isMicrophoneMuted,
          transmitMode: state.transmitMode,
          voiceActivationSensitivity: state.voiceActivationSensitivity,
          audioProfile: event.audioProfile,
        ),
      );
    }
  }

  void _onRoomAudioProfileChanged(
    RoomAudioProfileChanged event,
    Emitter<CommsState> emit,
  ) {
    final diagnostics = _appendDiagnostic(
      state.diagnostics,
      CommsDiagnosticEntry(
        event: 'room_audio_profile_changed',
        message:
            'Room audio profile set to ${event.audioProfile.label} (${event.audioProfile.sampleRate ~/ 1000} kHz).',
      ),
      connectedPeers: state.diagnostics.connectedPeers,
      isDiscovering: state.diagnostics.isDiscovering,
      isTransmitting: state.diagnostics.isTransmitting,
      isReceivingAudio: state.diagnostics.isReceivingAudio,
      isVoiceActivationArmed: state.diagnostics.isVoiceActivationArmed,
      transmitMode: state.transmitMode,
    );

    switch (state) {
      case CommsConnected():
      case CommsSessionOpen():
        return;
      case CommsFailure currentState:
        emit(
          CommsFailure(
            currentState.message,
            roomId: currentState.roomId,
            diagnostics: diagnostics,
            isMicrophoneMuted: currentState.isMicrophoneMuted,
            transmitMode: currentState.transmitMode,
            voiceActivationSensitivity: currentState.voiceActivationSensitivity,
            audioProfile: event.audioProfile,
          ),
        );
      case CommsInitial currentState:
        emit(
          CommsInitial(
            statusMessage: currentState.statusMessage,
            diagnostics: diagnostics,
            isMicrophoneMuted: currentState.isMicrophoneMuted,
            transmitMode: currentState.transmitMode,
            voiceActivationSensitivity: currentState.voiceActivationSensitivity,
            audioProfile: event.audioProfile,
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
          isVoiceActivationArmed: false,
          transmitMode: state.transmitMode,
        ),
        isMicrophoneMuted: state.isMicrophoneMuted,
        transmitMode: state.transmitMode,
        voiceActivationSensitivity: state.voiceActivationSensitivity,
        audioProfile: state.audioProfile,
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

    if (currentState.transmitMode == CommsTransmitMode.voiceActivated) {
      emit(
        currentState.copyWith(
          statusMessage:
              'Voice activation is enabled. Use the mode switch to return to Hold to Talk.',
          diagnostics: _appendDiagnostic(
            currentState.diagnostics,
            const CommsDiagnosticEntry(
              event: 'push_to_talk_blocked',
              message:
                  'Hold to Talk ignored while voice activation is enabled.',
            ),
            connectedPeers: currentState.connectedPeers,
            isDiscovering: false,
            isTransmitting: currentState.isTransmitting,
            isReceivingAudio: currentState.isReceivingAudio,
            isVoiceActivationArmed: currentState.isVoiceActivationArmed,
            transmitMode: currentState.transmitMode,
          ),
        ),
      );
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
              message: 'Hold to Talk ignored because the microphone is muted.',
            ),
            connectedPeers: currentState.connectedPeers,
            isDiscovering: false,
            isTransmitting: false,
            isReceivingAudio: currentState.isReceivingAudio,
            isVoiceActivationArmed: currentState.isVoiceActivationArmed,
            transmitMode: currentState.transmitMode,
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
          statusMessage: _connectedStatusMessage(
            roomId: currentState.roomId,
            connectedPeers: currentState.connectedPeers,
            isTransmitting: event.isActive,
            isReceivingAudio: currentState.isReceivingAudio,
            transmitMode: currentState.transmitMode,
            isVoiceActivationArmed: currentState.isVoiceActivationArmed,
          ),
          diagnostics: _appendDiagnostic(
            currentState.diagnostics,
            CommsDiagnosticEntry(
              event: event.isActive ? 'push_to_talk_down' : 'push_to_talk_up',
              message: event.isActive
                  ? 'Hold to Talk pressed.'
                  : 'Hold to Talk released.',
            ),
            connectedPeers: currentState.connectedPeers,
            isDiscovering: false,
            isTransmitting: event.isActive,
            isReceivingAudio: currentState.isReceivingAudio,
            isVoiceActivationArmed: currentState.isVoiceActivationArmed,
            transmitMode: currentState.transmitMode,
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
            isVoiceActivationArmed: currentState.isVoiceActivationArmed,
            transmitMode: currentState.transmitMode,
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
      isVoiceActivationArmed:
          event.isMuted ? false : state.diagnostics.isVoiceActivationArmed,
      transmitMode: state.transmitMode,
    );

    switch (state) {
      case CommsConnected currentState:
        emit(
          currentState.copyWith(
            isTransmitting: false,
            statusMessage: event.isMuted
                ? 'Microphone muted on this device.'
                : _connectedStatusMessage(
                    roomId: currentState.roomId,
                    connectedPeers: currentState.connectedPeers,
                    isTransmitting: false,
                    isReceivingAudio: currentState.isReceivingAudio,
                    transmitMode: currentState.transmitMode,
                    isVoiceActivationArmed:
                        !event.isMuted &&
                        currentState.transmitMode ==
                            CommsTransmitMode.voiceActivated,
                  ),
            diagnostics: diagnostics,
            isMicrophoneMuted: event.isMuted,
            isVoiceActivationArmed:
                !event.isMuted &&
                currentState.transmitMode == CommsTransmitMode.voiceActivated,
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
            transmitMode: currentState.transmitMode,
            voiceActivationSensitivity: currentState.voiceActivationSensitivity,
            audioProfile: currentState.audioProfile,
          ),
        );
      case CommsInitial currentState:
        emit(
          CommsInitial(
            statusMessage: currentState.statusMessage,
            diagnostics: diagnostics,
            isMicrophoneMuted: event.isMuted,
            transmitMode: currentState.transmitMode,
            voiceActivationSensitivity: currentState.voiceActivationSensitivity,
            audioProfile: currentState.audioProfile,
          ),
        );
    }

    if (state is CommsConnected && state.diagnostics.isTransmitting) {
      try {
        await _transportService.setPushToTalkActive(false);
      } catch (_) {}
    }

    try {
      await _transportService.setMicrophoneMuted(event.isMuted);
      if (state is CommsConnected) {
        await _transportService.configureVoiceActivation(
          isEnabled:
              !event.isMuted &&
              state.transmitMode == CommsTransmitMode.voiceActivated,
          sensitivity: state.voiceActivationSensitivity,
        );
      }
    } catch (_) {}
  }

  Future<void> _onTransmitModeChanged(
    TransmitModeChanged event,
    Emitter<CommsState> emit,
  ) async {
    final diagnostics = _appendDiagnostic(
      state.diagnostics,
      CommsDiagnosticEntry(
        event: 'transmit_mode_changed',
        message: event.mode == CommsTransmitMode.voiceActivated
            ? 'Voice-activated transmit enabled.'
            : 'Hold to Talk enabled.',
      ),
      connectedPeers: state.diagnostics.connectedPeers,
      isDiscovering: state.diagnostics.isDiscovering,
      isTransmitting: false,
      isReceivingAudio: state.diagnostics.isReceivingAudio,
      isVoiceActivationArmed:
          !state.isMicrophoneMuted &&
          event.mode == CommsTransmitMode.voiceActivated,
      transmitMode: event.mode,
    );

    Future<void> syncTransportForConnectedState(CommsConnected currentState) async {
      await _transportService.setPushToTalkActive(false);
      await _transportService.configureVoiceActivation(
        isEnabled:
            event.mode == CommsTransmitMode.voiceActivated &&
            !currentState.isMicrophoneMuted,
        sensitivity: currentState.voiceActivationSensitivity,
      );
    }

    switch (state) {
      case CommsConnected currentState:
        try {
          await syncTransportForConnectedState(currentState);
        } catch (_) {}
        emit(
          currentState.copyWith(
            isTransmitting: false,
            transmitMode: event.mode,
            isVoiceActivationArmed:
                !currentState.isMicrophoneMuted &&
                event.mode == CommsTransmitMode.voiceActivated,
            diagnostics: diagnostics,
            statusMessage: _connectedStatusMessage(
              roomId: currentState.roomId,
              connectedPeers: currentState.connectedPeers,
              isTransmitting: false,
              isReceivingAudio: currentState.isReceivingAudio,
              transmitMode: event.mode,
              isVoiceActivationArmed:
                  !currentState.isMicrophoneMuted &&
                  event.mode == CommsTransmitMode.voiceActivated,
            ),
          ),
        );
      case CommsSessionOpen currentState:
        emit(
          currentState.copyWith(
            transmitMode: event.mode,
            isVoiceActivationArmed: false,
            diagnostics: diagnostics,
          ),
        );
      case CommsFailure currentState:
        emit(
          CommsFailure(
            currentState.message,
            roomId: currentState.roomId,
            diagnostics: diagnostics,
            isMicrophoneMuted: currentState.isMicrophoneMuted,
            transmitMode: event.mode,
            voiceActivationSensitivity: currentState.voiceActivationSensitivity,
            audioProfile: currentState.audioProfile,
          ),
        );
      case CommsInitial currentState:
        emit(
          CommsInitial(
            statusMessage: currentState.statusMessage,
            diagnostics: diagnostics,
            isMicrophoneMuted: currentState.isMicrophoneMuted,
            transmitMode: event.mode,
            voiceActivationSensitivity: currentState.voiceActivationSensitivity,
            audioProfile: currentState.audioProfile,
          ),
        );
    }
  }

  Future<void> _onVoiceActivationSensitivityChanged(
    VoiceActivationSensitivityChanged event,
    Emitter<CommsState> emit,
  ) async {
    final clampedSensitivity = event.sensitivity.clamp(0.0, 1.0);
    final diagnostics = _appendDiagnostic(
      state.diagnostics,
      CommsDiagnosticEntry(
        event: 'voice_activation_sensitivity_changed',
        message:
            'Voice activation sensitivity set to ${_voiceSensitivityLabel(clampedSensitivity)}.',
      ),
      connectedPeers: state.diagnostics.connectedPeers,
      isDiscovering: state.diagnostics.isDiscovering,
      isTransmitting: state.diagnostics.isTransmitting,
      isReceivingAudio: state.diagnostics.isReceivingAudio,
      isVoiceActivationArmed: state.diagnostics.isVoiceActivationArmed,
      transmitMode: state.transmitMode,
    );

    if (state is CommsConnected &&
        state.transmitMode == CommsTransmitMode.voiceActivated &&
        !state.isMicrophoneMuted) {
      try {
        await _transportService.configureVoiceActivation(
          isEnabled: true,
          sensitivity: clampedSensitivity,
        );
      } catch (_) {}
    }

    switch (state) {
      case CommsConnected currentState:
        emit(
          currentState.copyWith(
            voiceActivationSensitivity: clampedSensitivity,
            diagnostics: diagnostics,
          ),
        );
      case CommsSessionOpen currentState:
        emit(
          currentState.copyWith(
            voiceActivationSensitivity: clampedSensitivity,
            diagnostics: diagnostics,
          ),
        );
      case CommsFailure currentState:
        emit(
          CommsFailure(
            currentState.message,
            roomId: currentState.roomId,
            diagnostics: diagnostics,
            isMicrophoneMuted: currentState.isMicrophoneMuted,
            transmitMode: currentState.transmitMode,
            voiceActivationSensitivity: clampedSensitivity,
            audioProfile: currentState.audioProfile,
          ),
        );
      case CommsInitial currentState:
        emit(
          CommsInitial(
            statusMessage: currentState.statusMessage,
            diagnostics: diagnostics,
            isMicrophoneMuted: currentState.isMicrophoneMuted,
            transmitMode: currentState.transmitMode,
            voiceActivationSensitivity: clampedSensitivity,
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
    final peers = _peersFromPayload(payload, fallback: state.peers);
    final connectedPeerCount = _connectedPeerCount(payload, peers);
    final isReceivingAudio = _receivingAudioFromPayload(payload, peers);
    final transmitMode = _transmitModeFromPayload(payload, state.transmitMode);
    final isVoiceActivationArmed = _voiceActivationArmedFromPayload(
      payload,
      fallback: state.isVoiceActivationArmed,
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
              peers: peers,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
              transmitMode: transmitMode,
              voiceActivationSensitivity: state.voiceActivationSensitivity,
              isVoiceActivationArmed: isVoiceActivationArmed,
              audioProfile: state.audioProfile,
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
              peers: peers,
              diagnostics: diagnostics,
              isVoiceActivationArmed: isVoiceActivationArmed,
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
              peers: peers,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
              transmitMode: transmitMode,
              voiceActivationSensitivity: state.voiceActivationSensitivity,
              isVoiceActivationArmed: isVoiceActivationArmed,
              audioProfile: state.audioProfile,
            ),
          );
        }
      case 'connected':
        if (roomId != null) {
          emit(
            CommsConnected(
              roomId,
              connectedPeers: connectedPeerCount,
              isReceivingAudio: isReceivingAudio,
              isTransmitting: diagnostics.isTransmitting,
              statusMessage: _connectedStatusMessage(
                roomId: roomId,
                connectedPeers: connectedPeerCount,
                isTransmitting: diagnostics.isTransmitting,
                isReceivingAudio: isReceivingAudio,
                transmitMode: transmitMode,
                isVoiceActivationArmed: isVoiceActivationArmed,
                fallbackMessage:
                    payload['message'] as String? ??
                    'Connected over Nearby Connections.',
              ),
              peers: peers,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
              transmitMode: transmitMode,
              voiceActivationSensitivity: state.voiceActivationSensitivity,
              isVoiceActivationArmed: isVoiceActivationArmed,
              audioProfile: state.audioProfile,
            ),
          );
        }
      case 'transmit_state':
        final currentState = state;
        if (currentState is CommsConnected) {
          emit(
            currentState.copyWith(
              isTransmitting: payload['isTransmitting'] as bool? ?? false,
              statusMessage: _connectedStatusMessage(
                roomId: currentState.roomId,
                connectedPeers: connectedPeerCount,
                isTransmitting: payload['isTransmitting'] as bool? ?? false,
                isReceivingAudio: currentState.isReceivingAudio,
                transmitMode: transmitMode,
                isVoiceActivationArmed: isVoiceActivationArmed,
                fallbackMessage: payload['message'] as String?,
              ),
              connectedPeers: connectedPeerCount,
              peers: peers,
              diagnostics: diagnostics,
              transmitMode: transmitMode,
              isVoiceActivationArmed: isVoiceActivationArmed,
            ),
          );
        }
      case 'receive_state':
        final currentState = state;
        if (currentState is CommsConnected) {
          emit(
            currentState.copyWith(
              isReceivingAudio: isReceivingAudio,
              connectedPeers: connectedPeerCount,
              statusMessage: _connectedStatusMessage(
                roomId: currentState.roomId,
                connectedPeers: connectedPeerCount,
                isTransmitting: currentState.isTransmitting,
                isReceivingAudio: isReceivingAudio,
                transmitMode: transmitMode,
                isVoiceActivationArmed: isVoiceActivationArmed,
                fallbackMessage: payload['message'] as String?,
              ),
              peers: peers,
              diagnostics: diagnostics,
              transmitMode: transmitMode,
              isVoiceActivationArmed: isVoiceActivationArmed,
            ),
          );
        }
      case 'os_session_state':
        switch (state) {
          case CommsConnected currentState:
            emit(
              currentState.copyWith(
                isReceivingAudio: isReceivingAudio,
                isTransmitting: diagnostics.isTransmitting,
                connectedPeers: connectedPeerCount,
                statusMessage: _connectedStatusMessage(
                  roomId: currentState.roomId,
                  connectedPeers: connectedPeerCount,
                  isTransmitting: diagnostics.isTransmitting,
                  isReceivingAudio: isReceivingAudio,
                  transmitMode: transmitMode,
                  isVoiceActivationArmed: isVoiceActivationArmed,
                  fallbackMessage: payload['message'] as String?,
                ),
                peers: peers,
                diagnostics: diagnostics,
                transmitMode: transmitMode,
                isVoiceActivationArmed: isVoiceActivationArmed,
              ),
            );
          case CommsSessionOpen currentState:
            emit(
              currentState.copyWith(
                statusMessage:
                    payload['message'] as String? ?? currentState.statusMessage,
                peers: peers,
                diagnostics: diagnostics,
                transmitMode: transmitMode,
                isVoiceActivationArmed: isVoiceActivationArmed,
              ),
            );
          default:
            break;
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
              peers: peers,
              diagnostics: diagnostics,
              isMicrophoneMuted: state.isMicrophoneMuted,
              transmitMode: transmitMode,
              voiceActivationSensitivity: state.voiceActivationSensitivity,
              isVoiceActivationArmed: isVoiceActivationArmed,
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
            transmitMode: transmitMode,
            voiceActivationSensitivity: state.voiceActivationSensitivity,
            audioProfile: state.audioProfile,
          ),
        );
    }
  }

  List<CommsPeer> _peersFromPayload(
    Map<String, dynamic> payload, {
    required List<CommsPeer> fallback,
  }) {
    final rawPeers = payload['peers'];
    if (rawPeers is! List) {
      return fallback;
    }

    return rawPeers
        .whereType<Map>()
        .map(
          (peer) => CommsPeer(
            peerId: peer['peerId']?.toString() ?? 'unknown',
            displayName:
                peer['displayName']?.toString().trim().isNotEmpty == true
                ? peer['displayName'].toString()
                : 'Nearby peer',
            isConnected: peer['isConnected'] as bool? ?? false,
            isSpeaking: peer['isSpeaking'] as bool? ?? false,
            streamSampleRate: peer['streamSampleRate'] as int?,
            codec: peer['codec']?.toString(),
          ),
        )
        .toList(growable: false);
  }

  int _connectedPeerCount(Map<String, dynamic> payload, List<CommsPeer> peers) {
    return payload['connectedPeers'] as int? ??
        peers.where((peer) => peer.isConnected).length;
  }

  bool _receivingAudioFromPayload(
    Map<String, dynamic> payload,
    List<CommsPeer> peers,
  ) {
    return payload['isReceivingAudio'] as bool? ??
        peers.any((peer) => peer.isSpeaking);
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
      if (payload['codec'] case final String codec when codec.isNotEmpty)
        'Codec: $codec',
      if (payload['audioSampleRate'] case final int sampleRate)
        'Rate: ${sampleRate ~/ 1000} kHz',
      if (payload['frameDurationMs'] case final int frameDurationMs)
        'Frame: $frameDurationMs ms',
      if (payload['transportVersion'] case final int transportVersion)
        'Transport: v$transportVersion',
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
      isVoiceActivationArmed:
          payload['isVoiceActivationArmed'] as bool? ??
          fallback.isVoiceActivationArmed,
      transmitMode: _transmitModeFromPayload(payload, fallback.transmitMode),
      codec: payload['codec'] as String? ?? fallback.codec,
      audioSampleRate: payload['audioSampleRate'] as int? ?? fallback.audioSampleRate,
      frameDurationMs: payload['frameDurationMs'] as int? ?? fallback.frameDurationMs,
      transportVersion:
          payload['transportVersion'] as int? ?? fallback.transportVersion,
    );
  }

  CommsDiagnostics _appendDiagnostic(
    CommsDiagnostics current,
    CommsDiagnosticEntry entry, {
    required int connectedPeers,
    required bool isDiscovering,
    required bool isTransmitting,
    required bool isReceivingAudio,
    required bool isVoiceActivationArmed,
    required CommsTransmitMode transmitMode,
    String? codec,
    int? audioSampleRate,
    int? frameDurationMs,
    int? transportVersion,
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
      isVoiceActivationArmed: isVoiceActivationArmed,
      transmitMode: transmitMode,
      codec: codec ?? current.codec,
      audioSampleRate: audioSampleRate ?? current.audioSampleRate,
      frameDurationMs: frameDurationMs ?? current.frameDurationMs,
      transportVersion: transportVersion ?? current.transportVersion,
      recentEvents: recentEvents,
    );
  }

  String _connectedStatusMessage({
    required String roomId,
    required int connectedPeers,
    required bool isTransmitting,
    required bool isReceivingAudio,
    required CommsTransmitMode transmitMode,
    required bool isVoiceActivationArmed,
    String? fallbackMessage,
  }) {
    if (isTransmitting && isReceivingAudio) {
      return 'Link is live with $connectedPeers peer(s) in room "$roomId".';
    }
    if (isTransmitting) {
      return 'Sending live voice to $connectedPeers peer(s) in room "$roomId".';
    }
    if (isReceivingAudio) {
      return 'Receiving live voice in room "$roomId".';
    }
    if (transmitMode == CommsTransmitMode.voiceActivated &&
        isVoiceActivationArmed) {
      return 'Voice activation is armed for room "$roomId".';
    }
    return fallbackMessage ?? 'Connected over Nearby Connections.';
  }

  CommsTransmitMode _transmitModeFromPayload(
    Map<String, dynamic> payload,
    CommsTransmitMode fallback,
  ) {
    return switch (payload['transmitMode']) {
      'voice_activated' => CommsTransmitMode.voiceActivated,
      'push_to_talk' => CommsTransmitMode.pushToTalk,
      _ => fallback,
    };
  }

  bool _voiceActivationArmedFromPayload(
    Map<String, dynamic> payload, {
    required bool fallback,
  }) {
    return payload['isVoiceActivationArmed'] as bool? ?? fallback;
  }

  String _voiceSensitivityLabel(double sensitivity) {
    if (sensitivity >= 0.72) {
      return 'High';
    }
    if (sensitivity >= 0.42) {
      return 'Medium';
    }
    return 'Low';
  }

  @override
  Future<void> close() async {
    await _transportSubscription.cancel();
    await _transportService.dispose();
    return super.close();
  }
}
