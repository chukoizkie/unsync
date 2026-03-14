import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class _PersistentSignalStore extends InMemorySignalProtocolStore {
  SharedPreferences? _prefs;
  static const _sessionsKey = 'signal_sessions';

  _PersistentSignalStore(super.keyPair, super.registrationId);

  Future<void> initPrefs(SharedPreferences prefs) async {
    _prefs = prefs;
    await _loadSessions();
  }

  Future<void> _loadSessions() async {
    final raw = _prefs?.getString(_sessionsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final address = SignalProtocolAddress(entry.key, 1);
        final sessionRecord = SessionRecord.fromSerialized(
          base64Decode(entry.value as String)
        );
        await super.storeSession(address, sessionRecord);
      }
    } catch (_) {}
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    await super.storeSession(address, record);
    await _persistSessions();
  }

  Future<void> _persistSessions() async {
    if (_prefs == null) return;
    final allSessions = <String, String>{};
    // Persist by iterating known session addresses
    final raw = _prefs?.getString(_sessionsKey);
    Map<String, dynamic> existing = {};
    if (raw != null) {
      try { existing = jsonDecode(raw) as Map<String, dynamic>; } catch (_) {}
    }
    for (final key in existing.keys) {
      final address = SignalProtocolAddress(key, 1);
      final record = await super.loadSession(address);
      if (record != null) {
        allSessions[key] = base64Encode(record.serialize());
      }
    }
    await _prefs!.setString(_sessionsKey, jsonEncode(allSessions));
  }

  Future<void> persistSession(String peerId) async {
    if (_prefs == null) return;
    final address = SignalProtocolAddress(peerId, 1);
    final record = await super.loadSession(address);
    if (record == null) return;
    final raw = _prefs?.getString(_sessionsKey);
    Map<String, dynamic> existing = {};
    if (raw != null) {
      try { existing = jsonDecode(raw) as Map<String, dynamic>; } catch (_) {}
    }
    existing[peerId] = base64Encode(record.serialize());
    await _prefs!.setString(_sessionsKey, jsonEncode(existing));
  }
}

class SignalService {
  static const _keyIdentityKeyPair = 'signal_identity_key_pair';
  static const _keyRegistrationId = 'signal_registration_id';

  IdentityKeyPair? _identityKeyPair;
  int? _registrationId;
  _PersistentSignalStore? _store;

  final Map<String, SessionCipher> _sessions = {};

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    final storedKeyPair = prefs.getString(_keyIdentityKeyPair);
    if (storedKeyPair != null) {
      final bytes = base64Decode(storedKeyPair);
      _identityKeyPair = IdentityKeyPair.fromSerialized(bytes);
    } else {
      _identityKeyPair = generateIdentityKeyPair();
      await prefs.setString(
        _keyIdentityKeyPair,
        base64Encode(_identityKeyPair!.serialize()),
      );
    }

    _registrationId = prefs.getInt(_keyRegistrationId);
    if (_registrationId == null) {
      _registrationId = generateRegistrationId(false);
      await prefs.setInt(_keyRegistrationId, _registrationId!);
    }

    _store = _PersistentSignalStore(_identityKeyPair!, _registrationId!);
    await _store!.initPrefs(prefs);

    final preKeys = generatePreKeys(0, 5);
    for (final preKey in preKeys) {
      await _store!.storePreKey(preKey.id, preKey);
    }

    final signedPreKey = generateSignedPreKey(_identityKeyPair!, 0);
    await _store!.storeSignedPreKey(signedPreKey.id, signedPreKey);
  }

  Map<String, dynamic> getPreKeyBundle() {
    final identityKey = _identityKeyPair!.getPublicKey();
    return {
      'registrationId': _registrationId,
      'identityKey': base64Encode(identityKey.serialize()),
    };
  }

  Future<PreKeyBundle> buildPreKeyBundle() async {
    final signedPreKey = await _store!.loadSignedPreKey(0);
    final preKey = await _store!.loadPreKey(0);
    return PreKeyBundle(
      _registrationId!,
      1,
      preKey.id,
      preKey.getKeyPair().publicKey,
      signedPreKey.id,
      signedPreKey.getKeyPair().publicKey,
      signedPreKey.signature,
      _identityKeyPair!.getPublicKey(),
    );
  }

  bool hasSession(String peerId) => _sessions.containsKey(peerId);

  Future<void> processPreKeyBundleFromMap(String peerId, Map<String, dynamic> map) async {
    final identityKey = IdentityKey(Curve.decodePoint(base64Decode(map['identityKey'] as String), 0));
    final preKey = Curve.decodePoint(base64Decode(map['preKey'] as String), 0);
    final signedPreKey = Curve.decodePoint(base64Decode(map['signedPreKey'] as String), 0);
    final signature = base64Decode(map['signedPreKeySignature'] as String);
    final bundle = PreKeyBundle(
      map['registrationId'] as int,
      1,
      map['preKeyId'] as int,
      preKey,
      map['signedPreKeyId'] as int,
      signedPreKey,
      signature,
      identityKey,
    );
    await processPreKeyBundle(peerId, bundle);
    await _store!.persistSession(peerId);
  }

  Future<void> processPreKeyBundle(String peerId, PreKeyBundle bundle) async {
    final address = SignalProtocolAddress(peerId, 1);
    final sessionBuilder = SessionBuilder.fromSignalStore(_store!, address);
    await sessionBuilder.processPreKeyBundle(bundle);
    _sessions[peerId] = SessionCipher.fromStore(_store!, address);
  }

  Future<String> encrypt(String peerId, String plaintext) async {
    final address = SignalProtocolAddress(peerId, 1);
    if (!_sessions.containsKey(peerId)) {
      _sessions[peerId] = SessionCipher.fromStore(_store!, address);
    }
    final cipher = _sessions[peerId]!;
    final encrypted = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext))
    );
    final result = base64Encode(encrypted.serialize());
    await _store!.persistSession(peerId);
    return result;
  }

  Future<String> decrypt(String peerId, String ciphertext) async {
    final address = SignalProtocolAddress(peerId, 1);
    if (!_sessions.containsKey(peerId)) {
      _sessions[peerId] = SessionCipher.fromStore(_store!, address);
    }
    final cipher = _sessions[peerId]!;
    final bytes = base64Decode(ciphertext);
    Uint8List decrypted;
    try {
      final preKeyMessage = PreKeySignalMessage(bytes);
      decrypted = await cipher.decrypt(preKeyMessage);
    } catch (_) {
      final message = SignalMessage.fromSerialized(bytes);
      decrypted = await cipher.decryptFromSignal(message);
    }
    await _store!.persistSession(peerId);
    return utf8.decode(decrypted);
  }

  bool get isInitialized => _store != null;
}
