import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

typedef OnSignalCallback = void Function(Map<String, dynamic> data);
typedef OnPeerJoinedCallback = void Function(String peerId);
typedef OnPeerLeftCallback = void Function(String peerId);
typedef OnRoomPeersCallback = void Function(List<String> peerIds);

class SignalingClient {
  late io.Socket _socket;
  final String serverUrl;

  OnSignalCallback? onSignal;
  OnPeerJoinedCallback? onPeerJoined;
  OnPeerLeftCallback? onPeerLeft;
  OnRoomPeersCallback? onRoomPeers;

  SignalingClient(this.serverUrl);

  void connect(String roomId) {
    _socket = io.io(serverUrl, io.OptionBuilder()
        .setTransports(['websocket'])
        .enableAutoConnect()
        .build());

    _socket.onConnect((_) {
      debugPrint('Signaling connected');
      _socket.emit('join', roomId);
    });

    _socket.on('peer-joined', (peerId) {
      debugPrint('Peer joined: $peerId');
      onPeerJoined?.call(peerId);
    });

    _socket.on('room-peers', (peerIds) {
      final normalizedPeerIds =
          (peerIds as List<dynamic>).map((peerId) => peerId.toString()).toList();
      onRoomPeers?.call(normalizedPeerIds);
    });

    _socket.on('signal', (data) {
      onSignal?.call(data);
    });

    _socket.on('peer-left', (peerId) {
      debugPrint('Peer left: $peerId');
      onPeerLeft?.call(peerId);
    });
  }

  void sendSignal(String targetPeerId, Map<String, dynamic> signalData) {
    _socket.emit('signal', {
      'target': targetPeerId,
      'signalData': signalData,
    });
  }

  void disconnect() {
    _socket.disconnect();
  }
}
