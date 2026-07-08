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
    print(
      '[relay-auth identity] loading mesh identity; secure-storage keys queried=$_meshIdentityKey',
    );
    final encoded = await _secureStorage.read(key: _meshIdentityKey);
    _logIdentityBundleDiagnostics(
      key: _meshIdentityKey,
      encoded: encoded,
      primary: true,
    );
    await _logAlternateIdentityCandidates();

    if (encoded == null || encoded.isEmpty) {
      return null;
    }

    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map<String, dynamic>) {
        print(
          '[relay-auth identity] $_meshIdentityKey validation=false reason=json_not_object',
        );
        return null;
      }

      final peerId = _stringValue(raw['peerId']);
      final publicKey = _stringValue(raw['publicKey']);
      final privateKey = _stringValue(raw['privateKey']);
      if (peerId == null || publicKey == null || privateKey == null) {
        print(
          '[relay-auth identity] $_meshIdentityKey validation=false reason=missing_expected_fields',
        );
        return null;
      }

      print('[relay-auth identity] $_meshIdentityKey validation=true');
      return _MeshIdentity(
        peerId: peerId,
        publicKey: publicKey,
        privateKey: privateKey,
      );
    } catch (_) {
      print(
        '[relay-auth identity] $_meshIdentityKey validation=false reason=json_decode_failed',
      );
      return null;
    }
  }

  Future<void> _logAlternateIdentityCandidates() async {
    try {
      final values = await _secureStorage.readAll();
      print(
        '[relay-auth identity] secure-storage readAll keys=${values.keys.toList()}',
      );
      for (final entry in values.entries) {
        if (entry.key == _meshIdentityKey) {
          continue;
        }
        final lowerKey = entry.key.toLowerCase();
        final keyLooksRelevant =
            lowerKey.contains('identity') ||
            lowerKey.contains('mesh') ||
            lowerKey.contains('ed25519') ||
            lowerKey.contains('peer') ||
            lowerKey.contains('key');
        if (!keyLooksRelevant) {
          continue;
        }
        _logIdentityBundleDiagnostics(
          key: entry.key,
          encoded: entry.value,
          primary: false,
        );
      }
    } catch (e) {
      print('[relay-auth identity] secure-storage readAll failed: $e');
    }
  }

  static void _logIdentityBundleDiagnostics({
    required String key,
    required String? encoded,
    required bool primary,
  }) {
    print(
      '[relay-auth identity] key=$key primary=$primary returnedNull=${encoded == null} stringLength=${encoded?.length ?? 0}',
    );
    if (encoded == null || encoded.isEmpty) {
      print('[relay-auth identity] key=$key jsonDecodeSucceeded=false');
      print('[relay-auth identity] key=$key validation=false');
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
      print('[relay-auth identity] key=$key jsonDecodeSucceeded=true');
    } catch (e) {
      print(
        '[relay-auth identity] key=$key jsonDecodeSucceeded=false error=$e',
      );
      print('[relay-auth identity] key=$key validation=false');
      return;
    }

    if (decoded is! Map<String, dynamic>) {
      print('[relay-auth identity] key=$key jsonObject=false');
      print('[relay-auth identity] key=$key validation=false');
      return;
    }

    final peerSnake = _stringValue(decoded['peer_id']);
    final peerCamel = _stringValue(decoded['peerId']);
    final pubkeySnake = _stringValue(decoded['pubkey']);
    final publicKeyCamel = _stringValue(decoded['publicKey']);
    final privateSnake = _stringValue(decoded['private_key']);
    final privateCamel = _stringValue(decoded['privateKey']);
    final publicKey = publicKeyCamel ?? pubkeySnake;
    final privateKey = privateCamel ?? privateSnake;
    final expectedFormatValid =
        peerCamel != null && publicKeyCamel != null && privateCamel != null;

    print(
      '[relay-auth identity] key=$key fields peer_id=${peerSnake != null} peerId=${peerCamel != null} pubkey=${pubkeySnake != null} publicKey=${publicKeyCamel != null} private_key=${privateSnake != null} privateKey=${privateCamel != null}',
    );
    print(
      '[relay-auth identity] key=$key lengths peer_id=${peerSnake?.length ?? 0} peerId=${peerCamel?.length ?? 0} publicKeyString=${publicKey?.length ?? 0} publicKeyDecoded=${_decodedLength(publicKey)} privateKeyString=${privateKey?.length ?? 0} privateKeyDecoded=${_decodedLength(privateKey)}',
    );
    print(
      '[relay-auth identity] key=$key validation=$expectedFormatValid expectedFormat=peerId/publicKey/privateKey',
    );
  }

  static int? _decodedLength(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    try {
      return base64Url.decode(_withBase64Padding(value)).length;
    } catch (_) {
      try {
        return base64Decode(value).length;
      } catch (_) {
        return null;
      }
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
