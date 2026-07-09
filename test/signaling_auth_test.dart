import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/services/identity_service.dart';
import 'package:unsync/services/signaling_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('signaling register waits until auth_ok', () async {
    final server = StreamController<String>();
    final sink = _RecordingWebSocketSink();
    final service = _signalingService(
      server: server,
      sink: sink,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');

    expect(sink.messages, isEmpty);

    server.add(
      jsonEncode({
        'type': 'auth_challenge',
        'nonce': 'nonce',
        'server_time': 1234567890,
      }),
    );
    await pumpEventQueue();

    expect(_messageTypes(sink.messages), ['auth_response']);

    server.add(jsonEncode({'type': 'auth_ok'}));
    await pumpEventQueue();

    expect(_messageTypes(sink.messages), ['auth_response', 'register']);
    expect(sink.messages.last, {
      'type': 'register',
      'id': 'mercury-peer',
      'fcmToken': 'fcm-token',
    });

    service.disconnect();
    await server.close();
  });

  test(
    'signaling sends legacy register after auth challenge timeout',
    () async {
      final server = StreamController<String>();
      final sink = _RecordingWebSocketSink();
      final service = _signalingService(server: server, sink: sink);

      await service.connect('mercury-peer', fcmToken: 'fcm-token');

      expect(sink.messages, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(_messageTypes(sink.messages), ['register']);
      expect(sink.messages.single, {
        'type': 'register',
        'id': 'mercury-peer',
        'fcmToken': 'fcm-token',
      });

      service.disconnect();
      await server.close();
    },
  );

  test(
    'signaling sends legacy register when auth identity is missing',
    () async {
      final server = StreamController<String>();
      final sink = _RecordingWebSocketSink();
      final service = _signalingService(
        server: server,
        sink: sink,
        identityResponse: null,
      );

      await service.connect('mercury-peer', fcmToken: 'fcm-token');

      server.add(
        jsonEncode({
          'type': 'auth_challenge',
          'nonce': 'nonce',
          'server_time': 1234567890,
        }),
      );
      await pumpEventQueue();

      expect(_messageTypes(sink.messages), ['register']);
      expect(sink.messages.single, {
        'type': 'register',
        'id': 'mercury-peer',
        'fcmToken': 'fcm-token',
      });

      service.disconnect();
      await server.close();
    },
  );

  test('signaling sends register only once per connection', () async {
    final server = StreamController<String>();
    final sink = _RecordingWebSocketSink();
    final service = _signalingService(
      server: server,
      sink: sink,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');

    server.add(
      jsonEncode({
        'type': 'auth_challenge',
        'nonce': 'nonce',
        'server_time': 1234567890,
      }),
    );
    await pumpEventQueue();

    server.add(jsonEncode({'type': 'auth_ok'}));
    server.add(jsonEncode({'type': 'auth_ok'}));
    await pumpEventQueue();

    expect(_messageTypes(sink.messages), ['auth_response', 'register']);
    expect(
      sink.messages.where((message) => message['type'] == 'register'),
      hasLength(1),
    );

    service.disconnect();
    await server.close();
  });

  test('signaling does not register after auth_error', () async {
    final server = StreamController<String>();
    final sink = _RecordingWebSocketSink();
    final service = _signalingService(
      server: server,
      sink: sink,
      identityResponse: const MeshAuthResponse(
        peerId: 'mercury-peer',
        publicKey: 'public-key',
        signature: 'signature',
      ),
    );

    await service.connect('mercury-peer', fcmToken: 'fcm-token');

    server.add(
      jsonEncode({
        'type': 'auth_challenge',
        'nonce': 'nonce',
        'server_time': 1234567890,
      }),
    );
    await pumpEventQueue();

    server.add(jsonEncode({'type': 'auth_error', 'reason': 'bad signature'}));
    server.add(jsonEncode({'type': 'auth_ok'}));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(_messageTypes(sink.messages), ['auth_response']);
    expect(
      sink.messages.where((message) => message['type'] == 'register'),
      isEmpty,
    );

    service.disconnect();
    await server.close();
  });
}

SignalingService _signalingService({
  required StreamController<String> server,
  required _RecordingWebSocketSink sink,
  MeshAuthResponse? identityResponse,
}) {
  return SignalingService(
    identityService: _FakeIdentityService(identityResponse),
    channelFactory: (_) => _FakeWebSocketChannel(server.stream, sink),
    authChallengeTimeout: const Duration(milliseconds: 20),
  );
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

class _FakeWebSocketChannel implements WebSocketChannel {
  _FakeWebSocketChannel(this.stream, this.sink);

  @override
  final Stream<String> stream;

  @override
  final _RecordingWebSocketSink sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingWebSocketSink implements WebSocketSink {
  final List<Map<String, dynamic>> messages = [];
  final Completer<void> _done = Completer<void>();

  @override
  void add(Object? event) {
    messages.add(jsonDecode(event! as String) as Map<String, dynamic>);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
