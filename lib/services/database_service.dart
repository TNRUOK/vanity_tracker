import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/category_model.dart';
import '../models/product_model.dart';
import '../models/vanity_item_model.dart';

/// Records read for a backup, with the reason the account copy could not be read (if any).
class OwnedRecords<T> {
  final List<T> records;

  /// Set when the cloud read failed; [records] then holds only this device's copy.
  final String? error;

  /// Records that exist only on this device (saved offline, not synced yet).
  final int deviceOnlyCount;

  const OwnedRecords(this.records, {this.error, this.deviceOnlyCount = 0});
}

/// Thrown (only when requested) when an item was saved locally but Firestore rejected it.
class VanitySyncException implements Exception {
  final String message;
  const VanitySyncException(this.message);

  @override
  String toString() => message;
}

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  final _uuid = const Uuid();
  bool get isFirebaseAvailable => cloudSessionActive;

  /// Firestore is used only with a signed-in Firebase account: the security rules refuse
  /// every unauthenticated request, so the demo account (not a Firebase sign-in) keeps its
  /// data on this device instead of failing on every call.
  static bool get cloudSessionActive {
    if (Firebase.apps.isEmpty) return false;
    try {
      return fb_auth.FirebaseAuth.instance.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  /// Offline, a Firestore write's future does not complete until the connection returns
  /// (the SDK keeps the write queued and sends it later). Waiting on it froze save
  /// screens, so after this long the write is treated as "saved locally, not synced yet".
  static const cloudWriteTimeout = Duration(seconds: 10);
  static DateTime? _cloudUnreachableUntil;

  /// Waits for a Firestore write, but never forever. After one write times out, the
  /// cloud is treated as unreachable for a minute: later writes are still handed to the
  /// SDK (which queues them) but not waited on, so a multi-item save reports back quickly.
  /// Throws [TimeoutException] when the write was not confirmed.
  static Future<void> awaitCloudWrite(Future<void> write) async {
    void clearWhenDone() => unawaited(write.then((_) => _cloudUnreachableUntil = null, onError: (Object _) {}));
    final until = _cloudUnreachableUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      clearWhenDone();
      throw TimeoutException('Cloud unreachable', cloudWriteTimeout);
    }
    try {
      await write.timeout(cloudWriteTimeout);
      _cloudUnreachableUntil = null;
    } on TimeoutException {
      _cloudUnreachableUntil = DateTime.now().add(const Duration(minutes: 1));
      clearWhenDone();
      rethrow;
    }
  }

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  // Local in-memory caches
  final List<VanityItemModel> _localVanityItems = [];
  final Map<String, ProductModel> _localProducts = {};
  final List<CategoryModel> _localCategories = List.from(CategoryModel.defaultCategories);

  List<VanityItemModel> getAllCachedItems() => List.unmodifiable(_localVanityItems);

  /// Initialize database and seed initial categories/mock data
  Future<void> initialize() async {
    await _loadLocalCache();
    if (_localVanityItems.isEmpty) {
      _seedDemoData();
      await _saveLocalCache();
    }
  }

  // ===================== CATEGORIES =====================

  Future<List<CategoryModel>> getCategories() async {
    if (isFirebaseAvailable) {
      try {
        final snapshot = await _firestore.collection('categories').get();
        if (snapshot.docs.isNotEmpty) {
          return snapshot.docs.map((d) => CategoryModel.fromMap(d.data(), d.id)).toList();
        }
      } catch (e) {
        debugPrint('Firestore getCategories error: $e');
      }
    }
    return _localCategories;
  }

  // ===================== PRODUCTS =====================

  Future<ProductModel?> getProductByBarcode(String barcode) async {
    if (barcode.isEmpty) return null;

    if (isFirebaseAvailable) {
      try {
        final query = await _firestore.collection('products').where('barcode', isEqualTo: barcode).limit(1).get();
        if (query.docs.isNotEmpty) {
          return ProductModel.fromMap(query.docs.first.data(), query.docs.first.id);
        }
      } catch (e) {
        debugPrint('Firestore getProductByBarcode error: $e');
      }
    }

    return _localProducts.values.cast<ProductModel?>().firstWhere((p) => p?.barcode == barcode, orElse: () => null);
  }

  Future<ProductModel> saveProduct(ProductModel product) async {
    final prodId = product.productId.isNotEmpty ? product.productId : _uuid.v4();
    final updatedProduct = product.copyWith(productId: prodId);

    if (isFirebaseAvailable) {
      try {
        // The shared catalog records who created each document so that only they can
        // change it (see firestore.rules). Writing a catalog document created by someone
        // else is rejected by the rules; items keep their own embedded copy regardless.
        final uid = fb_auth.FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          await awaitCloudWrite(
            _firestore
                .collection('products')
                .doc(prodId)
                .set({...updatedProduct.toMap(), 'created_by': uid}, SetOptions(merge: true)),
          );
        }
      } catch (e) {
        debugPrint('Firestore saveProduct error: $e');
      }
    }

    _localProducts[prodId] = updatedProduct;
    await _saveLocalCache();
    return updatedProduct;
  }

  // ===================== VANITY ITEMS =====================

  Future<List<VanityItemModel>> getVanityItems(String userId) async {
    if (isFirebaseAvailable) {
      try {
        final snapshot = await _firestore.collection('vanity_items').where('user_id', isEqualTo: userId).get();

        if (snapshot.docs.isNotEmpty) {
          final items = <VanityItemModel>[];
          for (var doc in snapshot.docs) {
            final data = doc.data();
            ProductModel? product;
            if (data['product'] != null) {
              product = ProductModel.fromMap(Map<String, dynamic>.from(data['product']));
            } else if (data['product_id'] != null) {
              product = await getProductById(data['product_id']);
            }
            items.add(VanityItemModel.fromMap(data, doc.id).copyWith(product: product));
          }
          return items;
        }
      } catch (e) {
        debugPrint('Firestore getVanityItems error: $e');
      }
    }

    if (userId == 'demo_user') {
      return _localVanityItems.where((item) => item.userId == 'demo_user').toList();
    }
    return _localVanityItems.where((item) => item.userId == userId).toList();
  }

  /// For backups: every inventory record of [userId] from the account (Firestore) plus
  /// records that exist only on this device (not synced yet), merged by id with the cloud
  /// copy winning. Unlike [getVanityItems], a failed cloud read is reported in
  /// [OwnedRecords.error] instead of silently falling back.
  /// (The Firestore client returns all matching documents from one query; no paging.)
  Future<OwnedRecords<VanityItemModel>> readVanityItemsForBackup(String userId) async {
    final local = {for (final i in _localVanityItems.where((i) => i.userId == userId)) i.vanityItemId: i};
    if (!isFirebaseAvailable) return OwnedRecords(local.values.toList());
    try {
      final snapshot = await _firestore
          .collection('vanity_items')
          .where('user_id', isEqualTo: userId)
          .get()
          .timeout(const Duration(seconds: 20));
      final byId = <String, VanityItemModel>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        ProductModel? product;
        if (data['product'] != null) {
          product = ProductModel.fromMap(Map<String, dynamic>.from(data['product']));
        } else if (data['product_id'] != null) {
          product = await getProductById(data['product_id']);
        }
        byId[doc.id] = VanityItemModel.fromMap(data, doc.id).copyWith(product: product);
      }
      final deviceOnly = local.keys.where((id) => !byId.containsKey(id)).toList();
      for (final id in deviceOnly) {
        byId[id] = local[id]!;
      }
      return OwnedRecords(byId.values.toList(), deviceOnlyCount: deviceOnly.length);
    } catch (e) {
      return OwnedRecords(
        local.values.toList(),
        error: 'Inventory could not be read from your account '
            '(${e is TimeoutException ? 'no connection' : e.toString().split('\n').first}).',
      );
    }
  }

  Future<ProductModel?> getProductById(String productId) async {
    if (isFirebaseAvailable) {
      try {
        final doc = await _firestore.collection('products').doc(productId).get();
        if (doc.exists && doc.data() != null) {
          return ProductModel.fromMap(doc.data()!, doc.id);
        }
      } catch (e) {
        debugPrint('Firestore getProductById error: $e');
      }
    }
    return _localProducts[productId];
  }

  /// Saves an item (idempotent on its id). With [throwOnSyncFailure], a failed Firestore
  /// write is reported as [VanitySyncException] after the local copy is kept, instead of
  /// being swallowed.
  Future<VanityItemModel> addVanityItem(VanityItemModel item, {bool throwOnSyncFailure = false}) async {
    final itemId = item.vanityItemId.isNotEmpty ? item.vanityItemId : _uuid.v4();
    final updatedItem = item.copyWith(vanityItemId: itemId);

    Object? syncError;
    if (isFirebaseAvailable) {
      try {
        await awaitCloudWrite(_firestore.collection('vanity_items').doc(itemId).set(updatedItem.toMap()));
      } catch (e) {
        debugPrint('Firestore addVanityItem error: $e');
        syncError = e;
      }
    }

    _localVanityItems.removeWhere((i) => i.vanityItemId == itemId);
    _localVanityItems.add(updatedItem);
    await _saveLocalCache();
    if (throwOnSyncFailure && syncError != null) {
      throw VanitySyncException(
        syncError is TimeoutException
            ? 'Saved on this device; not synced yet (no connection). It syncs when the connection returns while the app is open.'
            : 'Saved on this device, but not synced to your account ($syncError).',
      );
    }
    return updatedItem;
  }

  /// Updates one item (by its id). With [throwOnSyncFailure], a failed or timed-out
  /// Firestore write is reported as [VanitySyncException] after the local copy is kept.
  Future<VanityItemModel> updateVanityItem(VanityItemModel item, {bool throwOnSyncFailure = false}) async {
    Object? syncError;
    if (isFirebaseAvailable) {
      try {
        // Offline the write future never completes; see awaitCloudWrite.
        await awaitCloudWrite(
          _firestore.collection('vanity_items').doc(item.vanityItemId).set(item.toMap(), SetOptions(merge: true)),
        );
      } catch (e) {
        debugPrint('Firestore updateVanityItem error: $e');
        syncError = e;
      }
    }

    final index = _localVanityItems.indexWhere((i) => i.vanityItemId == item.vanityItemId);
    if (index >= 0) {
      _localVanityItems[index] = item;
    } else {
      _localVanityItems.add(item);
    }
    await _saveLocalCache();
    if (throwOnSyncFailure && syncError != null) {
      throw VanitySyncException(
        syncError is TimeoutException
            ? 'Saved on this device; not synced yet (no connection). It syncs when the connection returns while the app is open.'
            : 'Saved on this device, but not synced to your account ($syncError).',
      );
    }
    return item;
  }

  Future<void> deleteVanityItem(String vanityItemId) async {
    if (isFirebaseAvailable) {
      try {
        await _firestore.collection('vanity_items').doc(vanityItemId).delete();
      } catch (e) {
        debugPrint('Firestore deleteVanityItem error: $e');
      }
    }

    _localVanityItems.removeWhere((i) => i.vanityItemId == vanityItemId);
    await _saveLocalCache();
  }

  // ===================== LOCAL CACHE & DEMO SEED =====================

  Future<void> _loadLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final itemsStr = prefs.getString('local_vanity_items');
      if (itemsStr != null) {
        final List list = jsonDecode(itemsStr);
        _localVanityItems.clear();
        for (var map in list) {
          _localVanityItems.add(VanityItemModel.fromMap(Map<String, dynamic>.from(map)));
        }
      }

      final prodsStr = prefs.getString('local_products');
      if (prodsStr != null) {
        final Map<String, dynamic> map = jsonDecode(prodsStr);
        _localProducts.clear();
        map.forEach((k, v) {
          _localProducts[k] = ProductModel.fromMap(Map<String, dynamic>.from(v), k);
        });
      }
    } catch (e) {
      debugPrint('Load local cache error: $e');
    }
  }

  Future<void> _saveLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final itemsList = _localVanityItems.map((i) => i.toMap()).toList();
      await prefs.setString('local_vanity_items', jsonEncode(itemsList));

      final prodMap = _localProducts.map((k, v) => MapEntry(k, v.toMap()));
      await prefs.setString('local_products', jsonEncode(prodMap));
    } catch (e) {
      debugPrint('Save local cache error: $e');
    }
  }

  void _seedDemoData() {
    final now = DateTime.now();

    // 1. Fresh active serum (>30 days left - Green)
    final prod1 = const ProductModel(
      productId: 'demo_prod_1',
      barcode: '', // 3337875597180 is CeraVe Hydrating Cleanser in Open Beauty Facts
      name: 'Hyalu B5 Pure Hyaluronic Acid Serum',
      brand: 'La Roche-Posay',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      ingredients: 'Aqua, Glycerin, Alcohol Denat., Propylene Glycol, Panthenol, Sodium Hyaluronate...',
    );

    // 2. Expiring sunscreen (15 days left - Amber)
    final prod2 = const ProductModel(
      productId: 'demo_prod_2',
      barcode: '', // 8809643068098 has an invalid EAN-13 check digit
      name: 'Relief Sun : Rice + Probiotics (SPF50+ PA++++)',
      brand: 'Beauty of Joseon',
      categoryId: 'sunscreen',
      paoMonths: 12,
      volume: '50 ml',
      ingredients: 'Water, Oryza Sativa (Rice) Extract, Dibutyl Adipate, Diethylamino Hydroxybenzoyl Hexyl Benzoate...',
    );

    // 3. Expired mascara (-10 days - Red)
    final prod3 = const ProductModel(
      productId: 'demo_prod_3',
      barcode: '', // 041554420616 is Lash Sensational Washable in Open Beauty Facts
      name: 'Lash Sensational Sky High Mascara',
      brand: 'Maybelline New York',
      categoryId: 'mascara',
      paoMonths: 3,
      volume: '7.2 ml',
    );

    // 4. Finished moisturizer (Empties)
    final prod4 = const ProductModel(
      productId: 'demo_prod_4',
      barcode: '', // 3337872412483 has an invalid EAN-13 check digit
      name: 'Moisturizing Cream with Ceramides',
      brand: 'CeraVe',
      categoryId: 'moisturizer',
      paoMonths: 12,
      volume: '454 g',
    );

    _localProducts[prod1.productId] = prod1;
    _localProducts[prod2.productId] = prod2;
    _localProducts[prod3.productId] = prod3;
    _localProducts[prod4.productId] = prod4;

    // Demo barcodes are left empty: the earlier sample numbers were invalid or belonged to
    // other products (checked against Open Beauty Facts on 2026-10-19).
    // Items
    _localVanityItems.addAll([
      VanityItemModel(
        vanityItemId: 'item_1',
        productId: prod1.productId,
        userId: 'demo_user',
        openedDate: now.subtract(const Duration(days: 45)),
        expiryDate: VanityItemModel.computeExpiryDate(now.subtract(const Duration(days: 45)), 12),
        status: 'active',
        price: 39.99,
        product: prod1,
        notes: 'Great morning hydration, pairs well with sunscreen.',
      ),
      VanityItemModel(
        vanityItemId: 'item_2',
        productId: prod2.productId,
        userId: 'demo_user',
        openedDate: now.subtract(const Duration(days: 350)),
        expiryDate: VanityItemModel.computeExpiryDate(now.subtract(const Duration(days: 350)), 12),
        status: 'expiring_soon',
        price: 18.00,
        product: prod2,
        notes: 'Almost at 12M mark! Finish before beach trip.',
      ),
      VanityItemModel(
        vanityItemId: 'item_3',
        productId: prod3.productId,
        userId: 'demo_user',
        openedDate: now.subtract(const Duration(days: 105)),
        expiryDate: VanityItemModel.computeExpiryDate(now.subtract(const Duration(days: 105)), 3),
        status: 'expired',
        price: 12.99,
        product: prod3,
        notes: 'Mascara past 3M limit. Time to replace.',
      ),
      VanityItemModel(
        vanityItemId: 'item_4',
        productId: prod4.productId,
        userId: 'demo_user',
        openedDate: now.subtract(const Duration(days: 180)),
        expiryDate: VanityItemModel.computeExpiryDate(now.subtract(const Duration(days: 180)), 12),
        finishedDate: now.subtract(const Duration(days: 5)),
        status: 'finished',
        price: 19.50,
        wouldRepurchase: true,
        product: prod4,
        notes: 'Holy grail winter moisturizer! Used daily for 6 months.',
      ),
    ]);
  }
}
