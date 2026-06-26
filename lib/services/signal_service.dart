import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class SignalSessionMissingException implements Exception {
  final String peerId;
  final Object? cause;

  SignalSessionMissingException(this.peerId, [this.cause]);

  @override
  String toString() {
    final suffix = cause == null ? '' : ': $cause';
    return 'SignalSessionMissingException($peerId)$suffix';
  }
}

class _PersistentSignalStore extends InMemorySignalProtocolStore {
  final FlutterSecureStorage _secureStorage;
  static const _sessionsKey = 'signal_sessions';
  static const _preKeysKey = 'signal_pre_keys';
  static const _signedPreKeysKey = 'signal_signed_pre_keys';
  final Set<String> _sessionPeerIds = {};

  _PersistentSignalStore(
    super.keyPair,
    super.registrationId,
    this._secureStorage,
  );

  Future<void> init() async {
    await _loadSessions();
    await _loadPreKeys();
    await _loadSignedPreKeys();
  }

  Future<void> _loadSessions() async {
    final raw = await _secureStorage.read(key: _sessionsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final address = SignalProtocolAddress(entry.key, 1);
        final sessionRecord = SessionRecord.fromSerialized(
          base64Decode(entry.value as String),
        );
        await super.storeSession(address, sessionRecord);
        _sessionPeerIds.add(entry.key);
      }
    } catch (_) {}
  }

  Future<void> _loadPreKeys() async {
    final raw = await _secureStorage.read(key: _preKeysKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final record = PreKeyRecord.fromBuffer(
          base64Decode(entry.value as String),
        );
        await super.storePreKey(record.id, record);
      }
    } catch (_) {}
  }

  Future<void> _loadSignedPreKeys() async {
    final raw = await _secureStorage.read(key: _signedPreKeysKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final record = SignedPreKeyRecord.fromSerialized(
          base64Decode(entry.value as String),
        );
        await super.storeSignedPreKey(record.id, record);
      }
    } catch (_) {}
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    await super.storeSession(address, record);
    await _writeSessionRecord(address.getName(), record);
    _sessionPeerIds.add(address.getName());
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await super.storePreKey(preKeyId, record);
    await _writeRecord(_preKeysKey, preKeyId, record.serialize());
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await super.removePreKey(preKeyId);
    await _removeRecord(_preKeysKey, preKeyId);
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await super.storeSignedPreKey(signedPreKeyId, record);
    await _writeRecord(
      _signedPreKeysKey,
      signedPreKeyId,
      record.serialize(),
    );
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await super.removeSignedPreKey(signedPreKeyId);
    await _removeRecord(_signedPreKeysKey, signedPreKeyId);
  }

  Future<void> persistSession(String peerId) async {
    final address = SignalProtocolAddress(peerId, 1);
    final record = await super.loadSession(address);
    await _writeSessionRecord(peerId, record);
    _sessionPeerIds.add(peerId);
  }

  bool hasPersistedSession(String peerId) => _sessionPeerIds.contains(peerId);

  Future<void> _writeSessionRecord(String peerId, SessionRecord record) async {
    final raw = await _secureStorage.read(key: _sessionsKey);
    Map<String, dynamic> existing = {};
    if (raw != null) {
      try { existing = jsonDecode(raw) as Map<String, dynamic>; } catch (_) {}
    }
    existing[peerId] = base64Encode(record.serialize());
    await _secureStorage.write(
      key: _sessionsKey,
      value: jsonEncode(existing),
    );
  }

  Future<void> _writeRecord(String key, int id, Uint8List bytes) async {
    final raw = await _secureStorage.read(key: key);
    Map<String, dynamic> existing = {};
    if (raw != null) {
      try { existing = jsonDecode(raw) as Map<String, dynamic>; } catch (_) {}
    }
    existing[id.toString()] = base64Encode(bytes);
    await _secureStorage.write(key: key, value: jsonEncode(existing));
  }

  Future<void> _removeRecord(String key, int id) async {
    final raw = await _secureStorage.read(key: key);
    if (raw == null) return;
    try {
      final existing = jsonDecode(raw) as Map<String, dynamic>;
      existing.remove(id.toString());
      await _secureStorage.write(key: key, value: jsonEncode(existing));
    } catch (_) {}
  }
}

class SignalService {
  static const _keyIdentityKeyPair = 'signal_identity_key_pair';
  static const _keyRegistrationId = 'signal_registration_id';
  static const _keyNextPreKeyId = 'signal_next_pre_key_id';
  static const _keyNextSignedPreKeyId = 'signal_next_signed_pre_key_id';
  static const _keyActiveSignedPreKeyId = 'signal_active_signed_pre_key_id';
  final FlutterSecureStorage _secureStorage;

  IdentityKeyPair? _identityKeyPair;
  int? _registrationId;
  _PersistentSignalStore? _store;

  final Map<String, SessionCipher> _sessions = {};

  SignalService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  Future<void> initialize() async {
    final storedKeyPair = await _secureStorage.read(key: _keyIdentityKeyPair);
    if (storedKeyPair != null) {
      final bytes = base64Decode(storedKeyPair);
      _identityKeyPair = IdentityKeyPair.fromSerialized(bytes);
    } else {
      _identityKeyPair = generateIdentityKeyPair();
      await _secureStorage.write(
        key: _keyIdentityKeyPair,
        value: base64Encode(_identityKeyPair!.serialize()),
      );
    }

    final storedRegistrationId =
        await _secureStorage.read(key: _keyRegistrationId);
    _registrationId = int.tryParse(storedRegistrationId ?? '');
    if (_registrationId == null) {
      _registrationId = generateRegistrationId(false);
      await _secureStorage.write(
        key: _keyRegistrationId,
        value: _registrationId.toString(),
      );
    }

    _store = _PersistentSignalStore(
      _identityKeyPair!,
      _registrationId!,
      _secureStorage,
    );
    await _store!.init();

    await _ensureSignedPreKey();
  }

  Map<String, dynamic> getPreKeyBundle() {
    final identityKey = _identityKeyPair!.getPublicKey();
    return {
      'registrationId': _registrationId,
      'identityKey': base64Encode(identityKey.serialize()),
    };
  }

  Future<PreKeyBundle> buildPreKeyBundle() async {
    final signedPreKey = await _ensureSignedPreKey();
    final preKey = await _generateAndStoreNextPreKey();
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

  Future<PreKeyRecord> _generateAndStoreNextPreKey() async {
    final nextId = await _readInt(_keyNextPreKeyId, defaultValue: 1);
    final preKey = generatePreKeys(nextId, 1).first;
    await _store!.storePreKey(preKey.id, preKey);
    await _secureStorage.write(
      key: _keyNextPreKeyId,
      value: (preKey.id + 1).toString(),
    );
    return preKey;
  }

  Future<SignedPreKeyRecord> _ensureSignedPreKey() async {
    final activeIdRaw = await _secureStorage.read(key: _keyActiveSignedPreKeyId);
    final activeId = int.tryParse(activeIdRaw ?? '');
    if (activeId != null && await _store!.containsSignedPreKey(activeId)) {
      return _store!.loadSignedPreKey(activeId);
    }

    final nextId = await _readInt(_keyNextSignedPreKeyId, defaultValue: 1);
    final signedPreKey = generateSignedPreKey(_identityKeyPair!, nextId);
    await _store!.storeSignedPreKey(signedPreKey.id, signedPreKey);
    await _secureStorage.write(
      key: _keyActiveSignedPreKeyId,
      value: signedPreKey.id.toString(),
    );
    await _secureStorage.write(
      key: _keyNextSignedPreKeyId,
      value: (signedPreKey.id + 1).toString(),
    );
    return signedPreKey;
  }

  Future<int> _readInt(String key, {required int defaultValue}) async {
    final raw = await _secureStorage.read(key: key);
    return int.tryParse(raw ?? '') ?? defaultValue;
  }

  bool hasSession(String peerId) =>
      _sessions.containsKey(peerId) ||
      (_store?.hasPersistedSession(peerId) ?? false);

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

  Future<void> initializeSession(
    String peerId,
    Map<String, dynamic> bundle,
  ) async {
    await processPreKeyBundleFromMap(peerId, bundle);
  }

  Future<void> processPreKeyBundle(String peerId, PreKeyBundle bundle) async {
    final address = SignalProtocolAddress(peerId, 1);
    final sessionBuilder = SessionBuilder.fromSignalStore(_store!, address);
    await sessionBuilder.processPreKeyBundle(bundle);
    _sessions[peerId] = SessionCipher.fromStore(_store!, address);
  }

  Future<String> encrypt(String peerId, String plaintext) async {
    final store = _store;
    if (store == null) {
      throw SignalSessionMissingException(peerId);
    }

    try {
      final address = SignalProtocolAddress(peerId, 1);
      final cipher = _sessions[peerId] ?? SessionCipher.fromStore(store, address);
      _sessions[peerId] = cipher;

      final encrypted = await cipher.encrypt(
        Uint8List.fromList(utf8.encode(plaintext)),
      );
      final result = base64Encode(encrypted.serialize());
      await store.persistSession(peerId);
      return result;
    } catch (e) {
      _sessions.remove(peerId);
      throw SignalSessionMissingException(peerId, e);
    }
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
      try {
        final preKeyMessage = PreKeySignalMessage(bytes);
        decrypted = await cipher.decrypt(preKeyMessage);
      } catch (_) {
        final message = SignalMessage.fromSerialized(bytes);
        decrypted = await cipher.decryptFromSignal(message);
      }
      await _store!.persistSession(peerId);
      return utf8.decode(decrypted);
    } catch (e) {
      // Session is broken (e.g. keys wiped by reinstall).
      // Return a placeholder instead of raw ciphertext.
      return '[Unable to decrypt — re-add contact to reset session]';
    }
  }

  bool get isInitialized => _store != null;
}
