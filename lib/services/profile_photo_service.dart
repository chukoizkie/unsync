import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfilePhotoService {
  static const _keyProfilePhotoPath = 'profile_photo_path';
  static const _thumbnailSize = 160;

  final ImagePicker _picker = ImagePicker();

  Future<String?> loadProfilePhotoPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_keyProfilePhotoPath);
    if (path == null || path.isEmpty) return null;
    if (await File(path).exists()) return path;
    await prefs.remove(_keyProfilePhotoPath);
    return null;
  }

  Future<String?> pickAndSaveProfilePhoto() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final side = decoded.width < decoded.height ? decoded.width : decoded.height;
    final cropped = img.copyCrop(
      decoded,
      x: (decoded.width - side) ~/ 2,
      y: (decoded.height - side) ~/ 2,
      width: side,
      height: side,
    );
    final resized = img.copyResize(
      cropped,
      width: _thumbnailSize,
      height: _thumbnailSize,
      interpolation: img.Interpolation.average,
    );

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/profile_photo.jpg');
    await file.writeAsBytes(img.encodeJpg(resized, quality: 82), flush: true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProfilePhotoPath, file.path);
    return file.path;
  }
}
