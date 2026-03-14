import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class StoredMessage {
  final String text;
  final bool isSent;
  final String time;

  StoredMessage({
    required this.text,
    required this.isSent,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'isSent': isSent,
    'time': time,
  };

  factory StoredMessage.fromJson(Map<String, dynamic> json) => StoredMessage(
    text: json['text'],
    isSent: json['isSent'],
    time: json['time'],
  );
}

class MessagesService {
  static const _prefix = 'messages_';
  final Map<String, List<StoredMessage>> _cache = {};

  Future<List<StoredMessage>> getMessages(String peerId) async {
    if (_cache.containsKey(peerId)) return _cache[peerId]!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$peerId');
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    _cache[peerId] = list.map((e) => StoredMessage.fromJson(e)).toList();
    return _cache[peerId]!;
  }

  Future<void> clearMessages(String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$peerId');
  }

  Future<void> addMessage(String peerId, String text, bool isSent) async {
    _cache.putIfAbsent(peerId, () => []);
    _cache[peerId]!.add(StoredMessage(
      text: text,
      isSent: isSent,
      time: DateTime.now().toIso8601String(),
    ));
    await _save(peerId);
  }

  Future<void> _save(String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_prefix$peerId',
      jsonEncode(_cache[peerId]!.map((m) => m.toJson()).toList()),
    );
  }
}
