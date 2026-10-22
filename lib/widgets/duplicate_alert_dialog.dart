import 'package:flutter/material.dart';
import '../models/duplicate_match_model.dart';
import '../models/vanity_item_model.dart';
import '../screens/product/product_detail_screen.dart';
import '../theme/app_theme.dart';
import 'countdown_badge.dart';
import 'shared_item_viewer.dart';

/// What the user decided after a duplicate warning when adding a product.
enum DuplicateDecision {
  addPersonal, // a new, separate item owned by the user, kept private
  addShared, // a new, separate item owned by the user, shared with their household
  cancel, // add nothing
}

/// Duplicate warning shown BEFORE an inventory item is created. It lists every matching
/// item the user may see (their own, and items household members chose to share), says
/// why it matched and how strong the match is, and lets the user view the existing item.
class DuplicateAlertDialog extends StatelessWidget {
  final List<DuplicateMatch> matches;

  /// When set, the dialog offers "Add to Personal" / "Add to Shared" instead of the
  /// generic "Add Anyway" (shared only when [canShare]).
  final bool decisionMode;
  final bool canShare;

  DuplicateAlertDialog({
    super.key,
    List<DuplicateMatch>? matches,
    List<VanityItemModel>? duplicates,
    this.decisionMode = false,
    this.canShare = false,
  }) : matches = matches ??
            (duplicates ?? [])
                .map((d) => DuplicateMatch(
                      item: d,
                      source: DuplicateSource.personal,
                      matchType: DuplicateMatchType.exactBarcode,
                    ))
                .toList();

  static Future<bool?> show(BuildContext context, List<VanityItemModel> duplicates) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => DuplicateAlertDialog(duplicates: duplicates),
    );
  }

  /// "Add Anyway" / "Cancel" (used where the destination is already decided, e.g. editing).
  static Future<bool?> showMatches(BuildContext context, List<DuplicateMatch> matches) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => DuplicateAlertDialog(matches: matches),
    );
  }

  /// "Add to Personal" / "Add to Shared" (if [canShare]) / "Don't Add".
  static Future<DuplicateDecision> showDecision(
    BuildContext context,
    List<DuplicateMatch> matches, {
    required bool canShare,
  }) async {
    final result = await showDialog<DuplicateDecision>(
      context: context,
      builder: (ctx) => DuplicateAlertDialog(matches: matches, decisionMode: true, canShare: canShare),
    );
    return result ?? DuplicateDecision.cancel;
  }

  /// "View Existing Item": your own item opens its Product Details; a household member's
  /// shared item is shown read-only, with only what its owner chose to share.
  static Future<void> viewExisting(BuildContext context, DuplicateMatch match) async {
    if (match.isPersonal) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProductDetailScreen(vanityItemId: match.item.vanityItemId)),
      );
      return;
    }
    await showSharedItemDetails(context, match.item, ownerEmail: match.ownerEmail);
  }

  @override
  Widget build(BuildContext context) {
    final hasHousehold = matches.any((m) => m.isHousehold);
    final hasPersonal = matches.any((m) => m.isPersonal);
    final onlyPossible = matches.every((m) => !m.isLikelySame);
    final title = onlyPossible
        ? 'Possible Duplicate'
        : (hasHousehold && !hasPersonal ? 'A Household Member Has This' : 'Duplicate Detected!');
    final intro = [
      if (hasPersonal) 'This product may already be in your own vanity.',
      if (hasHousehold) 'A household member has shared a matching product.',
      onlyPossible
          ? 'It may be a different size or version: check before adding.'
          : 'Check the existing item before opening or buying another. You can still add yours as a '
              'separate item: members can own separate units of the same product.',
    ].join(' ');

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
                  decoration: const BoxDecoration(color: AppTheme.statusAmberBg, shape: BoxShape.circle),
                  child: const Icon(Icons.copy_rounded, color: AppTheme.statusAmber, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              intro,
              key: const ValueKey('duplicate-intro'),
              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: matches.length,
                separatorBuilder: (_, index) => const Divider(height: 16),
                itemBuilder: (context, index) => _matchTile(context, matches[index]),
              ),
            ),
            const SizedBox(height: 20),
            if (!decisionMode)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('duplicate-cancel'),
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
                      key: const ValueKey('duplicate-add-anyway'),
                      onPressed: () => Navigator.of(context).pop(true),
                      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
                      child: const Text('Add Anyway'),
                    ),
                  ),
                ],
              )
            else ...[
              ElevatedButton.icon(
                key: const ValueKey('duplicate-add-personal'),
                onPressed: () => Navigator.of(context).pop(DuplicateDecision.addPersonal),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
                icon: const Icon(Icons.lock_outline_rounded, size: 18),
                label: const Text('Add to Personal Inventory'),
              ),
              if (canShare) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('duplicate-add-shared'),
                  onPressed: () => Navigator.of(context).pop(DuplicateDecision.addShared),
                  icon: const Icon(Icons.people_alt_outlined, size: 18, color: Color(0xFF7E22CE)),
                  label: const Text('Add to Shared Household Inventory', style: TextStyle(color: Color(0xFF7E22CE))),
                ),
              ],
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('duplicate-cancel'),
                onPressed: () => Navigator.of(context).pop(DuplicateDecision.cancel),
                child: const Text("Don't Add", style: TextStyle(color: AppTheme.textMuted)),
              ),
              const Text(
                'Either way a new, separate item is created and owned by you; the existing item is not changed.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _matchTile(BuildContext context, DuplicateMatch match) {
    final dup = match.item;
    final name = dup.product?.name ?? 'Cosmetic Product';
    final brand = dup.product?.brand ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                [if (brand.isNotEmpty) brand, name, if (match.sizeLabel != null) '(${match.sizeLabel})'].join(' '),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: match.isLikelySame ? const Color(0xFFFEE2E2) : const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                match.strengthLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: match.isLikelySame ? AppTheme.statusRed : AppTheme.statusAmber,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          match.whoseLabel,
          style: TextStyle(
            fontSize: 11,
            color: match.isHousehold ? const Color(0xFF6B21A8) : const Color(0xFF475569),
            fontStyle: FontStyle.italic,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(match.matchDescription, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            ),
            CountdownBadge(item: dup, isCompact: true),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('view-existing-${dup.vanityItemId}'),
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            onPressed: () => viewExisting(context, match),
            icon: const Icon(Icons.visibility_outlined, size: 15),
            label: const Text('View Existing Item', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}
