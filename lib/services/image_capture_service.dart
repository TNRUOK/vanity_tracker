import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:vanity_tracker/screens/receipt/receipt_scanner_screen.dart' show PickedReceiptImage;
import 'package:vanity_tracker/services/ocr/receipt_ocr_service.dart';
import 'package:vanity_tracker/theme/app_theme.dart';

/// Centralized service for capturing photos with the device camera or picking from gallery/files.
class ImageCaptureService {
  static final ImagePicker _picker = ImagePicker();

  /// Captures a fresh photo directly from the device camera.
  static Future<PickedReceiptImage?> captureWithCamera() async {
    try {
      final xFile = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (xFile == null) return null;
      final bytes = await xFile.readAsBytes();
      final ext = xFile.name.contains('.') ? xFile.name.split('.').last : 'jpg';
      return PickedReceiptImage(
        bytes: bytes,
        path: kIsWeb ? null : xFile.path,
        name: xFile.name.isNotEmpty ? xFile.name : 'camera_photo.jpg',
        mimeType: ReceiptOcrService.mimeTypeForExtension(ext),
      );
    } catch (e) {
      debugPrint('Camera capture failed: $e');
      rethrow;
    }
  }

  /// Picks an existing photo from the photo library or file storage.
  static Future<PickedReceiptImage?> pickFromGallery() async {
    try {
      final xFile = await _picker.pickImage(source: ImageSource.gallery);
      if (xFile == null) return null;
      final bytes = await xFile.readAsBytes();
      final ext = xFile.name.contains('.') ? xFile.name.split('.').last : 'jpg';
      return PickedReceiptImage(
        bytes: bytes,
        path: kIsWeb ? null : xFile.path,
        name: xFile.name.isNotEmpty ? xFile.name : 'gallery_photo.jpg',
        mimeType: ReceiptOcrService.mimeTypeForExtension(ext),
      );
    } catch (e) {
      debugPrint('Gallery pick failed, falling back to FilePicker: $e');
      final files = await FilePicker.pickFiles(dialogTitle: 'Select Image', type: FileType.image);
      if (files.isEmpty) return null;
      final picked = files.first;
      final bytes = await picked.readAsBytes();
      return PickedReceiptImage(
        bytes: bytes,
        path: kIsWeb ? null : picked.path,
        name: picked.name,
        mimeType: ReceiptOcrService.mimeTypeForExtension(picked.extension),
      );
    }
  }

  /// Shows a bottom sheet asking the user to choose between Camera and Gallery/Files.
  static Future<PickedReceiptImage?> pickImageWithSourceChoice(
    BuildContext context, {
    String title = 'Choose Image Source',
    String cameraLabel = 'Take Photo with Camera',
    String galleryLabel = 'Choose from Gallery / Files',
  }) async {
    final choice = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
              ),
              const SizedBox(height: 16),
              ListTile(
                key: const Key('image-source-camera'),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryRose.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.camera_alt_rounded, color: AppTheme.primaryRose),
                ),
                title: Text(cameraLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Capture a fresh photo using your device camera'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
              ),
              const Divider(height: 12),
              ListTile(
                key: const Key('image-source-gallery'),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6B46C1).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.photo_library_rounded, color: Color(0xFF6B46C1)),
                ),
                title: Text(galleryLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Select an existing image from your device'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );

    if (choice == null) return null;
    if (choice == ImageSource.camera) {
      return captureWithCamera();
    } else {
      return pickFromGallery();
    }
  }
}
