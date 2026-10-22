import 'package:flutter/foundation.dart';
import '../models/category_model.dart';
import '../models/product_model.dart';
import '../models/receipt_model.dart';
import '../providers/receipt_provider.dart';
import '../providers/vanity_provider.dart';
import '../services/database_service.dart';
import 'receipt_service.dart';

/// What the user chose to do with one receipt line.
enum LineItemAction {
  ignore, // keep on the receipt only
  matchExisting, // this line is the purchase of an item already on the shelf
  createNew, // add a new item to the Vanity Inventory
}

/// One reviewed receipt line, as confirmed by the user.
class ReceiptLineRequest {
  /// Stable per line for the lifetime of the draft; used to derive idempotent ids.
  final String lineId;
  final String description;
  final int quantity;
  final double unitPrice;
  final LineItemAction action;
  final String? matchedVanityItemId;
  final bool updateShelfPrice;

  // Only for [LineItemAction.createNew]
  final String brand;

  /// Category chosen/confirmed in review; null = uncategorized (saved as other with an
  /// unknown source, never as an invented category).
  final String? categoryId;
  final CategorySource categorySource;

  /// Line total exactly as stored on an already-saved receipt. When set it is kept as is
  /// (re-saving a receipt from history must not change its historical amounts).
  final double? storedLineTotal;

  /// Only for [LineItemAction.createNew]: create the new item shared with the user's
  /// household (still owned by the user) instead of private.
  final bool shareWithHousehold;

  const ReceiptLineRequest({
    required this.lineId,
    required this.description,
    required this.quantity,
    required this.unitPrice,
    this.action = LineItemAction.ignore,
    this.matchedVanityItemId,
    this.updateShelfPrice = false,
    this.brand = '',
    this.categoryId,
    this.categorySource = CategorySource.user,
    this.storedLineTotal,
    this.shareWithHousehold = false,
  });

  double get lineTotal => storedLineTotal ?? double.parse((unitPrice * quantity).toStringAsFixed(2));
}

enum LineOutcome {
  keptOnReceipt,
  linkedExisting,
  added,
  addedNotSynced, // created on this device, cloud write failed
  failed,
}

class ReceiptLineResult {
  final String lineId;
  final String description;
  final LineOutcome outcome;
  final String? vanityItemId;
  final String? error;

  const ReceiptLineResult({
    required this.lineId,
    required this.description,
    required this.outcome,
    this.vanityItemId,
    this.error,
  });

  bool get wantsInventory => outcome != LineOutcome.keptOnReceipt && outcome != LineOutcome.linkedExisting;
  bool get isAddedToInventory => outcome == LineOutcome.added || outcome == LineOutcome.addedNotSynced;
}

class ReceiptSaveReport {
  final bool receiptSaved;
  final String? receiptError; // receipt not saved at all
  final String? receiptSyncWarning; // saved on this device only
  final List<ReceiptLineResult> lines;

  const ReceiptSaveReport({
    required this.receiptSaved,
    this.receiptError,
    this.receiptSyncWarning,
    required this.lines,
  });

  int get requestedCount => lines.where((l) => l.wantsInventory).length;
  int get addedCount => lines.where((l) => l.isAddedToInventory).length;
  int get failedCount => lines.where((l) => l.outcome == LineOutcome.failed).length;
  int get notSyncedCount => lines.where((l) => l.outcome == LineOutcome.addedNotSynced).length;
  bool get isComplete => receiptSaved && failedCount == 0;

  /// User-facing summary built only from actual outcomes.
  String get message {
    final parts = <String>[];
    if (!receiptSaved) {
      parts.add('Receipt NOT saved: ${receiptError ?? 'unknown error'}.');
    } else if (receiptSyncWarning != null) {
      parts.add('Receipt saved on this device but not synced to your account.');
    } else {
      parts.add('Receipt saved.');
    }
    if (requestedCount == 0) {
      parts.add('No products were selected for Vanity Inventory (you can add them later from Receipt History).');
    } else if (failedCount == 0) {
      parts.add('$addedCount of $requestedCount item${requestedCount == 1 ? '' : 's'} added to Vanity Inventory.');
    } else {
      final failedNames = lines.where((l) => l.outcome == LineOutcome.failed).map((l) => l.description).join(', ');
      parts.add(
        '$addedCount of $requestedCount items added to Vanity Inventory. '
        '$failedCount failed ($failedNames); tap Retry failed items.',
      );
    }
    if (notSyncedCount > 0) {
      parts.add(
        '$notSyncedCount item${notSyncedCount == 1 ? ' is' : 's are'} saved on this device but not synced yet.',
      );
    }
    return parts.join(' ');
  }
}

/// Saves a reviewed receipt and adds the selected lines to the Vanity Inventory using the
/// existing providers (single source of truth).
///
/// * Every line is processed (no early exit); each line gets its own result.
/// * Inventory ids are derived from receipt id + line id, so retries, double taps and
///   ambiguous timeouts rewrite the same record instead of creating duplicates.
/// * Lines are processed one at a time (bounded concurrency).
/// * Purchase date is NOT used as an opening date: new items start unopened.
/// * Spending is recorded once, by the receipt; inventory items are linked to their
///   receipt line so their price is not counted a second time.
class ReceiptInventoryService {
  /// Deterministic inventory id for a receipt line (Firestore-safe characters only).
  static String inventoryIdFor(String receiptId, String lineId) =>
      'item_${receiptId}_$lineId'.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  static Future<ReceiptSaveReport> saveReceiptAndInventory({
    required ReceiptModel receiptHeader,
    required List<ReceiptLineRequest> lines,
    required String userId,
    required VanityProvider vanity,
    required ReceiptProvider receipts,
    Set<String> alreadyAddedLineIds = const {},
    // The user's household, for lines whose destination is "shared".
    String? householdId,
  }) async {
    if (userId.isEmpty) {
      throw ArgumentError('A signed-in user is required to save receipts.');
    }

    final results = <ReceiptLineResult>[];
    final receiptItems = <ReceiptItemModel>[];

    for (final line in lines) {
      String? linkedId;
      ReceiptLineResult result;

      switch (line.action) {
        case LineItemAction.ignore:
          result = ReceiptLineResult(
            lineId: line.lineId,
            description: line.description,
            outcome: LineOutcome.keptOnReceipt,
          );

        case LineItemAction.matchExisting:
          linkedId = line.matchedVanityItemId;
          var outcome = LineOutcome.linkedExisting;
          String? error;
          if (linkedId == null) {
            outcome = LineOutcome.failed;
            error = 'No shelf item selected to match.';
          } else if (line.updateShelfPrice && line.unitPrice > 0) {
            // Price is only changed on explicit request (default keeps the shelf price).
            final existing = vanity.allItems.where((i) => i.vanityItemId == linkedId).firstOrNull;
            if (existing != null) {
              try {
                await vanity.updateItem(
                  existing.copyWith(price: line.unitPrice, priceCurrency: receiptHeader.effectiveCurrencyCode),
                );
              } catch (e) {
                error = 'Linked, but the shelf price could not be updated ($e).';
              }
            }
          }
          result = ReceiptLineResult(
            lineId: line.lineId,
            description: line.description,
            outcome: outcome,
            vanityItemId: linkedId,
            error: error,
          );

        case LineItemAction.createNew:
          final itemId = inventoryIdFor(receiptHeader.receiptId, line.lineId);
          if (alreadyAddedLineIds.contains(line.lineId)) {
            // Succeeded in an earlier attempt: do not write it again.
            linkedId = itemId;
            result = ReceiptLineResult(
              lineId: line.lineId,
              description: line.description,
              outcome: LineOutcome.added,
              vanityItemId: itemId,
            );
            break;
          }
          if (line.shareWithHousehold && (householdId == null || householdId.isEmpty)) {
            // Never silently substitute "private" for a requested "shared" destination.
            result = ReceiptLineResult(
              lineId: line.lineId,
              description: line.description,
              outcome: LineOutcome.failed,
              error: 'Not added: sharing needs a household. Choose Personal or join a household.',
            );
            break;
          }
          try {
            final created = await vanity.addItem(
              vanityItemId: itemId,
              product: _productFor(line, receiptHeader.receiptId),
              userId: userId,
              price: line.unitPrice > 0 ? line.unitPrice : null,
              // The receipt's currency (null when the receipt's currency is not established).
              priceCurrency: receiptHeader.effectiveCurrencyCode,
              inferPriceCurrency: false,
              notes: line.quantity > 1 ? 'Receipt line quantity: ${line.quantity}' : null,
              throwOnSyncFailure: true,
              isSharedWithHousehold: line.shareWithHousehold,
              sharedHouseholdId: line.shareWithHousehold ? householdId : null,
              // openedDate intentionally omitted: buying a product is not opening it.
            );
            linkedId = created.vanityItemId;
            result = ReceiptLineResult(
              lineId: line.lineId,
              description: line.description,
              outcome: LineOutcome.added,
              vanityItemId: linkedId,
            );
          } on VanitySyncException catch (e) {
            linkedId = itemId; // exists locally; a retry rewrites the same id
            result = ReceiptLineResult(
              lineId: line.lineId,
              description: line.description,
              outcome: LineOutcome.addedNotSynced,
              vanityItemId: itemId,
              error: e.message,
            );
          } catch (e) {
            debugPrint('Receipt line ${line.lineId} could not be added: $e');
            result = ReceiptLineResult(
              lineId: line.lineId,
              description: line.description,
              outcome: LineOutcome.failed,
              error: e.toString().replaceAll('Exception: ', ''),
            );
          }
      }

      results.add(result);
      receiptItems.add(
        ReceiptItemModel(
          itemId: line.lineId,
          description: line.description,
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          totalPrice: line.lineTotal,
          // Only lines whose inventory record exists are linked (failed lines stay unlinked).
          matchedVanityItemId: linkedId,
        ),
      );
    }

    // Saving the receipt once (same id on every retry) records the spending exactly once.
    final receipt = receiptHeader.copyWith(userId: userId, items: receiptItems);
    try {
      await receipts.saveReceipt(receipt);
      return ReceiptSaveReport(receiptSaved: true, lines: results);
    } on ReceiptSyncException catch (e) {
      return ReceiptSaveReport(receiptSaved: true, receiptSyncWarning: e.message, lines: results);
    } catch (e) {
      return ReceiptSaveReport(
        receiptSaved: false,
        receiptError: e.toString().replaceAll('Exception: ', ''),
        lines: results,
      );
    }
  }

  static ProductModel _productFor(ReceiptLineRequest line, String receiptId) {
    final category = CategoryModel.byId(line.categoryId);
    return ProductModel(
      productId: 'prod_${inventoryIdFor(receiptId, line.lineId)}',
      barcode: '', // receipts carry no barcode; left empty rather than invented
      name: line.description.trim(),
      brand: line.brand.trim(), // never the store name
      categoryId: category?.categoryId ?? 'other',
      categorySource: category != null ? line.categorySource : CategorySource.unknown,
      // A receipt says nothing about PAO: use the chosen category's default and record it
      // as such (shown as an unverified estimate the user can correct). It only drives an
      // expiry once the user marks the product as opened. Uncategorized = PAO unknown.
      paoMonths: category?.defaultPaoMonths ?? 12,
      paoSource: category != null ? PaoSource.categoryDefault : PaoSource.unknown,
      sourceDatabase: 'Receipt',
      createdAt: DateTime.now(),
    );
  }
}
