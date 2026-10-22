import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/receipt_model.dart';
import '../models/vanity_item_model.dart';
import '../models/wishlist_item_model.dart';
import '../providers/receipt_provider.dart';
import '../providers/vanity_provider.dart';
import '../providers/wishlist_provider.dart';
import 'backup_service.dart';
import 'database_service.dart';
import 'receipt_service.dart';
import 'wishlist_service.dart';

// ═══════════════════════════════ EXPORT ═══════════════════════════════

/// Everything read for one export, and what could not be read.
class BackupSnapshot {
  final List<VanityItemModel> items;
  final List<ReceiptModel> receipts;
  final List<WishlistItemModel> wishlist;
  final String currencySymbol;

  /// Sources that could not be read from the account (the export is then partial).
  final List<String> omissions;

  /// Records included that exist only on this device (not synced to the account yet).
  final int deviceOnlyCount;

  const BackupSnapshot({
    required this.items,
    required this.receipts,
    required this.wishlist,
    required this.currencySymbol,
    this.omissions = const [],
    this.deviceOnlyCount = 0,
  });

  bool get isComplete => omissions.isEmpty;
  int get totalRecords => items.length + receipts.length + wishlist.length;
}

class BackupExportService {
  /// Reads every supported record of [userId] from the source of truth (Firestore when
  /// configured, plus anything saved only on this device), never from screen state, so
  /// shelf filters or screens that were never opened cannot leave data out.
  static Future<BackupSnapshot> collect({required String userId, required String currencySymbol}) async {
    if (userId.isEmpty) throw ArgumentError('Sign in to export a backup.');
    await ReceiptService().initialize();
    await WishlistService().initialize();
    final results = await Future.wait([
      DatabaseService().readVanityItemsForBackup(userId),
      ReceiptService().readReceiptsForBackup(userId),
      WishlistService().readWishlistForBackup(userId),
    ]);
    final items = results[0] as OwnedRecords<VanityItemModel>;
    final receipts = results[1] as OwnedRecords<ReceiptModel>;
    final wishlist = results[2] as OwnedRecords<WishlistItemModel>;
    return BackupSnapshot(
      items: items.records,
      receipts: receipts.records,
      wishlist: wishlist.records,
      currencySymbol: currencySymbol,
      omissions: [for (final r in results) if (r.error != null) r.error!],
      deviceOnlyCount: items.deviceOnlyCount + receipts.deviceOnlyCount + wishlist.deviceOnlyCount,
    );
  }

  /// Builds the file content and checks it by reading it back with the import validator
  /// before it is offered to the user. Throws [StateError] if the check fails.
  static String buildVerifiedJson(BackupSnapshot s, {required String userId}) {
    final json = BackupService.exportToJson(
      items: s.items,
      receipts: s.receipts,
      wishlist: s.wishlist,
      currencySymbol: s.currencySymbol,
      sourceUserId: userId,
      omissions: s.omissions,
    );
    final check = BackupService.validateBackup(json, const []);
    final emptyOk = s.totalRecords == 0 && check.errorMessage != null && check.invalidReasons.isEmpty;
    if (!emptyOk &&
        (!check.isValid ||
            check.invalidReasons.isNotEmpty ||
            check.validItems.length != s.items.length ||
            check.validReceipts.length != s.receipts.length ||
            check.validWishlist.length != s.wishlist.length)) {
      throw StateError(
        'The backup could not be verified (${check.errorMessage ?? check.invalidReasons.take(3).join('; ')}). '
        'No file was created.',
      );
    }
    return json;
  }
}

// ═══════════════════════════════ RESTORE ═══════════════════════════════

enum RestoreAction {
  create, // not in this account yet
  skipIdentical, // already present with the same content (re-import)
  conflictKeep, // same record exists with different content: current version kept (default)
  conflictReplace, // same record exists with different content: backup version written
  possibleDuplicate, // a different record looks like the same product/receipt: skipped
  invalid, // could not be read from the file
}

class RestoreEntry {
  final String type; // 'Product', 'Receipt', 'Wishlist item'
  final String label;
  final String backupId;
  final String targetId;
  final RestoreAction action;
  final String? note;
  final Object? record; // what would be written (for create / conflictReplace)

  const RestoreEntry({
    required this.type,
    required this.label,
    required this.backupId,
    required this.targetId,
    required this.action,
    this.note,
    this.record,
  });

  bool get writes => action == RestoreAction.create || action == RestoreAction.conflictReplace;
}

class RestorePlan {
  final List<RestoreEntry> entries;
  final List<String> invalidReasons;
  final String? backupCurrency;
  final bool replaceConflicts;
  final bool importPossibleDuplicates;
  final bool crossAccount;

  /// Receipt lines whose product is neither in the backup nor in this account.
  final int unresolvedLinks;

  const RestorePlan({
    required this.entries,
    required this.invalidReasons,
    required this.backupCurrency,
    required this.replaceConflicts,
    required this.importPossibleDuplicates,
    required this.crossAccount,
    required this.unresolvedLinks,
  });

  int count(RestoreAction a, [String? type]) =>
      entries.where((e) => e.action == a && (type == null || e.type == type)).length;
  int get toWrite => entries.where((e) => e.writes).length;
  int get conflicts => count(RestoreAction.conflictKeep) + count(RestoreAction.conflictReplace);
}

enum RestoreOutcome { written, writtenNotSynced, failed }

class RestoreResult {
  final RestoreEntry entry;
  final RestoreOutcome outcome;
  final String? error;
  const RestoreResult(this.entry, this.outcome, [this.error]);
}

class RestoreReport {
  final RestorePlan plan;
  final List<RestoreResult> results;

  /// Written records that were found again in the app's data after the restore.
  final int verified;

  const RestoreReport(this.plan, this.results, this.verified);

  int get written => results.where((r) => r.outcome != RestoreOutcome.failed).length;
  int get notSynced => results.where((r) => r.outcome == RestoreOutcome.writtenNotSynced).length;
  int get failed => results.where((r) => r.outcome == RestoreOutcome.failed).length;
  int get skipped =>
      plan.count(RestoreAction.skipIdentical) + plan.count(RestoreAction.conflictKeep) + plan.count(RestoreAction.possibleDuplicate);
  bool get isComplete => failed == 0 && verified == written;

  String get summary {
    final parts = <String>[
      '$written record${written == 1 ? '' : 's'} restored'
          '${plan.count(RestoreAction.conflictReplace) > 0 ? ' (${plan.count(RestoreAction.conflictReplace)} replaced)' : ''}',
      if (skipped > 0) '$skipped skipped (already present, kept, or possible duplicates)',
      if (plan.invalidReasons.isNotEmpty) '${plan.invalidReasons.length} unreadable in the file',
      if (failed > 0) '$failed FAILED: run the same import again to retry only those',
      if (notSynced > 0) '$notSynced saved on this device but not synced yet',
    ];
    return parts.join(' · ');
  }
}

/// Plans and performs a restore as a safe merge.
///
/// Identity: records keep their backup ids, so importing the same file twice finds them
/// again ("already present") instead of creating copies. When the backup came from a
/// different account, ids are prefixed deterministically for this account, so another
/// user's documents can never be overwritten and repeated imports stay idempotent.
///
/// Nothing is ever deleted. An existing record with different content is kept unless the
/// user explicitly chooses to replace conflicts (the app stores no modification time, so it
/// cannot tell which version is newer). Records that look like an existing product or
/// receipt under a different id are skipped by default.
///
/// Writes are one document at a time (no Firestore batch, so no 500-write batch limit),
/// products first, then receipts (with links remapped), then wishlist. A failed write
/// leaves earlier writes in place; since every write is idempotent, importing the same
/// file again retries only what is missing.
class BackupRestoreService {
  static String _accountPrefix(String userId) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(userId)) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return 'rst_${h.toRadixString(16).padLeft(8, '0')}_';
  }

  static String _canonical(Map<String, dynamic> m) => jsonEncode(m);

  static RestorePlan plan({
    required BackupValidationResult backup,
    required String targetUserId,
    required List<VanityItemModel> currentItems,
    required List<ReceiptModel> currentReceipts,
    required List<WishlistItemModel> currentWishlist,
    bool replaceConflicts = false,
    bool importPossibleDuplicates = false,
  }) {
    final entries = <RestoreEntry>[];
    final prefix = _accountPrefix(targetUserId);
    String mapId(String id, String ownerId) =>
        (ownerId.isEmpty || ownerId == targetUserId || id.startsWith(prefix)) ? id : '$prefix$id';
    var crossAccount = false;

    // ---- Products
    final itemsById = {for (final i in currentItems) i.vanityItemId: i};
    final itemIdMap = <String, String>{}; // backup id -> id in this account
    for (final b in backup.validItems) {
      final sameOwner = b.userId.isEmpty || b.userId == targetUserId;
      if (!sameOwner) crossAccount = true;
      final targetId = mapId(b.vanityItemId, b.userId);
      var restored = b.copyWith(vanityItemId: targetId, userId: targetUserId);
      if (!sameOwner) {
        // Household sharing belongs to the original account's household.
        restored = restored.copyWith(isSharedWithHousehold: false, clearSharedHouseholdId: true);
      }
      final label = [b.product?.brand, b.product?.name].where((s) => s != null && s.isNotEmpty).join(' ');
      final existing = itemsById[targetId];
      itemIdMap[b.vanityItemId] = targetId;
      if (existing != null) {
        final identical = _canonical(existing.toMap()) == _canonical(restored.toMap());
        entries.add(RestoreEntry(
          type: 'Product',
          label: label,
          backupId: b.vanityItemId,
          targetId: targetId,
          action: identical
              ? RestoreAction.skipIdentical
              : (replaceConflicts ? RestoreAction.conflictReplace : RestoreAction.conflictKeep),
          note: identical ? null : 'This product exists with different details',
          record: restored,
        ));
        continue;
      }
      final lookalike = importPossibleDuplicates ? null : _lookalikeItem(restored, currentItems);
      if (lookalike != null) {
        itemIdMap[b.vanityItemId] = lookalike.vanityItemId; // receipts link to the existing one
        entries.add(RestoreEntry(
          type: 'Product',
          label: label,
          backupId: b.vanityItemId,
          targetId: lookalike.vanityItemId,
          action: RestoreAction.possibleDuplicate,
          note: 'Looks like a product already on your shelf',
        ));
        continue;
      }
      entries.add(RestoreEntry(
        type: 'Product',
        label: label,
        backupId: b.vanityItemId,
        targetId: targetId,
        action: RestoreAction.create,
        record: restored,
      ));
    }

    // ---- Receipts (links remapped to the products as they exist after the restore)
    final knownItemIds = {...itemsById.keys, ...itemIdMap.values};
    var unresolvedLinks = 0;
    final receiptsById = {for (final r in currentReceipts) r.receiptId: r};
    for (final b in backup.validReceipts) {
      final sameOwner = b.userId.isEmpty || b.userId == targetUserId;
      if (!sameOwner) crossAccount = true;
      final targetId = mapId(b.receiptId, b.userId);
      final lines = b.items.map((line) {
        final link = line.matchedVanityItemId;
        if (link == null || link.isEmpty) return line;
        final mapped = itemIdMap[link] ?? mapId(link, b.userId);
        if (!knownItemIds.contains(mapped)) unresolvedLinks++;
        return line.copyWith(matchedVanityItemId: mapped);
      }).toList();
      final restored = b.copyWith(receiptId: targetId, userId: targetUserId, items: lines);
      final label = '${b.merchant} ${b.currency}${b.totalAmount.toStringAsFixed(2)}';
      final existing = receiptsById[targetId];
      if (existing != null) {
        final identical = _canonical(existing.toMap()) == _canonical(restored.toMap());
        entries.add(RestoreEntry(
          type: 'Receipt',
          label: label,
          backupId: b.receiptId,
          targetId: targetId,
          action: identical
              ? RestoreAction.skipIdentical
              : (replaceConflicts ? RestoreAction.conflictReplace : RestoreAction.conflictKeep),
          note: identical ? null : 'This receipt exists with different details',
          record: restored,
        ));
        continue;
      }
      final lookalike = importPossibleDuplicates
          ? null
          : currentReceipts.where((r) {
              final sameDay = r.purchaseDate.year == b.purchaseDate.year &&
                  r.purchaseDate.month == b.purchaseDate.month &&
                  r.purchaseDate.day == b.purchaseDate.day;
              return sameDay &&
                  r.currency == b.currency &&
                  (r.totalAmount - b.totalAmount).abs() < 0.01 &&
                  r.merchant.trim().toLowerCase() == b.merchant.trim().toLowerCase();
            }).firstOrNull;
      entries.add(RestoreEntry(
        type: 'Receipt',
        label: label,
        backupId: b.receiptId,
        targetId: lookalike?.receiptId ?? targetId,
        action: lookalike != null ? RestoreAction.possibleDuplicate : RestoreAction.create,
        note: lookalike != null ? 'Same store, date and total as a saved receipt' : null,
        record: lookalike != null ? null : restored,
      ));
    }

    // ---- Wishlist
    final wishById = {for (final w in currentWishlist) w.wishlistId: w};
    for (final b in backup.validWishlist) {
      final sameOwner = b.userId.isEmpty || b.userId == targetUserId;
      if (!sameOwner) crossAccount = true;
      final targetId = mapId(b.wishlistId, b.userId);
      final restored = b.copyWith(wishlistId: targetId, userId: targetUserId);
      final existing = wishById[targetId];
      final label = [b.brand, b.name].where((s) => s.isNotEmpty).join(' ');
      if (existing != null) {
        final identical = _canonical(existing.toMap()) == _canonical(restored.toMap());
        entries.add(RestoreEntry(
          type: 'Wishlist item',
          label: label,
          backupId: b.wishlistId,
          targetId: targetId,
          action: identical
              ? RestoreAction.skipIdentical
              : (replaceConflicts ? RestoreAction.conflictReplace : RestoreAction.conflictKeep),
          record: restored,
        ));
        continue;
      }
      final lookalike = importPossibleDuplicates
          ? null
          : currentWishlist.where((w) {
              final bc = (w.barcode ?? '').trim();
              if (bc.isNotEmpty && bc == (b.barcode ?? '').trim()) return true;
              return VanityProvider.normalizeText(w.name) == VanityProvider.normalizeText(b.name) &&
                  VanityProvider.normalizeText(w.brand) == VanityProvider.normalizeText(b.brand);
            }).firstOrNull;
      entries.add(RestoreEntry(
        type: 'Wishlist item',
        label: label,
        backupId: b.wishlistId,
        targetId: lookalike?.wishlistId ?? targetId,
        action: lookalike != null ? RestoreAction.possibleDuplicate : RestoreAction.create,
        record: lookalike != null ? null : restored,
      ));
    }

    return RestorePlan(
      entries: entries,
      invalidReasons: backup.invalidReasons,
      backupCurrency: backup.currencySymbol,
      replaceConflicts: replaceConflicts,
      importPossibleDuplicates: importPossibleDuplicates,
      crossAccount: crossAccount,
      unresolvedLinks: unresolvedLinks,
    );
  }

  static VanityItemModel? _lookalikeItem(VanityItemModel b, List<VanityItemModel> current) {
    final bBarcode = b.product?.barcode.trim() ?? '';
    final bName = VanityProvider.normalizeText(b.product?.name ?? '');
    final bBrand = VanityProvider.normalizeText(b.product?.brand ?? '');
    for (final e in current) {
      final eBarcode = e.product?.barcode.trim() ?? '';
      // Same barcode AND same opening/finish state: a second unopened bottle of the same
      // product is legitimately a separate item, so barcode alone is not enough.
      final sameState = e.openedDate == b.openedDate && e.finishedDate == b.finishedDate;
      if (bBarcode.isNotEmpty && eBarcode == bBarcode && sameState) return e;
      final eName = VanityProvider.normalizeText(e.product?.name ?? '');
      final eBrand = VanityProvider.normalizeText(e.product?.brand ?? '');
      if (bName.isNotEmpty && eName == bName && eBrand == bBrand && sameState && e.price == b.price) return e;
    }
    return null;
  }

  /// Writes the planned records in a safe order and verifies them afterwards.
  static Future<RestoreReport> execute(
    RestorePlan plan, {
    required VanityProvider vanity,
    required ReceiptProvider receipts,
    required WishlistProvider wishlist,
  }) async {
    final results = <RestoreResult>[];
    for (final type in ['Product', 'Receipt', 'Wishlist item']) {
      for (final e in plan.entries.where((e) => e.type == type && e.writes)) {
        try {
          switch (e.record) {
            case final VanityItemModel item:
              await vanity.restoreItem(item);
            case final ReceiptModel receipt:
              await receipts.saveReceipt(receipt);
            case final WishlistItemModel w:
              await wishlist.restoreItem(w);
          }
          results.add(RestoreResult(e, RestoreOutcome.written));
        } on VanitySyncException catch (err) {
          results.add(RestoreResult(e, RestoreOutcome.writtenNotSynced, err.message));
        } on ReceiptSyncException catch (err) {
          results.add(RestoreResult(e, RestoreOutcome.writtenNotSynced, err.message));
        } catch (err) {
          debugPrint('Restore of ${e.type} ${e.backupId} failed: $err');
          results.add(RestoreResult(e, RestoreOutcome.failed, err.toString().replaceAll('Exception: ', '')));
        }
      }
    }

    // Verify: every written record must now be present in the app's data.
    final itemIds = vanity.allItems.map((i) => i.vanityItemId).toSet();
    final receiptIds = receipts.receipts.map((r) => r.receiptId).toSet();
    final wishIds = wishlist.allItems.map((w) => w.wishlistId).toSet();
    var verified = 0;
    for (final r in results.where((r) => r.outcome != RestoreOutcome.failed)) {
      final ids = switch (r.entry.type) { 'Product' => itemIds, 'Receipt' => receiptIds, _ => wishIds };
      if (ids.contains(r.entry.targetId)) verified++;
    }
    return RestoreReport(plan, results, verified);
  }
}
