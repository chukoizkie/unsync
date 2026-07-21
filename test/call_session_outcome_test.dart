import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/models/call_log_entry.dart';
import 'package:unsync/models/call_session.dart';

/// Outcome derivation used to be spread across two screens and a background
/// isolate, each guessing from different local signals. It is a pure function
/// of session state now, so it can be pinned down directly.
void main() {
  CallSession session({
    required CallSessionDirection direction,
    CallSessionState state = CallSessionState.incomingRinging,
  }) {
    return CallSession(
      callId: 'call-1',
      peerId: 'peer-1',
      direction: direction,
      state: state,
    );
  }

  test('answered incoming call reports answered with a duration', () {
    final s = session(direction: CallSessionDirection.incoming);
    s.markAnswered();

    final completed = s.toCompletedCall(locallyDeclined: false);

    expect(completed.outcome, CallOutcome.answered);
    expect(completed.direction, CallDirection.incoming);
    expect(completed.duration, isNotNull);
    // Regression: the callee's answered state was previously never recorded,
    // so every answered incoming call was logged as missed.
    expect(completed.outcome, isNot(CallOutcome.missed));
  });

  test('answered outgoing call reports answered and outgoing', () {
    final s = session(
      direction: CallSessionDirection.outgoing,
      state: CallSessionState.outgoingRinging,
    );
    s.markAnswered();

    final completed = s.toCompletedCall(locallyDeclined: false);

    expect(completed.outcome, CallOutcome.answered);
    expect(completed.direction, CallDirection.outgoing);
  });

  test('duration measures from answer time, not from when ringing began', () {
    final s = session(direction: CallSessionDirection.incoming);
    s.markAnswered();
    s.answeredAt = DateTime.now().subtract(const Duration(seconds: 5));

    final completed = s.toCompletedCall(locallyDeclined: false);

    expect(completed.duration!.inSeconds, greaterThanOrEqualTo(5));
    expect(completed.duration!.inSeconds, lessThan(10));
    expect(completed.timestamp, s.answeredAt);
  });

  test('markAnswered is idempotent so a duplicate answer cannot restart the '
      'clock', () {
    final s = session(direction: CallSessionDirection.incoming);
    s.markAnswered();
    final first = s.answeredAt;

    s.markAnswered();

    expect(s.answeredAt, same(first));
  });

  test('locally declined incoming call reports declined', () {
    final s = session(direction: CallSessionDirection.incoming);

    final completed = s.toCompletedCall(locallyDeclined: true);

    // Regression: declineCall() tears down synchronously, so the old code's
    // "missed" write landed first and won the callId dedup.
    expect(completed.outcome, CallOutcome.declined);
    expect(completed.duration, isNull);
  });

  test('unanswered incoming call reports missed', () {
    final s = session(direction: CallSessionDirection.incoming);

    final completed = s.toCompletedCall(locallyDeclined: false);

    expect(completed.outcome, CallOutcome.missed);
    expect(completed.duration, isNull);
  });

  test('outgoing call the peer declined is not logged as locally declined', () {
    final s = session(
      direction: CallSessionDirection.outgoing,
      state: CallSessionState.outgoingRinging,
    );

    final completed = s.toCompletedCall(locallyDeclined: false);

    expect(completed.outcome, CallOutcome.missed);
    expect(completed.direction, CallDirection.outgoing);
  });

  test('toLogEntry carries the resolved display name and satisfies the '
      'duration invariant', () {
    final s = session(direction: CallSessionDirection.incoming);
    s.markAnswered();

    final entry = s.toCompletedCall(locallyDeclined: false).toLogEntry('Ada');

    expect(entry.name, 'Ada');
    expect(entry.peerId, 'peer-1');
    expect(entry.callId, 'call-1');
    expect(entry.type, CallType.audio);
    // CallLogEntry asserts duration is set iff answered; constructing it at
    // all proves the projection respects that.
    expect(entry.outcome, CallOutcome.answered);
    expect(entry.duration, isNotNull);
  });

  _missedCallSemantics();

  test('unanswered projection builds a log entry with no duration', () {
    final s = session(direction: CallSessionDirection.outgoing);

    final entry = s.toCompletedCall(locallyDeclined: false).toLogEntry('Ada');

    expect(entry.outcome, CallOutcome.missed);
    expect(entry.duration, isNull);
  });
}

/// The Missed filter and the row styling each used to define "missed"
/// separately, so a row reading "No answer" still appeared under Missed.
void _missedCallSemantics() {
  CallLogEntry entry({
    required CallDirection direction,
    required CallOutcome outcome,
  }) {
    return CallLogEntry(
      peerId: 'peer',
      name: 'Peer',
      direction: direction,
      outcome: outcome,
      type: CallType.audio,
      timestamp: DateTime.now(),
      callId: 'call',
      duration: outcome == CallOutcome.answered
          ? const Duration(seconds: 5)
          : null,
    );
  }

  test('an unanswered incoming call is missed', () {
    expect(
      entry(
        direction: CallDirection.incoming,
        outcome: CallOutcome.missed,
      ).isMissedCall,
      isTrue,
    );
  });

  test('an unanswered outgoing call is a no-answer, not missed', () {
    expect(
      entry(
        direction: CallDirection.outgoing,
        outcome: CallOutcome.missed,
      ).isMissedCall,
      isFalse,
    );
  });

  test('declined and answered calls are never missed', () {
    for (final direction in CallDirection.values) {
      expect(
        entry(direction: direction, outcome: CallOutcome.declined).isMissedCall,
        isFalse,
      );
      expect(
        entry(direction: direction, outcome: CallOutcome.answered).isMissedCall,
        isFalse,
      );
    }
  });
}
