import 'package:flutter/foundation.dart';
import '../models/receipt_model.dart';
import '../services/receipt_parser_service.dart';
import '../services/receipt_service.dart';

class ReceiptProvider extends ChangeNotifier {
  final ReceiptService _service = ReceiptService();

  List<ReceiptModel> _receipts = [];
  bool _isLoading = false;
  String? _errorMessage;
  ParsedReceiptDraft? _currentDraft;

  List<ReceiptModel> get receipts => _receipts;
  bool get isLoading => _isLoading;
  String? _loadedForUserId;

  /// True once [loadReceipts] has finished for this user (distinguishes "not loaded yet"
  /// from "no receipts").
  bool hasLoadedFor(String userId) => _loadedForUserId == userId;

  /// The saved receipt with this id, if loaded.
  ReceiptModel? receiptById(String receiptId) {
    for (final r in _receipts) {
      if (r.receiptId == receiptId) return r;
    }
    return null;
  }

  String? get errorMessage => _errorMessage;
  ParsedReceiptDraft? get currentDraft => _currentDraft;

  /// Load confirmed receipts for user
  Future<void> loadReceipts(String userId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _service.initialize();
      _receipts = await _service.getReceipts(userId);
      _errorMessage = _service.lastLoadError;
      _loadedForUserId = userId;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      debugPrint('Error loading receipts: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void setDraft(ParsedReceiptDraft? draft) {
    _currentDraft = draft;
    notifyListeners();
  }

  void clearDraft() {
    _currentDraft = null;
    notifyListeners();
  }

  /// Check if a receipt with identical merchant, date, and total amount already exists
  ReceiptModel? findPotentialDuplicate({
    required String merchant,
    DateTime? date,
    DateTime? purchaseDate,
    required double total,
    String? excludeReceiptId,
  }) {
    final targetDate = date ?? purchaseDate ?? DateTime.now();
    for (final r in _receipts) {
      if (excludeReceiptId != null && r.receiptId == excludeReceiptId) continue;

      final sameMerchant = r.merchant.trim().toLowerCase() == merchant.trim().toLowerCase();
      final sameDay =
          r.purchaseDate.year == targetDate.year &&
          r.purchaseDate.month == targetDate.month &&
          r.purchaseDate.day == targetDate.day;
      final sameTotal = (r.totalAmount - total).abs() < 0.01;

      if (sameMerchant && sameDay && sameTotal) {
        return r;
      }
    }
    return null;
  }

  /// Test helper to load receipts directly
  void loadReceiptsFromList(List<ReceiptModel> list) {
    _receipts = List.from(list);
    notifyListeners();
  }

  /// Save confirmed receipt record
  /// Idempotent on receiptId. Rethrows [ReceiptSyncException] after recording the
  /// locally-saved receipt so the UI can tell the user it was not synced.
  Future<ReceiptModel> saveReceipt(ReceiptModel receipt) async {
    ReceiptSyncException? syncError;
    try {
      await _service.saveReceipt(receipt);
    } on ReceiptSyncException catch (e) {
      syncError = e;
    }
    _receipts.removeWhere((r) => r.receiptId == receipt.receiptId);
    _receipts.insert(0, receipt);
    _currentDraft = null;
    notifyListeners();
    if (syncError != null) throw syncError;
    return receipt;
  }

  /// Delete a receipt
  Future<void> deleteReceipt(String receiptId, String userId) async {
    try {
      await _service.deleteReceipt(receiptId, userId);
    } on ReceiptSyncException {
      _receipts.removeWhere((r) => r.receiptId == receiptId);
      notifyListeners();
      rethrow;
    }
    _receipts.removeWhere((r) => r.receiptId == receiptId);
    notifyListeners();
  }

  /// Total spending from confirmed receipts denominated in matching currency
  double totalReceiptSpendingForCurrency(String currencySymbol) {
    return _receipts.where((r) => r.currency == currencySymbol).fold(0.0, (sum, r) => sum + r.totalAmount);
  }

  /// Returns map of foreign currencies and their respective totals
  Map<String, double> getForeignCurrencyTotals(String domesticCurrency) {
    final foreignTotals = <String, double>{};
    for (final r in _receipts) {
      if (r.currency != domesticCurrency) {
        foreignTotals[r.currency] = (foreignTotals[r.currency] ?? 0.0) + r.totalAmount;
      }
    }
    return foreignTotals;
  }

  Map<String, double> foreignCurrencyTotals(String domesticCurrency) => getForeignCurrencyTotals(domesticCurrency);

  /// Import validated backup receipts safely merged into current user's purchase history
  Future<int> importBackupReceipts({
    required List<ReceiptModel> importedReceipts,
    required String targetUserId,
    bool skipDuplicates = true,
    Map<String, String> itemKeyMapping = const {},
    Map<String, String>? vanityItemIdMapping,
  }) async {
    final mapping = vanityItemIdMapping ?? itemKeyMapping;
    int count = 0;
    for (int i = 0; i < importedReceipts.length; i++) {
      final receipt = importedReceipts[i];

      if (skipDuplicates) {
        final isDup = findPotentialDuplicate(
          merchant: receipt.merchant,
          date: receipt.purchaseDate,
          total: receipt.totalAmount,
        );
        if (isDup != null) continue;
      }

      final freshId = 'rec_${DateTime.now().millisecondsSinceEpoch}_$i';

      // Remap linked item IDs if old item IDs were remapped during inventory import
      final remappedItems = receipt.items.map((item) {
        if (item.matchedVanityItemId != null && mapping.containsKey(item.matchedVanityItemId)) {
          return item.copyWith(matchedVanityItemId: mapping[item.matchedVanityItemId]);
        }
        return item;
      }).toList();

      final toSave = receipt.copyWith(receiptId: freshId, userId: targetUserId, items: remappedItems);

      try {
        await _service.saveReceipt(toSave);
      } on ReceiptSyncException catch (e) {
        debugPrint('Imported receipt kept locally only: $e');
      }
      _receipts.add(toSave);
      count++;
    }

    notifyListeners();
    return count;
  }

  /// Purge all in-memory receipt data upon signout
  void clear() {
    _receipts = [];
    _isLoading = false;
    _errorMessage = null;
    _currentDraft = null;
    _loadedForUserId = null;
    _service.clearLocalMemory();
    notifyListeners();
  }
}
