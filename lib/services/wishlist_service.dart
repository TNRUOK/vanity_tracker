import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/wishlist_item_model.dart';
import 'database_service.dart';

class WishlistService {
  static final WishlistService _instance = WishlistService._internal();
  factory WishlistService() => _instance;
  WishlistService._internal();

  final _uuid = const Uuid();
  // Only with a signed-in Firebase account (see DatabaseService.cloudSessionActive).
  bool get isFirebaseAvailable => DatabaseService.cloudSessionActive;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  final Map<String, WishlistItemModel> _localWishlist = {};

  Future<void> initialize() async {
    await _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('local_wishlist');
      if (str != null) {
        final List list = jsonDecode(str);
        _localWishlist.clear();
        for (var map in list) {
          final item = WishlistItemModel.fromMap(Map<String, dynamic>.from(map));
          _localWishlist[item.wishlistId] = item;
        }
      }
    } catch (e) {
      debugPrint('Error loading wishlist from prefs: $e');
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _localWishlist.values.map((w) => w.toMap()).toList();
      await prefs.setString('local_wishlist', jsonEncode(list));
    } catch (e) {
      debugPrint('Error saving wishlist to prefs: $e');
    }
  }

  /// Get wishlist strictly owned by the specified user
  Future<List<WishlistItemModel>> getWishlist(String userId) async {
    if (isFirebaseAvailable) {
      try {
        final snapshot = await _firestore
            .collection('wishlists')
            .where('user_id', isEqualTo: userId)
            .get();

        if (snapshot.docs.isNotEmpty) {
          final list = snapshot.docs
              .map((d) => WishlistItemModel.fromMap(d.data(), d.id))
              .toList();
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return list;
        }
      } catch (e) {
        debugPrint('Firestore getWishlist error: $e');
      }
    }

    final userItems = _localWishlist.values.where((w) => w.userId == userId).toList();
    userItems.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return userItems;
  }

  /// For backups: the user's wishlist from the account plus device-only entries, with
  /// the cloud read error (if any) instead of a silent fallback.
  Future<OwnedRecords<WishlistItemModel>> readWishlistForBackup(String userId) async {
    await _loadFromPrefs();
    final local = {for (final w in _localWishlist.values.where((w) => w.userId == userId)) w.wishlistId: w};
    if (!isFirebaseAvailable) return OwnedRecords(local.values.toList());
    try {
      final snapshot = await _firestore
          .collection('wishlists')
          .where('user_id', isEqualTo: userId)
          .get()
          .timeout(const Duration(seconds: 20));
      final byId = {for (final d in snapshot.docs) d.id: WishlistItemModel.fromMap(d.data(), d.id)};
      final deviceOnly = local.keys.where((id) => !byId.containsKey(id)).toList();
      for (final id in deviceOnly) {
        byId[id] = local[id]!;
      }
      return OwnedRecords(byId.values.toList(), deviceOnlyCount: deviceOnly.length);
    } catch (e) {
      return OwnedRecords(
        local.values.toList(),
        error: 'Wishlist could not be read from your account '
            '(${e is TimeoutException ? 'no connection' : e.toString().split('\n').first}).',
      );
    }
  }

  /// Add a new wishlist item. With [throwOnSyncFailure], a failed or timed-out cloud write
  /// is reported as [VanitySyncException] after the local copy is kept.
  Future<WishlistItemModel> addWishlistItem(WishlistItemModel item, {bool throwOnSyncFailure = false}) async {
    final itemId = item.wishlistId.isNotEmpty ? item.wishlistId : 'wish_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 4)}';
    final toSave = item.copyWith(wishlistId: itemId);

    Object? syncError;
    if (isFirebaseAvailable) {
      try {
        await DatabaseService.awaitCloudWrite(
          _firestore.collection('wishlists').doc(itemId).set(toSave.toMap(), SetOptions(merge: true)),
        );
      } catch (e) {
        debugPrint('Firestore addWishlistItem error: $e');
        syncError = e;
      }
    }

    _localWishlist[itemId] = toSave;
    await _saveToPrefs();
    if (throwOnSyncFailure && syncError != null) {
      throw VanitySyncException(
        syncError is TimeoutException
            ? 'Saved on this device; not synced yet (no connection).'
            : 'Saved on this device, but not synced to your account ($syncError).',
      );
    }
    return toSave;
  }

  /// Update an existing wishlist item
  Future<WishlistItemModel> updateWishlistItem(WishlistItemModel item) async {
    final existing = _localWishlist[item.wishlistId];
    if (existing != null && existing.userId != item.userId) {
      throw Exception('Unauthorized: You can only edit your own wishlist items.');
    }

    if (isFirebaseAvailable) {
      try {
        await _firestore
            .collection('wishlists')
            .doc(item.wishlistId)
            .set(item.toMap(), SetOptions(merge: true));
      } catch (e) {
        debugPrint('Firestore updateWishlistItem error: $e');
      }
    }

    _localWishlist[item.wishlistId] = item;
    await _saveToPrefs();
    return item;
  }

  /// Delete a wishlist item
  Future<bool> deleteWishlistItem(String wishlistId, String userId) async {
    final existing = _localWishlist[wishlistId];
    if (existing != null && existing.userId != userId) {
      throw Exception('Unauthorized: You can only delete your own wishlist items.');
    }

    if (isFirebaseAvailable) {
      try {
        await _firestore.collection('wishlists').doc(wishlistId).delete();
      } catch (e) {
        debugPrint('Firestore deleteWishlistItem error: $e');
      }
    }

    _localWishlist.remove(wishlistId);
    await _saveToPrefs();
    return true;
  }

  /// Clear in-memory cache on sign-out
  void clearLocalMemory() {
    _localWishlist.clear();
  }
}
