import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class MessageNotificationService {
  static final _player = AudioPlayer();
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'unsync_messages';

  static Future<void> initialize() async {
    // Create notification channel
    const channel = AndroidNotificationChannel(
      _channelId,
      'Messages',
      description: 'Incoming Unsync messages',
      importance: Importance.high,
      playSound: false,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  static Future<void> playMessageSound() async {
    try {
      await _player.play(AssetSource('message.wav'));
    } catch (_) {}
  }

  static Future<void> showMessageNotification(String senderName, String message) async {
    const details = AndroidNotificationDetails(
      _channelId,
      'Messages',
      channelDescription: 'Incoming Unsync messages',
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
      payload: 'msg:$senderName',
    );
  }
}
