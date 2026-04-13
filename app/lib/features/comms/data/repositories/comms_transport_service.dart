import 'dart:async';

import '../../comms_audio_profile.dart';

abstract class CommsTransportService {
  Stream<Map<String, dynamic>> get events;

  Future<void> initialize(String roomId, CommsAudioProfile audioProfile);
  Future<void> setPushToTalkActive(bool isActive);
  Future<void> configureVoiceActivation({
    required bool isEnabled,
    required double sensitivity,
  });
  Future<void> setMicrophoneMuted(bool isMuted);
  Future<void> dispose();
}
