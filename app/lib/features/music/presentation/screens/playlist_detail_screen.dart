import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../music_bloc.dart';
import '../../music_event.dart';
import '../../music_state.dart';

class PlaylistDetailScreen extends StatelessWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.musicRepository,
  });

  final String playlistId;
  final MusicRepository musicRepository;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Playlist>(
      future: musicRepository.fetchPlaylistDetails(playlistId),
      builder: (context, snapshot) {
        return Scaffold(
          appBar: AppBar(
            title: Text(snapshot.data?.name ?? 'Playlist'),
            actions: [
              IconButton(
                onPressed: () => context.go('/comms'),
                icon: const Icon(Icons.wifi_tethering),
                tooltip: 'Walkie-Talkie',
              ),
            ],
          ),
          body: switch (snapshot.connectionState) {
            ConnectionState.waiting || ConnectionState.active => const Center(
                child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
              ),
            _ when snapshot.hasError => _PlaylistDetailError(
                message: snapshot.error.toString(),
              ),
            _ when snapshot.hasData => _PlaylistSongsList(
                playlist: snapshot.requireData,
              ),
            _ => const _PlaylistDetailError(
                message: 'Playlist could not be loaded.',
              ),
          },
        );
      },
    );
  }
}

class _PlaylistSongsList extends StatelessWidget {
  const _PlaylistSongsList({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    if (playlist.songs.isEmpty) {
      return const Center(
        child: Text(
          'This playlist has no songs yet.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return BlocBuilder<MusicBloc, MusicState>(
      builder: (context, state) {
        final currentSong = switch (state) {
          MusicPlaying(:final currentSong) => currentSong,
          _ => null,
        };

        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: playlist.songs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final song = playlist.songs[index];
            final isPlaying = currentSong?.id == song.id;

            return Card(
              color: const Color(0xFF1E1E1E),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                leading: CircleAvatar(
                  backgroundColor: Colors.deepPurple.withValues(alpha: 0.2),
                  child: Icon(
                    isPlaying ? Icons.graphic_eq : Icons.music_note,
                    color: Colors.deepPurpleAccent,
                  ),
                ),
                title: Text(song.title),
                subtitle: Text(
                  '${song.artist} • ${song.album}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
                ),
                trailing: IconButton(
                  onPressed: () => _playSong(context, song),
                  icon: Icon(
                    isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    color: Colors.deepPurpleAccent,
                    size: 30,
                  ),
                ),
                onTap: () => _playSong(context, song),
              ),
            );
          },
        );
      },
    );
  }

  void _playSong(BuildContext context, Song song) {
    context.read<MusicBloc>().add(PlaySongEvent(song));
  }
}

class _PlaylistDetailError extends StatelessWidget {
  const _PlaylistDetailError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
        ),
      ),
    );
  }
}
