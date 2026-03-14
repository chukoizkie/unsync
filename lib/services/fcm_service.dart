import 'package:firebase_messaging/firebase_messaging.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FCM background ping from: ${message.data['from']}');
}

class FCMService {
  static final _fcm = FirebaseMessaging.instance;

  static Future<String?> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _fcm.requestPermission(
      alert: false,
      badge: false,
      sound: false,
    );
    FirebaseMessaging.onMessage.listen((message) {
      print('FCM ping received (foreground) from: ${message.data['from']}');
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      print('FCM ping — app reopened from: ${message.data['from']}');
    });
    final token = await _fcm.getToken();
    print('FCM Token: $token');
    return token;
  }

  static Future<String?> getToken() => _fcm.getToken();
}
