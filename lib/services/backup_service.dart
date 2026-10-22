import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../models/receipt_model.dart';
import '../models/vanity_item_model.dart';
import '../models/wishlist_item_model.dart';
import 'backup/backup_file_types.dart';
import 'backup/backup_file_stub.dart'
    if (dart.library.js_interop) 'backup/backup_file_web.dart'
    if (dart.library.io) 'backup/backup_file_io.dart' as platform_file;

export 'backup/backup_file_types.dart';

class FilePickResultData {
  final String fileName;
  final String? filePath;
  final String content;
  final int fileSizeBytes;

  const FilePickResultData({
    required this.fileName,
    this.filePath,
    required this.content,
    required this.fileSizeBytes,
  });
}

class BackupValidationResult {
  final bool isValid;
  final String? errorMessage;
  final int schemaVersion;
  final String? exportedAt;
  final String? currencySymbol;
  final List<VanityItemModel> validItems;
  final List<WishlistItemModel> validWishlist;
  final List<ReceiptModel> validReceipts;

  /// Records that cannot be restored, each with its type, position and reason.
  final List<String> invalidReasons;
  final List<VanityItemModel> duplicateItems;

  /// v3: the account the backup was made from (used to keep identifiers stable).
  final String? sourceUserId;

  /// v3: false when the export was explicitly partial; [omissions] says what is missing.
  final bool complete;
  final List<String> omissions;

  const BackupValidationResult({
    required this.isValid,
    this.errorMessage,
    this.schemaVersion = 2,
    this.exportedAt,
    this.currencySymbol,
    this.validItems = const [],
    this.validWishlist = const [],
    this.validReceipts = const [],
    this.invalidReasons = const [],
    this.duplicateItems = const [],
    this.sourceUserId,
    this.complete = true,
    this.omissions = const [],
  });
}

/// Vanity Tracker backup file (JSON).
///
/// Schema v3 (current):
/// ```
/// {
///   "format": "vanity-tracker-backup", "schema_version": 3, "app": "Vanity Tracker",
///   "exported_at": ISO-8601, "source_user_id": "<account id>",
///   "currency_symbol": "$", "complete": true, "omissions": [],
///   "counts": {"items": n, "receipts": n, "wishlist": n},
///   "items":    [VanityItemModel.toMap() ...]   // product, PAO + source, ingredients +
///                                               // provenance, dates, price, routine tags,
///                                               // finished/repurchase, notes, batch data
///   "receipts": [ReceiptModel.toMap() ...]      // header, totals, currency, line items with
///                                               // matched_vanity_item_id links
///   "wishlist": [WishlistItemModel.toMap() ...],
///   "excluded": ["..."]                          // what a backup never contains
/// }
/// ```
/// v2 (items, wishlist, receipts) and v1 (items only, camelCase header) are still read.
/// Never contains passwords, tokens or other people's data.
class BackupService {
  static const int currentSchemaVersion = 3;
  static const String formatId = 'vanity-tracker-backup';

  /// Largest file accepted for import (a backup with thousands of products is far smaller).
  static const int maxImportBytes = 25 * 1024 * 1024;

  /// What a backup deliberately does not contain (shown in the app and stored in the file).
  static const excludedData = [
    'Login details, passwords and access tokens',
    'Households, invitations and products other members shared with you',
    'Receipt and product photos (only text and links are stored)',
    'Scheduled reminders (they are recreated from the restored dates)',
    'The app\'s shared category list and product catalog',
  ];

  /// Builds the backup JSON (schema v3).
  static String exportToJson({
    required List<VanityItemModel> items,
    String currencySymbol = '\$',
    List<WishlistItemModel> wishlist = const [],
    List<ReceiptModel> receipts = const [],
    String? sourceUserId,
    List<String> omissions = const [],
    DateTime? exportedAt,
  }) {
    final exportMap = {
      'format': formatId,
      'schema_version': currentSchemaVersion,
      'app': 'Vanity Tracker',
      'exported_at': (exportedAt ?? DateTime.now()).toIso8601String(),
      'source_user_id': sourceUserId,
      'currency_symbol': currencySymbol,
      'complete': omissions.isEmpty,
      'omissions': omissions,
      'counts': {'items': items.length, 'receipts': receipts.length, 'wishlist': wishlist.length},
      'total_items': items.length,
      'items': items.map((i) => i.toMap()).toList(),
      'receipts': receipts.map((r) => r.toMap()).toList(),
      'wishlist': wishlist.map((w) => w.toMap()).toList(),
      'excluded': excludedData,
    };
    return const JsonEncoder.withIndent('  ').convert(exportMap);
  }

  /// `vanity_tracker_backup_YYYY-MM-DD.json`
  static String generateBackupFileName([DateTime? timestamp]) {
    final ts = timestamp ?? DateTime.now();
    return 'vanity_tracker_backup_${DateFormat('yyyy-MM-dd').format(ts)}.json';
  }

  /// Writes backup content to a designated File (headless tests and desktop tools only)
  static Future<File> writeBackupToFileDirect(File file, String jsonContent) async {
    return await file.writeAsString(jsonContent, flush: true);
  }

  /// Reads backup content from a designated File (headless tests and desktop tools only)
  static Future<String> readBackupFromFileDirect(File file) async {
    return await file.readAsString();
  }

  /// Tests only: replaces the platform save so success/failure handling can be exercised.
  @visibleForTesting
  static Future<BackupSaveOutcome> Function(Uint8List bytes, String fileName)? debugSaver;

  /// Saves the backup with the platform's mechanism: a browser download on the web, the
  /// system "save as" dialog on Android and desktop. Success is reported only when that
  /// action completed; a cancelled dialog returns `cancelled: true`.
  static Future<BackupSaveOutcome> saveBackup(String jsonContent, {String? fileName}) {
    final bytes = Uint8List.fromList(utf8.encode(jsonContent));
    final name = fileName ?? generateBackupFileName();
    return (debugSaver ?? platform_file.saveBackupBytes)(bytes, name);
  }

  /// Older entry point, kept for callers that expect a path (null when cancelled).
  static Future<String?> saveBackupToFile({required String jsonContent, String? suggestedFileName}) async {
    final outcome = await saveBackup(jsonContent, fileName: suggestedFileName);
    return outcome.saved ? (outcome.location ?? outcome.fileName) : null;
  }

  /// Decodes picked file bytes: UTF-8 (a leading byte-order mark is ignored).
  static String decodeBackupBytes(Uint8List bytes) {
    if (bytes.length > maxImportBytes) {
      throw const FormatException('The file is larger than 25 MB, which is too large to be a Vanity Tracker backup.');
    }
    var text = utf8.decode(bytes, allowMalformed: false);
    if (text.startsWith('﻿')) text = text.substring(1);
    return text;
  }

  /// Tests only: replaces the file picker.
  @visibleForTesting
  static Future<FilePickResultData?> Function()? debugPicker;

  /// Lets the user pick a backup file and reads it completely. Returns null when cancelled.
  /// Works on the web (bytes only, no file path) and on devices.
  static Future<FilePickResultData?> pickBackupFile() async {
    if (debugPicker != null) return debugPicker!();
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Select Vanity Tracker backup (.json)',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return null; // Cancelled
    final picked = files.first;
    final bytes = await picked.readAsBytes();
    final content = decodeBackupBytes(bytes);
    return FilePickResultData(
      fileName: picked.name,
      filePath: kIsWeb ? null : picked.path,
      content: content,
      fileSizeBytes: bytes.length,
    );
  }

  /// Alias for validateBackup with optional current inventory
  static BackupValidationResult validateBackupJson(
    String jsonStr, [
    List<VanityItemModel> currentInventory = const [],
  ]) {
    return validateBackup(jsonStr, currentInventory);
  }

  /// Validates a backup and returns what can be restored. Structural problems (not JSON,
  /// wrong root, unsupported or future version, missing arrays, counts that do not match
  /// = truncated file) reject the whole file. Individual bad records are listed in
  /// [BackupValidationResult.invalidReasons] (type, number, reason) and never silently dropped.
  static BackupValidationResult validateBackup(
    String jsonStr,
    List<VanityItemModel> currentInventory,
  ) {
    if (jsonStr.trim().isEmpty) {
      return const BackupValidationResult(
        isValid: false,
        errorMessage: 'The provided JSON backup is empty.',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (e) {
      return BackupValidationResult(
        isValid: false,
        errorMessage: 'Invalid JSON format: the file is damaged or incomplete '
            '(${e.toString().split('\n').first.replaceFirst(RegExp(r'^FormatException: (SyntaxError: )?'), '')})',
      );
    }

    if (decoded is! Map) {
      return const BackupValidationResult(
        isValid: false,
        errorMessage: 'JSON root must be an object containing backup data.',
      );
    }

    final map = Map<String, dynamic>.from(decoded);
    final rawVersion = map['schema_version'] ?? map['schemaVersion'];
    final schemaVersion = rawVersion is num ? rawVersion.toInt() : 1;
    if (schemaVersion > currentSchemaVersion || schemaVersion < 1) {
      return BackupValidationResult(
        isValid: false,
        errorMessage:
            'Unsupported backup schema version ($schemaVersion). This app reads versions 1 to $currentSchemaVersion; '
            'update the app to restore this file.',
      );
    }
    if (schemaVersion >= 3 && map['format'] != formatId) {
      return const BackupValidationResult(
        isValid: false,
        errorMessage: 'This file is not a Vanity Tracker backup.',
      );
    }

    final exportedAt = (map['exported_at'] ?? map['exportedAt'])?.toString();
    final currencySymbol = map['currency_symbol']?.toString();

    if (map['items'] is! List) {
      return const BackupValidationResult(
        isValid: false,
        errorMessage: 'JSON backup is missing the "items" array.',
      );
    }
    for (final key in ['receipts', 'wishlist']) {
      if (map.containsKey(key) && map[key] is! List) {
        return BackupValidationResult(isValid: false, errorMessage: 'The "$key" section of the backup is damaged.');
      }
    }
    if (schemaVersion >= 3) {
      final counts = map['counts'];
      if (counts is! Map) {
        return const BackupValidationResult(isValid: false, errorMessage: 'The backup is missing its record counts.');
      }
      for (final key in ['items', 'receipts', 'wishlist']) {
        final expected = (counts[key] as num?)?.toInt();
        final actual = (map[key] as List?)?.length ?? 0;
        if (expected != actual) {
          return BackupValidationResult(
            isValid: false,
            errorMessage: 'The backup looks truncated: it says it has $expected $key but contains $actual.',
          );
        }
      }
    }

    final rawItems = map['items'] as List<dynamic>;
    final validItems = <VanityItemModel>[];
    final invalidReasons = <String>[];
    final duplicateItems = <VanityItemModel>[];

    for (int i = 0; i < rawItems.length; i++) {
      final entry = rawItems[i];
      if (entry is! Map) {
        invalidReasons.add('Item #${i + 1} is not a valid JSON object.');
        continue;
      }

      try {
        final itemMap = Map<String, dynamic>.from(entry);
        final itemId = itemMap['vanity_item_id']?.toString().trim();
        if (itemId == null || itemId.isEmpty) {
          invalidReasons.add('Item #${i + 1}: missing vanity_item_id.');
          continue;
        }

        final item = VanityItemModel.fromMap(itemMap);

        // Validate basic integrity
        if (item.product == null && item.productId.isEmpty) {
          invalidReasons.add('Item #${i + 1}: missing product details.');
          continue;
        }
        for (final dateKey in ['opened_date', 'expiry_date', 'sealed_expiry_date', 'finished_date']) {
          final raw = itemMap[dateKey];
          if (raw != null && DateTime.tryParse(raw.toString()) == null) {
            throw FormatException('$dateKey "$raw" is not a date');
          }
        }

        validItems.add(item);

        // Check if item is duplicate of existing item
        final isDup = currentInventory.any((existing) {
          if (existing.vanityItemId.isNotEmpty &&
              existing.vanityItemId == item.vanityItemId) {
            return true;
          }
          final eBarcode = existing.product?.barcode ?? '';
          final iBarcode = item.product?.barcode ?? '';
          if (eBarcode.isNotEmpty && eBarcode == iBarcode) {
            return true;
          }
          final eName = existing.product?.name.toLowerCase().trim() ?? '';
          final iName = item.product?.name.toLowerCase().trim() ?? '';
          final eBrand = existing.product?.brand.toLowerCase().trim() ?? '';
          final iBrand = item.product?.brand.toLowerCase().trim() ?? '';
          if (eName.isNotEmpty && eName == iName && eBrand == iBrand) {
            return true;
          }
          return false;
        });

        if (isDup) {
          duplicateItems.add(item);
        }
      } catch (e) {
        invalidReasons.add('Item #${i + 1} failed to parse: ${e.toString().replaceAll('FormatException: ', '')}');
      }
    }

    final validWishlist = <WishlistItemModel>[];
    final rawWishlist = map['wishlist'] as List<dynamic>? ?? const [];
    for (int i = 0; i < rawWishlist.length; i++) {
      final entry = rawWishlist[i];
      if (entry is! Map) {
        invalidReasons.add('Wishlist item #${i + 1} is not a valid JSON object.');
        continue;
      }
      try {
        final wishItem = WishlistItemModel.fromMap(Map<String, dynamic>.from(entry));
        if (wishItem.wishlistId.trim().isEmpty) {
          invalidReasons.add('Wishlist item #${i + 1}: missing wishlist_id.');
        } else if (wishItem.name.trim().isEmpty) {
          invalidReasons.add('Wishlist item #${i + 1}: missing name.');
        } else {
          validWishlist.add(wishItem);
        }
      } catch (e) {
        invalidReasons.add('Wishlist item #${i + 1} failed to parse: $e');
      }
    }

    final validReceipts = <ReceiptModel>[];
    final rawReceipts = map['receipts'] as List<dynamic>? ?? const [];
    for (int i = 0; i < rawReceipts.length; i++) {
      final entry = rawReceipts[i];
      if (entry is! Map) {
        invalidReasons.add('Receipt #${i + 1} is not a valid JSON object.');
        continue;
      }
      try {
        final rMap = Map<String, dynamic>.from(entry);
        // The model would silently use "today" for a missing date; a restore must not.
        if (DateTime.tryParse('${rMap['purchase_date']}') == null) {
          invalidReasons.add('Receipt #${i + 1}: missing or invalid purchase_date.');
          continue;
        }
        if (rMap['total_amount'] is! num) {
          invalidReasons.add('Receipt #${i + 1}: missing total_amount.');
          continue;
        }
        final receipt = ReceiptModel.fromMap(rMap);
        if (receipt.receiptId.trim().isEmpty) {
          invalidReasons.add('Receipt #${i + 1}: missing receipt_id.');
        } else {
          validReceipts.add(receipt);
        }
      } catch (e) {
        invalidReasons.add('Receipt #${i + 1} failed to parse: $e');
      }
    }

    final hasAny = validItems.isNotEmpty || validWishlist.isNotEmpty || validReceipts.isNotEmpty;
    final isEmptyBackup = rawItems.isEmpty && rawWishlist.isEmpty && rawReceipts.isEmpty;
    return BackupValidationResult(
      isValid: hasAny,
      errorMessage: hasAny
          ? null
          : (isEmptyBackup
              ? 'This backup contains no products, receipts or wishlist entries.'
              : 'No valid vanity items, wishlist entries, or receipts found in the backup file.'),
      schemaVersion: schemaVersion,
      exportedAt: exportedAt,
      currencySymbol: currencySymbol,
      validItems: validItems,
      validWishlist: validWishlist,
      validReceipts: validReceipts,
      invalidReasons: invalidReasons,
      duplicateItems: duplicateItems,
      sourceUserId: map['source_user_id']?.toString(),
      complete: map['complete'] != false,
      omissions: (map['omissions'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }
}
