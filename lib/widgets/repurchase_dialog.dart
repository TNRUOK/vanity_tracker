import 'package:flutter/material.dart';
import '../models/vanity_item_model.dart';
import '../theme/app_theme.dart';

class RepurchaseDialog extends StatefulWidget {
  final VanityItemModel item;

  const RepurchaseDialog({super.key, required this.item});

  static Future<bool?> show(BuildContext context, VanityItemModel item) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => RepurchaseDialog(item: item),
    );
  }

  @override
  State<RepurchaseDialog> createState() => _RepurchaseDialogState();
}

class _RepurchaseDialogState extends State<RepurchaseDialog> {
  bool? _wouldRepurchase = true;

  @override
  Widget build(BuildContext context) {
    final product = widget.item.product;
    final name = product?.name ?? 'Cosmetic Product';
    final brand = product?.brand ?? '';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.statusFinishedBg,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.task_alt_rounded,
                color: AppTheme.statusFinished,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Mark as Finished (Empty)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.textDark,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              brand.isNotEmpty ? '$brand - $name' : name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textMuted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            const Text(
              'Would you repurchase this product?',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.textDark,
              ),
            ),
            const SizedBox(height: 14),

            // Choice Chips (Yes / No)
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _wouldRepurchase = true),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _wouldRepurchase == true
                            ? AppTheme.statusGreenBg
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _wouldRepurchase == true
                              ? AppTheme.statusGreen
                              : const Color(0xFFE2E8F0),
                          width: _wouldRepurchase == true ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.thumb_up_rounded,
                            color: _wouldRepurchase == true
                                ? AppTheme.statusGreen
                                : AppTheme.textMuted,
                            size: 24,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Yes! Loved it',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _wouldRepurchase == true
                                  ? AppTheme.statusGreen
                                  : AppTheme.textDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _wouldRepurchase = false),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _wouldRepurchase == false
                            ? AppTheme.statusRedBg
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _wouldRepurchase == false
                              ? AppTheme.statusRed
                              : const Color(0xFFE2E8F0),
                          width: _wouldRepurchase == false ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.thumb_down_rounded,
                            color: _wouldRepurchase == false
                                ? AppTheme.statusRed
                                : AppTheme.textMuted,
                            size: 24,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'No, pass',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _wouldRepurchase == false
                                  ? AppTheme.statusRed
                                  : AppTheme.textDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(null),
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
                    onPressed: () => Navigator.of(context).pop(_wouldRepurchase),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryRose,
                    ),
                    child: const Text('Confirm'),
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
