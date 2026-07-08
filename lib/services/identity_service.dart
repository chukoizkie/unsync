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

class MeshRelayAuthResponse {
  const MeshRelayAuthResponse({
    required this.peerId,
    required this.publicKey,
    required this.signature,
  });

  final String peerId;
  final String publicKey;
  final String signature;
}

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

  Future<MeshRelayAuthResponse?> signRelayAuthChallenge({
    required String version,
    required String nonce,
    required Object serverTime,
  }) async {
    final identity = await _loadMeshIdentity();
    if (identity == null) {
      return null;
    }

    final privateKey = _ed25519PrivateKey(identity.privateKey);
    final payload = '$version|relay|${identity.peerId}|$nonce|$serverTime';
    final signature = ed25519.sign(
      privateKey,
      Uint8List.fromList(utf8.encode(payload)),
    );

    return MeshRelayAuthResponse(
      peerId: identity.peerId,
      publicKey: _normalizePublicKey(identity.publicKey),
      signature: _base64UrlNoPadding(signature),
    );
  }

  Future<_MeshIdentity?> _loadMeshIdentity() async {
    final encoded = await _secureStorage.read(key: _meshIdentityKey);
    if (encoded == null || encoded.isEmpty) {
      return null;
    }

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

  static String _normalizePublicKey(String publicKey) {
    return _base64UrlNoPadding([
      ..._ed25519SpkiPrefix,
      ..._rawEd25519PublicKey(publicKey),
    ]);
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
