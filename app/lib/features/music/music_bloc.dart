import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/audio/audio_engine.dart';
import 'data/repositories/music_repository.dart';
import 'music_event.dart';
import 'music_state.dart';

class MusicBloc extends Bloc<MusicEvent, MusicState> {
  final MusicRepository repository;
  final AudioEngine audioEngine;

  MusicBloc({
    required this.repository,
    required this.audioEngine,
  }) : super(MusicInitial()) {
    on<LoadPlaylistsEvent>(_onLoadPlaylists);
    on<LoadPlaylistDetailsEvent>(_onLoadPlaylistDetails);
    on<PlaySongEvent>(_onPlaySong);
    on<PauseSongEvent>(_onPauseSong);
    on<ResumeSongEvent>(_onResumeSong);
  }

  Future<void> _onLoadPlaylists(LoadPlaylistsEvent event, Emitter<MusicState> emit) async {
    emit(MusicLoading());
    try {
      final playlists = await repository.fetchPlaylists();
      emit(PlaylistsLoaded(playlists));
    } catch (e) {
      emit(MusicError(e.toString()));
    }
  }

  Future<void> _onLoadPlaylistDetails(LoadPlaylistDetailsEvent event, Emitter<MusicState> emit) async {
    emit(MusicLoading());
    try {
      final playlist = await repository.fetchPlaylistDetails(event.playlistId);
      emit(PlaylistDetailsLoaded(playlist));
    } catch (e) {
      emit(MusicError(e.toString()));
    }
  }

  Future<void> _onPlaySong(PlaySongEvent event, Emitter<MusicState> emit) async {
    try {
      await audioEngine.playSong(event.song);
      emit(MusicPlaying(event.song));
    } catch (e) {
      emit(MusicError("Failed to play song: ${e.toString()}"));
    }
  }

  Future<void> _onPauseSong(PauseSongEvent event, Emitter<MusicState> emit) async {
    await audioEngine.pause();
  }

  Future<void> _onResumeSong(ResumeSongEvent event, Emitter<MusicState> emit) async {
    await audioEngine.resume();
  }

  @override
  Future<void> close() {
    audioEngine.dispose();
    return super.close();
  }
}
