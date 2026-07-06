import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MercuryTaskHandler());
}

class MercuryTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Keep alive — actual WebSocket is managed in main isolate
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Ping to keep the service alive every 25s
    FlutterForegroundTask.updateService(
      notificationTitle: 'Mercury',
      notificationText: 'Connected — end-to-end encrypted',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class ForegroundServiceManager {
  static void wakeScreen() {
    FlutterForegroundTask.wakeUpScreen();
  }

  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'unsync_foreground',
        channelName: 'Mercury',
        channelDescription: 'Keeps Mercury connected in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(25000),
        autoRunOnBoot: true,
      ),
    );
  }

  static Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) return;
    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
    await FlutterForegroundTask.startService(
      serviceId: 1000,
      notificationTitle: 'Mercury',
      notificationText: 'Connected — end-to-end encrypted',
      notificationIcon: null,
      notificationButtons: [],
      callback: startCallback,
    );
  }

  static Future<void> stop() async {
    await FlutterForegroundTask.stopService();
  }
}
