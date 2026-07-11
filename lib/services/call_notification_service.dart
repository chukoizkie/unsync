import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class CallLaunchDetails {
  const CallLaunchDetails({
    required this.callerId,
    required this.callerName,
    this.callId,
    this.createdAt,
    this.expiresAt,
  });

  final String callerId;
  final String callerName;
  final String? callId;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool get isExpired {
    final deadline = expiresAt;
    if (deadline == null) return false;
    final now = DateTime.now();
    return now.isAfter(deadline) || now.isAtSameMomentAs(deadline);
  }
}

class CallNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'unsync_incoming_call_v5';
  static const _notifId = 42;
  static const _androidAutoGroupSummaryId = 2147483647;
  static const _androidAutoGroupSummaryTag = 'ranker_group';

  static Function(String callerId)? onNotificationTapped;
  static String? lastCallerName;
  static String? _consumedInitialCallerId;

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (details) {
        final payload = details.payload;
        if (payload != null && payload.startsWith('call:')) {
          final launch = _parseCallPayload(payload);
          if (launch == null) return;
          if (launch.isExpired) {
            unawaited(cancel().catchError((_) {}));
            return;
          }
          final callerId = launch.callerId;
          lastCallerName = launch.callerName;
          onNotificationTapped?.call(callerId);
        }
      },
    );
    const channel = AndroidNotificationChannel(
      _channelId,
      'Incoming Calls',
      description: 'Incoming Mercury voice calls',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('ringtone'),
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      enableVibration: true,
    );
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.createNotificationChannel(channel);
  }

  static Future<void> showIncomingCall(
    String callerName,
    String callerId, {
    String? callId,
    DateTime? createdAt,
    DateTime? expiresAt,
  }) async {
    if (_isExpired(expiresAt)) {
      await cancel();
      return;
    }
    lastCallerName = callerName;
    const details = AndroidNotificationDetails(
      _channelId,
      'Incoming Calls',
      channelDescription: 'Incoming Mercury voice calls',
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
      payload: _callPayload(
        callerId,
        callerName,
        callId: callId,
        createdAt: createdAt,
        expiresAt: expiresAt,
      ),
    );
  }

  static Future<void> cancel() async {
    await _plugin.cancel(_notifId);
    await _plugin.cancel(
      _androidAutoGroupSummaryId,
      tag: _androidAutoGroupSummaryTag,
    );
  }

  static Future<String?> getInitialCallerId() async {
    final launch = await getInitialCallLaunch();
    return launch?.callerId;
  }

  static Future<CallLaunchDetails?> getInitialCallLaunch() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      final payload = details?.notificationResponse?.payload;
      if (payload != null && payload.startsWith('call:')) {
        final launch = _parseCallPayload(payload);
        if (launch == null) return null;
        if (launch.isExpired) {
          await cancel();
          return null;
        }
        if (launch.callerId == _consumedInitialCallerId) return null;
        lastCallerName = launch.callerName;
        return launch;
      }
    }
    return null;
  }

  static CallLaunchDetails? callLaunchFromPayload(String? payload) {
    if (payload == null || !payload.startsWith('call:')) return null;
    final launch = _parseCallPayload(payload);
    if (launch?.isExpired == true) return null;
    return launch;
  }

  static void suppressInitialCallLaunch(String callerId) {
    _consumedInitialCallerId = callerId;
  }

  static String _callPayload(
    String callerId,
    String callerName, {
    String? callId,
    DateTime? createdAt,
    DateTime? expiresAt,
  }) {
    final parts = [
      'call',
      Uri.encodeComponent(callerId),
      Uri.encodeComponent(callerName),
    ];
    if (callId != null || createdAt != null || expiresAt != null) {
      parts.add(Uri.encodeComponent(callId ?? ''));
      parts.add(createdAt?.millisecondsSinceEpoch.toString() ?? '');
      parts.add(expiresAt?.millisecondsSinceEpoch.toString() ?? '');
    }
    return parts.join(':');
  }

  static CallLaunchDetails? _parseCallPayload(String payload) {
    final value = payload.replaceFirst('call:', '');
    if (value.isEmpty) return null;
    final parts = value.split(':');
    final callerId = Uri.decodeComponent(parts[0]);
    final rawName = parts.length > 1 ? parts[1] : '';
    final callerName = rawName.isEmpty
        ? callerId
        : Uri.decodeComponent(rawName);
    final callId = parts.length > 2 && parts[2].isNotEmpty
        ? Uri.decodeComponent(parts[2])
        : null;
    final createdAt = parts.length > 3 ? _dateTimeFromMillis(parts[3]) : null;
    final expiresAt = parts.length > 4 ? _dateTimeFromMillis(parts[4]) : null;
    return CallLaunchDetails(
      callerId: callerId,
      callerName: callerName,
      callId: callId,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );
  }

  static DateTime? _dateTimeFromMillis(String value) {
    final millis = int.tryParse(value);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static bool _isExpired(DateTime? expiresAt) {
    if (expiresAt == null) return false;
    final now = DateTime.now();
    return now.isAfter(expiresAt) || now.isAtSameMomentAs(expiresAt);
  }
}
