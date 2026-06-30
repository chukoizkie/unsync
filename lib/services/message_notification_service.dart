import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class MessageNotificationService {
  static final _player = AudioPlayer();
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'unsync_messages';
  static Function(String peerId)? onNotificationTapped;

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (details) {
        final payload = details.payload;
        if (payload != null && payload.startsWith('msg:')) {
          onNotificationTapped?.call(payload.replaceFirst('msg:', ''));
        }
      },
    );
    const channel = AndroidNotificationChannel(
      _channelId,
      'Messages',
      description: 'Incoming Mercury messages',
      importance: Importance.high,
      playSound: false,
    );
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(channel);
  }

  static Future<void> playMessageSound() async {
    try {
      await _player.play(AssetSource('message.wav'));
    } catch (_) {}
  }

  static Future<void> showMessageNotification(String senderName, String message, {String? peerId}) async {
    const details = AndroidNotificationDetails(
      _channelId,
      'Messages',
      channelDescription: 'Incoming Mercury messages',
      importance: Importance.high,
      priority: Priority.high,
      playSound: false,
      visibility: NotificationVisibility.private,
    );
    await _plugin.show(
      senderName.hashCode,
      senderName,
      message,
      const NotificationDetails(android: details),
      payload: 'msg:${peerId ?? senderName}',
    );
  }

  static Future<void> cancel() async {
    await _plugin.cancelAll();
  }

  static Future<String?> getInitialPeerId() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      final payload = details?.notificationResponse?.payload;
      if (payload != null && payload.startsWith('msg:')) {
        return payload.replaceFirst('msg:', '');
      }
    }
    return null;
  }
}
