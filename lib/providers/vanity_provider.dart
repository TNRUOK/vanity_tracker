import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/category_model.dart';
import '../models/duplicate_match_model.dart';
import '../models/product_model.dart';
import '../models/receipt_model.dart';
import '../models/vanity_item_model.dart';
import '../services/budget_calculator.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../utils/barcode_utils.dart';
import '../utils/currency.dart';
import '../utils/ingredient_normalizer.dart';

export '../models/duplicate_match_model.dart';

class SpendingBreakdown {
  final double total;
  final double receiptTotal;
  final double directItemsTotal;
  final int matchedReceiptsCount;
  final int directItemsCount;

  const SpendingBreakdown({
    required this.total,
    required this.receiptTotal,
    required this.directItemsTotal,
    required this.matchedReceiptsCount,
    required this.directItemsCount,
  });
}

class VanityProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  static const _uuid = Uuid();
  final NotificationService _notifications = NotificationService();

  List<VanityItemModel> _items = [];
  List<CategoryModel> _categories = List.from(CategoryModel.defaultCategories);
  bool _isLoading = false;
  String _searchQuery = '';
  String? _selectedCategoryFilter;
  String? _selectedStatusFilter; // 'all', 'active', 'expiring', 'expired'
  String _budgetCurrencyCode = 'USD';

  List<VanityItemModel> get allItems => _items;
  List<VanityItemModel> get items => _items;
  List<CategoryModel> get categories => _categories;
  bool get isLoading => _isLoading;
  String get searchQuery => _searchQuery;
  String? get selectedCategoryFilter => _selectedCategoryFilter;
  String? get selectedStatusFilter => _selectedStatusFilter;

  /// The currency Budget Stats are shown in (a display preference only: stored amounts
  /// keep their own currency).
  CurrencyInfo get budgetCurrency => Currencies.byCode(_budgetCurrencyCode) ?? Currencies.usd;
  String get budgetCurrencyCode => budgetCurrency.code;
  String get currencySymbol => budgetCurrency.symbol;

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

  /// Every not-finished item, ignoring the dashboard's search/category/status filters.
  /// Use this when the user must pick from their whole shelf (e.g. matching a receipt line).
  List<VanityItemModel> get allActiveItems =>
      _items.where((i) => i.status != 'finished' && i.finishedDate == null).toList();

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

  /// The app's routines, in display order. A routine is the set of not-finished items whose
  /// `routine_tags` contain its tag.
  static const routineTagOrder = ['AM', 'PM', 'Weekly'];

  /// Items in one routine, in the routines' existing step order (soonest expiry first,
  /// unopened last). Not affected by the shelf's search/category/status filters, so a
  /// product added to a routine always shows up there.
  List<VanityItemModel> routineItems(String tag) {
    final list = allActiveItems.where((i) => i.routineTags.contains(tag)).toList();
    list.sort((a, b) {
      final aDays = a.daysUntilExpiry;
      final bDays = b.daysUntilExpiry;
      if (aDays == null && bDays == null) return 0;
      if (aDays == null) return 1;
      if (bDays == null) return -1;
      return aDays.compareTo(bDays);
    });
    return list;
  }

  /// Routine items
  List<VanityItemModel> get amRoutineItems => routineItems('AM');

  List<VanityItemModel> get pmRoutineItems => routineItems('PM');

  List<VanityItemModel> get weeklyRoutineItems => routineItems('Weekly');

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

  /// Budget figures in [target] (default: the budget currency) from every receipt and the
  /// user's items, converted with [rates] (see BudgetCalculator).
  BudgetSummary budgetSummary({
    required List<ReceiptModel> receipts,
    CurrencyInfo? target,
    RateLookup rates = BudgetCalculator.noRates,
  }) =>
      BudgetCalculator.compute(receipts: receipts, items: _items, target: target ?? budgetCurrency, rates: rates);

  /// Spending in one currency WITHOUT conversion: receipts and unlinked shelf prices that
  /// are recorded in that currency. An item linked to a receipt line (in any currency) is
  /// paid for by that receipt and is never counted again. For converted totals use
  /// [budgetSummary] with rates.
  SpendingBreakdown calculateUnifiedSpending({
    required List<ReceiptModel> receipts,
    String? currencySymbol,
  }) {
    final target = Currencies.byCode(Currencies.suggestedCodeForLegacySymbol(currencySymbol)) ?? budgetCurrency;
    final s = BudgetCalculator.compute(receipts: receipts, items: _items, target: target);
    return SpendingBreakdown(
      total: target.fromMinor(s.totalMinor),
      receiptTotal: target.fromMinor(s.receiptMinor),
      directItemsTotal: target.fromMinor(s.directMinor),
      matchedReceiptsCount: s.countedReceipts,
      directItemsCount: s.countedDirectItems,
    );
  }

  /// Test helper to load items directly
  void loadItemsFromList(List<VanityItemModel> list) {
    _items = List.from(list);
    notifyListeners();
  }

  double get averageCostPerDayUsed {
    // Only prices recorded in the budget currency (amounts in other currencies are not mixed in).
    final finishedWithPrice = empties
        .where((i) => (i.price ?? 0) > 0 && i.daysUsed > 0 && i.priceCurrency == budgetCurrencyCode)
        .toList();
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
      final prefs = await SharedPreferences.getInstance();
      // Older versions stored only a symbol; "$" was offered there as US Dollar.
      _budgetCurrencyCode = prefs.getString('budget_currency_code') ??
          Currencies.suggestedCodeForLegacySymbol(prefs.getString('user_currency_symbol')) ??
          'USD';
      _categories = CategoryModel.mergeWithDefaults(await _db.getCategories());
      _items = await _db.getVanityItems(userId);
    } catch (e) {
      debugPrint('Error loading vanity items: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Sets the budget display currency (an ISO code; a symbol from older callers is
  /// accepted). Only the display changes: no stored amount is modified.
  Future<void> setCurrency(String codeOrSymbol) async {
    final code = Currencies.byCode(codeOrSymbol)?.code ?? Currencies.suggestedCodeForLegacySymbol(codeOrSymbol);
    if (code == null) return;
    _budgetCurrencyCode = code;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('budget_currency_code', code);
    } catch (e) {
      debugPrint('Error saving currency: $e');
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

  /// Normalize string by lowercasing, stripping punctuation and collapsing whitespace
  static String normalizeText(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static final _sizePattern = RegExp(r'\b(\d+(?:[.,]\d+)?)\s?(ml|l|g|kg|oz|fl\.? ?oz)\b');

  /// Generic product words: a name made of only one of these is never matched by name.
  static const _genericNames = {
    'serum', 'cream', 'cleanser', 'toner', 'moisturizer', 'moisturiser', 'lotion', 'oil', 'mask',
    'balm', 'gel', 'lipstick', 'mascara', 'foundation', 'sunscreen', 'spf', 'perfume', 'fragrance',
    'eye cream', 'face wash', 'shampoo', 'conditioner', 'product', 'item',
  };

  /// "50 ml" / "50ml" / "1.7 fl oz" -> "50ml" / "1.7floz" (null when no size is given).
  static String? _sizeKey(String text) {
    final m = _sizePattern.firstMatch(text.toLowerCase());
    if (m == null) return null;
    return '${m.group(1)!.replaceAll(',', '.')}${m.group(2)!.replaceAll(RegExp(r'[\s.]'), '')}';
  }

  /// Name without size tokens, normalized.
  static String _coreName(String name) => normalizeText(name.toLowerCase().replaceAll(_sizePattern, ' '));

  /// Comparison key that ignores spacing and punctuation ("facial-cleanser" = "facial cleanser").
  static String _compact(String normalized) => normalized.replaceAll(' ', '');

  /// Duplicate detection across the user's own active items and the household items other
  /// members have explicitly shared (the only household items the user may see; private
  /// items are never loaded, so they can never leak through a warning).
  ///
  /// Conservative matching:
  /// * same barcode (UPC-A/EAN-13 spellings are equal) -> likely the same product;
  /// * otherwise the whole normalized name (sizes removed) must be equal, and the name must
  ///   be more than a generic word like "serum"; then brand and size decide between
  ///   "same product" and "possibly the same" (different size, or brand missing).
  /// Different shades/variants have different names, so they do not match.
  List<DuplicateMatch> checkHouseholdDuplicates({
    String? barcode,
    String? name,
    String? brand,
    String? volume,
    String? excludeItemId,
    Set<String> excludeItemIds = const {},
    List<VanityItemModel> sharedHouseholdItems = const [],
    Map<String, String> memberEmails = const {},
  }) {
    final matches = <DuplicateMatch>[];
    // Retail barcodes are compared with UPC-A/EAN-13 equivalence; any other code only exactly.
    String? codeKey(String? raw) => BarcodeUtils.normalize(raw) ?? ((raw ?? '').trim().isEmpty ? null : raw!.trim());
    final ownCode = codeKey(barcode);
    final barcodeForms = ownCode == null
        ? const <String>[]
        : (BarcodeUtils.normalize(barcode) != null ? BarcodeUtils.equivalents(ownCode) : [ownCode]);
    final cleanName = _coreName(name ?? '');
    final cleanBrand = normalizeText(brand ?? '');
    final size = _sizeKey('${volume ?? ''} ${name ?? ''}');
    final nameUsable = cleanName.length >= 3 && !_genericNames.contains(cleanName);

    DuplicateMatchType? matchItem(VanityItemModel item) {
      if (item.vanityItemId == excludeItemId || excludeItemIds.contains(item.vanityItemId)) {
        return null;
      }
      if (item.status == 'finished' || item.finishedDate != null) {
        return null; // Exclude finished items
      }
      final p = item.product;
      if (p == null) return null;

      final pBarcode = codeKey(p.barcode);
      if (pBarcode != null && barcodeForms.contains(pBarcode)) {
        return DuplicateMatchType.exactBarcode;
      }
      // Two different valid barcodes: different products (e.g. sizes or shades).
      if (pBarcode != null && barcodeForms.isNotEmpty) return null;

      final pBrand = normalizeText(p.brand);
      if (!nameUsable) return null;
      final itemName = _compact(_coreName(p.name));
      final candidate = _compact(cleanName);
      // Receipt lines often start with the brand ("The Ordinary Hyaluronic Acid Serum").
      final candidateWithoutBrand = pBrand.isNotEmpty && candidate.startsWith(_compact(pBrand))
          ? candidate.substring(_compact(pBrand).length)
          : null;
      if (candidate != itemName && candidateWithoutBrand != itemName) return null;
      if (cleanBrand.isNotEmpty && pBrand.isNotEmpty && _compact(cleanBrand) != _compact(pBrand)) return null;
      final pSize = _sizeKey('${p.volume ?? ''} ${p.name}');
      if (size != null && pSize != null && size != pSize) return DuplicateMatchType.sameNameDifferentSize;
      if (cleanBrand.isEmpty || pBrand.isEmpty) return DuplicateMatchType.sameNameBrandMissing;
      return DuplicateMatchType.normalizedBrandAndName;
    }

    // 1. Check personal active items (all of them: shelf search/filters must not hide one)
    for (final item in allActiveItems) {
      final matchType = matchItem(item);
      if (matchType != null) {
        matches.add(DuplicateMatch(
          item: item,
          source: DuplicateSource.personal,
          matchType: matchType,
        ));
      }
    }

    // 2. Check authorized shared household items
    for (final item in sharedHouseholdItems) {
      final matchType = matchItem(item);
      if (matchType != null) {
        matches.add(DuplicateMatch(
          item: item,
          source: DuplicateSource.householdShared,
          matchType: matchType,
          ownerEmail: memberEmails[item.userId],
        ));
      }
    }

    return matches;
  }

  /// Add new vanity item
  Future<VanityItemModel> addItem({
    required ProductModel product,
    required String userId,
    DateTime? openedDate,
    DateTime? sealedExpiryDate,
    DatePrecision sealedExpiryPrecision = DatePrecision.day,
    String? batchCode,
    DateTime? manufacturingDate,
    DatePrecision manufacturingDatePrecision = DatePrecision.day,
    double? price,
    // Currency of [price]. When null and [inferPriceCurrency] is true, the price is taken
    // to be in the budget currency (the currency the Add Product form shows).
    String? priceCurrency,
    bool inferPriceCurrency = true,
    String? notes,
    List<String> routineTags = const [],
    bool isSharedWithHousehold = false,
    String? sharedHouseholdId,
    // Stable id for idempotent creation (e.g. one per receipt line): saving again with
    // the same id updates the same record instead of creating a duplicate.
    String? vanityItemId,
    // Report (instead of swallow) a failed cloud write; the local copy is still kept.
    bool throwOnSyncFailure = false,
  }) async {
    // 1. Save product in catalog
    final savedProduct = await _db.saveProduct(product);

    // 2. Compute expiry only if opened and the PAO is known
    final expiryDate = VanityItemModel.paoExpiryFor(openedDate, savedProduct);

    final newItem = VanityItemModel(
      // A timestamp alone collides when several items are added in the same millisecond
      // (e.g. multiple receipt lines), which made later items overwrite earlier ones.
      vanityItemId: vanityItemId ?? 'item_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}',
      productId: savedProduct.productId,
      userId: userId,
      openedDate: openedDate,
      expiryDate: expiryDate,
      sealedExpiryDate: sealedExpiryDate,
      sealedExpiryPrecision: sealedExpiryPrecision,
      batchCode: batchCode,
      manufacturingDate: manufacturingDate,
      manufacturingDatePrecision: manufacturingDatePrecision,
      price: price,
      priceCurrency: price == null ? null : (priceCurrency ?? (inferPriceCurrency ? budgetCurrencyCode : null)),
      notes: notes,
      product: savedProduct,
      routineTags: routineTags,
      isSharedWithHousehold: isSharedWithHousehold,
      sharedHouseholdId: sharedHouseholdId,
    );

    // Resolve accurate status using computedStatus
    final itemToSave = newItem.copyWith(status: newItem.computedStatusString);
    VanityItemModel created;
    VanitySyncException? syncError;
    try {
      created = await _db.addVanityItem(itemToSave, throwOnSyncFailure: throwOnSyncFailure);
    } on VanitySyncException catch (e) {
      created = itemToSave; // kept locally; reported to the caller below
      syncError = e;
    }
    _items.removeWhere((i) => i.vanityItemId == created.vanityItemId);
    _items.add(created);

    // Schedule notifications if effectiveExpiryDate exists
    if (created.effectiveExpiryDate != null) {
      await _notifications.scheduleExpiryNotifications(created);
    }

    notifyListeners();
    if (syncError != null) throw syncError;
    return created;
  }

  /// Mark product as opened today or on an earlier date the user picked. This is the only
  /// way an opening date is set for an existing item; it starts the PAO countdown when the
  /// PAO is known (an unknown PAO leaves the expiry unset instead of assuming one).
  Future<void> markAsOpened(String vanityItemId, {DateTime? openedDate, bool throwOnSyncFailure = false}) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) return;

    final now = DateTime.now();
    final openDate = openedDate ?? now;
    if (openDate.isAfter(now)) {
      throw ArgumentError('The opening date cannot be in the future.');
    }
    final updated = _items[index].copyWith(openedDate: openDate).withRecalculatedExpiry();
    await updateItem(updated, throwOnSyncFailure: throwOnSyncFailure);
  }

  /// Undo an opening (e.g. "Opened Today" tapped by mistake): clears the opening date and
  /// the PAO expiry derived from it. The purchase price, PAO and sealed expiry are kept.
  Future<void> markAsUnopened(String vanityItemId, {bool throwOnSyncFailure = false}) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) return;
    final updated = _items[index].copyWith(clearOpenedDate: true).withRecalculatedExpiry();
    await updateItem(updated, throwOnSyncFailure: throwOnSyncFailure);
  }

  /// Change one item's PAO. Only this inventory item is changed (not its category or other
  /// products); the opening and purchase dates are kept, and the PAO expiry, status and
  /// reminders are recalculated from them. Throws [ArgumentError] for an invalid value and
  /// [VanitySyncException] (after saving on this device) if the cloud write fails.
  Future<VanityItemModel> updatePao(
    String vanityItemId,
    int paoMonths, {
    PaoSource source = PaoSource.user,
  }) async {
    if (paoMonths < ProductModel.minPaoMonths || paoMonths > ProductModel.maxPaoMonths) {
      throw ArgumentError(
        'PAO must be a whole number of months from ${ProductModel.minPaoMonths} to ${ProductModel.maxPaoMonths}.',
      );
    }
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) throw StateError('This product is no longer on your shelf.');
    final item = _items[index];
    final product = item.product;
    if (product == null) {
      throw StateError('This item has no product details. Use Edit Details to add them first.');
    }
    final updated = item
        .copyWith(product: product.copyWith(paoMonths: paoMonths, paoSource: source))
        .withRecalculatedExpiry();
    await updateItem(updated, throwOnSyncFailure: true);
    return updated;
  }

  /// Save this item's ingredient list with its provenance. Repeated ingredients are
  /// removed (same normalized name); an empty [rawList] clears the list. Only this item
  /// changes. Returns how many duplicates were removed. Throws [VanitySyncException]
  /// (after saving on this device) if the cloud write fails.
  Future<int> updateIngredients(
    String vanityItemId,
    String rawList, {
    required IngredientSource source,
    String? context,
  }) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) throw StateError('This product is no longer on your shelf.');
    final item = _items[index];
    final product = item.product;
    if (product == null) {
      throw StateError('This item has no product details. Use Edit Details to add them first.');
    }
    final text = rawList.trim();
    final removed = IngredientNormalizer.duplicateCount(text);
    final ProductModel updatedProduct;
    if (text.isEmpty) {
      updatedProduct = product.copyWith(clearIngredients: true);
    } else {
      final cleaned = IngredientNormalizer.dedupe(text);
      updatedProduct = product.copyWith(
        ingredients: cleaned,
        inci: cleaned,
        ingredientsSource: source,
        ingredientsUpdatedAt: DateTime.now(),
        ingredientsContext: context ?? (source == IngredientSource.user ? 'Entered in the app' : null),
      );
    }
    await updateItem(item.copyWith(product: updatedProduct), throwOnSyncFailure: true);
    return removed;
  }

  /// Replace this item's product data with an already merged version (see
  /// ProductDataMerge), keeping the item's dates and recalculating the PAO expiry.
  Future<VanityItemModel> applyProductData(String vanityItemId, ProductModel merged) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) throw StateError('This product is no longer on your shelf.');
    final updated = _items[index].copyWith(product: merged).withRecalculatedExpiry();
    await updateItem(updated, throwOnSyncFailure: true);
    return updated;
  }

  /// Set which routines (`AM`, `PM`, `Weekly`) contain this item. Membership is a set, so
  /// repeated taps or retries never create duplicate steps; nothing is written when the
  /// membership is unchanged. The inventory item itself is reused, never copied.
  /// Returns false when nothing changed.
  Future<bool> setRoutineMembership(String vanityItemId, Set<String> routineTags) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) throw StateError('This product is no longer on your shelf.');
    final item = _items[index];
    final unknown = routineTags.where((t) => !routineTagOrder.contains(t));
    if (unknown.isNotEmpty) throw ArgumentError('Unknown routine: ${unknown.join(', ')}');

    // Keep any legacy tags the app does not manage, then the routines in display order.
    final next = <String>[
      ...item.routineTags.where((t) => !routineTagOrder.contains(t)).toSet(),
      ...routineTagOrder.where(routineTags.contains),
    ];
    final current = item.routineTags.toSet();
    if (current.length == next.length && current.containsAll(next) && item.routineTags.length == next.length) {
      return false;
    }
    await updateItem(item.copyWith(routineTags: next), throwOnSyncFailure: true);
    return true;
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

  /// Restore product from Empties back to active shelf
  Future<void> restoreFromEmpties(String vanityItemId) async {
    final index = _items.indexWhere((i) => i.vanityItemId == vanityItemId);
    if (index < 0) return;

    final item = _items[index];
    final restored = item.copyWith(
      clearFinishedDate: true,
      clearRepurchase: true,
      status: item.openedDate != null ? 'active' : 'unopened',
    );
    final status = restored.computedStatus;
    final statusStr = status == VanityStatus.expired
        ? 'expired'
        : (status == VanityStatus.expiringSoon
            ? 'expiring'
            : (status == VanityStatus.active ? 'active' : 'unopened'));

    final updated = restored.copyWith(status: statusStr);
    await _db.updateVanityItem(updated);
    _items[index] = updated;

    if (updated.effectiveExpiryDate != null) {
      await _notifications.scheduleExpiryNotifications(updated);
    }
    notifyListeners();
  }

  /// Delete vanity item
  Future<void> deleteItem(String vanityItemId) async {
    await _db.deleteVanityItem(vanityItemId);
    await _notifications.cancelItemNotifications(vanityItemId);
    _items.removeWhere((i) => i.vanityItemId == vanityItemId);
    notifyListeners();
  }

  /// Update item details. Reminders are replaced to match the new effective expiry (or
  /// cancelled when there is none). With [throwOnSyncFailure], a failed cloud write is
  /// rethrown as [VanitySyncException] after the change is applied on this device.
  Future<void> updateItem(VanityItemModel updated, {bool throwOnSyncFailure = false}) async {
    final index = _items.indexWhere((i) => i.vanityItemId == updated.vanityItemId);
    if (index >= 0) {
      VanitySyncException? syncError;
      try {
        await _db.updateVanityItem(updated, throwOnSyncFailure: throwOnSyncFailure);
      } on VanitySyncException catch (e) {
        syncError = e;
      }
      _items[index] = updated;
      if (updated.effectiveExpiryDate != null && updated.status != 'finished') {
        await _notifications.scheduleExpiryNotifications(updated);
      } else {
        await _notifications.cancelItemNotifications(updated.vanityItemId);
      }
      notifyListeners();
      if (syncError != null) throw syncError;
    }
  }

  /// Restore one item exactly as given (id, dates, PAO, links preserved), e.g. from a
  /// backup. Idempotent on its id. Reminders are recreated from its dates. Throws
  /// [VanitySyncException] (after keeping it on this device) if the cloud write fails.
  Future<VanityItemModel> restoreItem(VanityItemModel item) async {
    if (item.product != null) await _db.saveProduct(item.product!);
    VanitySyncException? syncError;
    VanityItemModel saved;
    try {
      saved = await _db.addVanityItem(item, throwOnSyncFailure: true);
    } on VanitySyncException catch (e) {
      saved = item;
      syncError = e;
    }
    _items.removeWhere((i) => i.vanityItemId == saved.vanityItemId);
    _items.add(saved);
    if (saved.effectiveExpiryDate != null && saved.status != 'finished' && saved.finishedDate == null) {
      await _notifications.scheduleExpiryNotifications(saved);
    }
    notifyListeners();
    if (syncError != null) throw syncError;
    return saved;
  }

  /// Clear in-memory items on user signout
  void clear() {
    _items = [];
    notifyListeners();
  }

  /// Import validated backup items safely merged into current user's inventory
  Future<int> importBackupItems({
    required List<VanityItemModel> items,
    required String targetUserId,
    required bool skipDuplicates,
    Map<String, String>? idMappingOut,
  }) async {
    int importedCount = 0;
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (skipDuplicates) {
        final isDup = _items.any((existing) {
          final eBarcode = existing.product?.barcode ?? '';
          final iBarcode = item.product?.barcode ?? '';
          if (eBarcode.isNotEmpty && eBarcode == iBarcode) return true;
          final eName = existing.product?.name.toLowerCase().trim() ?? '';
          final iName = item.product?.name.toLowerCase().trim() ?? '';
          final eBrand = existing.product?.brand.toLowerCase().trim() ?? '';
          final iBrand = item.product?.brand.toLowerCase().trim() ?? '';
          return eName.isNotEmpty && eName == iName && eBrand == iBrand;
        });
        if (isDup) continue;
      }

      ProductModel? savedProduct = item.product;
      if (savedProduct != null) {
        savedProduct = await _db.saveProduct(savedProduct);
      }

      final freshId = 'item_${DateTime.now().millisecondsSinceEpoch}_$i';
      if (idMappingOut != null && item.vanityItemId.isNotEmpty) {
        idMappingOut[item.vanityItemId] = freshId;
      }

      final importedItem = item.copyWith(
        vanityItemId: freshId,
        userId: targetUserId,
        product: savedProduct,
      );

      final created = await _db.addVanityItem(importedItem);
      _items.add(created);
      importedCount++;

      if (created.effectiveExpiryDate != null && created.status != 'finished') {
        await _notifications.scheduleExpiryNotifications(created);
      }
    }

    notifyListeners();
    return importedCount;
  }
}
