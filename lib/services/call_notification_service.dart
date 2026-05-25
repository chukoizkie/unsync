import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class CallNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'unsync_incoming_call_v5';
  static const _notifId = 42;

  static Function(String callerId)? onNotificationTapped;
  static String? lastCallerName;

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (details) {
        final payload = details.payload;
        if (payload != null && payload.startsWith('call:')) {
          final parts = payload.replaceFirst('call:', '').split(':');
          final callerId = parts[0];
          lastCallerName = parts.length > 1 ? parts[1] : callerId;
          onNotificationTapped?.call(callerId);
        }
      },
    );
    const channel = AndroidNotificationChannel(
      _channelId,
      'Incoming Calls',
      description: 'Incoming Unsync voice calls',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('ringtone'),
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      enableVibration: true,
    );
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(channel);
  }

  static Future<void> showIncomingCall(String callerName, String callerId) async {
    lastCallerName = callerName;
    const details = AndroidNotificationDetails(
      _channelId,
      'Incoming Calls',
      channelDescription: 'Incoming Unsync voice calls',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      autoCancel: false,
      ongoing: true,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('ringtone'),
      visibility: NotificationVisibility.public,
    );
    await _plugin.show(
      _notifId,
      'Incoming call',
      callerName,
      const NotificationDetails(android: details),
      payload: 'call:$callerId',
    );
  }

  static Future<void> cancel() async {
    await _plugin.cancel(_notifId);
  }

  static Future<String?> getInitialCallerId() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      final payload = details?.notificationResponse?.payload;
      if (payload != null && payload.startsWith('call:')) {
        final parts = payload.replaceFirst('call:', '').split(':');
        lastCallerName = parts.length > 1 ? parts[1] : parts[0];
        return parts[0]; // return callerId only
      }
    }
    return null;
  }
}
