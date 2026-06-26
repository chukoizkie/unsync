import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedContact {
  final String peerId;
  final String displayName;
  final DateTime addedAt;

  SavedContact({
    required this.peerId,
    required this.displayName,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'displayName': displayName,
    'addedAt': addedAt.toIso8601String(),
  };

  factory SavedContact.fromJson(Map<String, dynamic> json) => SavedContact(
    peerId: json['peerId'],
    displayName: json['displayName'],
    addedAt: DateTime.parse(json['addedAt']),
  );
}

class ContactsService {
  static const _keyContacts = 'contacts';
  List<SavedContact> _contacts = [];

  List<SavedContact> get contacts => List.unmodifiable(_contacts);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyContacts);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      _contacts = list.map((e) => SavedContact.fromJson(e)).toList();
    }
  }

  Future<void> addContact(String peerId, String displayName) async {
    if (_contacts.any((c) => c.peerId == peerId)) return;
    _contacts.add(SavedContact(
      peerId: peerId,
      displayName: displayName,
      addedAt: DateTime.now(),
    ));
    await _save();
  }

  Future<void> removeContact(String peerId) async {
    _contacts.removeWhere((c) => c.peerId == peerId);
    await _save();
  }

  Future<String?> getContactPhotoPath(String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_contactPhotoKey(peerId));
    if (path == null || path.isEmpty) return null;
    if (await File(path).exists()) return path;
    await prefs.remove(_contactPhotoKey(peerId));
    return null;
  }

  Future<void> saveContactPhotoPath(String peerId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_contactPhotoKey(peerId), path);
  }

  Future<String> saveContactPhoto(String peerId, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/contact_photo_$peerId.jpg');
    await file.writeAsBytes(bytes, flush: true);
    await saveContactPhotoPath(peerId, file.path);
    return file.path;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyContacts, jsonEncode(_contacts.map((c) => c.toJson()).toList()));
  }

  String _contactPhotoKey(String peerId) => 'contact_photo_$peerId';
}
