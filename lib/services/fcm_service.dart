import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'call_notification_service.dart';
import 'message_notification_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FCM_BG_HANDLER_ENTERED');
  print('FCM_BG_HANDLER_DATA ${message.data}');
  print('FCM_BG_HANDLER_TIMESTAMP ${DateTime.now().toIso8601String()}');
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  final callerId = message.data['callerId'] as String?;
  final callerName = message.data['callerName'] as String? ?? callerId ?? 'Unknown';
  final type = message.data['type'] as String?;
  final callId = message.data['callId'] as String?;

  if (type == 'call_offer' && callerId != null) {
    print(
      '[CALL] FCM wake received while disconnected callerId=$callerId callId=${callId ?? 'missing'}',
    );
    // Wake only. Signaling must deliver the real call_offer before call UI opens.
    FlutterForegroundTask.wakeUpScreen();
    await CallNotificationService.initialize();
    await CallNotificationService.showIncomingCall(callerName, callerId);
  } else if (type == 'message_wake') {
    final fromId = (message.data['fromId'] as String?) ??
        (message.data['senderId'] as String?) ??
        '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_message_wake', fromId);
    await MessageNotificationService.initialize();
    await MessageNotificationService.showMessageNotification(
      'Mercury', 'You have a new message',
      peerId: fromId.isNotEmpty ? fromId : null);
  }
}

class FCMService {
  static final _fcm = FirebaseMessaging.instance;
  static bool _signalingConnected = false;

  static void setSignalingConnected(bool connected) {
    _signalingConnected = connected;
  }

  static Future<String?> initialize() async {
    await _fcm.requestPermission(alert: true, badge: false, sound: true);
    FirebaseMessaging.onMessage.listen((message) {
      final type = message.data['type'] as String?;
      final callerId = message.data['callerId'] as String?;
      final callId = message.data['callId'] as String?;
      if (type == 'call_offer' && callerId != null) {
        if (_signalingConnected) {
          print(
            '[CALL] FCM wake ignored because signaling already connected callerId=$callerId callId=${callId ?? 'missing'}',
          );
        } else {
          print(
            '[CALL] FCM wake received while disconnected callerId=$callerId callId=${callId ?? 'missing'}',
          );
        }
        return;
      }
      final from = message.data['from'];
      print('FCM ping received (foreground) from: $from');
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final type = message.data['type'] as String?;
      final callerId = message.data['callerId'] as String?;
      final callId = message.data['callId'] as String?;
      if (type == 'call_offer' && callerId != null) {
        if (_signalingConnected) {
          print(
            '[CALL] FCM wake ignored because signaling already connected callerId=$callerId callId=${callId ?? 'missing'}',
          );
        } else {
          print(
            '[CALL] FCM wake received while disconnected callerId=$callerId callId=${callId ?? 'missing'}',
          );
        }
        return;
      }
      final from = message.data['from'];
      print('FCM ping - app reopened from: $from');
    });
    final token = await _fcm.getToken();
    print('FCM Token: $token');
    return token;
  }

  static Future<String?> getToken() => _fcm.getToken();
}
