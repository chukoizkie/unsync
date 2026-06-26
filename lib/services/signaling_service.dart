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
  String? _activeCallId;

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
      _scheduleReconnect();
    }, onDone: () {
      print('Signaling disconnected');
      onConnectionStateChanged?.call(false);
      _scheduleReconnect();
    });

    _send({'type': 'register', 'id': myId, 'fcmToken': _fcmToken});
  }

  int _reconnectAttempt = 0;
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_myId == null) return;
    final delays = [1, 2, 5, 10, 30, 60];
    final delaySecs = delays[_reconnectAttempt.clamp(0, delays.length - 1)];
    _reconnectAttempt++;
    print('Signaling reconnect in ${delaySecs}s (attempt $_reconnectAttempt)');
    _reconnectTimer = Timer(Duration(seconds: delaySecs), () async {
      if (_myId != null) {
        print('Signaling reconnecting...');
        await connect(_myId!, fcmToken: _fcmToken, handle: _myHandle);
      }
    });
  }

  void _handleMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'registered':
        print('Registered as: ${msg['id']}');
        _reconnectAttempt = 0;
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
        }
        break;

      case 'ice':
        final fromId = msg['from'] as String;
        final candidate = RTCIceCandidate(
          msg['candidate']['candidate'],
          msg['candidate']['sdpMid'],
          msg['candidate']['sdpMLineIndex'],
        );
        final webrtc = await _getOrCreatePeer(fromId, isInitiator: false);
        await webrtc.addIceCandidate(candidate);
        break;

      case 'peer_offline':
        final id = msg['id'] as String;
        print('Peer offline: $id');
        await _closePeer(id);
        onPeerOffline?.call(id);
        break;

      case 'call_offer':
        final fromId = msg['from'] as String;
        final callId = msg['callId'] as String?;
        print('[CALL] offer received from $fromId callId=$callId');
        final offer = RTCSessionDescription(
          msg['sdp']['sdp'],
          msg['sdp']['type'],
        );
        _activeCallId = callId;
        _callPeerId = fromId;
        _pendingCallOffer = offer;
        onIncomingCall?.call(fromId);
        break;

      case 'call_declined': {
        final callId = msg['callId'] as String?;
        if (callId != null && _activeCallId != null && callId != _activeCallId) {
          print('[CALL] ignoring stale call event callId=$callId active=$_activeCallId');
          break;
        }
        _callPeerId = null;
        _pendingCallOffer = null;
        _activeCallId = null;
        onCallEnded?.call();
        break;
      }

      case 'call_answer': {
        final fromId = msg['from'] as String;
        final callId = msg['callId'] as String?;
        if (callId != null && callId != _activeCallId) {
          print('[CALL] ignoring stale call event callId=$callId active=$_activeCallId');
          break;
        }
        print('[CALL] answer received from $fromId callId=$callId');
        final webrtc = _peers[fromId];
        if (webrtc != null) {
          await webrtc.setRemoteDescription(
            RTCSessionDescription(msg['sdp']['sdp'], msg['sdp']['type']),
          );
        }
        onCallAnswered?.call();
        break;
      }

      case 'call_end': {
        final fromId = msg['from'] as String;
        final callId = msg['callId'] as String?;
        if (callId != null && _activeCallId != null && callId != _activeCallId) {
          print('[CALL] ignoring stale call event callId=$callId active=$_activeCallId');
          break;
        }
        print('[CALL] call ended by $fromId callId=$callId');
        await _closePeer(fromId);
        _callPeerId = null;
        _activeCallId = null;
        onCallEnded?.call();
        break;
      }

      case 'error':
        print('Signaling error from server: ${msg['message']}');
        if (_callPeerId != null) {
          await _closePeer(_callPeerId!);
          _callPeerId = null;
          _pendingCallOffer = null;
          _activeCallId = null;
          onCallEnded?.call();
        }
        break;
    }
  }

  Future<WebRTCService> _getOrCreatePeer(String peerId,
      {bool isInitiator = true, bool sendInitialOffer = true}) async {
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

    if (isInitiator && sendInitialOffer) {
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

  Future<void> _closePeer(String peerId) async {
    _idleTimers.remove(peerId)?.cancel();
    final peer = _peers.remove(peerId);
    if (peer != null) await peer.dispose();
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
    print('[CALL] startVoiceCall peer=$peerId');
    final now = DateTime.now().millisecondsSinceEpoch;
    final callId = '${_myId}_${peerId}_$now';
    print('[CALL] created callId=$callId');
    _callPeerId = peerId;
    _activeCallId = callId;
    _idleTimers[peerId]?.cancel();
    try {
      if (_peers.containsKey(peerId)) {
        await _closePeer(peerId);
      }
      final webrtc = await _getOrCreatePeer(peerId, sendInitialOffer: false);
      await webrtc.ensureDataChannel();
      if (!webrtc.isAudioActive) {
        await webrtc.addAudioTrack();
      }
      print('[CALL] local audio added');
      final offer = await webrtc.createOffer();
      print('[CALL] sending offer callId=$callId');
      _send({
        'type': 'call_offer',
        'to': peerId,
        'sdp': offer.toMap(),
        'callerName': callerName ?? _myId ?? '',
        'callId': callId,
      });
    } catch (e) {
      print('Voice call setup failed for $peerId: $e');
      _send({'type': 'call_declined', 'to': peerId, 'callId': _activeCallId});
      await _closePeer(peerId);
      if (_callPeerId == peerId) _callPeerId = null;
      _activeCallId = null;
      onCallEnded?.call();
    }
  }

  void setMicMuted(bool muted) {
    if (_callPeerId != null) {
      _peers[_callPeerId]?.setMicMuted(muted);
    }
  }

  Future<void> acceptCall() async {
    if (_callPeerId == null || _pendingCallOffer == null) return;
    final peerId = _callPeerId!;
    print('[CALL] acceptCall peer=$peerId');
    try {
      if (_peers.containsKey(peerId)) {
        await _closePeer(peerId);
      }
      final webrtc = await _getOrCreatePeer(peerId, isInitiator: false);
      final answer = await webrtc.createAnswer(_pendingCallOffer!, withAudio: true);
      print('[CALL] sending answer to $peerId callId=$_activeCallId');
      _send({'type': 'call_answer', 'to': peerId, 'sdp': answer.toMap(), 'callId': _activeCallId});
      _pendingCallOffer = null;
    } catch (e) {
      print('Accept call failed for $peerId: $e');
      _send({'type': 'call_declined', 'to': peerId, 'callId': _activeCallId});
      await _closePeer(peerId);
      if (_callPeerId == peerId) _callPeerId = null;
      _pendingCallOffer = null;
      _activeCallId = null;
      onCallEnded?.call();
    }
  }

  void declineCall() {
    if (_callPeerId == null) return;
    _send({'type': 'call_declined', 'to': _callPeerId, 'callId': _activeCallId});
    _callPeerId = null;
    _pendingCallOffer = null;
    _activeCallId = null;
  }

  void endVoiceCall() {
    if (_callPeerId != null) {
      _send({'type': 'call_end', 'to': _callPeerId, 'callId': _activeCallId});
      _closePeer(_callPeerId!);
      _callPeerId = null;
      _activeCallId = null;
    }
    onCallEnded?.call();
  }

  bool isPeerConnected(String peerId) =>
      _peers[peerId]?.isDataChannelOpen ?? false;

  void disconnect() {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    for (final p in _peers.values) {
      p.dispose();
    }
    _peers.clear();
    for (var t in _idleTimers.values) {
      t.cancel();
    }
    _idleTimers.clear();
    _channel?.sink.close();
    _myId = null;
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void dispose() => disconnect();
}
