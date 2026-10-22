import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/receipt_model.dart';
import 'database_service.dart';

/// Thrown when a receipt was saved on this device but could not be written to Firestore.
class ReceiptSyncException implements Exception {
  final String message;
  const ReceiptSyncException(this.message);

  @override
  String toString() => message;
}

class ReceiptService {
  static final ReceiptService _instance = ReceiptService._internal();
  factory ReceiptService() => _instance;
  ReceiptService._internal();

  // Only with a signed-in Firebase account (see DatabaseService.cloudSessionActive).
  bool get isFirebaseAvailable => DatabaseService.cloudSessionActive;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  final Map<String, ReceiptModel> _localReceipts = {};

  Future<void> initialize() async {
    await _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('local_receipts');
      // Device storage is the source of truth for local receipts: nothing stored = none.
      _localReceipts.clear();
      if (str != null) {
        final List list = jsonDecode(str);
        for (var map in list) {
          final receipt = ReceiptModel.fromMap(Map<String, dynamic>.from(map));
          _localReceipts[receipt.receiptId] = receipt;
        }
      }
    } catch (e) {
      debugPrint('Error loading receipts from prefs: $e');
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _localReceipts.values.map((r) => r.toMap()).toList();
      await prefs.setString('local_receipts', jsonEncode(list));
    } catch (e) {
      debugPrint('Error saving receipts to prefs: $e');
    }
  }

  /// Why the last [getReceipts] could not read the cloud copy (null when it could).
  String? lastLoadError;

  /// Get receipts strictly owned by the specified user.
  ///
  /// Cloud receipts and receipts saved on this device are merged by id (the cloud copy
  /// wins), so a receipt saved while offline is not hidden once other receipts exist in
  /// the cloud. A failed cloud read is reported in [lastLoadError] instead of silently
  /// looking like "no receipts".
  Future<List<ReceiptModel>> getReceipts(String userId) async {
    lastLoadError = null;
    final byId = <String, ReceiptModel>{
      for (final r in _localReceipts.values)
        if (r.userId == userId) r.receiptId: r,
    };

    if (isFirebaseAvailable) {
      try {
        final snapshot = await _firestore
            .collection('receipts')
            .where('user_id', isEqualTo: userId)
            .get()
            .timeout(const Duration(seconds: 15));
        for (final d in snapshot.docs) {
          byId[d.id] = ReceiptModel.fromMap(d.data(), d.id);
        }
      } catch (e) {
        debugPrint('Firestore getReceipts error: $e');
        lastLoadError =
            'Could not load receipts from your account '
            '(${e is TimeoutException ? 'no connection' : e.toString().split('\n').first}). '
            'Showing only receipts saved on this device.';
      }
    }

    final userReceipts = byId.values.toList()..sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
    return userReceipts;
  }

  /// For backups: like [getReceipts] but the read error and the number of receipts that
  /// exist only on this device are returned with the records.
  Future<OwnedRecords<ReceiptModel>> readReceiptsForBackup(String userId) async {
    await _loadFromPrefs();
    final local = {for (final r in _localReceipts.values.where((r) => r.userId == userId)) r.receiptId: r};
    if (!isFirebaseAvailable) return OwnedRecords(local.values.toList());
    try {
      final snapshot = await _firestore
          .collection('receipts')
          .where('user_id', isEqualTo: userId)
          .get()
          .timeout(const Duration(seconds: 20));
      final byId = {for (final d in snapshot.docs) d.id: ReceiptModel.fromMap(d.data(), d.id)};
      final deviceOnly = local.keys.where((id) => !byId.containsKey(id)).toList();
      for (final id in deviceOnly) {
        byId[id] = local[id]!;
      }
      return OwnedRecords(byId.values.toList(), deviceOnlyCount: deviceOnly.length);
    } catch (e) {
      return OwnedRecords(
        local.values.toList(),
        error: 'Receipts could not be read from your account '
            '(${e is TimeoutException ? 'no connection' : e.toString().split('\n').first}).',
      );
    }
  }

  /// Save or update a receipt (idempotent on receiptId)
  /// Throws [ReceiptSyncException] (after keeping the local copy) if Firestore rejects the write.
  Future<ReceiptModel> saveReceipt(ReceiptModel receipt) async {
    Object? syncError;
    if (isFirebaseAvailable) {
      try {
        // Offline the write future never completes; see DatabaseService.awaitCloudWrite.
        await DatabaseService.awaitCloudWrite(
          _firestore.collection('receipts').doc(receipt.receiptId).set(receipt.toMap(), SetOptions(merge: true)),
        );
      } catch (e) {
        debugPrint('Firestore saveReceipt error: $e');
        syncError = e;
      }
    }

    _localReceipts[receipt.receiptId] = receipt;
    await _saveToPrefs();
    if (syncError != null) {
      throw ReceiptSyncException(
        syncError is TimeoutException
            ? 'Receipt saved on this device; not synced yet (no connection). It syncs when the connection returns while the app is open.'
            : 'Receipt saved on this device, but it could not be synced to your account ($syncError).',
      );
    }
    return receipt;
  }

  /// Delete a receipt if authorized
  Future<bool> deleteReceipt(String receiptId, String userId) async {
    final existing = _localReceipts[receiptId];
    if (existing != null && existing.userId != userId) {
      throw Exception('Unauthorized: You can only delete your own receipts.');
    }

    Object? syncError;
    if (isFirebaseAvailable) {
      try {
        await DatabaseService.awaitCloudWrite(_firestore.collection('receipts').doc(receiptId).delete());
      } catch (e) {
        debugPrint('Firestore deleteReceipt error: $e');
        syncError = e;
      }
    }

    _localReceipts.remove(receiptId);
    await _saveToPrefs();
    if (syncError != null) {
      // Not silently "deleted": the cloud copy may still exist and come back on next load.
      throw ReceiptSyncException(
        syncError is TimeoutException
            ? 'Removed from this device; the deletion reaches your account when the connection returns.'
            : 'Removed from this device, but it could not be deleted from your account ($syncError).',
      );
    }
    return true;
  }

  /// Clear in-memory cache on sign-out
  void clearLocalMemory() {
    _localReceipts.clear();
  }
}
