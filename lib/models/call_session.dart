import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CallSessionDirection { incoming, outgoing }

enum CallSessionState {
  incomingRinging,
  outgoingPreparing,
  outgoingRinging,
  connecting,
  active,
  ending,
}

class CallSession {
  CallSession({
    required this.callId,
    required this.peerId,
    required this.direction,
    required this.state,
    this.createdAt,
    this.expiresAt,
    this.pendingOffer,
  });

  final String callId;
  final String peerId;
  final CallSessionDirection direction;
  DateTime? createdAt;
  DateTime? expiresAt;
  CallSessionState state;
  RTCSessionDescription? pendingOffer;

  bool get isIncoming => direction == CallSessionDirection.incoming;
  bool get hasPendingOffer => pendingOffer != null;
  bool get isAnswered => state == CallSessionState.active;
  bool get isRingingOrConnecting =>
      state == CallSessionState.incomingRinging ||
      state == CallSessionState.outgoingPreparing ||
      state == CallSessionState.outgoingRinging ||
      state == CallSessionState.connecting;
}
