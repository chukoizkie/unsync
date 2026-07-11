import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/call_notification_service.dart';
import 'services/fcm_service.dart';
import 'services/launch_intent_service.dart';
import 'services/ringtone_service.dart';
import 'services/startup_latency.dart';
import 'screens/incoming_call_recovery_screen.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  StartupLatency.mark('dart_main_entry');
  var initialCallLaunch = LaunchIntentService.getInitialCallLaunchFromRoute();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: kBg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  if (initialCallLaunch != null) {
    CallNotificationService.suppressInitialCallLaunch(
      initialCallLaunch.callerId,
    );
    StartupLatency.mark(
      'notification_launch_detection',
      data: {'callerId': initialCallLaunch.callerId},
    );
    _startIncomingRingtoneHandoff(initialCallLaunch.callerId);
    StartupLatency.firstFlutterFrame();
    StartupLatency.mark('runApp', data: {'mode': 'incoming_call'});
    runApp(MercuryApp(initialCallLaunch: initialCallLaunch));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeFirebaseServices());
    });
    return;
  }

  await CallNotificationService.initialize();
  initialCallLaunch = await CallNotificationService.getInitialCallLaunch();
  if (initialCallLaunch != null) {
    CallNotificationService.suppressInitialCallLaunch(
      initialCallLaunch.callerId,
    );
    StartupLatency.mark(
      'notification_launch_detection',
      data: {'callerId': initialCallLaunch.callerId},
    );
    _startIncomingRingtoneHandoff(initialCallLaunch.callerId);
    StartupLatency.firstFlutterFrame();
    StartupLatency.mark('runApp', data: {'mode': 'incoming_call'});
    runApp(MercuryApp(initialCallLaunch: initialCallLaunch));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeFirebaseServices());
    });
    return;
  }

  await _initializeFirebaseServices();
  StartupLatency.firstFlutterFrame();
  StartupLatency.mark('runApp', data: {'mode': 'normal'});
  runApp(const MercuryApp());
}

Future<void> _initializeFirebaseServices() async {
  await Firebase.initializeApp();
  FlutterForegroundTask.requestIgnoreBatteryOptimization();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
}

void _startIncomingRingtoneHandoff(String callerId) {
  if (RingtoneService.isRinging) return;
  StartupLatency.mark('ringtone_start', data: {'callerId': callerId});
  unawaited(RingtoneService.startRinging().catchError((_) {}));
}

class MercuryApp extends StatelessWidget {
  const MercuryApp({super.key, this.initialCallLaunch});

  final CallLaunchDetails? initialCallLaunch;

  @override
  Widget build(BuildContext context) {
    final launch = initialCallLaunch;
    final app = MaterialApp(
      title: 'Mercury',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kSurface,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: mercuryHomeForLaunch(launch),
    );
    if (launch != null) return app;
    return WithForegroundTask(child: app);
  }
}

Widget mercuryHomeForLaunch(CallLaunchDetails? launch) {
  return launch == null
      ? const SplashScreen()
      : IncomingCallRecoveryScreen(launch: launch);
}
