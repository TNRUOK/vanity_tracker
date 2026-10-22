import 'package:flutter/foundation.dart';
import '../models/vanity_item_model.dart';
import '../models/wishlist_item_model.dart';
import '../services/database_service.dart';
import '../services/wishlist_service.dart';
import 'vanity_provider.dart';

class WishlistProvider extends ChangeNotifier {
  final WishlistService _service = WishlistService();

  List<WishlistItemModel> _items = [];
  bool _isLoading = false;
  String? _errorMessage;
  String _searchQuery = '';
  String? _selectedCategoryFilter;

  List<WishlistItemModel> get allItems => _items;
  List<WishlistItemModel> get items => filteredItems;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String get searchQuery => _searchQuery;
  String? get selectedCategoryFilter => _selectedCategoryFilter;

  /// Test helper to load items directly
  void loadWishlistFromList(List<WishlistItemModel> list) {
    _items = List.from(list);
    notifyListeners();
  }

  /// Filtered wishlist items based on search query and category filter
  List<WishlistItemModel> get filteredItems {
    return _items.where((item) {
      if (_selectedCategoryFilter != null &&
          _selectedCategoryFilter != 'all' &&
          item.categoryId != _selectedCategoryFilter) {
        return false;
      }

      final q = _searchQuery.trim().toLowerCase();
      if (q.isEmpty) return true;

      final name = item.name.toLowerCase();
      final brand = item.brand.toLowerCase();
      final notes = item.notes?.toLowerCase() ?? '';
      return name.contains(q) || brand.contains(q) || notes.contains(q);
    }).toList();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setCategoryFilter(String? categoryId) {
    _selectedCategoryFilter = categoryId;
    notifyListeners();
  }

  /// Load wishlist for user
  Future<void> loadWishlist(String userId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _service.initialize();
      _items = await _service.getWishlist(userId);
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      debugPrint('Error loading wishlist: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Add new item to wishlist
  Future<WishlistItemModel> addItem(WishlistItemModel item) async {
    final saved = await _service.addWishlistItem(item);
    _items.removeWhere((w) => w.wishlistId == saved.wishlistId);
    _items.insert(0, saved);
    notifyListeners();
    return saved;
  }

  /// Update item in wishlist
  Future<WishlistItemModel> updateItem(WishlistItemModel item) async {
    final updated = await _service.updateWishlistItem(item);
    final index = _items.indexWhere((w) => w.wishlistId == item.wishlistId);
    if (index >= 0) {
      _items[index] = updated;
    } else {
      _items.add(updated);
    }
    notifyListeners();
    return updated;
  }

  /// Delete item from wishlist
  Future<void> deleteItem(String wishlistId, String userId) async {
    await _service.deleteWishlistItem(wishlistId, userId);
    _items.removeWhere((w) => w.wishlistId == wishlistId);
    notifyListeners();
  }

  /// Checks if a wishlisted item matches any currently active personal or shared household inventory
  DuplicateMatch? checkOwnership(
    WishlistItemModel wishItem,
    VanityProvider vanityProv, {
    List<VanityItemModel> sharedHouseholdItems = const [],
    Map<String, String> memberEmails = const {},
  }) {
    final matches = vanityProv.checkHouseholdDuplicates(
      barcode: wishItem.barcode,
      name: wishItem.name,
      brand: wishItem.brand,
      sharedHouseholdItems: sharedHouseholdItems,
      memberEmails: memberEmails,
    );

    return matches.isNotEmpty ? matches.first : null;
  }

  /// Import validated backup wishlist items safely merged into current user's wishlist
  Future<int> importBackupWishlist({
    required List<WishlistItemModel> importedItems,
    required String targetUserId,
    bool skipDuplicates = true,
  }) async {
    int count = 0;
    for (int i = 0; i < importedItems.length; i++) {
      final item = importedItems[i];

      if (skipDuplicates) {
        final isDup = _items.any((existing) {
          final eBarcode = existing.barcode?.trim() ?? '';
          final iBarcode = item.barcode?.trim() ?? '';
          if (eBarcode.isNotEmpty && eBarcode == iBarcode) return true;

          final eName = VanityProvider.normalizeText(existing.name);
          final iName = VanityProvider.normalizeText(item.name);
          final eBrand = VanityProvider.normalizeText(existing.brand);
          final iBrand = VanityProvider.normalizeText(item.brand);
          return eName.isNotEmpty && eName == iName && eBrand == iBrand;
        });
        if (isDup) continue;
      }

      final freshId = 'wish_${DateTime.now().millisecondsSinceEpoch}_$i';
      final toSave = item.copyWith(
        wishlistId: freshId,
        userId: targetUserId,
      );

      final created = await _service.addWishlistItem(toSave);
      _items.add(created);
      count++;
    }

    notifyListeners();
    return count;
  }

  /// Restore one wishlist entry exactly as given (id preserved; idempotent). Throws
  /// [VanitySyncException] (after keeping it on this device) if the cloud write fails.
  Future<WishlistItemModel> restoreItem(WishlistItemModel item) async {
    VanitySyncException? syncError;
    WishlistItemModel saved;
    try {
      saved = await _service.addWishlistItem(item, throwOnSyncFailure: true);
    } on VanitySyncException catch (e) {
      saved = item;
      syncError = e;
    }
    _items.removeWhere((w) => w.wishlistId == saved.wishlistId);
    _items.insert(0, saved);
    notifyListeners();
    if (syncError != null) throw syncError;
    return saved;
  }

  /// Purge all in-memory wishlist data upon signout
  void clear() {
    _items = [];
    _isLoading = false;
    _errorMessage = null;
    _searchQuery = '';
    _selectedCategoryFilter = null;
    _service.clearLocalMemory();
    notifyListeners();
  }
}
