import 'package:flutter/foundation.dart';
import '../models/category_model.dart';
import '../models/product_model.dart';
import '../models/vanity_item_model.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';

class VanityProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  final NotificationService _notifications = NotificationService();

  List<VanityItemModel> _items = [];
  List<CategoryModel> _categories = List.from(CategoryModel.defaultCategories);
  bool _isLoading = false;
  String _searchQuery = '';
  String? _selectedCategoryFilter;
  String? _selectedStatusFilter; // 'all', 'active', 'expiring', 'expired'

  List<VanityItemModel> get allItems => _items;
  List<CategoryModel> get categories => _categories;
  bool get isLoading => _isLoading;
  String get searchQuery => _searchQuery;
  String? get selectedCategoryFilter => _selectedCategoryFilter;
  String? get selectedStatusFilter => _selectedStatusFilter;

  /// Active vanity items (not finished), sorted by days until expiry ascending
  List<VanityItemModel> get activeItems {
    final list = _items.where((i) => i.status != 'finished' && i.finishedDate == null).toList();

    // Filter by search query
    var filtered = list.where((item) {
      final name = item.product?.name.toLowerCase() ?? '';
      final brand = item.product?.brand.toLowerCase() ?? '';
      final notes = item.notes?.toLowerCase() ?? '';
      final q = _searchQuery.toLowerCase().trim();
      if (q.isEmpty) return true;
      return name.contains(q) || brand.contains(q) || notes.contains(q);
    }).toList();

    // Filter by category
    if (_selectedCategoryFilter != null && _selectedCategoryFilter != 'all') {
      filtered = filtered.where((item) => item.product?.categoryId == _selectedCategoryFilter).toList();
    }

    // Filter by status
    if (_selectedStatusFilter != null && _selectedStatusFilter != 'all') {
      filtered = filtered.where((item) {
        final status = item.computedStatus;
        if (_selectedStatusFilter == 'active') return status == VanityStatus.active;
        if (_selectedStatusFilter == 'expiring') return status == VanityStatus.expiringSoon;
        if (_selectedStatusFilter == 'expired') return status == VanityStatus.expired;
        if (_selectedStatusFilter == 'unopened') return status == VanityStatus.unopened;
        return true;
      }).toList();
    }

    // Sort ascending: Expired (<0) first, then expiring soon (0..30), then active, then unopened
    filtered.sort((a, b) {
      final aDays = a.daysUntilExpiry;
      final bDays = b.daysUntilExpiry;
      if (aDays == null && bDays == null) return 0;
      if (aDays == null) return 1;
      if (bDays == null) return -1;
      return aDays.compareTo(bDays);
    });

    return filtered;
  }

  /// Finished products / Empties history
  List<VanityItemModel> get empties {
    final list = _items.where((i) => i.status == 'finished' || i.finishedDate != null).toList();
    list.sort((a, b) {
      final aDate = a.finishedDate ?? DateTime(2000);
      final bDate = b.finishedDate ?? DateTime(2000);
      return bDate.compareTo(aDate); // Most recently finished first
    });
    return list;
  }

  /// Summary count getters
  int get totalActiveCount => _items.where((i) => i.status != 'finished' && i.finishedDate == null).length;
  int get expiringSoonCount => _items.where((i) => i.computedStatus == VanityStatus.expiringSoon).length;
  int get expiredCount => _items.where((i) => i.computedStatus == VanityStatus.expired).length;
  int get emptiesCount => empties.length;

  /// Budget Analytics
  double get totalActiveVanityValue {
    return activeItems.fold(0.0, (sum, item) => sum + (item.price ?? 0.0));
  }

  double get totalEmptiesValue {
    return empties.fold(0.0, (sum, item) => sum + (item.price ?? 0.0));
  }

  double get totalOverallInvestment {
    return _items.fold(0.0, (sum, item) => sum + (item.price ?? 0.0));
  }

  double get averageCostPerDayUsed {
    final finishedWithPrice = empties.where((i) => (i.price ?? 0) > 0 && i.daysUsed > 0).toList();
    if (finishedWithPrice.isEmpty) return 0.0;
    final totalCost = finishedWithPrice.fold(0.0, (sum, item) => sum + item.costPerDay!);
    return totalCost / finishedWithPrice.length;
  }

  int get repurchaseYesCount => empties.where((i) => i.wouldRepurchase == true).length;
  int get repurchaseNoCount => empties.where((i) => i.wouldRepurchase == false).length;

  // ===================== ACTIONS =====================

  Future<void> loadItems(String userId) async {
    _isLoading = true;
    notifyListeners();

    try {
      _categories = await _db.getCategories();
      _items = await _db.getVanityItems(userId);
    } catch (e) {
      debugPrint('Error loading vanity items: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setCategoryFilter(String? categoryId) {
    _selectedCategoryFilter = categoryId;
    notifyListeners();
  }

  void setStatusFilter(String? status) {
    _selectedStatusFilter = status;
    notifyListeners();
  }

  /// Check if user already owns a product with the same barcode or similar name
  List<VanityItemModel> checkDuplicates({String? barcode, String? name, String? brand}) {
    return activeItems.where((item) {
      if (barcode != null && barcode.isNotEmpty && item.product?.barcode == barcode) {
        return true;
      }
      if (name != null && name.isNotEmpty && brand != null && brand.isNotEmpty) {
        final pName = item.product?.name.toLowerCase() ?? '';
        final pBrand = item.product?.brand.toLowerCase() ?? '';
        if (pBrand.contains(brand.toLowerCase()) && pName.contains(name.toLowerCase())) {
          return true;
        }
      }
      return false;
    }).toList();
  }

  /// Add new vanity item
  Future<VanityItemModel> addItem({
    required ProductModel product,
    required String userId,
    DateTime? openedDate,
    double? price,
    String? notes,
  }) async {
    // 1. Save product in catalog
    final savedProduct = await _db.saveProduct(product);

    // 2. Compute expiry if opened
    DateTime? expiryDate;
    String status = 'unopened';
    if (openedDate != null) {
      expiryDate = VanityItemModel.computeExpiryDate(openedDate, savedProduct.paoMonths);
      final days = expiryDate.difference(DateTime.now()).inDays;
      status = days < 0 ? 'expired' : (days <= 30 ? 'expiring' : 'active');
    }

    final newItem = VanityItemModel(
      vanityItemId: 'item_${DateTime.now().millisecondsSinceEpoch}',
      productId: savedProduct.productId,
      userId: userId,
      openedDate: openedDate,
      expiryDate: expiryDate,
      status: status,
      price: price,
      notes: notes,
      product: savedProduct,
    );

    final created = await _db.addVanityItem(newItem);
    _items.add(created);

    // Schedule notifications if opened
    if (created.openedDate != null) {
      await _notifications.scheduleExpiryNotifications(created);
    }

    notifyListeners();
    return created;
  }

  /// Mark product as opened today or custom date
  Future<void> markAsOpened(String vanityItemId, {DateTime? openedDate}) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) return;

    final openDate = openedDate ?? DateTime.now();
    final item = _items[index];
    final paoMonths = item.product?.paoMonths ?? 12;
    final expiryDate = VanityItemModel.computeExpiryDate(openDate, paoMonths);

    final days = expiryDate.difference(DateTime.now()).inDays;
    final status = days < 0 ? 'expired' : (days <= 30 ? 'expiring' : 'active');

    final updated = item.copyWith(
      openedDate: openDate,
      expiryDate: expiryDate,
      status: status,
    );

    await _db.updateVanityItem(updated);
    _items[index] = updated;

    // Schedule notifications
    await _notifications.scheduleExpiryNotifications(updated);
    notifyListeners();
  }

  /// Mark product as finished (Increment 2)
  Future<void> markAsFinished(
    String vanityItemId, {
    required bool wouldRepurchase,
    DateTime? finishedDate,
  }) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) return;

    final item = _items[index];
    final finishDate = finishedDate ?? DateTime.now();

    final updated = item.copyWith(
      status: 'finished',
      finishedDate: finishDate,
      wouldRepurchase: wouldRepurchase,
    );

    await _db.updateVanityItem(updated);
    _items[index] = updated;

    // Cancel pending expiry notifications
    await _notifications.cancelItemNotifications(vanityItemId);
    notifyListeners();
  }

  /// Delete vanity item
  Future<void> deleteItem(String vanityItemId) async {
    await _db.deleteVanityItem(vanityItemId);
    await _notifications.cancelItemNotifications(vanityItemId);
    _items.removeWhere((i) => i.vanityItemId == vanityItemId);
    notifyListeners();
  }

  /// Update item details
  Future<void> updateItem(VanityItemModel updated) async {
    final index = _items.indexWhere((i) => i.vanityItemId == updated.vanityItemId);
    if (index >= 0) {
      await _db.updateVanityItem(updated);
      _items[index] = updated;
      if (updated.openedDate != null && updated.status != 'finished') {
        await _notifications.scheduleExpiryNotifications(updated);
      }
      notifyListeners();
    }
  }
}
