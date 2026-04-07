import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'core/audio/audio_engine.dart';
import 'core/config/app_config.dart';
import 'features/comms/comms_bloc.dart';
import 'features/comms/comms_state.dart';
import 'features/comms/data/repositories/comms_transport_service.dart';
import 'features/comms/data/repositories/nearby_connections_service.dart';
import 'features/comms/presentation/screens/comms_screen.dart';
import 'features/music/data/datasources/subsonic_api_client.dart';
import 'features/music/data/repositories/music_repository.dart';
import 'features/music/music_bloc.dart';
import 'features/music/music_event.dart';
import 'features/music/presentation/screens/music_library_screen.dart';
import 'features/music/presentation/screens/playlist_detail_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final appConfig = AppConfig.fromEnvironment();
  final apiClient = SubsonicApiClient(
    baseUrl: appConfig.navidromeBaseUrl,
    username: appConfig.navidromeUsername,
    password: appConfig.navidromePassword,
  );
  final musicRepository = SubsonicMusicRepository(apiClient);
  final audioEngine = AudioEngine();
  final CommsTransportService commsTransportService =
      NearbyConnectionsService();

  runApp(
    NakamaSyncApp(
      appConfig: appConfig,
      musicRepository: musicRepository,
      audioEngine: audioEngine,
      commsTransportService: commsTransportService,
    ),
  );
}

class NakamaSyncApp extends StatelessWidget {
  final AppConfig appConfig;
  final MusicRepository musicRepository;
  final AudioEngine audioEngine;
  final CommsTransportService commsTransportService;

  const NakamaSyncApp({
    super.key,
    required this.appConfig,
    required this.musicRepository,
    required this.audioEngine,
    required this.commsTransportService,
  });

  GoRouter get _router => GoRouter(
    initialLocation: '/music',
    routes: [
      GoRoute(
        path: '/music',
        builder: (context, state) => appConfig.hasMusicConfig
            ? const MusicLibraryScreen()
            : const MusicConfigurationRequiredScreen(),
        routes: [
          GoRoute(
            path: ':playlistId',
            builder: (context, state) => PlaylistDetailScreen(
              playlistId: state.pathParameters['playlistId']!,
              musicRepository: musicRepository,
            ),
          ),
        ],
      ),
      GoRoute(path: '/comms', builder: (context, state) => const CommsScreen()),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp.router(
      title: 'Nakama Sync',
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
    );

    return MultiBlocProvider(
      providers: [
        BlocProvider<CommsBloc>(
          create: (context) =>
              CommsBloc(transportService: commsTransportService),
        ),
        if (appConfig.hasMusicConfig)
          BlocProvider<MusicBloc>(
            create: (context) =>
                MusicBloc(repository: musicRepository, audioEngine: audioEngine)
                  ..add(LoadPlaylistsEvent()),
          ),
      ],
      child: Builder(
        builder: (context) {
          if (!appConfig.hasMusicConfig) {
            return app;
          }

          return BlocListener<CommsBloc, CommsState>(
            listenWhen: (previous, current) {
              return previous.isSpeechActive != current.isSpeechActive;
            },
            listener: (context, state) {
              final targetVolume = state.isSpeechActive
                  ? AudioEngine.duckedVolume
                  : AudioEngine.defaultVolume;
              audioEngine.setVolume(targetVolume);
            },
            child: app,
          );
        },
      ),
    );
  }
}

class MusicConfigurationRequiredScreen extends StatelessWidget {
  const MusicConfigurationRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music'),
        actions: [
          IconButton(
            onPressed: () => context.go('/comms'),
            icon: const Icon(Icons.wifi_tethering),
            tooltip: 'Link',
          ),
        ],
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.settings_input_component,
                size: 56,
                color: Colors.white70,
              ),
              SizedBox(height: 16),
              Text(
                'Music service is not configured.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              Text(
                'Provide NAKAMA_NAVIDROME_BASE_URL, '
                'NAKAMA_NAVIDROME_USERNAME, and '
                'NAKAMA_NAVIDROME_PASSWORD via --dart-define.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
