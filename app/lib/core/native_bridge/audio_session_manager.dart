import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reactive Streams emitting link-switching events, mixing Subsonic audio 
/// when WebRTC voices trigger CallKit/ConnectionService channels.
class AudioSessionManager {
  static const MethodChannel _channel = MethodChannel('nakama.local/audio_session');
  static const EventChannel _eventChannel = EventChannel('nakama.local/audio_events');

  /// Requests high-priority telephony abstraction to prevent mic suspension
  static Future<void> requestPriorityVoiceCall() async {
    try {
      await _channel.invokeMethod('requestPriorityVoiceCall');
    } on PlatformException catch (e) {
      debugPrint("Failed to request priority voice call: '${e.message}'.");
    }
  }

  /// Listen to reactive audio events directly from the Native Bridge
  static Stream<dynamic> get audioEventsStream {
    return _eventChannel.receiveBroadcastStream();
  }
}
