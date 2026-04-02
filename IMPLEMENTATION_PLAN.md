# Nakama Project Initialization

This document outlines the implementation plan for laying the project foundations, covering the Flutter mobile application scaffolding and the Dockerized backend environment. 

## Goal Description

Initialize the project architecture for **Nakama**, a high-performance gym application. The app features two distinct lanes:
- **Lane 1 (Music)**: Subsonic-compliant player streaming from a Navidrome server.
- **Lane 2 (Comms)**: Zero-latency P2P walkie-talkie link powered by WebRTC via Wi-Fi 7 MLO and Wi-Fi Aware (NAN).

The focus of this plan is scaffolding the Flutter app with necessary native bridges for background audio/hardware networking, and configuring a Docker environment for the backend signaling server, STUN/TURN nodes, and Tailscale tunnels.

> [!IMPORTANT]
> **Key Architecture Decisions Included:**
> - **State Management**: BLoC and Reactive Streams for event-driven audio ducking and network link switching.
> - **WebRTC Fallback**: Tailscale-backed Coturn server for failovers when direct P2P NAN connectivity is lost.
> - **MLO implementation**: "Diversity Mode" Native Bridges bridging Opus packets redundantly across MLO connections.
> - **Native Lifecycles**: Foreground service logic via CallKit (iOS) and ConnectionService (Android).

---

## Proposed Changes

### Docker Environment

We will create a root `docker/` directory containing the containerized backend services needed for local development and remote Tailscale access.

#### [NEW] `docker/docker-compose.yml`
Sets up the local development/production environment containing:
- **Signaling Server:** Node.js WebSocket service coordinating WebRTC connections.
- **Navidrome:** A local Navidrome instance for testing Lane 1 audio.
- **Coturn:** STUN/TURN server for WebRTC NAT traversal if direct P2P fails.
- **Tailscale Sidecar:** A Tailscale container securely tunneling traffic (including the TURN failover) to your server.

#### [NEW] `docker/signaling/Dockerfile`
A lightweight Node.js Alpine image for the Signaling server.

#### [NEW] `docker/signaling/package.json` & `server.js`
Basic WebSocket server implementation for WebRTC session orchestration.

---

### Flutter Scaffolding

We will scaffold a fresh Flutter project optimized for high-performance use cases using BLoC.

#### [NEW] `app/` (Flutter Root)
Initialize a new Flutter application (`flutter create app --platforms=android,ios`).

#### [MODIFY] `app/android/app/src/main/AndroidManifest.xml`
- App permissions: Wi-Fi Aware (NAN), standard networking, manage own calls (`MANAGE_OWN_CALLS`), and background execution.
- Implement Android `ConnectionService` to ensure the OS treats the Walkie-Talkie link as a priority voice call (preventing mic suspension in the pocket).
- Enable Impeller rendering on Android.

#### [MODIFY] `app/ios/Runner/Info.plist`
- Add Background Modes for voice-over-IP (`voip`) and background audio.
- Initialize iOS `CallKit` configurations to map comms directly to the OS dialer/notification abstractions, enforcing high-priority microphone access.
- Add network capability definitions required for direct P2P and Wi-Fi bindings.

#### [NEW] `app/lib/core/native_bridge/`
Scaffolding for custom `MethodChannel` and `EventChannel` definitions communicating with Swift and Kotlin for:
1. **`MloNetworkManager`**: Wi-Fi 7 explicit native bindings configured for **Diversity Mode** (duplicating Opus audio packets concurrently across 2.4GHz and 5GHz bands for maximum resilience).
2. **`AudioSessionManager`**: Reactive Streams emitting link-switching events, combined with ducking/mixing Subsonic audio when WebRTC voices trigger the iOS CallKit/Android ConnectionService channels.

#### [NEW] `app/lib/features/`
- `features/music/`: UI and BLoC components for the Subsonic client (Lane 1).
- `features/comms/`: UI and BLoC logic handling WebRTC state, connection failover (NAN to Tailscale/TURN), and real-time audio ducking (Lane 2).

#### [MODIFY] `app/pubspec.yaml`
Add initial core dependencies: 
- `flutter_webrtc`: Core WebRTC implementation.
- `flutter_bloc` / `bloc`: Core state management and reactive streams for linking features.
- Audio and Telephony plugins to interface with ConnectionService/CallKit (e.g., `flutter_callkit_incoming` or custom bindings).
- `go_router` for performant navigation.

---

## Open Questions

- **Signaling Logic:** Does the signaling server need user authentication via a database right now, or should it just be transient/stateless for the POC?
- **Subsonic Library:** Should we use an existing Flutter Subsonic API wrapper, or build the API client from scratch for better performance and audio stream mixing control?

## Verification Plan

### Automated/Manual Constraints
- Start the Docker environment (`docker-compose up`) and verify the Tailscale tunnel and Coturn instances bind properly.
- Run the Flutter app with Impeller enabled on iOS and Android test devices.
- Trigger a mock CallKit/ConnectionService interruption to confirm the OS grants priority microphone/audio ducking capabilities.
