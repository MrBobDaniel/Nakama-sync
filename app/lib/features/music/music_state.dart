import 'package:equatable/equatable.dart';
import 'data/models/playlist.dart';
import 'data/models/song.dart';

abstract class MusicState extends Equatable {
  const MusicState();
  
  @override
  List<Object?> get props => [];
}

class MusicInitial extends MusicState {}

class MusicLoading extends MusicState {}

class PlaylistsLoaded extends MusicState {
  final List<Playlist> playlists;
  const PlaylistsLoaded(this.playlists);

  @override
  List<Object?> get props => [playlists];
}

class PlaylistDetailsLoaded extends MusicState {
  final Playlist playlist;
  const PlaylistDetailsLoaded(this.playlist);

  @override
  List<Object?> get props => [playlist];
}

class MusicPlaying extends MusicState {
  final Song currentSong;
  const MusicPlaying(this.currentSong);

  @override
  List<Object?> get props => [currentSong];
}

class MusicError extends MusicState {
  final String message;
  const MusicError(this.message);

  @override
  List<Object?> get props => [message];
}
