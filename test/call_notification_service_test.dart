import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/services/call_notification_service.dart';

void main() {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('cancel removes incoming call and Android auto-group summary', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });

    await CallNotificationService.cancel();

    expect(calls, hasLength(2));
    expect(calls[0].method, 'cancel');
    expect(calls[0].arguments, {'id': 42, 'tag': null});
    expect(calls[1].method, 'cancel');
    expect(calls[1].arguments, {'id': 2147483647, 'tag': 'ranker_group'});
  });

  test('expired call launch payload is ignored', () {
    final expiredAt = DateTime.now()
        .subtract(const Duration(seconds: 1))
        .millisecondsSinceEpoch;

    final launch = CallNotificationService.callLaunchFromPayload(
      'call:caller-1:Caller%20One:call-1::$expiredAt',
    );

    expect(launch, isNull);
  });

  test('unexpired call launch payload preserves server deadline', () {
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = DateTime.now()
        .add(const Duration(seconds: 12))
        .millisecondsSinceEpoch;

    final launch = CallNotificationService.callLaunchFromPayload(
      'call:caller-1:Caller%20One:call-1:$createdAt:$expiresAt',
    );

    expect(launch?.callerId, 'caller-1');
    expect(launch?.callerName, 'Caller One');
    expect(launch?.callId, 'call-1');
    expect(launch?.createdAt?.millisecondsSinceEpoch, createdAt);
    expect(launch?.expiresAt?.millisecondsSinceEpoch, expiresAt);
  });
}
