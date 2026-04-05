import 'dart:async';

import 'package:app/core/audio/audio_engine.dart';
import 'package:app/core/config/app_config.dart';
import 'package:app/features/comms/comms_bloc.dart';
import 'package:app/features/comms/comms_event.dart';
import 'package:app/features/comms/data/repositories/comms_transport_service.dart';
import 'package:app/features/music/data/models/song.dart';
import 'package:app/features/music/data/repositories/music_repository.dart';
import 'package:app/features/music/data/models/playlist.dart';
import 'package:app/main.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockMusicRepository extends Mock implements MusicRepository {}

class MockAudioEngine extends Mock implements AudioEngine {}

class MockCommsTransportService extends Mock implements CommsTransportService {}

class FakeSong extends Fake implements Song {}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeSong());
  });

  testWidgets('renders the music library shell', (WidgetTester tester) async {
    final repository = MockMusicRepository();
    final audioEngine = MockAudioEngine();
    final transportService = MockCommsTransportService();

    when(
      () => repository.fetchPlaylists(),
    ).thenAnswer((_) async => const <Playlist>[]);
    when(() => audioEngine.dispose()).thenAnswer((_) async {});
    when(() => audioEngine.setVolume(any())).thenAnswer((_) async {});
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.events).thenAnswer((_) => const Stream.empty());

    await tester.pumpWidget(
      NakamaApp(
        appConfig: const AppConfig(
          navidromeBaseUrl: 'http://localhost:4533',
          navidromeUsername: 'tester',
          navidromePassword: 'secret',
          signalingServerUrl: 'http://localhost:3000',
        ),
        musicRepository: repository,
        audioEngine: audioEngine,
        commsTransportService: transportService,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Music Library'), findsOneWidget);
    expect(find.text('No playlists found in Navidrome.'), findsOneWidget);
  });

  testWidgets('opens playlist details from the library', (
    WidgetTester tester,
  ) async {
    final repository = MockMusicRepository();
    final audioEngine = MockAudioEngine();
    final transportService = MockCommsTransportService();
    const playlist = Playlist(
      id: 'gym-favorites',
      name: 'Gym Favorites',
      songCount: 1,
      duration: 180,
    );
    const song = Song(
      id: 'track-1',
      title: 'Warmup',
      artist: 'Nakama',
      album: 'Gym Set',
      duration: 180,
      streamUrl: 'https://example.com/stream',
      coverArtUrl: 'https://example.com/cover',
    );

    when(
      () => repository.fetchPlaylists(),
    ).thenAnswer((_) async => const [playlist]);
    when(() => repository.fetchPlaylistDetails('gym-favorites')).thenAnswer(
      (_) async => const Playlist(
        id: 'gym-favorites',
        name: 'Gym Favorites',
        songCount: 1,
        duration: 180,
        songs: [song],
      ),
    );
    when(() => audioEngine.dispose()).thenAnswer((_) async {});
    when(() => audioEngine.playSong(any())).thenAnswer((_) async {});
    when(() => audioEngine.setVolume(any())).thenAnswer((_) async {});
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.events).thenAnswer((_) => const Stream.empty());

    await tester.pumpWidget(
      NakamaApp(
        appConfig: const AppConfig(
          navidromeBaseUrl: 'http://localhost:4533',
          navidromeUsername: 'tester',
          navidromePassword: 'secret',
          signalingServerUrl: 'http://localhost:3000',
        ),
        musicRepository: repository,
        audioEngine: audioEngine,
        commsTransportService: transportService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Gym Favorites'));
    await tester.pumpAndSettle();

    expect(find.text('Warmup'), findsOneWidget);
    expect(find.text('Nakama • Gym Set'), findsOneWidget);
  });

  testWidgets('opens the comms lane from music', (WidgetTester tester) async {
    final repository = MockMusicRepository();
    final audioEngine = MockAudioEngine();
    final transportService = MockCommsTransportService();

    when(
      () => repository.fetchPlaylists(),
    ).thenAnswer((_) async => const <Playlist>[]);
    when(() => audioEngine.dispose()).thenAnswer((_) async {});
    when(() => audioEngine.setVolume(any())).thenAnswer((_) async {});
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.events).thenAnswer((_) => const Stream.empty());

    await tester.pumpWidget(
      NakamaApp(
        appConfig: const AppConfig(
          navidromeBaseUrl: 'http://localhost:4533',
          navidromeUsername: 'tester',
          navidromePassword: 'secret',
          signalingServerUrl: 'http://localhost:3000',
        ),
        musicRepository: repository,
        audioEngine: audioEngine,
        commsTransportService: transportService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Walkie-Talkie'));
    await tester.pumpAndSettle();

    expect(find.text('Walkie-Talkie'), findsOneWidget);
    expect(find.text('Comms Lane'), findsOneWidget);
    expect(find.text('Open Room'), findsOneWidget);
  });

  testWidgets('ducks music volume while push-to-talk is active', (
    WidgetTester tester,
  ) async {
    final repository = MockMusicRepository();
    final audioEngine = MockAudioEngine();
    final transportEvents = StreamController<Map<String, dynamic>>.broadcast();
    final transportService = MockCommsTransportService();

    when(
      () => repository.fetchPlaylists(),
    ).thenAnswer((_) async => const <Playlist>[]);
    when(() => audioEngine.dispose()).thenAnswer((_) async {});
    when(() => audioEngine.setVolume(any())).thenAnswer((_) async {});
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.initialize(any())).thenAnswer((_) async {});
    when(
      () => transportService.setPushToTalkActive(any()),
    ).thenAnswer((_) async {});
    when(
      () => transportService.events,
    ).thenAnswer((_) => transportEvents.stream);

    await tester.pumpWidget(
      NakamaApp(
        appConfig: const AppConfig(
          navidromeBaseUrl: 'http://localhost:4533',
          navidromeUsername: 'tester',
          navidromePassword: 'secret',
          signalingServerUrl: 'http://localhost:3000',
        ),
        musicRepository: repository,
        audioEngine: audioEngine,
        commsTransportService: transportService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Walkie-Talkie'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Room'));
    await tester.pump();

    transportEvents.add(const {
      'event': 'connected',
      'roomId': 'gym-floor',
      'connectedPeers': 1,
      'message': 'Connected over Nearby Connections.',
    });
    await tester.pump();

    final context = tester.element(find.text('Comms Lane'));
    context.read<CommsBloc>().add(const PushToTalkChanged(true));
    await tester.pumpAndSettle();
    context.read<CommsBloc>().add(const PushToTalkChanged(false));
    await tester.pumpAndSettle();

    verify(() => audioEngine.setVolume(AudioEngine.duckedVolume)).called(1);
    verify(
      () => audioEngine.setVolume(AudioEngine.defaultVolume),
    ).called(greaterThanOrEqualTo(1));

    await transportEvents.close();
  });

  testWidgets('ducks music volume while incoming comms audio is active', (
    WidgetTester tester,
  ) async {
    final repository = MockMusicRepository();
    final audioEngine = MockAudioEngine();
    final transportEvents = StreamController<Map<String, dynamic>>.broadcast();
    final transportService = MockCommsTransportService();

    when(
      () => repository.fetchPlaylists(),
    ).thenAnswer((_) async => const <Playlist>[]);
    when(() => audioEngine.dispose()).thenAnswer((_) async {});
    when(() => audioEngine.setVolume(any())).thenAnswer((_) async {});
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.initialize(any())).thenAnswer((_) async {});
    when(
      () => transportService.setPushToTalkActive(any()),
    ).thenAnswer((_) async {});
    when(
      () => transportService.events,
    ).thenAnswer((_) => transportEvents.stream);

    await tester.pumpWidget(
      NakamaApp(
        appConfig: const AppConfig(
          navidromeBaseUrl: 'http://localhost:4533',
          navidromeUsername: 'tester',
          navidromePassword: 'secret',
          signalingServerUrl: 'http://localhost:3000',
        ),
        musicRepository: repository,
        audioEngine: audioEngine,
        commsTransportService: transportService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Walkie-Talkie'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Room'));
    await tester.pump();

    transportEvents.add(const {
      'event': 'connected',
      'roomId': 'gym-floor',
      'connectedPeers': 1,
      'message': 'Connected over Nearby Connections.',
    });
    await tester.pump();

    transportEvents.add(const {
      'event': 'receive_state',
      'roomId': 'gym-floor',
      'connectedPeers': 1,
      'message': 'Receiving nearby voice audio.',
      'isReceivingAudio': true,
    });
    await tester.pumpAndSettle();

    transportEvents.add(const {
      'event': 'receive_state',
      'roomId': 'gym-floor',
      'connectedPeers': 1,
      'message': 'Incoming voice audio is idle.',
      'isReceivingAudio': false,
    });
    await tester.pumpAndSettle();

    verify(() => audioEngine.setVolume(AudioEngine.duckedVolume)).called(1);
    verify(
      () => audioEngine.setVolume(AudioEngine.defaultVolume),
    ).called(greaterThanOrEqualTo(1));

    await transportEvents.close();
  });

  testWidgets('broadcast button toggles on tap and holds on long press', (
    WidgetTester tester,
  ) async {
    final repository = MockMusicRepository();
    final audioEngine = MockAudioEngine();
    final transportEvents = StreamController<Map<String, dynamic>>.broadcast();
    final transportService = MockCommsTransportService();

    when(
      () => repository.fetchPlaylists(),
    ).thenAnswer((_) async => const <Playlist>[]);
    when(() => audioEngine.dispose()).thenAnswer((_) async {});
    when(() => audioEngine.setVolume(any())).thenAnswer((_) async {});
    when(() => transportService.dispose()).thenAnswer((_) async {});
    when(() => transportService.initialize(any())).thenAnswer((_) async {});
    when(
      () => transportService.setPushToTalkActive(any()),
    ).thenAnswer((_) async {});
    when(
      () => transportService.events,
    ).thenAnswer((_) => transportEvents.stream);

    await tester.pumpWidget(
      NakamaApp(
        appConfig: const AppConfig(
          navidromeBaseUrl: 'http://localhost:4533',
          navidromeUsername: 'tester',
          navidromePassword: 'secret',
          signalingServerUrl: 'http://localhost:3000',
        ),
        musicRepository: repository,
        audioEngine: audioEngine,
        commsTransportService: transportService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Walkie-Talkie'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Room'));
    await tester.pump();

    transportEvents.add(const {
      'event': 'connected',
      'roomId': 'gym-floor',
      'connectedPeers': 1,
      'message': 'Connected over Nearby Connections.',
    });
    await tester.pumpAndSettle();

    final broadcastFinder = find.text('Broadcast');
    await tester.ensureVisible(broadcastFinder);
    await tester.tap(broadcastFinder);
    await tester.pumpAndSettle();
    expect(find.text('Broadcasting'), findsOneWidget);
    await tester.tap(find.text('Broadcasting'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(broadcastFinder);
    final gesture = await tester.startGesture(
      tester.getCenter(broadcastFinder),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    verify(
      () => transportService.setPushToTalkActive(true),
    ).called(greaterThanOrEqualTo(2));
    verify(
      () => transportService.setPushToTalkActive(false),
    ).called(greaterThanOrEqualTo(2));

    await transportEvents.close();
  });
}
