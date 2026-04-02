import 'package:socket_io_client/socket_io_client.dart' as IO;

typedef OnSignalCallback = void Function(Map<String, dynamic> data);
typedef OnPeerJoinedCallback = void Function(String peerId);
typedef OnPeerLeftCallback = void Function(String peerId);

class SignalingClient {
  late IO.Socket _socket;
  final String serverUrl;

  OnSignalCallback? onSignal;
  OnPeerJoinedCallback? onPeerJoined;
  OnPeerLeftCallback? onPeerLeft;

  SignalingClient(this.serverUrl);

  void connect(String roomId) {
    _socket = IO.io(serverUrl, IO.OptionBuilder()
        .setTransports(['websocket'])
        .enableAutoConnect()
        .build());

    _socket.onConnect((_) {
      print('Signaling connected');
      _socket.emit('join', roomId);
    });

    _socket.on('peer-joined', (peerId) {
      print('Peer joined: $peerId');
      onPeerJoined?.call(peerId);
    });

    _socket.on('signal', (data) {
      onSignal?.call(data);
    });

    _socket.on('peer-left', (peerId) {
      print('Peer left: $peerId');
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
