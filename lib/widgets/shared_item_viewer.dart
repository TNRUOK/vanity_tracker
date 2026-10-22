import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/category_model.dart';
import '../models/vanity_item_model.dart';
import '../theme/app_theme.dart';

/// Read-only view of an item another household member shared. It shows only product
/// identity and status (no price, notes, receipt or purchase details), and offers no
/// edit actions: the owner keeps control of their item.
Future<void> showSharedItemDetails(BuildContext context, VanityItemModel item, {String? ownerEmail}) {
  final p = item.product;
  final fmt = DateFormat('MMM d, yyyy');
  final category = CategoryModel.defaultCategories.where((c) => c.categoryId == p?.categoryId).firstOrNull?.name;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: ValueKey('shared-item-view-${item.vanityItemId}'),
      title: Text([p?.brand, p?.name].where((s) => s != null && s.isNotEmpty).join(' ')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ownerEmail != null && ownerEmail.isNotEmpty ? 'Shared by $ownerEmail' : 'Shared by a household member'),
          if (p?.volume != null && p!.volume!.isNotEmpty) Text('Size: ${p.volume}'),
          if (category != null) Text('Category: $category'),
          Text(item.openedDate != null ? 'Opened ${fmt.format(item.openedDate!)}' : 'Not opened yet'),
          if (item.effectiveExpiryDate != null) Text('Expires ${fmt.format(item.effectiveExpiryDate!)}'),
          const SizedBox(height: 8),
          const Text(
            'This item belongs to another member. You can view it here; only its owner can change or stop '
            'sharing it. Adding your own product never changes it.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
    ),
  );
}
