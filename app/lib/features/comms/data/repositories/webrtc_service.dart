import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../../core/native_bridge/mlo_network_manager.dart';
import '../datasources/signaling_client.dart';

class WebRtcService {
  final SignalingClient signaling;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final Set<String> _remotePeerIds = <String>{};

  Function(MediaStream)? onRemoteStreamAdded;

  WebRtcService(this.signaling) {
    signaling.onSignal = _handleSignal;
    signaling.onPeerJoined = _handlePeerJoined;
    signaling.onRoomPeers = _handleRoomPeers;
  }

  Future<void> initialize(String roomId) async {
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        // Coturn config will be injected here during runtime fallback config
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection?.onIceCandidate = (candidate) {
      for (final remotePeerId in _remotePeerIds) {
        signaling.sendSignal(remotePeerId, {
          'type': 'candidate',
          'candidate': candidate.toMap(),
        });
      }
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
    await setPushToTalkActive(false);

    signaling.connect(roomId);
  }

  Future<void> setPushToTalkActive(bool isActive) async {
    final audioTracks = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    for (final track in audioTracks) {
      track.enabled = isActive;
    }
  }

  Future<void> _handleRoomPeers(List<String> peerIds) async {
    for (final peerId in peerIds) {
      await _handlePeerJoined(peerId);
    }
  }

  Future<void> _handlePeerJoined(String peerId) async {
    if (_peerConnection == null || _remotePeerIds.contains(peerId)) {
      return;
    }

    _remotePeerIds.add(peerId);
    await MloNetworkManager.initializeDiversityMode(peerId);

    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    signaling.sendSignal(peerId, {
      'type': offer.type,
      'sdp': offer.sdp,
    });
  }

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    final sender = data['sender'] as String;
    final payload = data['signalData'] as Map<String, dynamic>;
    final type = payload['type'];

    if (_peerConnection == null) return;

    _remotePeerIds.add(sender);

    if (type == 'offer') {
      await MloNetworkManager.initializeDiversityMode(sender);
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
    await setPushToTalkActive(false);
    signaling.disconnect();
    _remotePeerIds.clear();
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
    _peerConnection?.close();
    _peerConnection?.dispose();
    _peerConnection = null;
  }
}
