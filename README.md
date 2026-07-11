> **Status:** Beta / Personal Project
> **Notice:** Read our [Development Disclaimer & AI Philosophy](./DISCLAIMER.md) before use

# Unsync
### Privacy-first, peer-to-peer encrypted messenger for Android.

No accounts. No phone numbers. No servers reading your messages. Just two devices talking directly to each other — encrypted end-to-end with the Signal Protocol.

[Download APK (v0.2.0-beta)](https://github.com/chukoizkie/unsync/releases/latest) · [Release Notes](https://github.com/chukoizkie/unsync/releases) · [Report a Bug](https://github.com/chukoizkie/unsync/issues)

---

## Why Unsync?

Most messengers say they're private. Most of them have a server in the middle that *could* read your messages, sell your metadata, or hand it over when asked. Unsync removes that server from the equation entirely. Your device connects directly to your contact's device — no middleman, no logs, no data.

---

## Features

| | |
|---|---|
| 🔐 **Signal Protocol E2EE** | Double Ratchet encryption — same as WhatsApp, but open |
| 📡 **True P2P via WebRTC** | Direct device-to-device — no messages touch a server |
| 📦 **Async store-and-forward** | Messages held encrypted and delivered when recipient is back online |
| 📞 **Encrypted voice calls** | WebRTC audio, fully encrypted |
| 🔔 **FCM wake-up** | Notifications even when the app is killed |
| 👁 **Biometric lock** | Fingerprint / face auth on open |
| 🔗 **On-demand connections** | Connects only when sending, auto-closes after 2 min idle |
| 🕸 **Multi-device mesh** | Each device connects independently — scales to any number of contacts |
| 🆔 **Zero identity** | No accounts, no phone numbers, no email — identity is a cryptographic key pair |

---

## Architecture

\`\`\`
Device A <──WebRTC P2P──> Device B
    |                          |
Signaling Server (WebSocket)   |
    |                          |
Relay Server (offline fallback)/
\`\`\`

- **Signaling server** — WebSocket server for WebRTC negotiation and peer discovery only. Never sees message content.
- **Relay server** — Stores encrypted blobs for offline delivery. Cannot read content.
- **P2P connection** — Created on demand, auto-closed after 2 min idle.
- **Signal Protocol** — Double Ratchet E2EE, pre-key bundles, persistent sessions.

---

## Getting Started

### Prerequisites
- Flutter 3.x
- Firebase project (for FCM push notifications)
- A running signaling server from the separate [`unsyncsoftware/unsync-cloaknet`](https://github.com/unsyncsoftware/unsync-cloaknet) repository
- A running relay server — see `/server/relay/`

### Configuration

1. Copy `android/app/google-services.json.example` to `android/app/google-services.json` and fill in your Firebase details.

2. Edit `lib/config.dart`:
\`\`\`dart
class UnsyncConfig {
  static const String signalingUrl = 'wss://signal.unsync.uk';
  static const String relayUrl = 'ws://YOUR_SERVER:5000';
}
\`\`\`

3. Build and run:
\`\`\`bash
flutter pub get
flutter run
\`\`\`

### Server Setup

Mercury is a client-only repository and does not contain the production signaling server. For local signaling development, run the separate `unsync-signaling` checkout independently:
\`\`\`bash
cd C:\dev\unsync-signaling
npm install
node server.js
\`\`\`

Production signaling is maintained in `unsyncsoftware/unsync-cloaknet` and deployed at `/root/signaling/server.js` on the VPS. Do not copy `server.js` back into Mercury.

The relay server, if used locally, is still managed separately:
\`\`\`bash
cd server/relay && npm install && pm2 start relay.js --name unsync-relay
\`\`\`

---

## Security Model

- Messages are encrypted on-device before transmission — the signaling server only sees peer IDs and WebRTC metadata
- The relay server stores encrypted blobs only — keys never leave the device
- No central identity store — your identity is a key pair generated locally on first launch
- Open source — audit it yourself

---

## Roadmap

- [ ] Mesh-Mail — decentralized email layer on the P2P backbone
- [ ] Unsync Vault — encrypted file sharing
- [ ] Mirror Station — always-on home relay node (tablet/homelab)
- [ ] Play Store public release

---

## License

GPL v3 — see [LICENSE](LICENSE)

---

## Built by

[Unsync Software](https://unsyncsoftware.com) — solo indie developer, Antipolo, Philippines.
Built with AI. Architected by a human. Tested on real devices.
