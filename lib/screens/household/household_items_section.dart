import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/household_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/countdown_badge.dart';
import '../../widgets/shared_item_viewer.dart';
import '../../widgets/sharing_actions.dart';
import '../product/product_detail_screen.dart';

enum HouseholdItemsView { sharedByMe, sharedWithMe, personal }

/// Household Sharing: Shared by Me / Shared with Me / My Personal Inventory.
///
/// * Shared by Me and Personal come from the user's own unfiltered records
///   (VanityProvider.allActiveItems), so shelf search/filters never hide items here.
/// * Shared with Me comes from the household query, which only returns items other members
///   explicitly shared; private items are never loaded.
/// Sharing changes visibility only: the owner, dates, price and receipt links stay.
class HouseholdItemsSection extends StatefulWidget {
  const HouseholdItemsSection({super.key});

  @override
  State<HouseholdItemsSection> createState() => _HouseholdItemsSectionState();
}

class _HouseholdItemsSectionState extends State<HouseholdItemsSection> {
  HouseholdItemsView _view = HouseholdItemsView.sharedByMe;

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final mine = context.watch<VanityProvider>().allActiveItems;
    final byMe = household.sharedByMe(mine);
    final withMe = household.sharedWithMe;
    final personal = household.privateItems(mine);

    final (items, empty, explain) = switch (_view) {
      HouseholdItemsView.sharedByMe => (
          byMe,
          'You are not sharing any products yet.',
          'Products you own and chose to share. Members can see them; only you can change them. '
              'Stopping sharing keeps the product on your shelf.',
        ),
      HouseholdItemsView.sharedWithMe => (
          withMe,
          'No one in your household has shared a product yet.',
          'Products other members chose to share. You can view them; their owner keeps control.',
        ),
      HouseholdItemsView.personal => (
          personal,
          'All your products are shared.',
          'Your private products. Members cannot see these. Joining a household never shares them automatically.',
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<HouseholdItemsView>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: HouseholdItemsView.sharedByMe,
              label: Text('Shared by Me (${byMe.length})', key: const ValueKey('tab-shared-by-me')),
            ),
            ButtonSegment(
              value: HouseholdItemsView.sharedWithMe,
              label: Text('Shared with Me (${withMe.length})', key: const ValueKey('tab-shared-with-me')),
            ),
            ButtonSegment(
              value: HouseholdItemsView.personal,
              label: Text('Private (${personal.length})', key: const ValueKey('tab-private')),
            ),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.first),
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: AppTheme.primaryRose.withValues(alpha: 0.15),
            selectedForegroundColor: AppTheme.primaryRose,
            textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        Text(explain, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        const SizedBox(height: 10),
        if (_view == HouseholdItemsView.sharedWithMe && !household.isSharedDataAvailable)
          Container(
            key: const ValueKey('shared-with-me-error'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12)),
            child: const Text(
              'Products shared with you could not be loaded (offline or no permission). Pull down to retry.',
              style: TextStyle(fontSize: 12),
            ),
          )
        else if (items.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFF1ECE8)),
            ),
            child: Text(empty, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textMuted)),
          )
        else
          ...items.map((item) => _tile(context, household, item)),
      ],
    );
  }

  Widget _tile(BuildContext context, HouseholdProvider household, VanityItemModel item) {
    final p = item.product;
    final category = CategoryModel.defaultCategories.where((c) => c.categoryId == p?.categoryId).firstOrNull?.name;
    final details = [if (p?.volume != null && p!.volume!.isNotEmpty) p.volume!, ?category].join(' · ');
    final isOthers = _view == HouseholdItemsView.sharedWithMe;
    final owner = isOthers ? (household.memberEmails[item.userId] ?? 'a household member') : 'You';

    return Card(
      key: ValueKey('household-item-${item.vanityItemId}'),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFF1ECE8)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => isOthers
            ? showSharedItemDetails(context, item, ownerEmail: household.memberEmails[item.userId])
            : Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ProductDetailScreen(vanityItemId: item.vanityItemId)),
              ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                isOthers
                    ? Icons.people_alt_rounded
                    : (_view == HouseholdItemsView.sharedByMe ? Icons.share_rounded : Icons.lock_outline_rounded),
                color: const Color(0xFF7E22CE),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((p?.brand ?? '').isNotEmpty)
                      Text(p!.brand.toUpperCase(),
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textMuted)),
                    Text(p?.name ?? 'Product',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            isOthers
                                ? 'Shared by $owner'
                                : (_view == HouseholdItemsView.sharedByMe ? 'Owned by you · shared' : 'Owned by you · private'),
                            style: const TextStyle(fontSize: 11, color: Color(0xFF6B21A8)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        CountdownBadge(item: item, isCompact: true),
                      ],
                    ),
                  ],
                ),
              ),
              if (_view == HouseholdItemsView.sharedByMe)
                TextButton(
                  key: ValueKey('stop-sharing-${item.vanityItemId}'),
                  onPressed: () => changeSharingWithFeedback(context, item, false),
                  child: const Text('Stop sharing', style: TextStyle(color: AppTheme.statusRed, fontSize: 12)),
                )
              else if (_view == HouseholdItemsView.personal && household.hasHousehold)
                TextButton(
                  key: ValueKey('share-${item.vanityItemId}'),
                  onPressed: () => changeSharingWithFeedback(context, item, true),
                  child: const Text('Share', style: TextStyle(color: Color(0xFF7E22CE), fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
