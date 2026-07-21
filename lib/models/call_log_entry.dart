import 'package:flutter/foundation.dart';

/// Direction of a logged call.
enum CallDirection { incoming, outgoing }

/// How a logged call ended.
enum CallOutcome { answered, missed, declined }

/// Media type of a logged call.
enum CallType { audio, video }

/// Explicit string serialization for the enums so future reordering of the
/// enum declarations can never corrupt already-persisted data. We deliberately
/// do NOT use `.name`/`.index` for persistence.
const Map<CallDirection, String> _directionToString = {
  CallDirection.incoming: 'incoming',
  CallDirection.outgoing: 'outgoing',
};

const Map<CallOutcome, String> _outcomeToString = {
  CallOutcome.answered: 'answered',
  CallOutcome.missed: 'missed',
  CallOutcome.declined: 'declined',
};

const Map<CallType, String> _typeToString = {
  CallType.audio: 'audio',
  CallType.video: 'video',
};

T _decodeEnum<T>(Object? value, Map<T, String> forward) {
  for (final entry in forward.entries) {
    if (entry.value == value) {
      return entry.key;
    }
  }
  throw FormatException('Unknown enum value: $value');
}

/// An immutable record of a single call, suitable for persistence.
///
/// [peerId] and [callId] are stored for correlation/dedup but must NEVER be
/// displayed in the UI — [name] is the only identity intended for display.
@immutable
class CallLogEntry {
  const CallLogEntry({
    required this.peerId,
    required this.name,
    required this.direction,
    required this.outcome,
    required this.type,
    required this.timestamp,
    required this.callId,
    this.duration,
  }) : assert(
          (outcome == CallOutcome.answered) == (duration != null),
          'duration must be set iff outcome is answered',
        );

  /// Stored for correlation only — NEVER displayed.
  final String peerId;

  /// Display name — the only identity shown in the UI.
  final String name;

  final CallDirection direction;
  final CallOutcome outcome;
  final CallType type;
  final DateTime timestamp;

  /// Non-null only when [outcome] is [CallOutcome.answered].
  final Duration? duration;

  /// Stored, used for dedup — NEVER displayed.
  final String callId;

  /// Whether this counts as a missed call: an *incoming* call that was never
  /// answered. An outgoing call nobody picked up is a no-answer, not a missed
  /// call, and must not appear under the Missed filter.
  ///
  /// Single definition on purpose — the filter and the row styling previously
  /// each had their own, so a row reading "No answer" still showed up when
  /// filtering by Missed.
  bool get isMissedCall =>
      outcome == CallOutcome.missed && direction == CallDirection.incoming;

  Map<String, dynamic> toJson() {
    return {
      'peerId': peerId,
      'name': name,
      'direction': _directionToString[direction],
      'outcome': _outcomeToString[outcome],
      'type': _typeToString[type],
      'timestamp': timestamp.toIso8601String(),
      'duration': duration?.inSeconds,
      'callId': callId,
    };
  }

  factory CallLogEntry.fromJson(Map<String, dynamic> json) {
    final durationSeconds = json['duration'];
    return CallLogEntry(
      peerId: json['peerId'] as String,
      name: json['name'] as String,
      direction: _decodeEnum(json['direction'], _directionToString),
      outcome: _decodeEnum(json['outcome'], _outcomeToString),
      type: _decodeEnum(json['type'], _typeToString),
      timestamp: DateTime.parse(json['timestamp'] as String),
      duration: durationSeconds == null
          ? null
          : Duration(seconds: (durationSeconds as num).toInt()),
      callId: json['callId'] as String,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CallLogEntry &&
        other.peerId == peerId &&
        other.name == name &&
        other.direction == direction &&
        other.outcome == outcome &&
        other.type == type &&
        other.timestamp == timestamp &&
        other.duration == duration &&
        other.callId == callId;
  }

  @override
  int get hashCode {
    return Object.hash(
      peerId,
      name,
      direction,
      outcome,
      type,
      timestamp,
      duration,
      callId,
    );
  }
}
