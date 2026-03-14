# Unsync

A privacy-first, peer-to-peer encrypted messenger for Android.

## Features

- **End-to-end encrypted** messaging using Signal Protocol
- **P2P direct connections** via WebRTC — no messages stored on server
- **Async delivery** — messages delivered when recipient comes back online
- **Biometric lock** — fingerprint/face authentication on app open
- **Voice calls** — encrypted WebRTC audio
- **On-demand connections** — connects only when sending, idle connections auto-close
- **Multi-device mesh** — each device connects independently, scales to any number of contacts
- **Foreground service** — stays connected in background
- **FCM wake-up** — wakes app when message arrives

## Architecture
```
Device A ←──WebRTC P2P──→ Device B
    ↕                          ↕
Signaling Server (WebSocket)   ↕
    ↕                          ↕
Relay Server (offline fallback)↗
```

- **Signaling server** — WebSocket server for WebRTC negotiation and peer discovery
- **Relay server** — Fallback for offline message delivery (store-and-forward)
- **P2P connection** — Created on demand when sending a message, auto-closed after 2 min idle
- **Signal Protocol** — Double Ratchet E2EE, pre-key bundles, persistent sessions

## Setup

### Prerequisites

- Flutter 3.x
- Firebase project (for FCM push notifications)
- A signaling server (see `/server/signaling/`)
- A relay server (see `/server/relay/`)

### Configuration

1. Copy `android/app/google-services.json.example` to `android/app/google-services.json` and fill in your Firebase project details.

2. Edit `lib/config.dart` and point to your servers:
```dart
class UnsyncConfig {
  static const String signalingUrl = 'ws://YOUR_SERVER:4000';
  static const String relayUrl = 'ws://YOUR_SERVER:5000';
}
```

3. Run:
```bash
flutter pub get
flutter run
```

## Server Setup

Both servers are Node.js and managed with PM2.
```bash
cd server/signaling && npm install && pm2 start server.js --name unsync-signaling
cd server/relay && npm install && pm2 start relay.js --name unsync-relay
```

## Security

- All messages are encrypted with Signal Protocol before leaving the device
- The signaling server only sees peer IDs and WebRTC negotiation metadata — never message content
- The relay server stores encrypted blobs only — cannot read message content
- No accounts, no phone numbers, no email — identity is a cryptographic key pair generated on device

## License

GPL v3 — see [LICENSE](LICENSE)

## Built by

[Unsync Software](https://unsyncsoftware.com) — built and maintained by a solo indie developer from the Philippines.
