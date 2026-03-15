import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class CallNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'unsync_incoming_call';
  static const _notifId = 42;

  static Function(String callerId)? onNotificationTapped;

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) {
          onNotificationTapped?.call(details.payload!);
        }
      },
    );
    const channel = AndroidNotificationChannel(
      _channelId,
      'Incoming Calls',
      description: 'Incoming Unsync voice calls',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
    );
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(channel);
  }

  static Future<void> showIncomingCall(String callerName, String callerId) async {
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
      playSound: false,
      visibility: NotificationVisibility.public,
    );
    await _plugin.show(
      _notifId,
      'Incoming call',
      callerName,
      const NotificationDetails(android: details),
      payload: callerId,
    );
  }

  static Future<void> cancel() async {
    await _plugin.cancel(_notifId);
  }
}
