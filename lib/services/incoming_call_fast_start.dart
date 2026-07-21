import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_notification_service.dart';
import 'identity_service.dart';
import 'message_notification_service.dart';
import 'ringtone_service.dart';
import 'signaling_service.dart';
import 'startup_latency.dart';

enum IncomingCallFastStartPhase { recovering, validated, expired }

class IncomingCallFastStartState {
  const IncomingCallFastStartState({required this.phase, required this.launch});

  final IncomingCallFastStartPhase phase;
  final CallLaunchDetails launch;
}

typedef StartRingtone = Future<void> Function();
typedef StopRingtone = Future<void> Function();
typedef ShowMissedCall = Future<void> Function(CallLaunchDetails launch);

class IncomingCallFastStartController {
  factory IncomingCallFastStartController({
    required CallLaunchDetails launch,
    IdentityService? identityService,
    SignalingService? signalingService,
    StartRingtone? startRingtone,
    StopRingtone? stopRingtone,
    ShowMissedCall? showMissedCall,
    Duration replayTimeout = const Duration(seconds: 30),
  }) {
    final resolvedIdentity = identityService ?? IdentityService();
    return IncomingCallFastStartController._(
      launch: launch,
      identityService: resolvedIdentity,
      signalingService:
          signalingService ??
          SignalingService(identityService: resolvedIdentity),
      startRingtone: startRingtone,
      stopRingtone: stopRingtone,
      showMissedCall: showMissedCall,
      replayTimeout: replayTimeout,
    );
  }

  IncomingCallFastStartController._({
    required this.launch,
    required this.identityService,
    required this.signalingService,
    StartRingtone? startRingtone,
    StopRingtone? stopRingtone,
    ShowMissedCall? showMissedCall,
    required Duration replayTimeout,
  }) : _startRingtone = startRingtone ?? RingtoneService.startRinging,
       _stopRingtone = stopRingtone ?? RingtoneService.stopRinging,
       _showMissedCall = showMissedCall ?? _defaultShowMissedCall,
       _defaultReplayTimeout = replayTimeout,
       state = ValueNotifier<IncomingCallFastStartState>(
         IncomingCallFastStartState(
           phase: IncomingCallFastStartPhase.recovering,
           launch: launch,
         ),
       );

  final CallLaunchDetails launch;
  final IdentityService identityService;
  final SignalingService signalingService;
  final StartRingtone _startRingtone;
  final StopRingtone _stopRingtone;
  final ShowMissedCall _showMissedCall;
  final Duration _defaultReplayTimeout;
  final ValueNotifier<IncomingCallFastStartState> state;

  Timer? _timeout;
  bool _started = false;
  bool _missedShown = false;
  bool _releasedForHandoff = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (launch.isExpired) {
      await _cancelCallNotification();
      await _expire(showMissed: false);
      return;
    }
    final replayTimeout = _remainingReplayTimeout();
    if (!RingtoneService.isRinging) {
      StartupLatency.mark(
        'ringtone_start',
        data: {'callerId': launch.callerId},
      );
      unawaited(_startRingtone().catchError((_) {}));
    }

    signalingService.onIncomingCall = _handleIncomingCall;
    signalingService.onCallEnded = () {
      unawaited(_expire());
    };

    _timeout = Timer(replayTimeout, () {
      unawaited(_expire());
    });

    StartupLatency.mark('identity_load_start');
    await identityService.initialize();
    StartupLatency.mark(
      'identity_load_end',
      data: {'peerId': identityService.peerId ?? 'missing'},
    );

    final id = identityService.peerId;
    if (id == null || id.isEmpty) {
      await _expire();
      return;
    }

    StartupLatency.mark('signaling_connect_start');
    await signalingService.connect(id, handle: identityService.displayName);
  }

  void _handleIncomingCall(String peerId) {
    StartupLatency.mark('pending_call_replay', data: {'callerId': peerId});
    if (peerId != launch.callerId ||
        !signalingService.hasPendingIncomingCallFrom(peerId)) {
      return;
    }
    _timeout?.cancel();
    state.value = IncomingCallFastStartState(
      phase: IncomingCallFastStartPhase.validated,
      launch: launch,
    );
    StartupLatency.mark('route_push', data: {'route': 'IncomingCallScreen'});
  }

  Duration _remainingReplayTimeout() {
    final expiresAt = launch.expiresAt;
    if (expiresAt == null) return _defaultReplayTimeout;
    final remaining = expiresAt.difference(DateTime.now());
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  Future<void> _expire({bool showMissed = true}) async {
    if (state.value.phase != IncomingCallFastStartPhase.recovering) return;
    _timeout?.cancel();
    await _stopRingtone();
    await _cancelCallNotification();
    if (showMissed && !_missedShown) {
      _missedShown = true;
      await _showMissedCall(launch);
    }
    state.value = IncomingCallFastStartState(
      phase: IncomingCallFastStartPhase.expired,
      launch: launch,
    );
  }

  Future<void> dispose() async {
    _timeout?.cancel();
    if (!_releasedForHandoff) {
      signalingService.dispose();
    }
    state.dispose();
  }

  void releaseForHandoff() {
    _releasedForHandoff = true;
    _timeout?.cancel();
    // Ownership of the signaling service transfers to ContactsScreen, but its
    // _connect() only reassigns these after several awaits. Until then these
    // closures still point at this controller and at the recovery screen's
    // notifiers — all about to be disposed. A call event landing in that
    // window would write to a disposed ValueNotifier and throw inside the
    // WebSocket listener, so detach them here rather than at dispose().
    signalingService.onIncomingCall = null;
    signalingService.onCallEnded = null;
    signalingService.onCallAnswered = null;
    signalingService.onRemoteStream = null;
    signalingService.onCallCompleted = null;
  }

  Future<void> _cancelCallNotification() async {
    try {
      await CallNotificationService.cancel();
    } catch (_) {}
  }

  static Future<void> _defaultShowMissedCall(CallLaunchDetails launch) async {
    await MessageNotificationService.initialize();
    await MessageNotificationService.showMessageNotification(
      'Missed call from ${launch.callerName}',
      'Tap to open Mercury',
      peerId: launch.callerId,
    );
  }
}
