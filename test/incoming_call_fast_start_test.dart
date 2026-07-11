import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/main.dart';
import 'package:unsync/screens/incoming_call_recovery_screen.dart';
import 'package:unsync/screens/splash_screen.dart';
import 'package:unsync/services/call_notification_service.dart';
import 'package:unsync/services/identity_service.dart';
import 'package:unsync/services/incoming_call_fast_start.dart';
import 'package:unsync/services/launch_intent_service.dart';
import 'package:unsync/services/signaling_service.dart';

void main() {
  const launch = CallLaunchDetails(
    callerId: 'caller-1',
    callerName: 'Caller One',
  );

  test('call-launch fast path bypasses nonessential initialization', () async {
    final events = <String>[];
    final controller = IncomingCallFastStartController(
      launch: launch,
      identityService: _FakeIdentityService(events),
      signalingService: _FakeSignalingService(events),
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
    );

    await controller.start();

    expect(events, ['ringtone', 'identity_load', 'signaling_connect']);
    expect(events, isNot(contains('fcm_token_fetch')));
    expect(events, isNot(contains('contacts_load')));
    expect(events, isNot(contains('chat_sync')));

    await controller.dispose();
  });

  test('signaling starts before FCM token fetch', () async {
    final events = <String>[];
    final signaling = _FakeSignalingService(events);
    final controller = IncomingCallFastStartController(
      launch: launch,
      identityService: _FakeIdentityService(events),
      signalingService: signaling,
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
    );

    await controller.start();
    events.add('fcm_token_fetch');

    expect(
      events.indexOf('signaling_connect'),
      lessThan(events.indexOf('fcm_token_fetch')),
    );
    expect(signaling.connectedPeerId, 'me');

    await controller.dispose();
  });

  testWidgets('recovery UI appears before pending replay completes', (
    tester,
  ) async {
    final events = <String>[];
    final controller = IncomingCallFastStartController(
      launch: launch,
      identityService: _FakeIdentityService(events),
      signalingService: _FakeSignalingService(events),
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
      replayTimeout: const Duration(seconds: 30),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: IncomingCallRecoveryScreen(
          launch: launch,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reconnecting call...'), findsOneWidget);
    expect(find.text('Incoming call...'), findsNothing);
    expect(events, contains('signaling_connect'));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('pending replay validates the full incoming call UI', () async {
    final events = <String>[];
    final signaling = _FakeSignalingService(events);
    final controller = IncomingCallFastStartController(
      launch: launch,
      identityService: _FakeIdentityService(events),
      signalingService: signaling,
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
      replayTimeout: const Duration(seconds: 30),
    );

    await controller.start();
    signaling.replayPendingCall();

    expect(controller.state.value.phase, IncomingCallFastStartPhase.validated);

    await controller.dispose();
  });

  test('expired calls do not open full call UI', () async {
    final events = <String>[];
    final controller = IncomingCallFastStartController(
      launch: launch,
      identityService: _FakeIdentityService(events),
      signalingService: _FakeSignalingService(events),
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
      replayTimeout: const Duration(milliseconds: 1),
    );

    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(controller.state.value.phase, IncomingCallFastStartPhase.expired);
    expect(events, contains('missed_call'));
    expect(events, isNot(contains('incoming_call_ui')));

    await controller.dispose();
  });

  test('already expired notification launch shows nothing', () async {
    final events = <String>[];
    final expiredLaunch = CallLaunchDetails(
      callerId: 'caller-1',
      callerName: 'Caller One',
      callId: 'call-1',
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final controller = IncomingCallFastStartController(
      launch: expiredLaunch,
      identityService: _FakeIdentityService(events),
      signalingService: _FakeSignalingService(events),
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
    );

    await controller.start();

    expect(controller.state.value.phase, IncomingCallFastStartPhase.expired);
    expect(events, isNot(contains('ringtone')));
    expect(events, isNot(contains('signaling_connect')));
    expect(events, isNot(contains('missed_call')));

    await controller.dispose();
  });

  test('notification launch timeout uses remaining server deadline', () async {
    final events = <String>[];
    final expiringLaunch = CallLaunchDetails(
      callerId: 'caller-1',
      callerName: 'Caller One',
      callId: 'call-1',
      expiresAt: DateTime.now().add(const Duration(milliseconds: 25)),
    );
    final controller = IncomingCallFastStartController(
      launch: expiringLaunch,
      identityService: _FakeIdentityService(events),
      signalingService: _FakeSignalingService(events),
      startRingtone: () async => events.add('ringtone'),
      stopRingtone: () async => events.add('stop_ringtone'),
      showMissedCall: (_) async => events.add('missed_call'),
      replayTimeout: const Duration(seconds: 30),
    );

    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(controller.state.value.phase, IncomingCallFastStartPhase.expired);
    expect(events, contains('missed_call'));

    await controller.dispose();
  });

  test('normal non-call launch remains unchanged', () {
    expect(mercuryHomeForLaunch(null), isA<SplashScreen>());
    expect(mercuryHomeForLaunch(launch), isA<IncomingCallRecoveryScreen>());
  });

  test('native initial route carries call launch payload synchronously', () {
    final parsed = LaunchIntentService.getInitialCallLaunchFromRoute(
      '/incoming-call?payload=call%3Acaller-1%3ACaller%2520One',
    );

    expect(parsed?.callerId, 'caller-1');
    expect(parsed?.callerName, 'Caller One');
  });
}

class _FakeIdentityService extends IdentityService {
  _FakeIdentityService(this.events);

  final List<String> events;

  @override
  String? get peerId => 'me';

  @override
  String? get displayName => 'Me';

  @override
  Future<void> initialize() async {
    events.add('identity_load');
  }
}

class _FakeSignalingService extends SignalingService {
  _FakeSignalingService(this.events);

  final List<String> events;
  String? connectedPeerId;
  bool pendingIncomingCall = false;

  @override
  Future<void> connect(String myId, {String? fcmToken, String? handle}) async {
    connectedPeerId = myId;
    events.add('signaling_connect');
  }

  @override
  bool hasPendingIncomingCallFrom(String peerId) {
    return pendingIncomingCall && peerId == 'caller-1';
  }

  void replayPendingCall() {
    pendingIncomingCall = true;
    onIncomingCall?.call('caller-1');
  }

  @override
  void dispose() {}
}
