// Unsync configuration
class UnsyncConfig {
  static const String signalingUrl = 'wss://signal.unsync.uk';
  static const String relayUrl = 'wss://relay.unsync.uk';

  // ── TURN ──────────────────────────────────────────────────────────────────
  // Supplied at build time, never committed:
  //   flutter build apk --dart-define=TURN_URL=turn:host:3478 \
  //                     --dart-define=TURN_USERNAME=... \
  //                     --dart-define=TURN_CREDENTIAL=...
  //
  // These were previously source literals, and the committed credential did
  // not match the one coturn actually accepts — so TURN allocation failed and
  // calls only connected when STUN alone was enough. Relay is required when
  // both peers sit behind symmetric or carrier-grade NAT.
  static const String turnUrl = String.fromEnvironment(
    'TURN_URL',
    defaultValue: 'turn:64.188.17.219:3478',
  );
  static const String turnUsername = String.fromEnvironment('TURN_USERNAME');
  static const String turnCredential = String.fromEnvironment(
    'TURN_CREDENTIAL',
  );

  /// Whether a usable TURN credential was supplied at build time. When false
  /// the TURN entry is omitted entirely rather than sent with a known-bad
  /// credential, which only buys failed allocations and slower ICE.
  static bool get hasTurnCredentials =>
      turnUrl.isNotEmpty &&
      turnUsername.isNotEmpty &&
      turnCredential.isNotEmpty;
}

