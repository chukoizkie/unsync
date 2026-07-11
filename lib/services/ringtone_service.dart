import 'package:audioplayers/audioplayers.dart';

class RingtoneService {
  static final AudioPlayer _player = AudioPlayer();
  static bool _ringing = false;
  static bool get isRinging => _ringing;

  static Future<void> startRinging() async {
    if (_ringing) return;
    _ringing = true;
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource('ringtone.wav'));
  }

  static Future<void> stopRinging() async {
    if (!_ringing) return;
    _ringing = false;
    await _player.stop();
  }
}
