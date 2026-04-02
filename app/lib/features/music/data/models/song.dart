import 'package:equatable/equatable.dart';

class Song extends Equatable {
  final String id;
  final String title;
  final String artist;
  final String album;
  final int duration; // in seconds
  final String streamUrl; // Constructed URL for streaming
  final String coverArtUrl; // Constructed URL for the album cover

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.streamUrl,
    required this.coverArtUrl,
  });

  factory Song.fromJson(Map<String, dynamic> json, String baseUrl, String authQuery) {
    final id = json['id'];
    final coverArtId = json['coverArt'];
    
    return Song(
      id: id,
      title: json['title'] ?? 'Unknown Title',
      artist: json['artist'] ?? 'Unknown Artist',
      album: json['album'] ?? 'Unknown Album',
      duration: json['duration'] ?? 0,
      streamUrl: '$baseUrl/rest/stream?id=$id&$authQuery',
      coverArtUrl: '$baseUrl/rest/getCoverArt?id=$coverArtId&$authQuery',
    );
  }

  @override
  List<Object?> get props => [id, title, artist, album, duration, streamUrl, coverArtUrl];
}
