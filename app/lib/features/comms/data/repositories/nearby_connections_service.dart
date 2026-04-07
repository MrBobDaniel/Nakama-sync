import 'dart:async';
import 'dart:io';

import '../../../../core/native_bridge/nearby_connections_manager.dart';
import 'comms_transport_service.dart';

class NearbyConnectionsService implements CommsTransportService {
  NearbyConnectionsService({
    String displayName = 'Nakama Sync',
  }) : _displayName = displayName;

  final String _displayName;

  @override
  Stream<Map<String, dynamic>> get events => NearbyConnectionsManager.events;

  @override
  Future<void> initialize(String roomId) {
    final platformSuffix = Platform.isIOS ? 'iPhone' : 'Android';
    return NearbyConnectionsManager.startSession(
      roomId: roomId,
      displayName: '$_displayName $platformSuffix',
    );
  }

  @override
  Future<void> setPushToTalkActive(bool isActive) {
    return NearbyConnectionsManager.setPushToTalkActive(isActive);
  }

  @override
  Future<void> configureVoiceActivation({
    required bool isEnabled,
    required double sensitivity,
  }) {
    return NearbyConnectionsManager.configureVoiceActivation(
      isEnabled: isEnabled,
      sensitivity: sensitivity,
    );
  }

  @override
  Future<void> setMicrophoneMuted(bool isMuted) {
    return NearbyConnectionsManager.setMicrophoneMuted(isMuted);
  }

  @override
  Future<void> dispose() {
    return NearbyConnectionsManager.stopSession();
  }
}
