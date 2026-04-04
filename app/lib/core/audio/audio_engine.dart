import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../../features/music/data/models/song.dart';

/// Wraps the just_audio package to decouple the presentation layer (BLoC) 
/// from the specific audio package implementation.
class AudioEngine {
  static const double defaultVolume = 1.0;
  static const double duckedVolume = 0.2;

  final AudioPlayer _player;

  AudioEngine({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    _player.setVolume(defaultVolume);
  }

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  Future<void> playSong(Song song) async {
    try {
      // Load the song's secure stream URL
      await _player.setUrl(song.streamUrl);
      // Automatically begin playback
      await _player.play();
    } catch (e) {
      debugPrint('AudioEngine error playing ${song.title}: $e');
      throw Exception("Failed to play audio");
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume);
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
