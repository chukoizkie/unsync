import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/call_log_entry.dart';

/// Persists the local call log in secure storage.
///
/// The entire log is stored as a JSON array under a single key. This layer is
/// dormant by design — nothing else in the app wires into it yet.
class CallLogStore {
  static const _key = 'call_log_v1';

  final FlutterSecureStorage _secureStorage;

  CallLogStore({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  /// Returns all logged calls, most-recent-first.
  ///
  /// A missing key or a corrupt/unparseable blob both yield an empty list
  /// rather than throwing.
  Future<List<CallLogEntry>> load() async {
    final entries = await _read();
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries;
  }

  /// Adds [entry], replacing any existing entry with the same `callId`
  /// (last-write-wins) so an updated outcome/duration overwrites cleanly.
  Future<void> append(CallLogEntry entry) async {
    final entries = await _read();
    entries.removeWhere((existing) => existing.callId == entry.callId);
    entries.add(entry);
    await _write(entries);
  }

  /// Removes the call log entirely (user-controlled deletion of their data).
  Future<void> clear() async {
    await _secureStorage.delete(key: _key);
  }

  Future<List<CallLogEntry>> _read() async {
    try {
      final raw = await _secureStorage.read(key: _key);
      if (raw == null || raw.isEmpty) {
        return [];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        debugPrint('CallLogStore: stored blob is not a JSON array; ignoring.');
        return [];
      }
      return decoded
          .map((e) => CallLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CallLogStore: failed to read call log: $e');
      return [];
    }
  }

  Future<void> _write(List<CallLogEntry> entries) async {
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await _secureStorage.write(key: _key, value: raw);
  }
}
