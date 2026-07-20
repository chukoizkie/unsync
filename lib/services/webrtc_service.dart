import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../config.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  bool _isRemoteDescriptionSet = false;
  bool _audioActive = false;
  Future<void>? _disposeFuture;
  final List<RTCIceCandidate> _iceCandidateBuffer = [];

  // DHT identity — set by SignalingService before use
  String? ownHandle;
  String? ownPeerId;

  Function(String message)? onMessageReceived;
  Function(bool connected)? onConnectionStateChanged;
  Function(MediaStream stream)? onRemoteStream;

  // DHT message handler — set by SignalingService
  Function(Map<String, dynamic> msg)? onDhtMessage;

  static final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      // Omitted unless a credential was supplied at build time. See
      // UnsyncConfig for why this is no longer a source literal.
      if (UnsyncConfig.hasTurnCredentials)
        {
          'urls': UnsyncConfig.turnUrl,
          'username': UnsyncConfig.turnUsername,
          'credential': UnsyncConfig.turnCredential,
        },
    ]
  };

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ]
  };

  Future<void> initialize() async {
    _disposeFuture = null;
    _isRemoteDescriptionSet = false;
    _iceCandidateBuffer.clear();
    _peerConnection = await createPeerConnection(_iceServers, _config);

    _peerConnection!.onIceConnectionState = (state) {
      print('ICE state: $state');
      final connected =
          state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted;
      if (connected) {
        unawaited(_activateAudioRoute());
      }
      onConnectionStateChanged?.call(connected);
    };

    _peerConnection!.onDataChannel = (channel) {
      _setupDataChannel(channel);
    };

    _peerConnection!.onTrack = (event) {
      print('[CALL] remote track received');
      if (event.streams.isNotEmpty) {
        onRemoteStream?.call(event.streams[0]);
      }
    };
  }

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    print('Data channel setup: ${channel.label} state: ${channel.state}');

    _dataChannel!.onDataChannelState = (state) {
      print('Data channel state changed: $state');
      // Announce ourselves to the peer as soon as channel opens
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _announceToDht();
      }
    };

    _dataChannel!.onMessage = (data) {
      final text = data.text;
      print('Data channel message received: $text');

      // Try to parse as DHT message first
      try {
        final msg = jsonDecode(text) as Map<String, dynamic>;
        final type = msg['type'] as String?;
        if (type != null &&
            ['dht_announce', 'dht_find', 'dht_found', 'dht_not_found'].contains(type)) {
          onDhtMessage?.call(msg);
          return;
        }
      } catch (_) {}

      // Regular message
      onMessageReceived?.call(text);
    };

    // If channel is already open (caller side), announce immediately
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _announceToDht();
    }
  }

  void _announceToDht() {
    if (ownHandle == null || ownPeerId == null) return;
    final msg = jsonEncode({
      'type':      'dht_announce',
      'handle':    ownHandle,
      'peerId':    ownPeerId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    _dataChannel?.send(RTCDataChannelMessage(msg));
    print('[DHT] Announced @$ownHandle → $ownPeerId');
  }

  // Handle incoming DHT find — check if we know the handle
  void handleDhtFind(Map<String, dynamic> msg) {
    final handle  = msg['handle'] as String?;
    final queryId = msg['queryId'] as String?;
    final ttl     = (msg['ttl'] as int?) ?? 0;
    if (handle == null || queryId == null) return;

    if (handle == ownHandle && ownPeerId != null) {
      // We are the target — respond with found
      final response = jsonEncode({
        'type':    'dht_found',
        'handle':  handle,
        'peerId':  ownPeerId,
        'queryId': queryId,
      });
      _dataChannel?.send(RTCDataChannelMessage(response));
      return;
    }

    // We don't know — if TTL allows, forward (browser handles gossip)
    if (ttl > 0) {
      final forward = jsonEncode({...msg, 'ttl': ttl - 1});
      _dataChannel?.send(RTCDataChannelMessage(forward));
    }
  }

  Future<RTCDataChannel> createDataChannel() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('Cannot create data channel after peer disposal');
    }
    final init = RTCDataChannelInit()..ordered = true;
    _dataChannel = await peerConnection.createDataChannel('messages', init);
    _setupDataChannel(_dataChannel!);
    return _dataChannel!;
  }

  Future<RTCDataChannel> ensureDataChannel() async {
    final channel = _dataChannel;
    if (channel != null &&
        channel.state != RTCDataChannelState.RTCDataChannelClosed) {
      return channel;
    }
    return createDataChannel();
  }

  // ── AUDIO ─────────────────────────────────────────────────────────────────

  Future<void> addAudioTrack() async {
    print('[CALL] addAudioTrack');
    if (_audioActive) return;
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('Cannot add audio after peer disposal');
    }
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      final audioTracks = _localStream!.getAudioTracks();
      for (final track in audioTracks) {
        await peerConnection.addTrack(track, _localStream!);
      }
      for (final track in audioTracks) {
        track.enabled = true;
      }
      _audioActive = true;
    } catch (e) {
      print('Audio initialization failed: $e');
      await _disposeLocalPeerConnectionState();
      rethrow;
    }
  }

  bool _speakerOn = false;

  bool get isSpeakerOn => _speakerOn;

  /// Routes call audio to the loudspeaker or back to the earpiece. Remembered
  /// so a route applied before the connection is established survives the
  /// activation that runs when ICE reaches connected.
  Future<void> setSpeakerphone(bool on) async {
    _speakerOn = on;
    await _activateAudioRoute();
  }

  Future<void> _activateAudioRoute() async {
    try {
      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (e) {
      print('Audio route activation failed: $e');
    }
  }

  Future<void> stopAudio() async {
    final stream = _localStream;
    _localStream = null;
    _audioActive = false;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        track.stop();
      } catch (e) {
        print('Audio track stop failed: $e');
      }
    }
    try {
      await stream.dispose();
    } catch (e) {
      print('Audio stream dispose failed: $e');
    }
  }

  Future<void> _disposeLocalPeerConnectionState() async {
    final dataChannel = _dataChannel;
    final peerConnection = _peerConnection;
    _dataChannel = null;
    _peerConnection = null;
    _isRemoteDescriptionSet = false;
    _audioActive = false;
    _iceCandidateBuffer.clear();

    await stopAudio();
    try {
      dataChannel?.close();
    } catch (e) {
      print('Data channel close failed: $e');
    }
    try {
      await peerConnection?.close();
    } catch (e) {
      print('Peer connection close failed: $e');
    }
  }

  void setMicMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  bool get isAudioActive => _localStream != null;

  bool get isSignalingStable =>
      _peerConnection?.signalingState ==
      RTCSignalingState.RTCSignalingStateStable;

  // ── SIGNALING ─────────────────────────────────────────────────────────────

  Future<RTCSessionDescription> createOffer({bool withAudio = false}) async {
    print('[CALL] createOffer');
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('Cannot create offer after peer disposal');
    }
    await ensureDataChannel();
    if (withAudio && !isAudioActive) await addAudioTrack();
    final offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer(RTCSessionDescription offer,
      {bool withAudio = false}) async {
    print('[CALL] createAnswer');
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('Cannot create answer after peer disposal');
    }
    await peerConnection.setRemoteDescription(offer);
    await _markRemoteDescriptionSetAndDrainIce();
    if (withAudio) await addAudioTrack();
    final answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    return answer;
  }

  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('Cannot set remote description after peer disposal');
    }
    await peerConnection.setRemoteDescription(description);
    await _markRemoteDescriptionSetAndDrainIce();
  }

  Future<void> _markRemoteDescriptionSetAndDrainIce() async {
    _isRemoteDescriptionSet = true;
    final buffered = List<RTCIceCandidate>.from(_iceCandidateBuffer);
    _iceCandidateBuffer.clear();
    for (final candidate in buffered) {
      final peerConnection = _peerConnection;
      if (peerConnection == null) return;
      await peerConnection.addCandidate(candidate);
    }
  }

  Future<void> safeAddIceCandidate(RTCIceCandidate candidate) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      print('[CALL] dropping ICE candidate after peer disposal');
      return;
    }
    if (_isRemoteDescriptionSet) {
      await peerConnection.addCandidate(candidate);
      return;
    }
    _iceCandidateBuffer.add(candidate);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await safeAddIceCandidate(candidate);
  }

  void onIceCandidate(Function(RTCIceCandidate) callback) {
    _peerConnection?.onIceCandidate = (candidate) {
      callback(candidate);
    };
  }

  bool get isDataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  void sendMessage(String message) {
    _dataChannel?.send(RTCDataChannelMessage(message));
  }

  Future<void> dispose() async {
    _disposeFuture ??= _disposeLocalPeerConnectionState();
    await _disposeFuture;
  }
}
