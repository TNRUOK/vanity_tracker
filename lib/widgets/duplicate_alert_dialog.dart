import 'package:flutter/material.dart';
import '../models/vanity_item_model.dart';
import '../theme/app_theme.dart';
import 'countdown_badge.dart';

class DuplicateAlertDialog extends StatelessWidget {
  final List<VanityItemModel> duplicates;

  const DuplicateAlertDialog({super.key, required this.duplicates});

  static Future<bool?> show(BuildContext context, List<VanityItemModel> duplicates) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => DuplicateAlertDialog(duplicates: duplicates),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.statusAmberBg,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.copy_rounded,
                    color: AppTheme.statusAmber,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Duplicate Detected!',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textDark,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'You already have this product active in your vanity. Check your existing bottle before opening or buying another:',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textMuted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),

            // Duplicate item preview
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: duplicates.length,
                separatorBuilder: (_, index) => const Divider(height: 12),
                itemBuilder: (context, index) {
                  final dup = duplicates[index];
                  final name = dup.product?.name ?? 'Cosmetic Product';
                  final brand = dup.product?.brand ?? '';
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              brand.isNotEmpty ? '$brand - $name' : name,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textDark,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            CountdownBadge(item: dup, isCompact: true),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textMuted,
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryRose,
                    ),
                    child: const Text('Add Anyway'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
