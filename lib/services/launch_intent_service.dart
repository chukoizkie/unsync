import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'call_notification_service.dart';

class LaunchIntentService {
  static const _channel = MethodChannel('uk.unsync.messenger/launch_intent');

  static CallLaunchDetails? getInitialCallLaunchFromRoute([String? route]) {
    final routeName = route ?? ui.PlatformDispatcher.instance.defaultRouteName;
    if (!routeName.startsWith('/incoming-call')) return null;
    final uri = Uri.tryParse(routeName);
    final payload = uri?.queryParameters['payload'];
    return CallNotificationService.callLaunchFromPayload(payload);
  }

  static Future<CallLaunchDetails?> getInitialCallLaunch() async {
    try {
      final payload = await _channel.invokeMethod<String>(
        'initialNotificationPayload',
      );
      return CallNotificationService.callLaunchFromPayload(payload);
    } catch (_) {
      return null;
    }
  }
}
