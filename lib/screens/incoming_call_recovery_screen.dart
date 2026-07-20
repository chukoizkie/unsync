import 'dart:async';

import 'package:flutter/material.dart';

import '../services/call_log_store.dart';
import '../services/call_notification_service.dart';
import '../services/incoming_call_fast_start.dart';
import '../services/ringtone_service.dart';
import '../services/startup_latency.dart';
import '../theme.dart';
import 'call_screen.dart';
import 'contacts_screen.dart';
import 'incoming_call_screen.dart';

class IncomingCallRecoveryScreen extends StatefulWidget {
  const IncomingCallRecoveryScreen({
    super.key,
    required this.launch,
    this.controller,
  });

  final CallLaunchDetails launch;
  final IncomingCallFastStartController? controller;

  @override
  State<IncomingCallRecoveryScreen> createState() =>
      _IncomingCallRecoveryScreenState();
}

class _IncomingCallRecoveryScreenState
    extends State<IncomingCallRecoveryScreen> {
  late final IncomingCallFastStartController _controller;
  final _callLog = CallLogStore();
  final _callAnsweredNotifier = ValueNotifier<bool>(false);
  final _remoteStreamNotifier = ValueNotifier<dynamic>(null);
  bool _showIncomingCall = false;
  bool _showActiveCall = false;
  bool _isMuted = false;
  bool _leaving = false;
  bool _handoffStarted = false;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        IncomingCallFastStartController(launch: widget.launch);
    _controller.state.addListener(_onFastStartState);
    _controller.signalingService.onCallAnswered = () {
      _callAnsweredNotifier.value = true;
    };
    // Cold-start calls are torn down here, before ContactsScreen exists, so
    // without this handler an answered call kept the FCM wake handler's
    // missed-by-default entry forever.
    _controller.signalingService.onCallCompleted = (call) {
      unawaited(
        _callLog
            .append(call.toLogEntry(widget.launch.callerName))
            .catchError((_) {}),
      );
    };
    _controller.signalingService.onRemoteStream = (stream) {
      _remoteStreamNotifier.value = stream;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupLatency.mark('incoming_call_recovery_first_frame');
    });
    unawaited(_controller.start());
  }

  void _onFastStartState() {
    final phase = _controller.state.value.phase;
    if (phase == IncomingCallFastStartPhase.validated) {
      _controller.signalingService.onCallEnded = () {
        unawaited(_handleCallEnded());
      };
      if (mounted) {
        setState(() => _showIncomingCall = true);
      }
      return;
    }
    if (phase == IncomingCallFastStartPhase.expired && mounted) {
      unawaited(CallNotificationService.cancel().catchError((_) {}));
      _handoffToContacts();
    }
  }

  Future<void> _handleCallEnded() async {
    if (_leaving) return;
    _leaving = true;
    await RingtoneService.stopRinging();
    await CallNotificationService.cancel();
    _callAnsweredNotifier.value = false;
    _remoteStreamNotifier.value = null;
    if (!mounted) return;
    _handoffToContacts();
  }

  void _handoffToContacts() {
    if (_handoffStarted) return;
    _handoffStarted = true;
    _leaving = true;
    _controller.releaseForHandoff();
    StartupLatency.mark('recovery_handoff_complete');
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => ContactsScreen(
          identity: _controller.identityService,
          signaling: _controller.signalingService,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _decline() async {
    await RingtoneService.stopRinging();
    _controller.signalingService.declineCall();
    await CallNotificationService.cancel();
    await _handleCallEnded();
  }

  Future<void> _accept() async {
    await RingtoneService.stopRinging();
    await CallNotificationService.cancel();
    final accepted = await _controller.signalingService.acceptCall();
    if (!accepted) {
      await _handleCallEnded();
      return;
    }
    if (mounted) setState(() => _showActiveCall = true);
  }

  @override
  void dispose() {
    _controller.state.removeListener(_onFastStartState);
    unawaited(_controller.dispose());
    _callAnsweredNotifier.dispose();
    _remoteStreamNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showActiveCall) {
      return CallScreen(
        contactName: widget.launch.callerName,
        isOutgoing: false,
        isMuted: _isMuted,
        onMuteTap: () {
          setState(() => _isMuted = !_isMuted);
          _controller.signalingService.setMicMuted(_isMuted);
        },
        onHangUp: () => _controller.signalingService.endVoiceCall(),
        callAnsweredNotifier: _callAnsweredNotifier,
        remoteStreamNotifier: _remoteStreamNotifier,
      );
    }
    if (_showIncomingCall) {
      return IncomingCallScreen(
        callerName: widget.launch.callerName,
        onDecline: _decline,
        onAccept: _accept,
      );
    }
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: kAccent, width: 2),
                ),
                child: const Icon(Icons.call, color: kAccent, size: 42),
              ),
              const SizedBox(height: 22),
              Text(
                widget.launch.callerName,
                style: const TextStyle(
                  color: kText,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Reconnecting call...',
                style: TextStyle(color: kMuted, fontSize: 14),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: kAccent,
                  strokeWidth: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
