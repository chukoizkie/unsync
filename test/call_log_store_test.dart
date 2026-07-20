import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unsync/models/call_log_entry.dart';
import 'package:unsync/services/call_log_store.dart';

CallLogEntry _entry(String callId, {CallOutcome? outcome}) {
  final resolved = outcome ?? CallOutcome.missed;
  return CallLogEntry(
    peerId: 'peer-$callId',
    name: 'Peer $callId',
    direction: CallDirection.incoming,
    outcome: resolved,
    type: CallType.audio,
    timestamp: DateTime.now(),
    callId: callId,
    duration: resolved == CallOutcome.answered
        ? const Duration(seconds: 30)
        : null,
  );
}

void main() {
  test('concurrent appends do not drop entries', () async {
    final storage = _FakeSecureStorage();
    final store = CallLogStore(secureStorage: storage);

    // append() rewrites the whole JSON array. Fired without awaiting, these
    // used to interleave read-modify-write cycles and silently lose entries.
    await Future.wait([
      store.append(_entry('call-1')),
      store.append(_entry('call-2')),
      store.append(_entry('call-3')),
      store.append(_entry('call-4')),
      store.append(_entry('call-5')),
    ]);

    final loaded = await store.load();

    expect(loaded.map((e) => e.callId).toSet(), {
      'call-1',
      'call-2',
      'call-3',
      'call-4',
      'call-5',
    });
  });

  test('appends from separate instances share the serialization queue',
      () async {
    final storage = _FakeSecureStorage();

    // ContactsScreen and the recovery screen each hold their own CallLogStore
    // against the same underlying storage.
    await Future.wait([
      CallLogStore(secureStorage: storage).append(_entry('a')),
      CallLogStore(secureStorage: storage).append(_entry('b')),
      CallLogStore(secureStorage: storage).append(_entry('c')),
    ]);

    final loaded = await CallLogStore(secureStorage: storage).load();

    expect(loaded.map((e) => e.callId).toSet(), {'a', 'b', 'c'});
  });

  test('re-appending a callId overwrites the earlier outcome', () async {
    final storage = _FakeSecureStorage();
    final store = CallLogStore(secureStorage: storage);

    // The FCM wake handler writes a missed-by-default entry; the answered
    // record for the same call must replace it rather than duplicate it.
    await store.append(_entry('call-1'));
    await store.append(_entry('call-1', outcome: CallOutcome.answered));

    final loaded = await store.load();

    expect(loaded, hasLength(1));
    expect(loaded.single.outcome, CallOutcome.answered);
  });

  test('a failing write does not wedge later appends', () async {
    final storage = _FakeSecureStorage()..failNextWrite = true;
    final store = CallLogStore(secureStorage: storage);

    await expectLater(store.append(_entry('boom')), throwsA(isA<Exception>()));

    // The queue must recover: a rejected future left in the chain would block
    // every subsequent append forever.
    await store.append(_entry('call-after'));

    final loaded = await store.load();
    expect(loaded.map((e) => e.callId), contains('call-after'));
  });
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _data = {};
  bool failNextWrite = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    // Yield between read and write so an unserialized implementation is
    // guaranteed to interleave rather than merely being able to.
    await Future<void>.delayed(Duration.zero);
    return _data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (failNextWrite) {
      failNextWrite = false;
      throw Exception('write failed');
    }
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
