import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

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
        title: const Text('Walkie-Talkie'),
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

          if (state is! CommsConnected &&
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
          final isMicrophoneMuted = state.isMicrophoneMuted;
          final isBroadcastActive = _isTalkLatched || _isMomentaryTalking;
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
                        'Comms Lane',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Join a room to advertise and discover peers with Nearby Connections, then stream push-to-talk audio over a low-latency payload stream.',
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
                                        : '$statusMessage You can keep using the app while this room waits for inbound connections.',
                                  CommsConnected(
                                    :final isTransmitting,
                                    :final isReceivingAudio,
                                    :final connectedPeers,
                                    :final statusMessage,
                                  ) =>
                                    isTransmitting
                                        ? 'Transmitting to $connectedPeers peer(s) in room "$roomId".'
                                        : isReceivingAudio
                                        ? 'Receiving voice audio from $connectedPeers peer(s) in room "$roomId".'
                                        : statusMessage,
                                  CommsFailure(:final message) => message,
                                  CommsInitial(:final statusMessage) =>
                                    statusMessage,
                                  _ => 'Idle. No room joined yet.',
                                },
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
                                  ConnectToRoomRequested(requestedRoom),
                                );
                              },
                        icon: const Icon(Icons.wifi_calling_3),
                        label: const Text('Open Room'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: isRoomOpen || isConnected
                            ? () {
                                context.read<CommsBloc>().add(
                                  const PushToTalkChanged(false),
                                );
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
                        GestureDetector(
                          onTap: isMicrophoneMuted ? null : _toggleBroadcast,
                          onLongPressStart: isMicrophoneMuted
                              ? null
                              : (_) => _startMomentaryBroadcast(),
                          onLongPressEnd: (_) => _stopMomentaryBroadcast(),
                          onLongPressCancel: _stopMomentaryBroadcast,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            height: 140,
                            decoration: BoxDecoration(
                              color: isMicrophoneMuted
                                  ? Colors.grey.shade700
                                  : isBroadcastActive || isTransmitting
                                  ? Colors.redAccent
                                  : isReceivingAudio
                                  ? Colors.blueAccent
                                  : Colors.teal,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      ((isBroadcastActive || isTransmitting)
                                              ? Colors.redAccent
                                              : isReceivingAudio
                                              ? Colors.blueAccent
                                              : Colors.tealAccent)
                                          .withValues(alpha: 0.28),
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
                                        : isBroadcastActive || isTransmitting
                                        ? 'Broadcasting'
                                        : isReceivingAudio
                                        ? 'Receiving Audio'
                                        : 'Broadcast',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    isMicrophoneMuted
                                        ? 'Unmute to broadcast.'
                                        : isBroadcastActive
                                        ? 'Tap to stop. Hold for momentary talk.'
                                        : 'Tap to latch on. Hold to talk only while pressed.',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.82,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      _DiagnosticsCard(state: state),
                      const SizedBox(height: 24),
                      Text(
                        switch (state) {
                          CommsSessionOpen(:final isDiscovering) =>
                            isDiscovering
                                ? 'Nearby is scanning briefly for matching room peers while keeping this room open for inbound connections.'
                                : 'This room stays open for inbound connections without continuously scanning nearby devices.',
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

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.state});

  final CommsState state;

  @override
  Widget build(BuildContext context) {
    final diagnostics = state.diagnostics;
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DiagnosticChip(label: 'room', value: roomId),
                _DiagnosticChip(label: 'event', value: diagnostics.lastEvent),
                _DiagnosticChip(
                  label: 'discovering',
                  value: diagnostics.isDiscovering ? 'yes' : 'no',
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
                  label: 'mic',
                  value: state.isMicrophoneMuted ? 'muted' : 'live',
                ),
                _DiagnosticChip(
                  label: 'peers',
                  value: '${diagnostics.connectedPeers}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              diagnostics.lastMessage,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
            ),
            if (diagnostics.recentEvents.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              ...diagnostics.recentEvents.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.event,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.message,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.76),
                        ),
                      ),
                      if (entry.details.isNotEmpty) ...[
                        const SizedBox(height: 2),
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
                ),
              ),
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
