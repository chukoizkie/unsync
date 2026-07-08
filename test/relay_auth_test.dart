import 'dart:convert';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed25519;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/services/identity_service.dart';

const _meshIdentityKey = 'mesh_identity_bundle';
const _ed25519SpkiPrefix = [
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

void main() {
  test('signs relay auth challenges with the stored mesh identity', () async {
    final keyPair = ed25519.generateKey();
    const peerId = 'mercury-peer';
    const nonce = 'relay-nonce';
    const serverTime = 1234567890;
    const version = 'cloaknet-auth-v1';
    final publicKey = _base64UrlNoPadding(keyPair.publicKey.bytes);
    final privateKey = base64Encode(keyPair.privateKey.bytes);

    FlutterSecureStorage.setMockInitialValues({
      _meshIdentityKey: jsonEncode({
        'peerId': peerId,
        'publicKey': publicKey,
        'privateKey': privateKey,
      }),
    });

    final response = await IdentityService().signRelayAuthChallenge(
      version: version,
      nonce: nonce,
      serverTime: serverTime,
    );

    expect(response, isNotNull);
    expect(response!.peerId, peerId);
    expect(
      response.publicKey,
      _base64UrlNoPadding([..._ed25519SpkiPrefix, ...keyPair.publicKey.bytes]),
    );

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
