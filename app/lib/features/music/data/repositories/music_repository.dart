import '../models/playlist.dart';
import '../models/song.dart';
import '../datasources/subsonic_api_client.dart';

abstract class MusicRepository {
  Future<List<Playlist>> fetchPlaylists();
  Future<Playlist> fetchPlaylistDetails(String id);
  Future<List<Song>> searchSongs(String query);
}

class SubsonicMusicRepository implements MusicRepository {
  final SubsonicApiClient apiClient;

  SubsonicMusicRepository(this.apiClient);

  @override
  Future<List<Playlist>> fetchPlaylists() async {
    final playlistsJson = await apiClient.getPlaylists();
    return playlistsJson
        .map((json) => Playlist.fromJson(json, apiClient.baseUrl, apiClient.authQuery))
        .toList();
  }

  @override
  Future<Playlist> fetchPlaylistDetails(String id) async {
    final playlistJson = await apiClient.getPlaylist(id);
    return Playlist.fromJson(playlistJson, apiClient.baseUrl, apiClient.authQuery);
  }

  @override
  Future<List<Song>> searchSongs(String query) async {
    final songsJson = await apiClient.searchSongs(query);
    return songsJson
        .map((json) => Song.fromJson(json, apiClient.baseUrl, apiClient.authQuery))
        .toList();
  }
}
