# Nakama Sync Implementation Status Checklist

This checklist compares the current codebase against [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md) and [IMPLEMENTATION_PLAN.md](/home/mrbobdaniel/Nakama-sync/IMPLEMENTATION_PLAN.md).

## Status Key

- `[x]` Implemented
- `[~]` Partially implemented / scaffolded only
- `[ ]` Not implemented

## Checklist

- `[x]` Flutter app scaffold exists.
  Evidence: [main.dart](/home/mrbobdaniel/Nakama-sync/app/lib/main.dart#L19), [pubspec.yaml](/home/mrbobdaniel/Nakama-sync/app/pubspec.yaml#L1)

- `[x]` BLoC-based music and comms feature structure exists.
  Evidence: [music_bloc.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/music/music_bloc.dart#L6), [comms_bloc.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/comms/comms_bloc.dart#L9)

- `[x]` Subsonic/Navidrome client and music UI are implemented.
  Evidence: [subsonic_api_client.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/music/data/datasources/subsonic_api_client.dart#L6), [music_library_screen.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/music/presentation/screens/music_library_screen.dart#L12), [playlist_detail_screen.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/music/presentation/screens/playlist_detail_screen.dart#L11)

- `[x]` Cross-platform Nearby native bridge scaffolding exists.
  Evidence: [nearby_connections_manager.dart](/home/mrbobdaniel/Nakama-sync/app/lib/core/native_bridge/nearby_connections_manager.dart#L6), [NearbyConnectionsBridge.kt](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/kotlin/com/nakamasync/app/NearbyConnectionsBridge.kt#L55), [NearbyConnectionsBridge.swift](/home/mrbobdaniel/Nakama-sync/app/ios/Runner/NearbyConnectionsBridge.swift#L9)

- `[x]` Nearby room open/connect/PTT flow is implemented in app state and UI.
  Evidence: [comms_bloc.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/comms/comms_bloc.dart#L27), [nearby_connections_service.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/comms/data/repositories/nearby_connections_service.dart#L7), [comms_screen.dart](/home/mrbobdaniel/Nakama-sync/app/lib/features/comms/presentation/screens/comms_screen.dart#L215)

- `[x]` Music ducking to `20%` is implemented for active speech states.
  Evidence: [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md#L8), [audio_engine.dart](/home/mrbobdaniel/Nakama-sync/app/lib/core/audio/audio_engine.dart#L8), [main.dart](/home/mrbobdaniel/Nakama-sync/app/lib/main.dart#L114)

- `[x]` Android and iOS permission/platform config scaffolding is present.
  Evidence: [AndroidManifest.xml](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/AndroidManifest.xml#L2), [Info.plist](/home/mrbobdaniel/Nakama-sync/app/ios/Runner/Info.plist#L5)

- `[x]` Android `ConnectionService` requirement is functionally integrated for self-managed walkie-talkie sessions.
  Evidence: [CallConnectionService.kt](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/kotlin/com/nakamasync/app/CallConnectionService.kt#L12), [CommsSessionManager.kt](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/kotlin/com/nakamasync/app/CommsSessionManager.kt#L15), [NearbyConnectionsBridge.kt](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/kotlin/com/nakamasync/app/NearbyConnectionsBridge.kt#L94)

- `[x]` iOS CallKit session management and audio-session handling are implemented for comms persistence.
  Evidence: [Info.plist](/home/mrbobdaniel/Nakama-sync/app/ios/Runner/Info.plist#L5), [IOSCommsSessionManager.swift](/home/mrbobdaniel/Nakama-sync/app/ios/Runner/IOSCommsSessionManager.swift#L1), [NearbyConnectionsBridge.swift](/home/mrbobdaniel/Nakama-sync/app/ios/Runner/NearbyConnectionsBridge.swift#L9)

- `[x]` Android foreground service to keep comms alive is implemented.
  Evidence: [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md#L12), [CommsForegroundService.kt](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/kotlin/com/nakamasync/app/CommsForegroundService.kt#L14), [AndroidManifest.xml](/home/mrbobdaniel/Nakama-sync/app/android/app/src/main/AndroidManifest.xml#L16)

- `[~]` Dedicated `AudioSessionManager` bridge is still missing as a standalone cross-platform abstraction, but iOS-native audio-session handling now exists.
  Expected by: [IMPLEMENTATION_PLAN.md](/home/mrbobdaniel/Nakama-sync/IMPLEMENTATION_PLAN.md#L61)

- `[ ]` 5-song lookahead cache is missing.
  Expected by: [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md#L10)

- `[ ]` Relay fallback transport is missing.
  Expected by: [IMPLEMENTATION_PLAN.md](/home/mrbobdaniel/Nakama-sync/IMPLEMENTATION_PLAN.md#L28)

- `[ ]` Tailscale integration is missing.
  Expected by: [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md#L6), [IMPLEMENTATION_PLAN.md](/home/mrbobdaniel/Nakama-sync/IMPLEMENTATION_PLAN.md#L33)

- `[ ]` Docker environment is missing.
  Expected by: [IMPLEMENTATION_PLAN.md](/home/mrbobdaniel/Nakama-sync/IMPLEMENTATION_PLAN.md#L24)

- `[ ]` Diversity mode / Wi-Fi 7 MLO redundant packet path is missing.
  Expected by: [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md#L5)

- `[ ]` Diversity status overlay for 2.4 GHz and 5 GHz lane health is missing.
  Expected by: [.ai-instructions.md](/home/mrbobdaniel/Nakama-sync/.ai-instructions.md#L16)

## Recommendation

The next highest-value step is a dedicated cross-platform `AudioSessionManager`.

Why this should go first:

- Android foreground service/`ConnectionService` and iOS CallKit persistence are now in place, so the next gap is unifying OS audio focus/session state instead of adding another transport.
- The implementation plan explicitly calls for an `AudioSessionManager` bridge to coordinate ducking, routing, and system audio interruptions across both platforms.
- That abstraction will reduce duplication between the Android communication audio controller and the new iOS CallKit/audio-session lane, making later relay and caching work safer to add.

Recommended order after that:

1. Dedicated `AudioSessionManager` abstraction to unify ducking and session state.
2. Docker stack with relay/Navidrome/Tailscale.
3. Relay fallback path in the app.
4. 5-song lookahead cache.
5. Diversity mode and diversity status overlay.

## Validation

- `flutter analyze` passed in `/home/mrbobdaniel/Nakama-sync/app`
- `./gradlew app:compileDebugKotlin` passed in `/home/mrbobdaniel/Nakama-sync/app/android` after pinning Gradle to JDK 21 via `org.gradle.java.home=/usr/lib/jvm/java-21-openjdk-amd64`
