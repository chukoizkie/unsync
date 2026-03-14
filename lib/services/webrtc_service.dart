import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;

  Function(String message)? onMessageReceived;
  Function(bool connected)? onConnectionStateChanged;
  Function(MediaStream stream)? onRemoteStream;

  // ICE servers — override with your own TURN server in production
  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      // Add your TURN server here:
      // {
      //   'urls': 'turn:YOUR_TURN_SERVER:3478',
      //   'username': 'YOUR_USERNAME',
      //   'credential': 'YOUR_CREDENTIAL',
      // },
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
    };
    _dataChannel!.onMessage = (data) {
      print('Data channel message received: ${data.text}');
      print('onMessageReceived is null: ${onMessageReceived == null}');
      onMessageReceived?.call(data.text);
    };
  }

  Future<RTCDataChannel> createDataChannel() async {
    final init = RTCDataChannelInit()..ordered = true;
    _dataChannel = await _peerConnection!.createDataChannel('messages', init);
    _setupDataChannel(_dataChannel!);
    return _dataChannel!;
  }

  // ── AUDIO ──────────────────────────────────────────────────────────────────

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

  // ── SIGNALING ──────────────────────────────────────────────────────────────

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
