import 'dart:convert';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed25519;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unsync/services/identity_service.dart';

const _meshIdentityKey = 'mesh_identity_bundle';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('builds the relay auth canonical signing string byte-for-byte', () {
    const expected =
        'cloaknet-auth-v1|relay|mercury-peer|relay-nonce|1234567890';
    final actual = IdentityService.relayAuthSigningString(
      version: 'cloaknet-auth-v1',
      peerId: 'mercury-peer',
      nonce: 'relay-nonce',
      serverTime: 1234567890,
    );

    expect(actual, expected);
    expect(utf8.encode(actual), utf8.encode(expected));
    expect(actual.endsWith('\n'), isFalse);
  });

  test('builds the signaling auth canonical signing string byte-for-byte', () {
    const expected =
        'cloaknet-auth-v1|signaling|mercury-peer|signaling-nonce|1234567890';
    final actual = IdentityService.signalingAuthSigningString(
      peerId: 'mercury-peer',
      nonce: 'signaling-nonce',
      serverTime: 1234567890,
    );

    expect(actual, expected);
    expect(utf8.encode(actual), utf8.encode(expected));
    expect(actual.endsWith('\n'), isFalse);
  });

  test('creates a relay mesh identity when missing', () async {
    SharedPreferences.setMockInitialValues({'peer_id': 'mercury-peer'});

    final response = await IdentityService().signRelayAuthChallenge(
      version: 'cloaknet-auth-v1',
      nonce: 'relay-nonce',
      serverTime: 1234567890,
    );

    expect(response, isNotNull);
    expect(response!.peerId, 'mercury-peer');

    final stored = await const FlutterSecureStorage().read(
      key: _meshIdentityKey,
    );
    expect(stored, isNotNull);

    final identity = jsonDecode(stored!) as Map<String, dynamic>;
    expect(identity['peerId'], 'mercury-peer');
    expect(_decodedLength(identity['publicKey'] as String), 32);
    expect(_decodedLength(identity['privateKey'] as String), 64);
  });

  test('reuses an existing relay mesh identity', () async {
    final keyPair = ed25519.generateKey();
    final storedIdentity = jsonEncode({
      'peerId': 'stored-peer',
      'publicKey': _base64UrlNoPadding(keyPair.publicKey.bytes),
      'privateKey': base64Encode(keyPair.privateKey.bytes),
    });
    FlutterSecureStorage.setMockInitialValues({
      _meshIdentityKey: storedIdentity,
    });
    SharedPreferences.setMockInitialValues({'peer_id': 'different-peer'});

    final response = await IdentityService().signRelayAuthChallenge(
      version: 'cloaknet-auth-v1',
      nonce: 'relay-nonce',
      serverTime: 1234567890,
    );

    expect(response, isNotNull);
    expect(response!.peerId, 'stored-peer');
    expect(
      await const FlutterSecureStorage().read(key: _meshIdentityKey),
      storedIdentity,
    );
  });

  test('signs the relay auth canonical payload', () async {
    final keyPair = ed25519.generateKey();
    const peerId = 'mercury-peer';
    const nonce = 'relay-nonce';
    const serverTime = 1234567890;
    const version = 'cloaknet-auth-v1';

    FlutterSecureStorage.setMockInitialValues({
      _meshIdentityKey: jsonEncode({
        'peerId': peerId,
        'publicKey': _base64UrlNoPadding(keyPair.publicKey.bytes),
        'privateKey': base64Encode(keyPair.privateKey.bytes),
      }),
    });

    final response = await IdentityService().signRelayAuthChallenge(
      version: version,
      nonce: nonce,
      serverTime: serverTime,
    );

    expect(response, isNotNull);
    expect(response!.peerId, peerId);
    expect(response.publicKey, _base64UrlNoPadding(keyPair.publicKey.bytes));

    final payload = '$version|relay|$peerId|$nonce|$serverTime';
    expect(
      ed25519.verify(
        keyPair.publicKey,
        utf8.encode(payload),
        base64Url.decode(_withBase64Padding(response.signature)),
      ),
      isTrue,
    );
  });
}

String _base64UrlNoPadding(List<int> bytes) {
  return base64UrlEncode(bytes).replaceAll('=', '');
}

String _withBase64Padding(String value) {
  final remainder = value.length % 4;
  if (remainder == 0) {
    return value;
  }
  return value.padRight(value.length + 4 - remainder, '=');
}

int _decodedLength(String value) {
  return base64Url.decode(_withBase64Padding(value)).length;
}
