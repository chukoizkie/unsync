import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/services/identity_service.dart';

/// The wake request is verified by the signaling server, which rebuilds the
/// signed string itself. Any disagreement about format is invisible here and
/// shows up as a silent 403 in production, so the contract is pinned exactly.
///
/// Server (unsync-signaling/server.js):
///   const WAKE_AUTH_VERSION = 'cloaknet-wake-v1';
///   const WAKE_AUTH_CONTEXT = 'message_wake';
///   function wakeAuthPayload({ fromId, peerId, timestamp, requestId }) {
///     return JSON.stringify([WAKE_AUTH_VERSION, WAKE_AUTH_CONTEXT,
///                            fromId, peerId, timestamp, requestId]);
///   }
void main() {
  test('signing string matches the server canonical form exactly', () {
    final payload = IdentityService.wakeSigningString(
      fromId: 'alice',
      peerId: 'bob',
      timestamp: 1784550000000,
      requestId: 'req-abcdefgh',
    );

    expect(
      payload,
      '["cloaknet-wake-v1","message_wake","alice","bob",1784550000000,'
      '"req-abcdefgh"]',
    );
  });

  test('signing string is a JSON array, not a delimited string', () {
    // The auth challenges use pipe-delimited strings; this one does not.
    // Copying that shape here would fail verification on every wake.
    final decoded = jsonDecode(
      IdentityService.wakeSigningString(
        fromId: 'a',
        peerId: 'b',
        timestamp: 1,
        requestId: 'req-12345678',
      ),
    );

    expect(decoded, isA<List<dynamic>>());
    expect((decoded as List).length, 6);
    expect(decoded[4], isA<int>(), reason: 'timestamp must stay numeric');
  });

  test('field order is part of the contract', () {
    final decoded =
        jsonDecode(
              IdentityService.wakeSigningString(
                fromId: 'sender',
                peerId: 'target',
                timestamp: 7,
                requestId: 'req-87654321',
              ),
            )
            as List<dynamic>;

    // fromId precedes peerId. Swapping them still produces valid JSON and a
    // valid signature — of the wrong statement.
    expect(decoded[2], 'sender');
    expect(decoded[3], 'target');
  });

  group('identity id normalization matches the server', () {
    // Server: String(peerId || '').trim().replace(/^@+/, '').toLowerCase()
    // The canonical payload is built from the *normalized* binding id, so the
    // client has to normalize identically before signing.
    for (final testCase in const [
      ('  Alice  ', 'alice'),
      ('@Bob', 'bob'),
      ('@@carol', 'carol'),
      ('1783827592539', '1783827592539'),
      ('MiXeD@Case', 'mixed@case'),
      ('', ''),
    ]) {
      test('"${testCase.$1}" normalizes to "${testCase.$2}"', () {
        expect(
          IdentityService.normalizeSignalingIdentityId(testCase.$1),
          testCase.$2,
        );
      });
    }

    test('null normalizes to empty rather than throwing', () {
      expect(IdentityService.normalizeSignalingIdentityId(null), '');
    });

    test('only leading @ is stripped', () {
      expect(
        IdentityService.normalizeSignalingIdentityId('a@b'),
        'a@b',
      );
    });
  });
}
