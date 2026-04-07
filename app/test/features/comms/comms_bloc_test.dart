import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nakama_sync/features/comms/comms_bloc.dart';
import 'package:nakama_sync/features/comms/comms_event.dart';
import 'package:nakama_sync/features/comms/comms_state.dart';
import 'package:nakama_sync/features/comms/data/repositories/comms_transport_service.dart';

class MockCommsTransportService extends Mock implements CommsTransportService {}

void main() {
  late MockCommsTransportService transportService;

  setUp(() {
    transportService = MockCommsTransportService();
    when(() => transportService.events).thenAnswer((_) => const Stream.empty());
    when(() => transportService.dispose()).thenAnswer((_) async {});
  });

  blocTest<CommsBloc, CommsState>(
    'voice-activated standby does not count as active speech',
    build: () => CommsBloc(transportService: transportService),
    act: (bloc) {
      bloc.add(
        const TransportStatusChanged({
          'event': 'connected',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Connected over Nearby Connections.',
          'transmitMode': 'voice_activated',
          'isVoiceActivationArmed': true,
          'isTransmitting': false,
          'isReceivingAudio': false,
        }),
      );
    },
    expect: () => [
      isA<CommsConnected>()
          .having((state) => state.transmitMode, 'transmitMode', CommsTransmitMode.voiceActivated)
          .having((state) => state.isVoiceActivationArmed, 'isVoiceActivationArmed', true)
          .having((state) => state.isSpeechActive, 'isSpeechActive', false)
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Voice activation is armed for room "gym-floor".',
          ),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'voice-activated transmit becomes active only when speech starts',
    build: () => CommsBloc(transportService: transportService),
    act: (bloc) {
      bloc.add(
        const TransportStatusChanged({
          'event': 'connected',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Connected over Nearby Connections.',
          'transmitMode': 'voice_activated',
          'isVoiceActivationArmed': true,
          'isTransmitting': false,
          'isReceivingAudio': false,
        }),
      );
      bloc.add(
        const TransportStatusChanged({
          'event': 'transmit_state',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Voice activation opened transmit to 1 peer(s).',
          'transmitMode': 'voice_activated',
          'isVoiceActivationArmed': true,
          'isTransmitting': true,
          'isReceivingAudio': false,
        }),
      );
    },
    expect: () => [
      isA<CommsConnected>()
          .having((state) => state.isSpeechActive, 'isSpeechActive', false),
      isA<CommsConnected>()
          .having((state) => state.isSpeechActive, 'isSpeechActive', true)
          .having((state) => state.isTransmitting, 'isTransmitting', true)
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Sending live voice to 1 peer(s) in room "gym-floor".',
          ),
    ],
  );
}
