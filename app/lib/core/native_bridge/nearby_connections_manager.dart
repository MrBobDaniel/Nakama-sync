import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NearbyConnectionsManager {
  static const MethodChannel _channel =
      MethodChannel('nakama_sync.local/nearby_connections');
  static const EventChannel _eventChannel =
      EventChannel('nakama_sync.local/nearby_connections/events');

  static Stream<Map<String, dynamic>>? _events;

  static Future<void> startSession({
    required String roomId,
    required String displayName,
  }) async {
    try {
      await _channel.invokeMethod<void>('startSession', {
        'roomId': roomId,
        'displayName': displayName,
      });
    } on PlatformException catch (error) {
      debugPrint(
        "Failed to start Nearby Connections session: '${error.message}'.",
      );
      rethrow;
    }
  }

  static Future<void> setPushToTalkActive(bool isActive) async {
    try {
      await _channel.invokeMethod<void>('setPushToTalkActive', {
        'isActive': isActive,
      });
    } on PlatformException catch (error) {
      debugPrint(
        "Failed to change Nearby Connections audio stream state: '${error.message}'.",
      );
      rethrow;
    }
  }

  static Future<void> configureVoiceActivation({
    required bool isEnabled,
    required double sensitivity,
  }) async {
    try {
      await _channel.invokeMethod<void>('configureVoiceActivation', {
        'isEnabled': isEnabled,
        'sensitivity': sensitivity,
      });
    } on PlatformException catch (error) {
      debugPrint(
        "Failed to configure Nearby voice activation: '${error.message}'.",
      );
      rethrow;
    }
  }

  static Future<void> setMicrophoneMuted(bool isMuted) async {
    try {
      await _channel.invokeMethod<void>('setMicrophoneMuted', {
        'isMuted': isMuted,
      });
    } on PlatformException catch (error) {
      debugPrint(
        "Failed to update Nearby microphone mute state: '${error.message}'.",
      );
      rethrow;
    }
  }

  static Future<void> stopSession() async {
    try {
      await _channel.invokeMethod<void>('stopSession');
    } on PlatformException catch (error) {
      debugPrint(
        "Failed to stop Nearby Connections session: '${error.message}'.",
      );
    }
  }

  static Stream<Map<String, dynamic>> get events {
    return _events ??= _eventChannel.receiveBroadcastStream().map(
      (dynamic event) => Map<String, dynamic>.from(event as Map),
    );
  }
}
