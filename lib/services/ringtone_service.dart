import 'package:audioplayers/audioplayers.dart';

class RingtoneService {
  static final AudioPlayer _player = AudioPlayer();
  static bool _ringing = false;
  static bool get isRinging => _ringing;

  static Future<void> startRinging() async {
    if (_ringing) return;
    _ringing = true;
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('ringtone.wav'));
    } catch (_) {
      // Roll the flag back. Every call site swallows this error, so leaving
      // _ringing latched would silence the ringtone for the rest of the
      // process — each later startRinging() would early-return on the stale
      // flag. Rethrow so callers keep whatever handling they already have.
      _ringing = false;
      rethrow;
    }
  }

  static Future<void> stopRinging() async {
    if (!_ringing) return;
    _ringing = false;
    try {
      await _player.stop();
    } catch (e) {
      // Already marked not-ringing and there is nothing to recover, so don't
      // propagate: callers like _expire() await this on their teardown path.
      print('Ringtone stop failed: $e');
    }
  }
}
