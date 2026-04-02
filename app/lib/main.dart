import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'core/audio/audio_engine.dart';
import 'features/music/data/datasources/subsonic_api_client.dart';
import 'features/music/data/repositories/music_repository.dart';
import 'features/music/music_bloc.dart';
import 'features/music/music_event.dart';
import 'features/music/presentation/screens/music_library_screen.dart';

void main() {
  // Dependency Injection for Lane 1
  final apiClient = SubsonicApiClient(
    baseUrl: 'http://localhost:4533', // Default mock Navidrome URL
    username: 'admin',                // Placeholder default
    password: 'admin_password',       // Placeholder default
  );
  
  final musicRepository = SubsonicMusicRepository(apiClient);
  final audioEngine = AudioEngine();

  runApp(NakamaApp(
    musicRepository: musicRepository,
    audioEngine: audioEngine,
  ));
}

class NakamaApp extends StatelessWidget {
  final MusicRepository musicRepository;
  final AudioEngine audioEngine;

  NakamaApp({
    super.key,
    required this.musicRepository,
    required this.audioEngine,
  });

  final GoRouter _router = GoRouter(
    initialLocation: '/music',
    routes: [
      GoRoute(
        path: '/music',
        builder: (context, state) => const MusicLibraryScreen(),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<MusicBloc>(
          create: (context) => MusicBloc(
            repository: musicRepository,
            audioEngine: audioEngine,
          )..add(LoadPlaylistsEvent()), // Auto-fetch library on launch
        ),
      ],
      child: MaterialApp.router(
        title: 'Nakama',
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: Colors.deepPurpleAccent,
          scaffoldBackgroundColor: const Color(0xFF101010),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1A1A1A),
            elevation: 0,
          ),
        ),
        routerConfig: _router,
      ),
    );
  }
}
