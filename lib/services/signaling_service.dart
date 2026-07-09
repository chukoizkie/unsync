import 'dart:async';
import 'dart:convert';
import '../config.dart';
import '../models/call_session.dart';
import 'identity_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'webrtc_service.dart';

typedef SignalingChannelFactory = WebSocketChannel Function(Uri uri);

class SignalingService {
  static const String signalingUrl = UnsyncConfig.signalingUrl;
  static const int _idleTimeoutSeconds = 120;

  WebSocketChannel? _channel;
  final IdentityService _identityService;
  final SignalingChannelFactory _channelFactory;
  final Duration _authChallengeTimeout;

  final Map<String, WebRTCService> _peers = {};
  final Map<String, Timer> _idleTimers = {};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};
  final Map<String, List<RTCIceCandidate>> _pendingCallIceCandidates = {};

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

  // DHT identity - set before connecting
  String? _myHandle;

  CallSession? _activeCall;
  bool _registered = false;
  bool _registerSent = false;
  bool _authErrorReceived = false;
  int _connectionGeneration = 0;

  bool get isConnected => _registered;
  String? get activeCallId => _activeCall?.callId;

  bool hasPendingIncomingCallFrom(String peerId) {
    final session = _activeCall;
    return session != null &&
        session.peerId == peerId &&
        session.isIncoming &&
        session.hasPendingOffer;
  }

  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _authChallengeTimer;
  Future<void>? _activeCallCleanup;

  SignalingService({
    IdentityService? identityService,
    SignalingChannelFactory? channelFactory,
    Duration authChallengeTimeout = const Duration(seconds: 2),
  }) : _identityService = identityService ?? IdentityService(),
       _channelFactory = channelFactory ?? IOWebSocketChannel.connect,
       _authChallengeTimeout = authChallengeTimeout;

  Future<void> connect(String myId, {String? fcmToken, String? handle}) async {
    _fcmToken = fcmToken;
    _myId = myId;
    _myHandle = handle;
    _registerSent = false;
    _authErrorReceived = false;
    final connectionGeneration = ++_connectionGeneration;

    _authChallengeTimer?.cancel();
    _channel = _channelFactory(Uri.parse(signalingUrl));
    _channel!.stream.listen(
      (data) {
        if (connectionGeneration != _connectionGeneration) return;
        final msg = jsonDecode(data as String);
        _handleMessage(msg, connectionGeneration);
      },
      onError: (e) {
        if (connectionGeneration != _connectionGeneration) return;
        _authChallengeTimer?.cancel();
        print('Signaling error: $e');
        _registered = false;
        onConnectionStateChanged?.call(false);
        _scheduleReconnect();
      },
      onDone: () {
        if (connectionGeneration != _connectionGeneration) return;
        _authChallengeTimer?.cancel();
        print('Signaling disconnected');
        _registered = false;
        onConnectionStateChanged?.call(false);
        _scheduleReconnect();
      },
    );

    _startAuthChallengeTimeout(connectionGeneration);
  }

  void _startAuthChallengeTimeout(int connectionGeneration) {
    _authChallengeTimer?.cancel();
    _authChallengeTimer = Timer(_authChallengeTimeout, () {
      if (connectionGeneration != _connectionGeneration || _registerSent) {
        return;
      }
      print('Signaling auth challenge timeout; continuing legacy mode');
      _sendRegister(connectionGeneration);
    });
  }

  void _sendRegister(int connectionGeneration) {
    if (connectionGeneration != _connectionGeneration || _registerSent) {
      return;
    }
    final myId = _myId;
    if (myId == null) return;
    _registerSent = true;
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

  void _handleMessage(
    Map<String, dynamic> msg,
    int connectionGeneration,
  ) async {
    switch (msg['type']) {
      case 'auth_challenge':
        await _handleAuthChallenge(msg, connectionGeneration);
        break;

      case 'auth_ok':
        _authChallengeTimer?.cancel();
        print('Signaling auth_ok');
        if (!_authErrorReceived) {
          _sendRegister(connectionGeneration);
        }
        break;

      case 'auth_error':
        _authChallengeTimer?.cancel();
        _authErrorReceived = true;
        final reason = msg['reason']?.toString() ?? 'unknown';
        print('Signaling auth_error $reason');
        break;

      case 'registered':
        print('Registered as: ${msg['id']}');
        _registered = true;
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
        await _flushPendingIceCandidates(fromId, webrtc);
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
        final callId = msg['callId'] as String?;
        final candidate = RTCIceCandidate(
          msg['candidate']['candidate'],
          msg['candidate']['sdpMid'],
          msg['candidate']['sdpMLineIndex'],
        );
        final session = _activeCall;
        if (callId != null) {
          if (session == null) {
            _rejectStaleCallEvent('ice', callId);
            break;
          }
          if (session.callId != callId || session.peerId != fromId) {
            _rejectStaleCallEvent('ice', callId);
            break;
          }
        } else if (session != null && session.peerId == fromId) {
          _rejectStaleCallEvent('ice', null);
          break;
        }
        final webrtc = _peers[fromId];
        if (webrtc != null) {
          await webrtc.addIceCandidate(candidate);
        } else {
          if (callId != null) {
            (_pendingCallIceCandidates[callId] ??= []).add(candidate);
          } else {
            (_pendingIceCandidates[fromId] ??= []).add(candidate);
          }
        }
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
        if (callId == null) {
          _rejectStaleCallEvent('call_offer', null);
          break;
        }
        if (_activeCall != null && _activeCall!.callId != callId) {
          _rejectStaleCallEvent('call_offer', callId);
          break;
        }
        final expiresAt = msg['expiresAt'];
        if (expiresAt is num &&
            DateTime.now().millisecondsSinceEpoch > expiresAt) {
          print(
            '[CALL] expired call_offer rejected callId=$callId expiresAt=$expiresAt',
          );
          break;
        }
        print('[CALL] offer received from $fromId callId=$callId');
        final offer = RTCSessionDescription(
          msg['sdp']['sdp'],
          msg['sdp']['type'],
        );
        _pendingCallIceCandidates.removeWhere((id, _) => id != callId);
        _activeCall = CallSession(
          callId: callId,
          peerId: fromId,
          direction: CallSessionDirection.incoming,
          state: CallSessionState.incomingRinging,
          pendingOffer: offer,
        );
        print(
          '[CALL] signaling call_offer created session callId=$callId peer=$fromId',
        );
        onIncomingCall?.call(fromId);
        break;

      case 'call_declined':
        {
          final callId = msg['callId'] as String?;
          if (!_isActiveCallEvent(callId, 'call_declined')) {
            break;
          }
          await _cleanupActiveCall(reason: 'call_declined');
          break;
        }

      case 'call_answer':
        {
          final fromId = msg['from'] as String;
          final callId = msg['callId'] as String?;
          if (!_isActiveCallEvent(callId, 'call_answer')) {
            break;
          }
          print('[CALL] answer received from $fromId callId=$callId');
          final webrtc = _peers[fromId];
          if (webrtc == null) break;
          await webrtc.setRemoteDescription(
            RTCSessionDescription(msg['sdp']['sdp'], msg['sdp']['type']),
          );
          await _flushPendingCallIceCandidates(callId!, webrtc);
          _activeCall?.state = CallSessionState.active;
          onCallAnswered?.call();
          break;
        }

      case 'call_end':
        {
          final fromId = msg['from'] as String;
          final callId = msg['callId'] as String?;
          if (!_isActiveCallEvent(callId, 'call_end')) {
            break;
          }
          print('[CALL] call ended by $fromId callId=$callId');
          await _cleanupActiveCall(reason: 'call_end');
          break;
        }

      case 'error':
        final message = msg['message']?.toString() ?? 'Unknown error';
        print('Signaling server error: $message');

        final isPeerOffline =
            message.toLowerCase().contains('peer not found') ||
            message.toLowerCase().contains('offline');

        final session = _activeCall;
        if (session != null) {
          if (!session.isAnswered && isPeerOffline) {
            print('[CALL] non-fatal error while ringing: $message');
            break;
          }

          await _cleanupActiveCall(reason: 'signaling_error');
        }
        break;
    }
  }

  Future<void> _handleAuthChallenge(
    Map<String, dynamic> msg,
    int connectionGeneration,
  ) async {
    _authChallengeTimer?.cancel();
    if (_registerSent) {
      return;
    }
    final nonce = msg['nonce'];
    final serverTime = msg['server_time'];
    if (nonce is! String || (serverTime is! int && serverTime is! String)) {
      print('Signaling auth identity missing; continuing legacy mode');
      _sendRegister(connectionGeneration);
      return;
    }

    final response = await _identityService.signSignalingAuthChallenge(
      nonce: nonce,
      serverTime: serverTime,
    );
    if (response == null) {
      print('Signaling auth identity missing; continuing legacy mode');
      _sendRegister(connectionGeneration);
      return;
    }
    if (connectionGeneration != _connectionGeneration || _authErrorReceived) {
      return;
    }

    _send({
      'type': 'auth_response',
      'peer_id': response.peerId,
      'pubkey': response.publicKey,
      'signature': response.signature,
    });
    print('Signaling auth_response sent');
  }

  Future<WebRTCService> _getOrCreatePeer(
    String peerId, {
    bool isInitiator = true,
    bool sendInitialOffer = true,
  }) async {
    if (_peers.containsKey(peerId)) {
      _resetIdleTimer(peerId);
      return _peers[peerId]!;
    }

    final webrtc = WebRTCService();

    // DHT: inject our identity so peer can resolve our handle
    webrtc.ownHandle = _myHandle;
    webrtc.ownPeerId = _myId;
    webrtc.onDhtMessage = (msg) {
      // Handle dht_find - peer is looking for a handle
      if (msg['type'] == 'dht_find') {
        webrtc.handleDhtFind(msg);
      }
      // dht_announce / dht_found - just let browser handle via data channel
    };
    // DHT setup complete

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
      final payload = <String, dynamic>{
        'type': 'ice',
        'to': peerId,
        'candidate': candidate.toMap(),
      };
      final session = _activeCall;
      if (session != null && session.peerId == peerId) {
        payload['callId'] = session.callId;
      }
      _send(payload);
    });

    if (isInitiator && sendInitialOffer) {
      _send({'type': 'knock', 'to': peerId});
      final offer = await webrtc.createOffer();
      _send({'type': 'offer', 'to': peerId, 'sdp': offer.toMap()});
    }

    _resetIdleTimer(peerId);
    return webrtc;
  }

  Future<void> _flushPendingIceCandidates(
    String peerId,
    WebRTCService webrtc,
  ) async {
    final candidates = _pendingIceCandidates.remove(peerId);
    if (candidates == null) return;
    for (final candidate in candidates) {
      await webrtc.addIceCandidate(candidate);
    }
  }

  Future<void> _flushPendingCallIceCandidates(
    String callId,
    WebRTCService webrtc,
  ) async {
    final candidates = _pendingCallIceCandidates.remove(callId);
    if (candidates == null) return;
    for (final candidate in candidates) {
      await webrtc.addIceCandidate(candidate);
    }
  }

  void _resetIdleTimer(String peerId) {
    if (peerId == _activeCall?.peerId) return;
    _idleTimers[peerId]?.cancel();
    _idleTimers[peerId] = Timer(
      const Duration(seconds: _idleTimeoutSeconds),
      () => _closePeer(peerId),
    );
  }

  Future<void> _closePeer(String peerId) async {
    _idleTimers.remove(peerId)?.cancel();
    final peer = _peers.remove(peerId);
    if (peer == null) return;
    await peer.dispose();
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

  Future<bool> startVoiceCall(String peerId, {String? callerName}) async {
    if (!_registered) {
      print('[CALL] startVoiceCall blocked because signaling is disconnected');
      return false;
    }
    if (_activeCall != null) {
      print(
        '[CALL] startVoiceCall closing active session before new call callId=${_activeCall!.callId}',
      );
      await _cleanupActiveCall(reason: 'new_call');
    }
    if (_peers.containsKey(peerId)) {
      await _closePeer(peerId);
    }
    _pendingCallIceCandidates.clear();
    print('[CALL] startVoiceCall peer=$peerId');
    final now = DateTime.now().millisecondsSinceEpoch;
    final callId = '${_myId}_${peerId}_$now';
    print('[CALL] created callId=$callId');
    _activeCall = CallSession(
      callId: callId,
      peerId: peerId,
      direction: CallSessionDirection.outgoing,
      state: CallSessionState.outgoingPreparing,
    );
    _idleTimers[peerId]?.cancel();
    try {
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
      _activeCall?.state = CallSessionState.outgoingRinging;
      return true;
    } catch (e) {
      print('Voice call setup failed for $peerId: $e');
      _send({
        'type': 'call_declined',
        'to': peerId,
        'callId': _activeCall?.callId,
      });
      await _cleanupActiveCall(reason: 'start_failed');
      return false;
    }
  }

  void setMicMuted(bool muted) {
    final peerId = _activeCall?.peerId;
    if (peerId != null) {
      _peers[peerId]?.setMicMuted(muted);
    }
  }

  Future<bool> acceptCall() async {
    final session = _activeCall;
    if (session == null ||
        !session.isIncoming ||
        session.pendingOffer == null) {
      print('[CALL] accept blocked because no SDP offer');
      return false;
    }
    final peerId = session.peerId;
    print('[CALL] acceptCall peer=$peerId');
    try {
      if (_peers.containsKey(peerId)) {
        await _closePeer(peerId);
      }
      session.state = CallSessionState.connecting;
      final webrtc = await _getOrCreatePeer(peerId, isInitiator: false);
      final answer = await webrtc.createAnswer(
        session.pendingOffer!,
        withAudio: true,
      );
      await _flushPendingCallIceCandidates(session.callId, webrtc);
      print('[CALL] sending answer to $peerId callId=${session.callId}');
      _send({
        'type': 'call_answer',
        'to': peerId,
        'sdp': answer.toMap(),
        'callId': session.callId,
      });
      session.pendingOffer = null;
      session.state = CallSessionState.active;
      return true;
    } catch (e) {
      print('Accept call failed for $peerId: $e');
      _send({'type': 'call_declined', 'to': peerId, 'callId': session.callId});
      await _cleanupActiveCall(reason: 'accept_failed');
      return false;
    }
  }

  void declineCall() {
    final session = _activeCall;
    if (session == null) return;
    _send({
      'type': 'call_declined',
      'to': session.peerId,
      'callId': session.callId,
    });
    unawaited(_cleanupActiveCall(reason: 'decline'));
  }

  Future<void> endVoiceCall() async {
    final session = _activeCall;
    if (session != null) {
      _send({
        'type': 'call_end',
        'to': session.peerId,
        'callId': session.callId,
      });
      await _cleanupActiveCall(reason: 'local_end');
      return;
    }
    onCallEnded?.call();
  }

  bool _isActiveCallEvent(String? callId, String type) {
    final session = _activeCall;
    if (callId == null || session == null || session.callId != callId) {
      _rejectStaleCallEvent(type, callId);
      return false;
    }
    return true;
  }

  void _rejectStaleCallEvent(String type, String? callId) {
    print(
      '[CALL] stale call event rejected type=$type callId=${callId ?? 'missing'} active=${_activeCall?.callId ?? 'none'}',
    );
  }

  Future<void> _cleanupActiveCall({required String reason}) async {
    final existingCleanup = _activeCallCleanup;
    if (existingCleanup != null) {
      print('[CALL] centralized cleanup already running reason=$reason');
      return existingCleanup;
    }

    final session = _activeCall;
    print(
      '[CALL] centralized cleanup reason=$reason callId=${session?.callId ?? 'none'}',
    );
    if (session == null) {
      return;
    }

    session.state = CallSessionState.ending;
    _activeCall = null;
    session.pendingOffer = null;
    _pendingCallIceCandidates.remove(session.callId);
    onCallEnded?.call();

    _activeCallCleanup = () async {
      try {
        await _closePeer(session.peerId);
      } finally {
        _activeCallCleanup = null;
      }
    }();
    await _activeCallCleanup;
  }

  bool isPeerConnected(String peerId) =>
      _peers[peerId]?.isDataChannelOpen ?? false;

  void disconnect() {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _authChallengeTimer?.cancel();
    _connectionGeneration++;
    unawaited(_cleanupActiveCall(reason: 'disconnect'));
    for (final peerId in List<String>.from(_peers.keys)) {
      unawaited(_closePeer(peerId));
    }
    for (var t in _idleTimers.values) {
      t.cancel();
    }
    _idleTimers.clear();
    _pendingIceCandidates.clear();
    _pendingCallIceCandidates.clear();
    _channel?.sink.close();
    _registered = false;
    _myId = null;
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void dispose() => disconnect();
}
