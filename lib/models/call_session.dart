import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CallSessionDirection {
  incoming,
  outgoing,
}

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
    this.pendingOffer,
  });

  final String callId;
  final String peerId;
  final CallSessionDirection direction;
  CallSessionState state;
  RTCSessionDescription? pendingOffer;

  bool get isIncoming => direction == CallSessionDirection.incoming;
  bool get hasPendingOffer => pendingOffer != null;
  bool get isAnswered => state == CallSessionState.active;
}
