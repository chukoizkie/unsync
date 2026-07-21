import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_log_entry.dart';

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

  /// When media actually started, for both call legs. This is the single
  /// source of truth for "was this answered" — previously the caller and the
  /// callee each inferred it from different UI signals, and the callee's
  /// inference was simply wrong.
  DateTime? answeredAt;

  bool get isIncoming => direction == CallSessionDirection.incoming;
  bool get hasPendingOffer => pendingOffer != null;
  bool get isAnswered => state == CallSessionState.active;
  bool get isRingingOrConnecting =>
      state == CallSessionState.incomingRinging ||
      state == CallSessionState.outgoingPreparing ||
      state == CallSessionState.outgoingRinging ||
      state == CallSessionState.connecting;

  /// Marks the call as connected. Idempotent so a duplicate `call_answer`
  /// cannot restart the duration clock.
  void markAnswered() {
    state = CallSessionState.active;
    answeredAt ??= DateTime.now();
  }

  /// Projects this session into the record that gets logged, once, at
  /// teardown. [locallyDeclined] distinguishes "I pressed decline" from every
  /// other way a call can fail to connect.
  CompletedCall toCompletedCall({required bool locallyDeclined}) {
    final answered = answeredAt;
    if (answered != null) {
      return CompletedCall(
        callId: callId,
        peerId: peerId,
        direction: _logDirection,
        outcome: CallOutcome.answered,
        timestamp: answered,
        duration: DateTime.now().difference(answered),
      );
    }
    return CompletedCall(
      callId: callId,
      peerId: peerId,
      direction: _logDirection,
      // A remote decline of our outgoing call is not "declined" from this
      // device's point of view — nobody here declined anything. It reads as
      // an unanswered outgoing call, same as a timeout.
      outcome: locallyDeclined ? CallOutcome.declined : CallOutcome.missed,
      timestamp: DateTime.now(),
    );
  }

  CallDirection get _logDirection => isIncoming
      ? CallDirection.incoming
      : CallDirection.outgoing;
}

/// The terminal projection of a [CallSession], emitted exactly once when the
/// call is torn down. Carries no display name: the peer id is resolved to a
/// contact name by the UI layer, which is where the contact list lives.
class CompletedCall {
  const CompletedCall({
    required this.callId,
    required this.peerId,
    required this.direction,
    required this.outcome,
    required this.timestamp,
    this.duration,
  });

  final String callId;
  final String peerId;
  final CallDirection direction;
  final CallOutcome outcome;
  final DateTime timestamp;
  final Duration? duration;

  /// Builds the persistable entry once a display [name] has been resolved.
  CallLogEntry toLogEntry(String name) {
    return CallLogEntry(
      peerId: peerId,
      name: name,
      direction: direction,
      outcome: outcome,
      type: CallType.audio,
      timestamp: timestamp,
      callId: callId,
      duration: duration,
    );
  }
}
