import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/services/identity_service.dart';
import 'package:unsync/services/signaling_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('signaling register waits until auth_ok', () async {
    final harness = _SocketHarness();
    final service = _signalingService(
      harness: harness,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');
    final channel = harness.single;

    expect(channel.sink.messages, isEmpty);

    channel.sendServer({
      'type': 'auth_challenge',
      'nonce': 'nonce',
      'server_time': 1234567890,
    });
    await pumpEventQueue();

    expect(_messageTypes(channel.sink.messages), ['auth_response']);

    channel.sendServer({'type': 'auth_ok'});
    await pumpEventQueue();

    expect(_messageTypes(channel.sink.messages), ['auth_response', 'register']);
    expect(channel.sink.messages.last, {
      'type': 'register',
      'id': 'mercury-peer',
      'fcmToken': 'fcm-token',
    });

    service.disconnect();
    await harness.close();
  });

  test(
    'auth challenge timeout closes and reconnects without legacy register',
    () async {
      final harness = _SocketHarness();
      final service = _signalingService(harness: harness);

      await service.connect('mercury-peer', fcmToken: 'fcm-token');
      final first = harness.single;

      await _waitForReconnect(harness);

      expect(first.sink.messages, isEmpty);
      expect(first.sink.closed, isTrue);

      service.disconnect();
      await harness.close();
    },
  );

  test(
    'missing auth identity closes and reconnects without legacy register',
    () async {
      final harness = _SocketHarness();
      final service = _signalingService(
        harness: harness,
        identityResponse: null,
      );

      await service.connect('mercury-peer', fcmToken: 'fcm-token');
      final first = harness.single;

      first.sendServer({
        'type': 'auth_challenge',
        'nonce': 'nonce',
        'server_time': 1234567890,
      });
      await _waitForReconnect(harness);

      expect(_messageTypes(first.sink.messages), isEmpty);
      expect(first.sink.closed, isTrue);

      service.disconnect();
      await harness.close();
    },
  );

  test('register_error closes and reconnects', () async {
    final harness = _SocketHarness();
    final service = _signalingService(
      harness: harness,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');
    final first = harness.single;
    await _authenticate(first);

    first.sendServer({
      'type': 'register_error',
      'code': 'AUTH_REQUIRED_FOR_FCM',
    });
    await _waitForReconnect(harness);

    expect(first.sink.closed, isTrue);
    expect(service.isConnected, isFalse);

    service.disconnect();
    await harness.close();
  });

  test('auth_error closes and reconnects', () async {
    final harness = _SocketHarness();
    final service = _signalingService(
      harness: harness,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');
    final first = harness.single;

    first.sendServer({
      'type': 'auth_challenge',
      'nonce': 'nonce',
      'server_time': 1234567890,
    });
    await pumpEventQueue();
    first.sendServer({'type': 'auth_error', 'reason': 'bad_signature'});
    await _waitForReconnect(harness);

    expect(_messageTypes(first.sink.messages), ['auth_response']);
    expect(first.sink.closed, isTrue);

    service.disconnect();
    await harness.close();
  });

  test('auth_failed closes and reconnects', () async {
    final harness = _SocketHarness();
    final service = _signalingService(
      harness: harness,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');
    final first = harness.single;

    first.sendServer({
      'type': 'auth_challenge',
      'nonce': 'nonce',
      'server_time': 1234567890,
    });
    await pumpEventQueue();
    first.sendServer({'type': 'auth_failed', 'reason': 'bad_signature'});
    await _waitForReconnect(harness);

    expect(_messageTypes(first.sink.messages), ['auth_response']);
    expect(first.sink.closed, isTrue);

    service.disconnect();
    await harness.close();
  });

  test('stale registered event cannot revive a reset socket', () async {
    final harness = _SocketHarness();
    final service = _signalingService(
      harness: harness,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');
    final first = harness.single;
    await _authenticate(first);
    first.sendServer({
      'type': 'register_error',
      'code': 'AUTH_REQUIRED_FOR_FCM',
    });
    await pumpEventQueue();
    first.sendServer({'type': 'registered', 'id': 'mercury-peer'});
    await pumpEventQueue();

    expect(service.isConnected, isFalse);
    await _waitForReconnect(harness);

    service.disconnect();
    await harness.close();
  });

  test('FCM token update is sent after authenticated registration', () async {
    final harness = _SocketHarness();
    final service = _signalingService(
      harness: harness,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer');
    final channel = harness.single;
    await _authenticate(channel);
    channel.sendServer({'type': 'registered', 'id': 'mercury-peer'});
    await pumpEventQueue();

    service.updateFcmToken('fresh-fcm-token');
    await pumpEventQueue();

    expect(
      channel.sink.messages.where((message) => message['type'] == 'register'),
      [
        {'type': 'register', 'id': 'mercury-peer', 'fcmToken': null},
        {
          'type': 'register',
          'id': 'mercury-peer',
          'fcmToken': 'fresh-fcm-token',
        },
      ],
    );

    service.disconnect();
    await harness.close();
  });
}

SignalingService _signalingService({
  required _SocketHarness harness,
  MeshAuthResponse? identityResponse,
}) {
  return SignalingService(
    identityService: _FakeIdentityService(identityResponse),
    channelFactory: harness.connect,
    authChallengeTimeout: const Duration(milliseconds: 20),
    reconnectDelays: const [Duration(milliseconds: 1)],
  );
}

Future<void> _authenticate(_FakeWebSocketChannel channel) async {
  channel.sendServer({
    'type': 'auth_challenge',
    'nonce': 'nonce',
    'server_time': 1234567890,
  });
  await pumpEventQueue();
  channel.sendServer({'type': 'auth_ok'});
  await pumpEventQueue();
}

Future<void> _waitForReconnect(_SocketHarness harness) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (harness.channels.length > 1) return;
  }
  fail('expected reconnect');
}

List<String?> _messageTypes(List<Map<String, dynamic>> messages) {
  return messages.map((message) => message['type'] as String?).toList();
}

class _FakeIdentityService extends IdentityService {
  _FakeIdentityService(this.response);

  final MeshAuthResponse? response;

  @override
  Future<MeshAuthResponse?> signSignalingAuthChallenge({
    required String nonce,
    required Object serverTime,
  }) async {
    return response;
  }
}

class _SocketHarness {
  final List<_FakeWebSocketChannel> channels = [];

  _FakeWebSocketChannel get single => channels.single;

  WebSocketChannel connect(Uri uri) {
    final channel = _FakeWebSocketChannel();
    channels.add(channel);
    return channel;
  }

  Future<void> close() async {
    for (final channel in channels) {
      await channel.closeServer();
    }
  }
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<String> _server = StreamController<String>();

  @override
  late final Stream<String> stream = _server.stream;

  @override
  final _RecordingWebSocketSink sink = _RecordingWebSocketSink();

  @override
  Future<void> get ready => Future<void>.value();

  void sendServer(Map<String, dynamic> message) {
    if (!_server.isClosed) {
      _server.add(jsonEncode(message));
    }
  }

  Future<void> closeServer() => _server.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingWebSocketSink implements WebSocketSink {
  final List<Map<String, dynamic>> messages = [];
  final Completer<void> _done = Completer<void>();
  bool closed = false;

  @override
  void add(Object? event) {
    messages.add(jsonDecode(event! as String) as Map<String, dynamic>);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
