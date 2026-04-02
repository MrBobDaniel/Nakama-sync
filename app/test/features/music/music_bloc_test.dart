import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:app/features/music/music_bloc.dart';
import 'package:app/features/music/music_event.dart';
import 'package:app/features/music/music_state.dart';
import 'package:app/features/music/data/repositories/music_repository.dart';
import 'package:app/core/audio/audio_engine.dart';
import 'package:app/features/music/data/models/playlist.dart';

class MockMusicRepository extends Mock implements MusicRepository {}
class MockAudioEngine extends Mock implements AudioEngine {}

void main() {
  late MusicBloc musicBloc;
  late MockMusicRepository mockRepository;
  late MockAudioEngine mockAudioEngine;

  setUp(() {
    mockRepository = MockMusicRepository();
    mockAudioEngine = MockAudioEngine();
    musicBloc = MusicBloc(repository: mockRepository, audioEngine: mockAudioEngine);
    when(() => mockAudioEngine.dispose()).thenAnswer((_) async {});
  });

  tearDown(() {
    musicBloc.close();
  });

  group('MusicBloc', () {
    test('initial state is MusicInitial', () {
      expect(musicBloc.state, isA<MusicInitial>());
    });

    blocTest<MusicBloc, MusicState>(
      'emits [MusicLoading, PlaylistsLoaded] when LoadPlaylistsEvent succeeds',
      build: () {
        when(() => mockRepository.fetchPlaylists())
            .thenAnswer((_) async => const [Playlist(id: '1', name: 'Chill', songCount: 5, duration: 1500)]);
        return musicBloc;
      },
      act: (bloc) => bloc.add(LoadPlaylistsEvent()),
      expect: () => [
        isA<MusicLoading>(),
        isA<PlaylistsLoaded>(),
      ],
      verify: (_) {
        verify(() => mockRepository.fetchPlaylists()).called(1);
      },
    );

    blocTest<MusicBloc, MusicState>(
      'emits [MusicLoading, MusicError] when LoadPlaylistsEvent fails',
      build: () {
        when(() => mockRepository.fetchPlaylists()).thenThrow(Exception('Network disconnected'));
        return musicBloc;
      },
      act: (bloc) => bloc.add(LoadPlaylistsEvent()),
      expect: () => [
        isA<MusicLoading>(),
        isA<MusicError>(),
      ],
    );
  });
}
