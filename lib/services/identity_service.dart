// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed25519;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const List<int> _ed25519SpkiPrefix = [
  0x30,
  0x2a,
  0x30,
  0x05,
  0x06,
  0x03,
  0x2b,
  0x65,
  0x70,
  0x03,
  0x21,
  0x00,
];

const bool _relayAuthDebug = bool.fromEnvironment('RELAY_AUTH_DEBUG');
const bool _signalingAuthDebug = bool.fromEnvironment('SIGNALING_AUTH_DEBUG');

class MeshAuthResponse {
  const MeshAuthResponse({
    required this.peerId,
    required this.publicKey,
    required this.signature,
  });

  final String peerId;
  final String publicKey;
  final String signature;
}

typedef MeshRelayAuthResponse = MeshAuthResponse;

class _MeshIdentity {
  const _MeshIdentity({
    required this.peerId,
    required this.publicKey,
    required this.privateKey,
  });

  final String peerId;
  final String publicKey;
  final String privateKey;
}

class IdentityService {
  static const _keyPeerId = 'peer_id';
  static const _keyDisplayName = 'display_name';
  static const _meshIdentityKey = 'mesh_identity_bundle';

  final FlutterSecureStorage _secureStorage;

  String? _peerId;
  String? _displayName;

  IdentityService({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  String? get peerId => _peerId;
  String? get displayName => _displayName;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _peerId = prefs.getString(_keyPeerId);
    _displayName = prefs.getString(_keyDisplayName);
    if (_peerId == null) {
      _peerId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString(_keyPeerId, _peerId!);
    }
  }

  Future<void> setDisplayName(String name) async {
    _displayName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDisplayName, name);
  }

  bool get isSetup => _displayName != null && _displayName!.isNotEmpty;

  Future<MeshAuthResponse?> signRelayAuthChallenge({
    required String version,
    required String nonce,
    required Object serverTime,
  }) async {
    final identity = await _loadOrCreateMeshIdentity();
    if (identity == null) {
      print('Relay auth unavailable');
      return null;
    }

    return _signAuthChallenge(
      identity: identity,
      version: version,
      role: 'relay',
      nonce: nonce,
      serverTime: serverTime,
      debugLogPrefix: _relayAuthDebug ? '[relay-auth]' : null,
    );
  }

  Future<MeshAuthResponse?> signSignalingAuthChallenge({
    required String nonce,
    required Object serverTime,
  }) async {
    final identity = await _loadMeshIdentity();
    if (identity == null) {
      return null;
    }

    return _signAuthChallenge(
      identity: identity,
      version: 'cloaknet-auth-v1',
      role: 'signaling',
      nonce: nonce,
      serverTime: serverTime,
      debugLogPrefix: _signalingAuthDebug ? '[signaling-auth]' : null,
    );
  }

  static String relayAuthSigningString({
    required String version,
    required String peerId,
    required String nonce,
    required Object serverTime,
  }) {
    return authSigningString(
      version: version,
      role: 'relay',
      peerId: peerId,
      nonce: nonce,
      serverTime: serverTime,
    );
  }

  static String signalingAuthSigningString({
    required String peerId,
    required String nonce,
    required Object serverTime,
  }) {
    return authSigningString(
      version: 'cloaknet-auth-v1',
      role: 'signaling',
      peerId: peerId,
      nonce: nonce,
      serverTime: serverTime,
    );
  }

  static String authSigningString({
    required String version,
    required String role,
    required String peerId,
    required String nonce,
    required Object serverTime,
  }) {
    return '$version|$role|$peerId|$nonce|$serverTime';
  }

  MeshAuthResponse _signAuthChallenge({
    required _MeshIdentity identity,
    required String version,
    required String role,
    required String nonce,
    required Object serverTime,
    required String? debugLogPrefix,
  }) {
    final privateKey = _ed25519PrivateKey(identity.privateKey);
    final payload = authSigningString(
      version: version,
      role: role,
      peerId: identity.peerId,
      nonce: nonce,
      serverTime: serverTime,
    );
    if (debugLogPrefix != null) {
      print('$debugLogPrefix signing_string=$payload');
    }
    final signature = ed25519.sign(
      privateKey,
      Uint8List.fromList(utf8.encode(payload)),
    );

    return MeshAuthResponse(
      peerId: identity.peerId,
      publicKey: _relayPublicKey(identity.publicKey),
      signature: _base64UrlNoPadding(signature),
    );
  }

  Future<_MeshIdentity?> _loadMeshIdentity() async {
    try {
      final encoded = await _secureStorage.read(key: _meshIdentityKey);
      if (encoded == null || encoded.isEmpty) {
        return null;
      }
      return _meshIdentityFromJson(encoded);
    } catch (_) {
      return null;
    }
  }

  Future<_MeshIdentity?> _loadOrCreateMeshIdentity() async {
    try {
      final encoded = await _secureStorage.read(key: _meshIdentityKey);
      if (encoded != null && encoded.isNotEmpty) {
        final existing = _meshIdentityFromJson(encoded);
        if (existing == null) {
          print('Relay auth identity invalid');
          return null;
        }
        print('Relay auth identity exists');
        return existing;
      }

      final prefs = await SharedPreferences.getInstance();
      final peerId = _stringValue(prefs.getString(_keyPeerId));
      if (peerId == null) {
        return null;
      }

      final keyPair = ed25519.generateKey();
      final identity = _MeshIdentity(
        peerId: peerId,
        publicKey: _base64UrlNoPadding(keyPair.publicKey.bytes),
        privateKey: base64Encode(keyPair.privateKey.bytes),
      );
      await _secureStorage.write(
        key: _meshIdentityKey,
        value: jsonEncode({
          'peerId': identity.peerId,
          'publicKey': identity.publicKey,
          'privateKey': identity.privateKey,
        }),
      );
      print('Relay auth identity created');
      return identity;
    } catch (e) {
      print('Relay auth identity invalid');
      return null;
    }
  }

  static _MeshIdentity? _meshIdentityFromJson(String encoded) {
    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map<String, dynamic>) {
        return null;
      }

      final peerId = _stringValue(raw['peerId']);
      final publicKey = _stringValue(raw['publicKey']);
      final privateKey = _stringValue(raw['privateKey']);
      if (peerId == null || publicKey == null || privateKey == null) {
        return null;
      }

      _rawEd25519PublicKey(publicKey);
      _ed25519PrivateKey(privateKey);
      return _MeshIdentity(
        peerId: peerId,
        publicKey: publicKey,
        privateKey: privateKey,
      );
    } catch (_) {
      return null;
    }
  }

  static ed25519.PrivateKey _ed25519PrivateKey(String encodedPrivateKey) {
    final bytes = base64Decode(encodedPrivateKey);
    if (bytes.length == ed25519.PrivateKeySize) {
      return ed25519.PrivateKey(Uint8List.fromList(bytes));
    }
    if (bytes.length == ed25519.SeedSize) {
      return ed25519.newKeyFromSeed(Uint8List.fromList(bytes));
    }
    throw const FormatException('Invalid Ed25519 private key length.');
  }

  static String _relayPublicKey(String publicKey) {
    return _base64UrlNoPadding(_rawEd25519PublicKey(publicKey));
  }

  static List<int> _rawEd25519PublicKey(String encodedPublicKey) {
    final bytes = base64Url.decode(_withBase64Padding(encodedPublicKey));
    if (bytes.length == ed25519.PublicKeySize) {
      return bytes;
    }

    if (bytes.length == _ed25519SpkiPrefix.length + ed25519.PublicKeySize) {
      for (var index = 0; index < _ed25519SpkiPrefix.length; index++) {
        if (bytes[index] != _ed25519SpkiPrefix[index]) {
          throw const FormatException('Invalid Ed25519 SPKI public key.');
        }
      }
      return bytes.sublist(_ed25519SpkiPrefix.length);
    }

    throw const FormatException('Invalid Ed25519 public key length.');
  }

  static String _base64UrlNoPadding(List<int> bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _withBase64Padding(String value) {
    final remainder = value.length % 4;
    if (remainder == 0) {
      return value;
    }
    return value.padRight(value.length + 4 - remainder, '=');
  }

  static String? _stringValue(Object? value) {
    return value is String && value.isNotEmpty ? value : null;
  }
}
