Status: Beta / Personal Project
Notice: Read our Development Disclaimer & AI Philosophy before use

Unsync
Privacy-first, peer-to-peer encrypted messenger for Android.
No accounts. No phone numbers. No servers reading your messages. Just two devices talking directly to each other — encrypted end-to-end with the Signal Protocol.
Download APK (v0.2.0-beta) · Release Notes · Report a Bug

Why Unsync?
Most messengers say they're private. Most of them have a server in the middle that could read your messages, sell your metadata, or hand it over when asked. Unsync removes that server from the equation entirely. Your device connects directly to your contact's device — no middleman, no logs, no data.

Features
🔐 Signal Protocol E2EEDouble Ratchet encryption — same as WhatsApp, but open📡 True P2P via WebRTCDirect device-to-device — no messages touch a server📦 Async store-and-forwardMessages held encrypted and delivered when recipient is back online📞 Encrypted voice callsWebRTC audio, fully encrypted🔔 FCM wake-upNotifications even when the app is killed👁 Biometric lockFingerprint / face auth on open🔗 On-demand connectionsConnects only when sending, auto-closes after 2 min idle🕸 Multi-device meshEach device connects independently — scales to any number of contacts🆔 Zero identityNo accounts, no phone numbers, no email — identity is a cryptographic key pair

Architecture
Device A ←──WebRTC P2P──→ Device B
    ↕                          ↕
Signaling Server (WebSocket)   ↕
    ↕                          ↕
Relay Server (offline fallback)↗

Signaling server — WebSocket server for WebRTC negotiation and peer discovery only. Never sees message content.
Relay server — Stores encrypted blobs for offline delivery. Cannot read content.
P2P connection — Created on demand, auto-closed after 2 min idle.
Signal Protocol — Double Ratchet E2EE, pre-key bundles, persistent sessions.


Getting Started
Prerequisites

Flutter 3.x
Firebase project (for FCM push notifications)
A running signaling server — see /server/signaling/
A running relay server — see /server/relay/

Configuration

Copy android/app/google-services.json.example → android/app/google-services.json and fill in your Firebase details.
Edit lib/config.dart:

dartclass UnsyncConfig {
  static const String signalingUrl = 'ws://YOUR_SERVER:4000';
  static const String relayUrl = 'ws://YOUR_SERVER:5000';
}

Build and run:

bashflutter pub get
flutter run
Server Setup
Both servers are Node.js, managed with PM2:
bashcd server/signaling && npm install && pm2 start server.js --name unsync-signaling
cd server/relay && npm install && pm2 start relay.js --name unsync-relay

Security Model

Messages are encrypted on-device before transmission — the signaling server only sees peer IDs and WebRTC metadata
The relay server stores encrypted blobs only — keys never leave the device
No central identity store — your identity is a key pair generated locally on first launch
Open source — audit it yourself


Roadmap

 Mesh-Mail — decentralized email layer on the P2P backbone
 Unsync Vault — encrypted file sharing
 Mirror Station — always-on home relay node (tablet/homelab)
 Play Store public release


License
GPL v3 — see LICENSE

Built by
Unsync Software — solo indie developer, Antipolo, Philippines.
Built with AI. Architected by a human. Tested on real devices.
