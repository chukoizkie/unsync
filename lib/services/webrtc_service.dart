import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;

  // DHT identity — set by SignalingService before use
  String? ownHandle;
  String? ownPeerId;

  Function(String message)? onMessageReceived;
  Function(bool connected)? onConnectionStateChanged;
  Function(MediaStream stream)? onRemoteStream;

  // DHT message handler — set by SignalingService
  Function(Map<String, dynamic> msg)? onDhtMessage;

  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ]
  };

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ]
  };

  Future<void> initialize() async {
    _peerConnection = await createPeerConnection(_iceServers, _config);

    _peerConnection!.onIceConnectionState = (state) {
      print('ICE state: $state');
      onConnectionStateChanged?.call(
        state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted
      );
    };

    _peerConnection!.onDataChannel = (channel) {
      _setupDataChannel(channel);
    };

    _peerConnection!.onTrack = (event) {
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
    final init = RTCDataChannelInit()..ordered = true;
    _dataChannel = await _peerConnection!.createDataChannel('messages', init);
    _setupDataChannel(_dataChannel!);
    return _dataChannel!;
  }

  // ── AUDIO ─────────────────────────────────────────────────────────────────

  Future<void> addAudioTrack() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    for (final track in _localStream!.getAudioTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }
  }

  Future<void> stopAudio() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    await _localStream?.dispose();
    _localStream = null;
  }

  void setMicMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  bool get isAudioActive => _localStream != null;

  // ── SIGNALING ─────────────────────────────────────────────────────────────

  Future<RTCSessionDescription> createOffer({bool withAudio = false}) async {
    await createDataChannel();
    if (withAudio) await addAudioTrack();
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer(RTCSessionDescription offer,
      {bool withAudio = false}) async {
    await _peerConnection!.setRemoteDescription(offer);
    if (withAudio) await addAudioTrack();
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    await _peerConnection!.setRemoteDescription(description);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _peerConnection!.addCandidate(candidate);
  }

  void onIceCandidate(Function(RTCIceCandidate) callback) {
    _peerConnection!.onIceCandidate = (candidate) {
      callback(candidate);
    };
  }

  bool get isDataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  void sendMessage(String message) {
    _dataChannel?.send(RTCDataChannelMessage(message));
  }

  void dispose() {
    stopAudio();
    _dataChannel?.close();
    _peerConnection?.close();
  }
}
