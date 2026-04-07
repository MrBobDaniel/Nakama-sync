import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/playlist.dart';
import '../../music_bloc.dart';
import '../../music_state.dart';

class MusicLibraryScreen extends StatefulWidget {
  const MusicLibraryScreen({super.key});

  @override
  State<MusicLibraryScreen> createState() => _MusicLibraryScreenState();
}

class _MusicLibraryScreenState extends State<MusicLibraryScreen> {
  List<Playlist> _cachedPlaylists = const [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Music Library',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () => context.go('/comms'),
            icon: const Icon(Icons.wifi_tethering),
            tooltip: 'Link',
          ),
        ],
      ),
      body: BlocBuilder<MusicBloc, MusicState>(
        builder: (context, state) {
          if (state is PlaylistsLoaded) {
            _cachedPlaylists = state.playlists;
          }

          if ((state is MusicInitial || state is MusicLoading) &&
              _cachedPlaylists.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
            );
          }

          if (state is PlaylistsLoaded && _cachedPlaylists.isEmpty) {
            return const Center(
              child: Text(
                'No playlists found in Navidrome.',
                style: TextStyle(color: Colors.grey),
              ),
            );
          }

          if (_cachedPlaylists.isNotEmpty) {
            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              itemCount: _cachedPlaylists.length,
              itemBuilder: (context, index) {
                final playlist = _cachedPlaylists[index];
                return Card(
                  color: const Color(0xFF1E1E1E),
                  elevation: 2,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(12),
                    leading: Container(
                      height: 50,
                      width: 50,
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.queue_music,
                        color: Colors.deepPurpleAccent,
                      ),
                    ),
                    title: Text(
                      playlist.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      '${playlist.songCount} songs',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                    onTap: () {
                      context.go('/music/${Uri.encodeComponent(playlist.id)}');
                    },
                  ),
                );
              },
            );
          }

          if (state is MusicError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 60,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load library:\n${state.message}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ),
              ),
            );
          }

          return const Center(child: Text('Unknown State'));
        },
      ),
    );
  }
}
