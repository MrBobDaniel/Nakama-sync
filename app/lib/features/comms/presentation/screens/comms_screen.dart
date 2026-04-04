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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(state.message)),
            );
          }
        },
        builder: (context, state) {
          final isConnecting = state is CommsConnecting;
          final isConnected = state is CommsConnected;
          final isTransmitting =
              state is CommsConnected && state.isTransmitting;
          final roomId = switch (state) {
            CommsConnecting(:final roomId) => roomId,
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
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Join a room to bring up the walkie-talkie signaling and WebRTC path.',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _roomController,
                        enabled: !isConnecting && !isConnected,
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
                                  CommsConnecting() =>
                                    'Connecting to room "$roomId"...',
                                  CommsConnected(:final isTransmitting) =>
                                    isTransmitting
                                        ? 'Transmitting in room "$roomId".'
                                        : 'Connected to room "$roomId". Hold to talk.',
                                  CommsFailure(:final message) => message,
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
                        onPressed: isConnecting || isConnected
                            ? null
                            : () {
                                final requestedRoom = _roomController.text.trim();
                                if (requestedRoom.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Enter a room ID to connect.'),
                                    ),
                                  );
                                  return;
                                }

                                context.read<CommsBloc>().add(
                                      ConnectToRoomRequested(requestedRoom),
                                    );
                              },
                        icon: isConnecting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_calling_3),
                        label: Text(isConnecting ? 'Connecting...' : 'Join Room'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: isConnected
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
                        label: const Text('Leave Room'),
                      ),
                      if (isConnected) ...[
                        const SizedBox(height: 20),
                        GestureDetector(
                          onLongPressStart: (_) {
                            context.read<CommsBloc>().add(
                                  const PushToTalkChanged(true),
                                );
                          },
                          onLongPressEnd: (_) {
                            context.read<CommsBloc>().add(
                                  const PushToTalkChanged(false),
                                );
                          },
                          onLongPressCancel: () {
                            context.read<CommsBloc>().add(
                                  const PushToTalkChanged(false),
                                );
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            height: 140,
                            decoration: BoxDecoration(
                              color: isTransmitting
                                  ? Colors.redAccent
                                  : Colors.deepPurple,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: (isTransmitting
                                          ? Colors.redAccent
                                          : Colors.deepPurpleAccent)
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
                                    isTransmitting ? Icons.mic : Icons.mic_none,
                                    size: 40,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    isTransmitting
                                        ? 'Transmitting'
                                        : 'Hold To Talk',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'Next steps: push-to-talk control, live mic state, ducking, and signal health.',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
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
      CommsConnecting() => 'Connecting',
      CommsConnected() => 'Connected',
      CommsFailure() => 'Connection Error',
      _ => 'Ready',
    };
  }
}
