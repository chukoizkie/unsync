import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'call_notification_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final callerId = message.data['callerId'] as String?;
  final callerName = message.data['callerName'] as String? ?? callerId ?? 'Unknown';
  final type = message.data['type'] as String?;
  if (type == 'call_offer' && callerId != null) {
    await CallNotificationService.initialize();
    await CallNotificationService.showIncomingCall(callerName, callerId);
  }
}

class FCMService {
  static final _fcm = FirebaseMessaging.instance;
  static Future<String?> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _fcm.requestPermission(alert: true, badge: false, sound: false);
    FirebaseMessaging.onMessage.listen((message) {
      final from = message.data['from'];
      print('FCM ping received (foreground) from: $from');
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final from = message.data['from'];
      print('FCM ping - app reopened from: $from');
    });
    final token = await _fcm.getToken();
    print('FCM Token: $token');
    return token;
  }
  static Future<String?> getToken() => _fcm.getToken();
}
