import 'dart:async';
import 'dart:convert';
import '../config.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'webrtc_service.dart';

class SignalingService {
  static const String signalingUrl = UnsyncConfig.signalingUrl;
  static const int _idleTimeoutSeconds = 120;

  WebSocketChannel? _channel;

  final Map<String, WebRTCService> _peers = {};
  final Map<String, Timer> _idleTimers = {};
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};

  Function(String peerId, String message)? onMessageReceived;
  Function(bool connected)? onConnectionStateChanged;
  Function(String peerId)? onPeerConnected;
  Function(String peerId)? onPeerOffline;
  Function(String peerId)? onIncomingCall;
  Function()? onCallAnswered;
  Function()? onCallEnded;
  Function(dynamic stream)? onRemoteStream;

  String? _myId;
  String? get myId => _myId;
  String? _fcmToken;

  // DHT identity — set before connecting
  String? _myHandle;

  String? _callPeerId;
  RTCSessionDescription? _pendingCallOffer;

  Timer? _pingTimer;
  Timer? _reconnectTimer;

  Future<void> connect(String myId, {String? fcmToken, String? handle}) async {
    _fcmToken = fcmToken;
    _myId     = myId;
    _myHandle = handle;

    _channel = IOWebSocketChannel.connect(Uri.parse(signalingUrl));
    _channel!.stream.listen((data) {
      final msg = jsonDecode(data as String);
      _handleMessage(msg);
    }, onError: (e) {
      print('Signaling error: $e');
      onConnectionStateChanged?.call(false);
    }, onDone: () {
      print('Signaling disconnected');
      onConnectionStateChanged?.call(false);
    });

    _send({'type': 'register', 'id': myId, 'fcmToken': _fcmToken});
  }

  void _handleMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'registered':
        print('Registered as: ${msg['id']}');
        onConnectionStateChanged?.call(true);
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          _send({'type': 'ping'});
        });
        break;

      case 'knock':
        print('Knock from: ${msg['from']}');
        break;

      case 'offer':
        final fromId = msg['from'] as String;
        final webrtc = await _getOrCreatePeer(fromId, isInitiator: false);
        final answer = await webrtc.createAnswer(
          RTCSessionDescription(msg['sdp']['sdp'], msg['sdp']['type']),
        );
        _send({'type': 'answer', 'to': fromId, 'sdp': answer.toMap()});
        onPeerConnected?.call(fromId);
        break;

      case 'answer':
        final fromId = msg['from'] as String;
        final webrtc = _peers[fromId];
        if (webrtc != null) {
          await webrtc.setRemoteDescription(
            RTCSessionDescription(msg['sdp']['sdp'], msg['sdp']['type']),
          );
          final pending = _pendingIce.remove(fromId) ?? [];
          for (final c in pending) await webrtc.addIceCandidate(c);
        }
        break;

      case 'ice':
        final fromId = msg['from'] as String;
        final candidate = RTCIceCandidate(
          msg['candidate']['candidate'],
          msg['candidate']['sdpMid'],
          msg['candidate']['sdpMLineIndex'],
        );
        final webrtc = _peers[fromId];
        if (webrtc != null) {
          await webrtc.addIceCandidate(candidate);
        } else {
          _pendingIce.putIfAbsent(fromId, () => []).add(candidate);
        }
        break;

      case 'peer_offline':
        final id = msg['id'] as String;
        print('Peer offline: $id');
        _closePeer(id);
        onPeerOffline?.call(id);
        break;

      case 'call_offer':
        final fromId = msg['from'] as String;
        _callPeerId = fromId;
        _pendingCallOffer = RTCSessionDescription(msg['sdp']['sdp'], msg['sdp']['type']);
        onIncomingCall?.call(fromId);
        break;

      case 'call_declined':
        _callPeerId = null;
        _pendingCallOffer = null;
        onCallEnded?.call();
        break;

      case 'call_answer':
        final fromId = msg['from'] as String;
        final webrtc = _peers[fromId];
        if (webrtc != null) {
          await webrtc.setRemoteDescription(
            RTCSessionDescription(msg['sdp']['sdp'], msg['sdp']['type']),
          );
        }
        onCallAnswered?.call();
        break;

      case 'call_end':
        final fromId = msg['from'] as String;
        _peers[fromId]?.stopAudio();
        _callPeerId = null;
        onCallEnded?.call();
        break;
    }
  }

  Future<WebRTCService> _getOrCreatePeer(String peerId,
      {bool isInitiator = true}) async {
    if (_peers.containsKey(peerId)) {
      _resetIdleTimer(peerId);
      return _peers[peerId]!;
    }

    final webrtc = WebRTCService();

    // ── DHT: inject our identity so peer can resolve our handle ──
    webrtc.ownHandle = _myHandle;
    webrtc.ownPeerId = _myId;
    webrtc.onDhtMessage = (msg) {
      // Handle dht_find — peer is looking for a handle
      if (msg['type'] == 'dht_find') {
        webrtc.handleDhtFind(msg);
      }
      // dht_announce / dht_found — just let browser handle via data channel
    };
    // ─────────────────────────────────────────────────────────────

    await webrtc.initialize();
    _peers[peerId] = webrtc;

    webrtc.onMessageReceived = (msg) {
      _resetIdleTimer(peerId);
      onMessageReceived?.call(peerId, msg);
    };

    webrtc.onConnectionStateChanged = (connected) {
      if (connected) {
        onPeerConnected?.call(peerId);
        _resetIdleTimer(peerId);
      }
    };

    webrtc.onRemoteStream = (stream) {
      onRemoteStream?.call(stream);
    };

    webrtc.onIceCandidate((candidate) {
      _send({'type': 'ice', 'to': peerId, 'candidate': candidate.toMap()});
    });

    if (isInitiator) {
      _send({'type': 'knock', 'to': peerId});
      final offer = await webrtc.createOffer();
      _send({'type': 'offer', 'to': peerId, 'sdp': offer.toMap()});
    }

    _resetIdleTimer(peerId);
    return webrtc;
  }

  void _resetIdleTimer(String peerId) {
    if (peerId == _callPeerId) return;
    _idleTimers[peerId]?.cancel();
    _idleTimers[peerId] = Timer(
      const Duration(seconds: _idleTimeoutSeconds),
      () => _closePeer(peerId),
    );
  }

  void _closePeer(String peerId) {
    _idleTimers.remove(peerId)?.cancel();
    _pendingIce.remove(peerId);
    _peers.remove(peerId)?.dispose();
    print('P2P connection closed: $peerId');
  }

  Future<void> sendMessage(String peerId, String message) async {
    final webrtc = await _getOrCreatePeer(peerId);
    for (int i = 0; i < 50; i++) {
      if (webrtc.isDataChannelOpen) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    webrtc.sendMessage(message);
    _resetIdleTimer(peerId);
  }

  Future<void> startVoiceCall(String peerId, {String? callerName}) async {
    _callPeerId = peerId;
    _idleTimers[peerId]?.cancel();
    final webrtc = await _getOrCreatePeer(peerId);
    await webrtc.addAudioTrack();
    final offer = await webrtc.createOffer(withAudio: true);
    _send({'type': 'call_offer', 'to': peerId, 'sdp': offer.toMap(), 'callerName': callerName ?? _myId ?? ''});
  }

  void setMicMuted(bool muted) {
    if (_callPeerId != null) {
      _peers[_callPeerId]?.setMicMuted(muted);
    }
  }

  Future<void> acceptCall() async {
    if (_callPeerId == null || _pendingCallOffer == null) return;
    final webrtc = await _getOrCreatePeer(_callPeerId!, isInitiator: false);
    await webrtc.addAudioTrack();
    final answer = await webrtc.createAnswer(_pendingCallOffer!, withAudio: true);
    _send({'type': 'call_answer', 'to': _callPeerId, 'sdp': answer.toMap()});
    _pendingCallOffer = null;
  }

  void declineCall() {
    if (_callPeerId == null) return;
    _send({'type': 'call_declined', 'to': _callPeerId});
    _callPeerId = null;
    _pendingCallOffer = null;
  }

  void endVoiceCall() {
    if (_callPeerId != null) {
      _send({'type': 'call_end', 'to': _callPeerId});
      _peers[_callPeerId]?.stopAudio();
      _resetIdleTimer(_callPeerId!);
      _callPeerId = null;
    }
    onCallEnded?.call();
  }

  bool isPeerConnected(String peerId) =>
      _peers[peerId]?.isDataChannelOpen ?? false;

  void disconnect() {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    for (final p in _peers.values) p.dispose();
    _peers.clear();
    _idleTimers.values.forEach((t) => t.cancel());
    _idleTimers.clear();
    _channel?.sink.close();
    _myId = null;
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void dispose() => disconnect();
}
