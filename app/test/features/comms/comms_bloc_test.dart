import 'package:app/features/comms/comms_bloc.dart';
import 'package:app/features/comms/comms_event.dart';
import 'package:app/features/comms/comms_state.dart';
import 'package:app/features/comms/data/repositories/webrtc_service.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockWebRtcService extends Mock implements WebRtcService {}

void main() {
  late MockWebRtcService webRtcService;

  setUp(() {
    webRtcService = MockWebRtcService();
    when(() => webRtcService.dispose()).thenAnswer((_) async {});
    when(() => webRtcService.setPushToTalkActive(any())).thenAnswer((_) async {});
  });

  test('initial state is CommsInitial', () {
    final bloc = CommsBloc(webRtcService: webRtcService);
    expect(bloc.state, const CommsInitial());
    bloc.close();
  });

  blocTest<CommsBloc, CommsState>(
    'emits connecting then connected when room initialization succeeds',
    build: () {
      when(() => webRtcService.initialize('gym-floor')).thenAnswer((_) async {});
      return CommsBloc(webRtcService: webRtcService);
    },
    act: (bloc) => bloc.add(const ConnectToRoomRequested('gym-floor')),
    expect: () => const [
      CommsConnecting('gym-floor'),
      CommsConnected('gym-floor'),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'emits failure when room initialization throws',
    build: () {
      when(() => webRtcService.initialize('gym-floor'))
          .thenThrow(Exception('socket offline'));
      return CommsBloc(webRtcService: webRtcService);
    },
    act: (bloc) => bloc.add(const ConnectToRoomRequested('gym-floor')),
    expect: () => [
      const CommsConnecting('gym-floor'),
      isA<CommsFailure>(),
    ],
  );

  blocTest<CommsBloc, CommsState>(
    'updates transmit state when push-to-talk changes while connected',
    build: () {
      when(() => webRtcService.initialize('gym-floor')).thenAnswer((_) async {});
      return CommsBloc(webRtcService: webRtcService);
    },
    act: (bloc) async {
      bloc.add(const ConnectToRoomRequested('gym-floor'));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const PushToTalkChanged(true));
      bloc.add(const PushToTalkChanged(false));
    },
    expect: () => const [
      CommsConnecting('gym-floor'),
      CommsConnected('gym-floor'),
      CommsConnected('gym-floor', isTransmitting: true),
      CommsConnected('gym-floor', isTransmitting: false),
    ],
    verify: (_) {
      verify(() => webRtcService.setPushToTalkActive(true)).called(1);
      verify(() => webRtcService.setPushToTalkActive(false)).called(greaterThan(0));
    },
  );
}
