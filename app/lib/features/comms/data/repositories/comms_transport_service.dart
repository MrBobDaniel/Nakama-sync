import 'dart:async';

abstract class CommsTransportService {
  Stream<Map<String, dynamic>> get events;

  Future<void> initialize(String roomId);
  Future<void> setPushToTalkActive(bool isActive);
  Future<void> dispose();
}
