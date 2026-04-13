import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../comms_audio_profile.dart';
import '../../comms_bloc.dart';
import '../../comms_event.dart';
import '../../comms_state.dart';

class CommsScreen extends StatefulWidget {
  const CommsScreen({super.key});

  @override
  State<CommsScreen> createState() => _CommsScreenState();
}

class _CommsScreenState extends State<CommsScreen> {
  late final TextEditingController _roomController;
  bool _isTalkLatched = false;
  bool _isMomentaryTalking = false;
  bool _restoreLatchedStateAfterHold = false;

  @override
  void initState() {
    super.initState();
    _roomController = TextEditingController(text: 'gym-floor');
  }

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  void _setBroadcastActive(bool isActive) {
    context.read<CommsBloc>().add(PushToTalkChanged(isActive));
  }

  void _setTransmitMode(CommsTransmitMode mode) {
    context.read<CommsBloc>().add(TransmitModeChanged(mode));
  }

  void _toggleBroadcast() {
    if (_isMomentaryTalking) {
      return;
    }

    final nextLatchedState = !_isTalkLatched;
    setState(() {
      _isTalkLatched = nextLatchedState;
    });
    _setBroadcastActive(nextLatchedState);
  }

  void _startMomentaryBroadcast() {
    if (_isMomentaryTalking) {
      return;
    }

    setState(() {
      _restoreLatchedStateAfterHold = _isTalkLatched;
      _isTalkLatched = false;
      _isMomentaryTalking = true;
    });
    _setBroadcastActive(true);
  }

  void _stopMomentaryBroadcast() {
    if (!_isMomentaryTalking) {
      return;
    }

    final shouldRemainActive = _restoreLatchedStateAfterHold;
    setState(() {
      _isMomentaryTalking = false;
      _isTalkLatched = shouldRemainActive;
      _restoreLatchedStateAfterHold = false;
    });
    _setBroadcastActive(shouldRemainActive);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link'),
        actions: [
          IconButton(
            onPressed: () => context.go('/music'),
            icon: const Icon(Icons.library_music),
            tooltip: 'Music',
          ),
        ],
      ),
      body: BlocConsumer<CommsBloc, CommsState>(
        listener: (context, state) {
          if (state is CommsFailure) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(state.message)));
          }

          if ((state is! CommsConnected ||
                  state.transmitMode == CommsTransmitMode.voiceActivated) &&
              (_isTalkLatched || _isMomentaryTalking)) {
            setState(() {
              _isTalkLatched = false;
              _isMomentaryTalking = false;
              _restoreLatchedStateAfterHold = false;
            });
          }

          if (state.isMicrophoneMuted &&
              (_isTalkLatched || _isMomentaryTalking)) {
            setState(() {
              _isTalkLatched = false;
              _isMomentaryTalking = false;
              _restoreLatchedStateAfterHold = false;
            });
          }
        },
        builder: (context, state) {
          final isRoomOpen = state is CommsSessionOpen;
          final isConnected = state is CommsConnected;
          final isTransmitting =
              state is CommsConnected && state.isTransmitting;
          final isReceivingAudio =
              state is CommsConnected && state.isReceivingAudio;
          final isDuplexActive =
              state is CommsConnected &&
              state.isTransmitting &&
              state.isReceivingAudio;
          final isMicrophoneMuted = state.isMicrophoneMuted;
          final transmitMode = state.transmitMode;
          final isVoiceMode =
              transmitMode == CommsTransmitMode.voiceActivated;
          final isVoiceActivationArmed = state.isVoiceActivationArmed;
          final isBroadcastActive = _isTalkLatched || _isMomentaryTalking;
          final peers = state.peers;
          final activeSpeakers = peers
              .where((peer) => peer.isSpeaking)
              .toList();
          final roomId = switch (state) {
            CommsSessionOpen(:final roomId) => roomId,
            CommsConnected(:final roomId) => roomId,
            _ => _roomController.text.trim(),
          };

          return LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Link',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Join a room to discover nearby peers, then open a low-latency live link for voice.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _roomController,
                        enabled: !isRoomOpen && !isConnected,
                        decoration: const InputDecoration(
                          labelText: 'Room ID',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _RoomAudioProfileCard(
                        selectedProfile: state.audioProfile,
                        enabled: !isRoomOpen && !isConnected,
                        onProfileChanged: (profile) {
                          context.read<CommsBloc>().add(
                            RoomAudioProfileChanged(profile),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Card(
                        color: const Color(0xFF1A1A1A),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _statusLabel(state),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                switch (state) {
                                  CommsSessionOpen(
                                    :final statusMessage,
                                    :final isDiscovering,
                                  ) =>
                                    isDiscovering
                                        ? '$statusMessage You can leave this screen while it listens in the background.'
                                        : '$statusMessage You can keep using the app while this room waits for inbound peers.',
                                  CommsConnected(
                                    :final isTransmitting,
                                    :final isReceivingAudio,
                                    :final connectedPeers,
                                    :final statusMessage,
                                  ) =>
                                    isTransmitting && isReceivingAudio
                                        ? 'Link is live with $connectedPeers peer(s) in room "$roomId".'
                                        : isTransmitting
                                        ? 'Sending live voice to $connectedPeers peer(s) in room "$roomId".'
                                        : isReceivingAudio
                                        ? 'Receiving live voice from ${activeSpeakers.length} active peer(s) in room "$roomId".'
                                        : statusMessage,
                                  CommsFailure(:final message) => message,
                                  CommsInitial(:final statusMessage) =>
                                    statusMessage,
                                  _ => 'Idle. No room open yet.',
                                },
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isRoomOpen || isConnected) ...[
                        const SizedBox(height: 16),
                        _TransmitModeCard(
                          mode: transmitMode,
                          isMicrophoneMuted: isMicrophoneMuted,
                          sensitivity: state.voiceActivationSensitivity,
                          onModeChanged: _setTransmitMode,
                          onSensitivityChanged: (value) {
                            context.read<CommsBloc>().add(
                              VoiceActivationSensitivityChanged(value),
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: isRoomOpen || isConnected
                            ? null
                            : () {
                                final requestedRoom = _roomController.text
                                    .trim();
                                if (requestedRoom.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Enter a room ID to open.'),
                                    ),
                                  );
                                  return;
                                }

                                context.read<CommsBloc>().add(
                                  ConnectToRoomRequested(
                                    requestedRoom,
                                    state.audioProfile,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.wifi_calling_3),
                        label: const Text('Open Room'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: isRoomOpen || isConnected
                            ? () {
                                if (state.transmitMode ==
                                    CommsTransmitMode.pushToTalk) {
                                  context.read<CommsBloc>().add(
                                    const PushToTalkChanged(false),
                                  );
                                }
                                context.read<CommsBloc>().add(
                                  const DisconnectRequested(),
                                );
                              }
                            : null,
                        icon: const Icon(Icons.call_end),
                        label: Text(isConnected ? 'Leave Room' : 'Close Room'),
                      ),
                      if (isRoomOpen || isConnected) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () {
                            context.read<CommsBloc>().add(
                              MicrophoneMuteChanged(!isMicrophoneMuted),
                            );
                          },
                          icon: Icon(
                            isMicrophoneMuted ? Icons.mic_off : Icons.mic,
                          ),
                          label: Text(
                            isMicrophoneMuted
                                ? 'Unmute Microphone'
                                : 'Mute Microphone',
                          ),
                        ),
                      ],
                      if (isConnected) ...[
                        const SizedBox(height: 20),
                        if (!isVoiceMode)
                          GestureDetector(
                            onTap: isMicrophoneMuted ? null : _toggleBroadcast,
                            onLongPressStart: isMicrophoneMuted
                                ? null
                                : (_) => _startMomentaryBroadcast(),
                            onLongPressEnd: (_) => _stopMomentaryBroadcast(),
                            onLongPressCancel: _stopMomentaryBroadcast,
                            child: _BroadcastPanel(
                              isMicrophoneMuted: isMicrophoneMuted,
                              isDuplexActive: isDuplexActive,
                              isBroadcastActive: isBroadcastActive,
                              isTransmitting: isTransmitting,
                              isReceivingAudio: isReceivingAudio,
                            ),
                          )
                        else
                          _VoiceActivationPanel(
                            isMicrophoneMuted: isMicrophoneMuted,
                            isVoiceActivationArmed: isVoiceActivationArmed,
                            isTransmitting: isTransmitting,
                            isReceivingAudio: isReceivingAudio,
                            isDuplexActive: isDuplexActive,
                          ),
                      ],
                      const SizedBox(height: 24),
                      _DiagnosticsCard(state: state),
                      if (peers.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        _PeerListCard(peers: peers),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        switch (state) {
                          CommsSessionOpen(:final isDiscovering) =>
                            isDiscovering
                                ? 'Nearby is scanning briefly for matching room peers while keeping this room open for inbound connections.'
                                : 'This room stays open for inbound peers without continuously scanning nearby devices.',
                          _ =>
                            'Nearby Connections handles discovery and connection setup. Next steps are runtime permissions, audio focus, and resilience/metrics.',
                        },
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _statusLabel(CommsState state) {
    return switch (state) {
      CommsSessionOpen() => 'Room Open',
      CommsConnected() => 'Connected',
      CommsFailure() => 'Connection Error',
      _ => 'Ready',
    };
  }
}

class _TransmitModeCard extends StatelessWidget {
  const _TransmitModeCard({
    required this.mode,
    required this.isMicrophoneMuted,
    required this.sensitivity,
    required this.onModeChanged,
    required this.onSensitivityChanged,
  });

  final CommsTransmitMode mode;
  final bool isMicrophoneMuted;
  final double sensitivity;
  final ValueChanged<CommsTransmitMode> onModeChanged;
  final ValueChanged<double> onSensitivityChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF171717),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Transmit Mode',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SegmentedButton<CommsTransmitMode>(
              segments: const [
                ButtonSegment(
                  value: CommsTransmitMode.pushToTalk,
                  icon: Icon(Icons.touch_app),
                  label: Text('Hold to Talk'),
                ),
                ButtonSegment(
                  value: CommsTransmitMode.voiceActivated,
                  icon: Icon(Icons.graphic_eq),
                  label: Text('Voice activated'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) {
                onModeChanged(selection.first);
              },
            ),
            const SizedBox(height: 12),
            Text(
              mode == CommsTransmitMode.pushToTalk
                  ? 'Use the talk button exactly as before: tap to latch or hold to talk.'
                  : isMicrophoneMuted
                  ? 'Voice activation is disabled while the microphone is muted.'
                  : 'The mic stays armed while connected and opens transmit automatically when speech is detected.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
            ),
            if (mode == CommsTransmitMode.voiceActivated) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Sensitivity',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    _sensitivityLabel(sensitivity),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              Slider(
                value: sensitivity,
                min: 0.0,
                max: 1.0,
                divisions: 10,
                onChanged: isMicrophoneMuted ? null : onSensitivityChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _sensitivityLabel(double value) {
    if (value >= 0.72) {
      return 'High';
    }
    if (value >= 0.42) {
      return 'Medium';
    }
    return 'Low';
  }
}

class _RoomAudioProfileCard extends StatelessWidget {
  const _RoomAudioProfileCard({
    required this.selectedProfile,
    required this.enabled,
    required this.onProfileChanged,
  });

  final CommsAudioProfile selectedProfile;
  final bool enabled;
  final ValueChanged<CommsAudioProfile> onProfileChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF171717),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Room Audio',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    selectedProfile.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: selectedProfile.id,
              decoration: const InputDecoration(
                labelText: 'Audio profile',
                border: OutlineInputBorder(),
              ),
              items: CommsAudioProfile.values
                  .map(
                    (profile) => DropdownMenuItem<String>(
                      value: profile.id,
                      child: Text(
                        '${profile.label} (${profile.sampleRate ~/ 1000} kHz)',
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: enabled
                  ? (value) {
                      onProfileChanged(CommsAudioProfile.fromId(value));
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _BroadcastPanel extends StatelessWidget {
  const _BroadcastPanel({
    required this.isMicrophoneMuted,
    required this.isDuplexActive,
    required this.isBroadcastActive,
    required this.isTransmitting,
    required this.isReceivingAudio,
  });

  final bool isMicrophoneMuted;
  final bool isDuplexActive;
  final bool isBroadcastActive;
  final bool isTransmitting;
  final bool isReceivingAudio;

  @override
  Widget build(BuildContext context) {
    final panelColor = isMicrophoneMuted
        ? Colors.grey.shade700
        : isDuplexActive
        ? Colors.deepPurpleAccent
        : isBroadcastActive || isTransmitting
        ? Colors.redAccent
        : isReceivingAudio
        ? Colors.blueAccent
        : Colors.teal;
    final glowColor = isDuplexActive
        ? Colors.deepPurpleAccent
        : (isBroadcastActive || isTransmitting)
        ? Colors.redAccent
        : isReceivingAudio
        ? Colors.blueAccent
        : Colors.tealAccent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 140,
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: glowColor.withValues(alpha: 0.28),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isMicrophoneMuted
                  ? Icons.mic_off
                  : isDuplexActive
                  ? Icons.sync
                  : isBroadcastActive || isTransmitting
                  ? Icons.campaign
                  : isReceivingAudio
                  ? Icons.volume_up
                  : Icons.mic_none,
              size: 40,
              color: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              isMicrophoneMuted
                  ? 'Microphone Muted'
                  : isDuplexActive
                  ? 'Duplex Active'
                  : isBroadcastActive || isTransmitting
                  ? 'Link Live'
                  : isReceivingAudio
                  ? 'Receiving Audio'
                  : 'Hold to Talk',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isMicrophoneMuted
                  ? 'Unmute to use Link.'
                  : isDuplexActive
                  ? 'Mic and speaker are both live.'
                  : isBroadcastActive || isTransmitting
                  ? 'Tap to stop'
                  : 'Tap to lock on',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.82)),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceActivationPanel extends StatelessWidget {
  const _VoiceActivationPanel({
    required this.isMicrophoneMuted,
    required this.isVoiceActivationArmed,
    required this.isTransmitting,
    required this.isReceivingAudio,
    required this.isDuplexActive,
  });

  final bool isMicrophoneMuted;
  final bool isVoiceActivationArmed;
  final bool isTransmitting;
  final bool isReceivingAudio;
  final bool isDuplexActive;

  @override
  Widget build(BuildContext context) {
    final panelColor = isMicrophoneMuted
        ? Colors.grey.shade700
        : isDuplexActive
        ? Colors.deepPurpleAccent
        : isTransmitting
        ? Colors.redAccent
        : isReceivingAudio
        ? Colors.blueAccent
        : isVoiceActivationArmed
        ? Colors.orangeAccent
        : Colors.grey.shade800;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 140,
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: panelColor.withValues(alpha: 0.24),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isMicrophoneMuted
                  ? Icons.mic_off
                  : isDuplexActive
                  ? Icons.sync
                  : isTransmitting
                  ? Icons.record_voice_over
                  : isVoiceActivationArmed
                  ? Icons.hearing
                  : Icons.mic_none,
              size: 40,
              color: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              isMicrophoneMuted
                  ? 'Microphone Muted'
                  : isDuplexActive
                  ? 'Duplex Active'
                  : isTransmitting
                  ? 'Link Live'
                  : isVoiceActivationArmed
                  ? 'Voice Activation Armed'
                  : 'Voice Activation Idle',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isMicrophoneMuted
                  ? 'Unmute to re-arm voice activation.'
                  : isTransmitting
                  ? 'Transmit opened automatically from local speech.'
                  : isVoiceActivationArmed
                  ? 'Speak naturally to open transmit.'
                  : 'Waiting for a connected peer before arming the microphone.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.82)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.state});

  final CommsState state;

  @override
  Widget build(BuildContext context) {
    final diagnostics = state.diagnostics;
    final isReceivingAudio = diagnostics.isReceivingAudio;
    final isTransmitting = diagnostics.isTransmitting;
    final roomId = switch (state) {
      CommsSessionOpen(:final roomId) => roomId,
      CommsConnected(:final roomId) => roomId,
      CommsFailure(:final roomId) => roomId ?? 'n/a',
      _ => 'n/a',
    };

    return Card(
      color: const Color(0xFF131313),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Diagnostics',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            _AudioActivityBanner(
              isReceivingAudio: isReceivingAudio,
              isTransmitting: isTransmitting,
              connectedPeers: diagnostics.connectedPeers,
              roomId: roomId,
              lastEvent: diagnostics.lastEvent,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DiagnosticChip(label: 'room', value: roomId),
                _DiagnosticChip(
                  label: 'audio',
                  value:
                      '${state.audioProfile.label.toLowerCase()} ${state.audioProfile.sampleRate ~/ 1000}k',
                ),
                _DiagnosticChip(label: 'codec', value: diagnostics.codec),
                if (diagnostics.audioSampleRate case final int sampleRate)
                  _DiagnosticChip(
                    label: 'rate',
                    value: '${sampleRate ~/ 1000}k',
                  ),
                if (diagnostics.frameDurationMs case final int frameDurationMs)
                  _DiagnosticChip(
                    label: 'frame',
                    value: '${frameDurationMs}ms',
                  ),
                if (diagnostics.transportVersion case final int transportVersion)
                  _DiagnosticChip(
                    label: 'transport',
                    value: 'v$transportVersion',
                  ),
                _DiagnosticChip(label: 'event', value: diagnostics.lastEvent),
                _DiagnosticChip(
                  label: 'discovering',
                  value: diagnostics.isDiscovering ? 'yes' : 'no',
                ),
                _DiagnosticChip(
                  label: 'mode',
                  value: diagnostics.transmitMode.diagnosticValue,
                ),
                _DiagnosticChip(
                  label: 'tx',
                  value: diagnostics.isTransmitting ? 'active' : 'idle',
                ),
                _DiagnosticChip(
                  label: 'rx',
                  value: diagnostics.isReceivingAudio ? 'active' : 'idle',
                ),
                _DiagnosticChip(
                  label: 'voice',
                  value: diagnostics.isVoiceActivationArmed ? 'armed' : 'off',
                ),
                _DiagnosticChip(
                  label: 'mic',
                  value: state.isMicrophoneMuted ? 'muted' : 'live',
                ),
                _DiagnosticChip(
                  label: 'peers',
                  value: '${diagnostics.connectedPeers}',
                ),
                _DiagnosticChip(
                  label: 'speakers',
                  value:
                      '${state.peers.where((peer) => peer.isSpeaking).length}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isReceivingAudio
                    ? Colors.blueAccent.withValues(alpha: 0.12)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isReceivingAudio
                      ? Colors.blueAccent.withValues(alpha: 0.4)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Text(
                diagnostics.lastMessage,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontWeight: isReceivingAudio
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
            if (diagnostics.recentEvents.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              ...diagnostics.recentEvents.map((entry) {
                final isReceiveEvent =
                    entry.event == 'receive_state' ||
                    entry.message.toLowerCase().contains('receiving');
                final accent = isReceiveEvent
                    ? Colors.blueAccent
                    : entry.event == 'transmit_state'
                    ? Colors.redAccent
                    : Colors.white;

                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isReceiveEvent
                        ? Colors.blueAccent.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.02),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isReceiveEvent
                          ? Colors.blueAccent.withValues(alpha: 0.28)
                          : Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.event,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                              color: accent.withValues(
                                alpha: accent == Colors.white ? 0.9 : 1,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry.message,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.76),
                        ),
                      ),
                      if (entry.details.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          entry.details.join(' • '),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

class _DiagnosticChip extends StatelessWidget {
  const _DiagnosticChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45)),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioActivityBanner extends StatelessWidget {
  const _AudioActivityBanner({
    required this.isReceivingAudio,
    required this.isTransmitting,
    required this.connectedPeers,
    required this.roomId,
    required this.lastEvent,
  });

  final bool isReceivingAudio;
  final bool isTransmitting;
  final int connectedPeers;
  final String roomId;
  final String lastEvent;

  @override
  Widget build(BuildContext context) {
    final bool isDuplexActive = isReceivingAudio && isTransmitting;
    final Color accent = isDuplexActive
        ? Colors.deepPurpleAccent
        : isReceivingAudio
        ? Colors.blueAccent
        : isTransmitting
        ? Colors.redAccent
        : Colors.grey;
    final IconData icon = isDuplexActive
        ? Icons.sync
        : isReceivingAudio
        ? Icons.hearing
        : isTransmitting
        ? Icons.campaign
        : Icons.graphic_eq;
    final String title = isDuplexActive
        ? 'Duplex Audio Active'
        : isReceivingAudio
        ? 'Incoming Audio Detected'
        : isTransmitting
        ? 'Link Live'
        : 'Audio Idle';
    final String subtitle = isDuplexActive
        ? 'This device is sending microphone audio while receiving live voice in room "$roomId".'
        : isReceivingAudio
        ? 'Receiving live voice in room "$roomId" from $connectedPeers peer(s).'
        : isTransmitting
        ? 'This device is currently sending live voice to the room.'
        : 'No live voice packets are being received right now.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withValues(alpha: 0.24), const Color(0xFF1A1A1A)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.76),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _SignalPill(
                color: accent,
                label: isReceivingAudio
                    ? (isTransmitting ? 'LIVE TX/RX' : 'LIVE RX')
                    : isTransmitting
                    ? 'LIVE TX'
                    : 'IDLE',
              ),
              const SizedBox(height: 8),
              Text(
                lastEvent,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.56),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PeerListCard extends StatelessWidget {
  const _PeerListCard({required this.peers});

  final List<CommsPeer> peers;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF131313),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Room Peers',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...peers.map(
              (peer) => Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: peer.isSpeaking
                      ? Colors.blueAccent.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: peer.isSpeaking
                        ? Colors.blueAccent.withValues(alpha: 0.28)
                        : Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: peer.isSpeaking
                            ? Colors.blueAccent
                            : peer.isConnected
                            ? Colors.greenAccent
                            : Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            peer.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            peer.isSpeaking
                                ? 'Speaking now'
                                : peer.isConnected
                                ? 'Connected'
                                : 'Discovered',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (peer.streamSampleRate case final int sampleRate)
                      Text(
                        [
                          if (peer.codec case final String codec when codec.isNotEmpty)
                            codec,
                          '${sampleRate ~/ 1000} kHz',
                        ].join(' • '),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalPill extends StatelessWidget {
  const _SignalPill({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
