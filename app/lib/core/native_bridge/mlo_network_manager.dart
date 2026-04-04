import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges the Wi-Fi 7 Explicit Native APIs configuring "Diversity Mode".
/// Duplicates Opus audio packets concurrently across 2.4GHz and 5GHz.
class MloNetworkManager {
  static const MethodChannel _channel = MethodChannel('nakama.local/mlo_network');

  /// Initialize Wi-Fi Aware (NAN) connection with Diversity Mode
  static Future<void> initializeDiversityMode(String peerId) async {
    try {
      await _channel.invokeMethod('initializeDiversityMode', {'peerId': peerId});
    } on PlatformException catch (e) {
      debugPrint("Failed to initialize MLO Diversity Mode: '${e.message}'.");
    }
  }
}
