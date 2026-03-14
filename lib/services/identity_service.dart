import 'package:shared_preferences/shared_preferences.dart';

class IdentityService {
  static const _keyPeerId = 'peer_id';
  static const _keyDisplayName = 'display_name';

  String? _peerId;
  String? _displayName;

  String? get peerId => _peerId;
  String? get displayName => _displayName;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _peerId = prefs.getString(_keyPeerId);
    _displayName = prefs.getString(_keyDisplayName);
    if (_peerId == null) {
      _peerId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString(_keyPeerId, _peerId!);
    }
  }

  Future<void> setDisplayName(String name) async {
    _displayName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDisplayName, name);
  }

  bool get isSetup => _displayName != null && _displayName!.isNotEmpty;
}
