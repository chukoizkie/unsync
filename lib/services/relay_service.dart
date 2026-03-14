import 'dart:async';
import 'dart:convert';
import '../config.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class RelayService {
  static const String _relayUrl = UnsyncConfig.relayUrl;
  WebSocketChannel? _channel;
  String? _myId;
  bool _connected = false;
  bool _reconnecting = false;
  Timer? _pingTimer;
  Function(String from, String payload)? onQueuedMessage;
  final Map<String, Completer<Map<String, dynamic>?>> _bundleCompleters = {};

  Future<void> connect(String myId) async {
    if (_reconnecting) return;
    _reconnecting = true;
    _myId = myId;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_relayUrl));
      _channel!.stream.listen(
        (data) => _handleMessage(data),
        onDone: () {
          _connected = false;
          print('Relay disconnected');
          Future.delayed(const Duration(seconds: 10), () => connect(myId));
        },
        onError: (e) {
          _connected = false;
          print('Relay error: ' + e.toString());
          Future.delayed(const Duration(seconds: 10), () => connect(myId));
        },
        cancelOnError: false,
      );
      _send({'type': 'register', 'id': myId});
      _connected = true;
      _reconnecting = false;
      _startPing();
      print('Relay connected as ' + myId);
    } catch (e) {
      print('Relay connect failed: ' + e.toString());
      Future.delayed(const Duration(seconds: 10), () => connect(myId));
    }
  }

  void _handleMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String);
      final type = msg['type'] as String?;
      switch (type) {
        case 'registered':
          print('Relay registered: ' + msg['id'].toString());
          break;
        case 'queued':
          print('Relay: queued from ' + msg['from'].toString());
          onQueuedMessage?.call(msg['from'] as String, msg['payload'] as String);
          break;
        case 'stored':
          print('Relay: blob stored for ' + msg['to'].toString());
          break;
        case 'bundle_uploaded':
          print('Relay: bundle uploaded for ' + msg['id'].toString());
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
      print('Relay handle error: ' + e.toString());
    }
  }

  void uploadBundle(String peerId, Map<String, dynamic> bundle) {
    _send({'type': 'upload_bundle', 'id': peerId, 'bundle': bundle});
  }

  Future<Map<String, dynamic>?> fetchBundle(String peerId) async {
    if (!_connected) return null;
    final completer = Completer<Map<String, dynamic>?>();
    _bundleCompleters[peerId] = completer;
    _send({'type': 'get_bundle', 'id': peerId});
    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _bundleCompleters.remove(peerId);
      return null;
    });
  }

  void storeMessage(String to, String from, String encryptedPayload) {
    if (!_connected) {
      print('Relay: not connected, cannot store');
      return;
    }
    _send({'type': 'store', 'to': to, 'from': from, 'payload': encryptedPayload});
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
