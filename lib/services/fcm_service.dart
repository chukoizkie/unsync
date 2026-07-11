import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'call_notification_service.dart';
import 'message_notification_service.dart';
import 'call_log_store.dart';
import '../models/call_log_entry.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FCM_BG_HANDLER_ENTERED');
  print('FCM_BG_HANDLER_TIMESTAMP ${DateTime.now().toIso8601String()}');
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  final callerId = message.data['callerId'] as String?;
  final callerName =
      message.data['callerName'] as String? ?? callerId ?? 'Unknown';
  final type = message.data['type'] as String?;
  final callId = message.data['callId'] as String?;
  final createdAt = _dateTimeFromServerMillis(message.data['createdAt']);
  final expiresAt = _dateTimeFromServerMillis(message.data['expiresAt']);

  if (type == 'call_offer' && callerId != null) {
    if (_isExpired(expiresAt)) {
      print(
        '[CALL] expired FCM wake ignored callerId=$callerId callId=${callId ?? 'missing'}',
      );
      await CallNotificationService.initialize();
      await CallNotificationService.cancel();
      return;
    }
    print(
      '[CALL] FCM wake received while disconnected callerId=$callerId callId=${callId ?? 'missing'}',
    );
    // Wake only. Signaling must deliver the real call_offer before call UI opens.
    FlutterForegroundTask.wakeUpScreen();
    await CallNotificationService.initialize();
    await CallNotificationService.showIncomingCall(
      callerName,
      callerId,
      callId: callId,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );
    if (callId != null) {
      // Default "missed" entry on arrival. The accept/decline hooks in
      // contacts_screen.dart write the same callId later and overwrite this
      // via the store's callId dedup (last-write-wins).
      final entry = CallLogEntry(
        peerId: callerId,
        name: callerName.isNotEmpty ? callerName : callerId,
        direction: CallDirection.incoming,
        outcome: CallOutcome.missed,
        type: CallType.audio,
        timestamp: DateTime.now(),
        callId: callId,
        duration: null,
      );
      unawaited(CallLogStore().append(entry).catchError((_) {}));
    }
  } else if (type == 'message_wake') {
    final fromId =
        (message.data['fromId'] as String?) ??
        (message.data['senderId'] as String?) ??
        '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_message_wake', fromId);
    await MessageNotificationService.initialize();
    await MessageNotificationService.showMessageNotification(
      'Mercury',
      'You have a new message',
      peerId: fromId.isNotEmpty ? fromId : null,
    );
  }
}

class FCMService {
  static final _fcm = FirebaseMessaging.instance;
  static bool _signalingConnected = false;
  static bool _listenersInitialized = false;
  static void Function(String token)? _onToken;

  static void setSignalingConnected(bool connected) {
    _signalingConnected = connected;
  }

  static Future<String?> initialize({
    void Function(String token)? onToken,
  }) async {
    _onToken = onToken;
    await _fcm.requestPermission(alert: true, badge: false, sound: true);
    if (!_listenersInitialized) {
      _listenersInitialized = true;
      FirebaseMessaging.onMessage.listen((message) {
        final type = message.data['type'] as String?;
        final callerId = message.data['callerId'] as String?;
        final callId = message.data['callId'] as String?;
        final expiresAt = _dateTimeFromServerMillis(message.data['expiresAt']);
        if (type == 'call_offer' && callerId != null) {
          if (_isExpired(expiresAt)) {
            print(
              '[CALL] expired FCM wake ignored callerId=$callerId callId=${callId ?? 'missing'}',
            );
            return;
          }
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
        final expiresAt = _dateTimeFromServerMillis(message.data['expiresAt']);
        if (type == 'call_offer' && callerId != null) {
          if (_isExpired(expiresAt)) {
            print(
              '[CALL] expired FCM wake ignored callerId=$callerId callId=${callId ?? 'missing'}',
            );
            return;
          }
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
      _fcm.onTokenRefresh.listen((token) {
        print('FCM token refreshed');
        _onToken?.call(token);
      });
    }
    final token = await _fcm.getToken();
    print('FCM token available: ${token != null ? 'yes' : 'no'}');
    if (token != null) {
      _onToken?.call(token);
    }
    return token;
  }

  static Future<String?> getToken() => _fcm.getToken();
}

DateTime? _dateTimeFromServerMillis(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String) {
    final millis = int.tryParse(value);
    if (millis != null) {
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
  }
  return null;
}

bool _isExpired(DateTime? expiresAt) {
  if (expiresAt == null) return false;
  final now = DateTime.now();
  return now.isAfter(expiresAt) || now.isAtSameMomentAs(expiresAt);
}
