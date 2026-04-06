import 'package:nakama_sync/features/comms/comms_bloc.dart';
import 'package:nakama_sync/features/comms/comms_event.dart';
import 'package:nakama_sync/features/comms/comms_state.dart';
import 'package:nakama_sync/features/comms/data/repositories/comms_transport_service.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockCommsTransportService extends Mock implements CommsTransportService {}

void main() {
  late MockCommsTransportService transportService;

  setUp(() {
    transportService = MockCommsTransportService();
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(
      () => transportService.setPushToTalkActive(any()),
    ).thenAnswer((_) async {});
    when(() => transportService.events).thenAnswer((_) => const Stream.empty());
  });

  test('initial state is CommsInitial', () {
    final bloc = CommsBloc(transportService: transportService);
    expect(
      bloc.state,
      const CommsInitial(statusMessage: 'Ready to search for nearby peers.'),
    );
    bloc.close();
  });

  blocTest<CommsBloc, CommsState>(
    'emits room open when Nearby session initialization succeeds',
    build: () {
      when(
        () => transportService.initialize('gym-floor'),
      ).thenAnswer((_) async {});
      return CommsBloc(transportService: transportService);
    },
    act: (bloc) => bloc.add(const ConnectToRoomRequested('gym-floor')),
    expect: () => [
      isA<CommsSessionOpen>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Opening room for nearby connections.',
          ),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'emits failure when room initialization throws',
    build: () {
      when(
        () => transportService.initialize('gym-floor'),
      ).thenThrow(Exception('socket offline'));
      return CommsBloc(transportService: transportService);
    },
    act: (bloc) => bloc.add(const ConnectToRoomRequested('gym-floor')),
    expect: () => [
      isA<CommsSessionOpen>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Opening room for nearby connections.',
          ),
      isA<CommsFailure>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having(
            (state) => state.message,
            'message',
            'Exception: socket offline',
          ),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'marks discovery idle while keeping the room open',
    build: () => CommsBloc(transportService: transportService),
    act: (bloc) async {
      bloc.add(const ConnectToRoomRequested('gym-floor'));
      await Future<void>.delayed(Duration.zero);
      bloc.add(
        const TransportStatusChanged({
          'event': 'discovery_idle',
          'roomId': 'gym-floor',
          'message': 'Room is open. Listening for incoming connections.',
          'isDiscovering': false,
        }),
      );
    },
    expect: () => [
      isA<CommsSessionOpen>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Opening room for nearby connections.',
          ),
      isA<CommsSessionOpen>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Room is open. Listening for incoming connections.',
          )
          .having((state) => state.isDiscovering, 'isDiscovering', false),
    ],
    setUp: () {
      when(
        () => transportService.initialize('gym-floor'),
      ).thenAnswer((_) async {});
    },
  );

  blocTest<CommsBloc, CommsState>(
    'updates transmit state when push-to-talk changes while connected',
    build: () {
      when(
        () => transportService.initialize('gym-floor'),
      ).thenAnswer((_) async {});
      return CommsBloc(transportService: transportService);
    },
    act: (bloc) async {
      bloc.add(
        const TransportStatusChanged({
          'event': 'connected',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Connected over Nearby Connections.',
        }),
      );
      bloc.add(const PushToTalkChanged(true));
      bloc.add(const PushToTalkChanged(false));
    },
    expect: () => [
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isTransmitting, 'isTransmitting', false),
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isTransmitting, 'isTransmitting', true),
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isTransmitting, 'isTransmitting', false),
    ],
    verify: (_) {
      verify(() => transportService.setPushToTalkActive(true)).called(1);
      verify(() => transportService.setPushToTalkActive(false)).called(1);
    },
  );

  blocTest<CommsBloc, CommsState>(
    'tracks incoming audio activity while connected',
    build: () => CommsBloc(transportService: transportService),
    act: (bloc) async {
      bloc.add(
        const TransportStatusChanged({
          'event': 'connected',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Connected over Nearby Connections.',
        }),
      );
      bloc.add(
        const TransportStatusChanged({
          'event': 'receive_state',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Receiving nearby voice audio.',
          'isReceivingAudio': true,
        }),
      );
      bloc.add(
        const TransportStatusChanged({
          'event': 'receive_state',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Incoming voice audio is idle.',
          'isReceivingAudio': false,
        }),
      );
    },
    expect: () => [
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isReceivingAudio, 'isReceivingAudio', false),
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isReceivingAudio, 'isReceivingAudio', true)
          .having((state) => state.isSpeechActive, 'isSpeechActive', true),
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isReceivingAudio, 'isReceivingAudio', false)
          .having((state) => state.isSpeechActive, 'isSpeechActive', false),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'blocks push-to-talk while microphone is muted',
    build: () => CommsBloc(transportService: transportService),
    act: (bloc) async {
      bloc.add(
        const TransportStatusChanged({
          'event': 'connected',
          'roomId': 'gym-floor',
          'connectedPeers': 1,
          'message': 'Connected over Nearby Connections.',
        }),
      );
      bloc.add(const MicrophoneMuteChanged(true));
      bloc.add(const PushToTalkChanged(true));
    },
    expect: () => [
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having(
            (state) => state.isMicrophoneMuted,
            'isMicrophoneMuted',
            false,
          ),
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isMicrophoneMuted, 'isMicrophoneMuted', true)
          .having((state) => state.isTransmitting, 'isTransmitting', false),
      isA<CommsConnected>()
          .having((state) => state.roomId, 'roomId', 'gym-floor')
          .having((state) => state.isMicrophoneMuted, 'isMicrophoneMuted', true)
          .having((state) => state.isTransmitting, 'isTransmitting', false)
          .having(
            (state) => state.statusMessage,
            'statusMessage',
            'Microphone is muted on this device.',
          ),
    ],
    verify: (_) {
      verifyNever(() => transportService.setPushToTalkActive(true));
    },
  );
}
