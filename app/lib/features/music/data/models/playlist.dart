import 'package:equatable/equatable.dart';
import 'song.dart';

class Playlist extends Equatable {
  final String id;
  final String name;
  final int songCount;
  final int duration; // total duration in seconds
  final List<Song> songs;

  const Playlist({
    required this.id,
    required this.name,
    required this.songCount,
    required this.duration,
    this.songs = const [],
  });

  factory Playlist.fromJson(Map<String, dynamic> json, String baseUrl, String authQuery) {
    var songsList = <Song>[];
    if (json['entry'] != null) {
      songsList = (json['entry'] as List)
          .map((songJson) => Song.fromJson(songJson, baseUrl, authQuery))
          .toList();
    }

    return Playlist(
      id: json['id'],
      name: json['name'] ?? 'Unnamed Playlist',
      songCount: json['songCount'] ?? 0,
      duration: json['duration'] ?? 0,
      songs: songsList,
    );
  }

  Playlist copyWith({
    String? id,
    String? name,
    int? songCount,
    int? duration,
    List<Song>? songs,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      songCount: songCount ?? this.songCount,
      duration: duration ?? this.duration,
      songs: songs ?? this.songs,
    );
  }

  @override
  List<Object?> get props => [id, name, songCount, duration, songs];
}
