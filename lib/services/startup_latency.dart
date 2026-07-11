import 'package:flutter/widgets.dart';

class StartupLatency {
  static final Stopwatch _watch = Stopwatch()..start();
  static final DateTime _startedAt = DateTime.now();

  static void mark(String milestone, {Map<String, Object?> data = const {}}) {
    final buffer = StringBuffer()
      ..write('[STARTUP_LATENCY] ')
      ..write(DateTime.now().toIso8601String())
      ..write(' +')
      ..write(_watch.elapsedMilliseconds)
      ..write('ms ')
      ..write(milestone);
    if (data.isNotEmpty) {
      data.forEach((key, value) {
        if (value != null) {
          buffer
            ..write(' ')
            ..write(key)
            ..write('=')
            ..write(value);
        }
      });
    }
    // ignore: avoid_print
    print(buffer.toString());
  }

  static void firstFlutterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mark('first_flutter_frame');
    });
  }

  static DateTime get startedAt => _startedAt;
}
