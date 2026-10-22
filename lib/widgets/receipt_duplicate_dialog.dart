import 'package:flutter/material.dart';
import '../models/vanity_item_model.dart';
import '../providers/vanity_provider.dart';
import '../services/receipt_inventory_service.dart';
import '../theme/app_theme.dart';
import 'duplicate_alert_dialog.dart';

/// A receipt line about to become a new inventory item, and what it may duplicate.
class LineDuplicates {
  final String lineId;
  final String description;
  final List<DuplicateMatch> matches;
  const LineDuplicates(this.lineId, this.description, this.matches);
}

enum ReceiptDuplicateChoice {
  addAnyway, // add every selected line (separate units are legitimate)
  keepOnReceipt, // add the others; keep the possibly duplicated lines on the receipt only
  cancel, // go back; nothing is saved
}

/// Duplicate check for receipt lines that would create inventory items.
///
/// Uses the same matching as manual adds (own active items + items household members
/// explicitly shared). Items created earlier from this same receipt (deterministic ids)
/// are excluded, so retrying a receipt never warns about itself. The receipt itself is
/// always saveable: the check only decides which lines become inventory items, so
/// spending (recorded once, by the receipt) is not affected.
class ReceiptDuplicateCheck {
  static List<LineDuplicates> find({
    required String receiptId,
    required List<({String lineId, String description, String brand})> lines,
    required Iterable<String> allLineIds,
    required VanityProvider vanity,
    List<VanityItemModel> sharedHouseholdItems = const [],
    Map<String, String> memberEmails = const {},
  }) {
    final ownReceiptItems = {for (final id in allLineIds) ReceiptInventoryService.inventoryIdFor(receiptId, id)};
    final found = <LineDuplicates>[];
    for (final l in lines) {
      final matches = vanity.checkHouseholdDuplicates(
        name: l.description,
        brand: l.brand,
        excludeItemIds: ownReceiptItems,
        sharedHouseholdItems: sharedHouseholdItems,
        memberEmails: memberEmails,
      );
      if (matches.isNotEmpty) found.add(LineDuplicates(l.lineId, l.description, matches));
    }
    return found;
  }

  static Future<ReceiptDuplicateChoice> show(BuildContext context, List<LineDuplicates> found) async {
    final choice = await showDialog<ReceiptDuplicateChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(found.length == 1 ? 'Possible duplicate product' : '${found.length} possible duplicate products'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Text(
                'Some products on this receipt match items already in your vanity or shared by your household. '
                'The receipt is saved either way; this only decides which lines become new shelf items.',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
              ),
              for (final f in found) ...[
                const Divider(),
                Text(f.description, style: const TextStyle(fontWeight: FontWeight.w700)),
                for (final m in f.matches)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${m.isHousehold ? (m.ownerEmail != null ? 'Shared by ${m.ownerEmail}' : 'Shared by a household member') : 'In your vanity'}'
                          ': ${[m.item.product?.brand, m.item.product?.name].where((s) => s != null && s.isNotEmpty).join(' ')}'
                          ' (${m.matchDescription})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        key: ValueKey('view-existing-${m.item.vanityItemId}'),
                        onPressed: () => DuplicateAlertDialog.viewExisting(ctx, m),
                        child: const Text('View Existing Item', style: TextStyle(fontSize: 11.5)),
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('receipt-dup-cancel'),
            onPressed: () => Navigator.of(ctx).pop(ReceiptDuplicateChoice.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('receipt-dup-keep'),
            onPressed: () => Navigator.of(ctx).pop(ReceiptDuplicateChoice.keepOnReceipt),
            child: const Text('Keep These on Receipt Only'),
          ),
          ElevatedButton(
            key: const ValueKey('receipt-dup-add-anyway'),
            onPressed: () => Navigator.of(ctx).pop(ReceiptDuplicateChoice.addAnyway),
            child: const Text('Add Anyway'),
          ),
        ],
      ),
    );
    return choice ?? ReceiptDuplicateChoice.cancel;
  }
}
