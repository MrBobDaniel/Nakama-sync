import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../../core/native_bridge/mlo_network_manager.dart';
import 'signaling_client.dart';

class WebRtcService {
  final SignalingClient signaling;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  Function(MediaStream)? onRemoteStreamAdded;

  WebRtcService(this.signaling) {
    signaling.onSignal = _handleSignal;
    signaling.onPeerJoined = _handlePeerJoined;
  }

  Future<void> initialize(String roomId) async {
    // Attempt MLO Diversity mode explicitly for Opus redundancy on hardware link
    await MloNetworkManager.initializeDiversityMode("remote_peer_placeholder");

    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        // Coturn config will be injected here during runtime fallback config
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection?.onIceCandidate = (candidate) {
      // Broadcast ICE candidate to remote peer
      signaling.sendSignal('remote_peer', {
        'type': 'candidate',
        'candidate': candidate.toMap(),
      });
    };

    _peerConnection?.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        onRemoteStreamAdded?.call(event.streams[0]);
      }
    };

    // Initialize very-low-latency Opus 64kbps local microphone capture
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });

    _localStream?.getTracks().forEach((track) {
      _peerConnection?.addTrack(track, _localStream!);
    });

    signaling.connect(roomId);
  }

  Future<void> _handlePeerJoined(String peerId) async {
    // Initiate SDP Offer when a peer joins
    if (_peerConnection != null) {
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      signaling.sendSignal(peerId, {
        'type': offer.type,
        'sdp': offer.sdp,
      });
    }
  }

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    final sender = data['sender'];
    final payload = data['signalData'];
    final type = payload['type'];

    if (_peerConnection == null) return;

    if (type == 'offer') {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(payload['sdp'], type),
      );
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      signaling.sendSignal(sender, {
        'type': answer.type,
        'sdp': answer.sdp,
      });
    } else if (type == 'answer') {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(payload['sdp'], type),
      );
    } else if (type == 'candidate') {
      final candidateMap = payload['candidate'];
      await _peerConnection!.addCandidate(
        RTCIceCandidate(
          candidateMap['candidate'],
          candidateMap['sdpMid'],
          candidateMap['sdpMLineIndex'],
        ),
      );
    }
  }

  Future<void> dispose() async {
    signaling.disconnect();
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.close();
    _peerConnection?.dispose();
  }
}
