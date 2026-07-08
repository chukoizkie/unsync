// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import '../config.dart';
import 'identity_service.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class RelayService {
  static const String _relayUrl = UnsyncConfig.relayUrl;
  WebSocketChannel? _channel;
  bool _connected = false;
  bool _reconnecting = false;
  Timer? _pingTimer;
  Function(String from, String payload)? onQueuedMessage;
  final Map<String, Completer<Map<String, dynamic>?>> _bundleCompleters = {};
  final IdentityService _identityService;

  RelayService({IdentityService? identityService})
    : _identityService = identityService ?? IdentityService();

  Future<void> connect(String myId, {String? fcmToken}) async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      _channel = IOWebSocketChannel.connect(Uri.parse(_relayUrl));
      _channel!.stream.listen(
        (data) => _handleMessage(data),
        onDone: () {
          _connected = false;
          print('Relay disconnected');
          Future.delayed(
            const Duration(seconds: 10),
            () => connect(myId, fcmToken: fcmToken),
          );
        },
        onError: (e) {
          _connected = false;
          print('Relay error: $e');
          Future.delayed(
            const Duration(seconds: 10),
            () => connect(myId, fcmToken: fcmToken),
          );
        },
        cancelOnError: false,
      );
      _send({'type': 'register', 'id': myId, 'fcmToken': fcmToken});
      _connected = true;
      _reconnecting = false;
      _startPing();
      print('Relay connected as $myId');
    } catch (e) {
      print('Relay connect failed: $e');
      Future.delayed(
        const Duration(seconds: 10),
        () => connect(myId, fcmToken: fcmToken),
      );
    }
  }

  Future<void> _handleMessage(dynamic data) async {
    try {
      final msg = jsonDecode(data as String);
      final type = msg['type'] as String?;
      switch (type) {
        case 'auth_challenge':
          await _handleAuthChallenge(msg);
          break;
        case 'auth_ok':
          print('Relay auth ok');
          break;
        case 'auth_failed':
          print('Relay auth failed: ${msg['reason'] ?? 'unknown'}');
          break;
        case 'registered':
          print('Relay registered: ${msg['id']}');
          break;
        case 'queued':
          print('Relay: queued from ${msg['from']}');
          onQueuedMessage?.call(
            msg['from'] as String,
            msg['payload'] as String,
          );
          break;
        case 'stored':
          print('Relay: blob stored for ${msg['to']}');
          break;
        case 'bundle_uploaded':
          print('Relay: bundle uploaded for ${msg['id']}');
          break;
        case 'bundle':
          final id = msg['id'] as String;
          final completer = _bundleCompleters.remove(id);
          completer?.complete(msg['bundle'] as Map<String, dynamic>?);
          break;
        case 'bundle_not_found':
          final id = msg['id'] as String;
          final completer = _bundleCompleters.remove(id);
          completer?.complete(null);
          break;
      }
    } catch (e) {
      print('Relay handle error: $e');
    }
  }

  Future<void> _handleAuthChallenge(Map<String, dynamic> msg) async {
    final version = msg['version'];
    final nonce = msg['nonce'];
    final serverTime = msg['server_time'];
    if (version is! String ||
        nonce is! String ||
        (serverTime is! int && serverTime is! String)) {
      print('Relay auth challenge invalid; continuing legacy mode');
      return;
    }

    final response = await _identityService.signRelayAuthChallenge(
      version: version,
      nonce: nonce,
      serverTime: serverTime,
    );
    if (response == null) {
      print('Relay auth identity missing; continuing legacy mode');
      return;
    }

    _send({
      'type': 'auth_response',
      'peer_id': response.peerId,
      'pubkey': response.publicKey,
      'signature': response.signature,
    });
  }

  void uploadBundle(String peerId, Map<String, dynamic> bundle) {
    _send({'type': 'upload_bundle', 'id': peerId, 'bundle': bundle});
  }

  Future<Map<String, dynamic>?> fetchBundle(String peerId) async {
    if (!_connected) return null;
    final completer = Completer<Map<String, dynamic>?>();
    _bundleCompleters[peerId] = completer;
    _send({'type': 'get_bundle', 'id': peerId});
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _bundleCompleters.remove(peerId);
        return null;
      },
    );
  }

  Future<Map<String, dynamic>?> getBundle(String peerId) => fetchBundle(peerId);

  void storeMessage(String to, String from, String encryptedPayload) {
    if (!_connected) {
      print('Relay: not connected, cannot store');
      return;
    }
    _send({
      'type': 'store',
      'to': to,
      'from': from,
      'payload': encryptedPayload,
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_connected) _send({'type': 'ping'});
    });
  }

  void _send(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  bool get isConnected => _connected;

  void dispose() {
    _pingTimer?.cancel();
    _channel?.sink.close();
  }
}
