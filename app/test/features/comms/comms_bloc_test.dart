import 'package:app/features/comms/comms_bloc.dart';
import 'package:app/features/comms/comms_event.dart';
import 'package:app/features/comms/comms_state.dart';
import 'package:app/features/comms/data/repositories/comms_transport_service.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockCommsTransportService extends Mock implements CommsTransportService {}

void main() {
  late MockCommsTransportService transportService;

  setUp(() {
    transportService = MockCommsTransportService();
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.setPushToTalkActive(any())).thenAnswer((_) async {});
    when(() => transportService.events).thenAnswer((_) => const Stream.empty());
  });

  test('initial state is CommsInitial', () {
    final bloc = CommsBloc(transportService: transportService);
    expect(bloc.state, const CommsInitial(statusMessage: 'Ready to search for nearby peers.'));
    bloc.close();
  });

  blocTest<CommsBloc, CommsState>(
    'emits connecting when Nearby session initialization succeeds',
    build: () {
      when(() => transportService.initialize('gym-floor')).thenAnswer((_) async {});
      return CommsBloc(transportService: transportService);
    },
    act: (bloc) => bloc.add(const ConnectToRoomRequested('gym-floor')),
    expect: () => const [
      CommsConnecting('gym-floor'),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'emits failure when room initialization throws',
    build: () {
      when(() => transportService.initialize('gym-floor'))
          .thenThrow(Exception('socket offline'));
      return CommsBloc(transportService: transportService);
    },
    act: (bloc) => bloc.add(const ConnectToRoomRequested('gym-floor')),
    expect: () => [
      const CommsConnecting('gym-floor'),
      const CommsFailure('Exception: socket offline', roomId: 'gym-floor'),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'updates transmit state when push-to-talk changes while connected',
    build: () {
      when(() => transportService.initialize('gym-floor')).thenAnswer((_) async {});
      return CommsBloc(transportService: transportService);
    },
    act: (bloc) async {
      bloc.add(const TransportStatusChanged({
        'event': 'connected',
        'roomId': 'gym-floor',
        'connectedPeers': 1,
        'message': 'Connected over Nearby Connections.',
      }));
      bloc.add(const PushToTalkChanged(true));
      bloc.add(const PushToTalkChanged(false));
    },
    expect: () => const [
      CommsConnected('gym-floor'),
      CommsConnected('gym-floor', isTransmitting: true),
      CommsConnected('gym-floor'),
    ],
    verify: (_) {
      verify(() => transportService.setPushToTalkActive(true)).called(1);
      verify(() => transportService.setPushToTalkActive(false)).called(1);
    },
  );
}
