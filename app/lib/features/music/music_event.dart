import 'package:equatable/equatable.dart';
import 'data/models/song.dart';

abstract class MusicEvent extends Equatable {
  const MusicEvent();

  @override
  List<Object?> get props => [];
}

class LoadPlaylistsEvent extends MusicEvent {}

class LoadPlaylistDetailsEvent extends MusicEvent {
  final String playlistId;
  const LoadPlaylistDetailsEvent(this.playlistId);

  @override
  List<Object?> get props => [playlistId];
}

class PlaySongEvent extends MusicEvent {
  final Song song;
  const PlaySongEvent(this.song);

  @override
  List<Object?> get props => [song];
}

class PauseSongEvent extends MusicEvent {}

class ResumeSongEvent extends MusicEvent {}
