import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

class SubsonicApiClient {
  final Dio _dio;
  final String baseUrl;
  final String username;
  final String password;

  SubsonicApiClient({
    required this.baseUrl,
    required this.username,
    required this.password,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  String _generateSalt() {
    var random = Random.secure();
    var values = List<int>.generate(8, (i) => random.nextInt(255));
    return base64UrlEncode(values).substring(0, 8);
  }

  String _generateAuthQuery() {
    final salt = _generateSalt();
    final token = md5.convert(utf8.encode(password + salt)).toString();
    return 'u=$username&t=$token&s=$salt&v=1.16.1&c=nakama&f=json';
  }
  
  String get authQuery => _generateAuthQuery();

  Future<Map<String, dynamic>> _get(String endpoint, {Map<String, dynamic>? queryParameters}) async {
    final query = _generateAuthQuery();
    final url = '$baseUrl/rest/$endpoint';
    
    final finalQueryParams = queryParameters ?? {};
    finalQueryParams.addAll(Uri.splitQueryString(query));

    try {
      final response = await _dio.get(url, queryParameters: finalQueryParams);
      if (response.data != null && response.data['subsonic-response'] != null) {
        final subResponse = response.data['subsonic-response'];
        if (subResponse['status'] == 'ok') {
          return subResponse;
        } else {
          throw Exception('Subsonic API Error: ${subResponse['error']?['message'] ?? 'Unknown error'}');
        }
      }
      throw Exception('Invalid response format');
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  /// Fetches all playlists
  Future<List<dynamic>> getPlaylists() async {
    final response = await _get('getPlaylists');
    return response['playlists']?['playlist'] ?? [];
  }

  /// Fetches the details and songs of a specific playlist
  Future<Map<String, dynamic>> getPlaylist(String id) async {
    final response = await _get('getPlaylist', queryParameters: {'id': id});
    return response['playlist'] ?? {};
  }
  
  /// Searches for songs
  Future<List<dynamic>> searchSongs(String query) async {
    final response = await _get('search3', queryParameters: {'query': query, 'songCount': 50});
    return response['searchResult3']?['song'] ?? [];
  }
}
