import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/receipt_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../providers/wishlist_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/category_chip.dart';
import '../../widgets/opened_feedback.dart';
import '../../widgets/repurchase_dialog.dart';
import '../../widgets/vanity_item_card.dart';
import '../backup/backup_restore_screen.dart';
import '../guide/pao_guide_screen.dart';
import '../household/household_screen.dart';
import '../product/add_product_screen.dart';
import '../product/product_detail_screen.dart';
import '../receipt/receipt_history_screen.dart';
import '../receipt/receipt_scanner_screen.dart';
import '../wishlist/wishlist_screen.dart';

class VanityDashboardScreen extends StatefulWidget {
  const VanityDashboardScreen({super.key});

  @override
  State<VanityDashboardScreen> createState() => _VanityDashboardScreenState();
}

class _VanityDashboardScreenState extends State<VanityDashboardScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();
    final wishlistProv = context.watch<WishlistProvider>();
    final auth = context.watch<AuthProvider>();
    final items = vanityProv.activeItems;
    final userName = auth.currentUser?.name ?? 'Skincare Lover';

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // App Header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hello, $userName ✨',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'My Vanity Shelf',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            color: AppTheme.textDark,
                          ),
                        ),
                      ],
                    ),
                    Semantics(
                      button: true,
                      label: 'Sign Out',
                      child: IconButton(
                        icon: const Icon(Icons.logout_rounded, color: AppTheme.textMuted),
                        tooltip: 'Sign Out',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () => _confirmSignOut(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Always-Visible Navigation Action Strip
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Row(
                  children: [
                    _buildNavActionCard(
                      context: context,
                      icon: Icons.favorite_rounded,
                      iconColor: AppTheme.primaryRose,
                      title: 'Wishlist',
                      subtitle: '${wishlistProv.items.length} items',
                      semanticLabel: 'Wishlist, ${wishlistProv.items.length} items',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const WishlistScreen()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildNavActionCard(
                      context: context,
                      icon: Icons.receipt_long_rounded,
                      iconColor: const Color(0xFF0D9488),
                      title: 'Scan Receipt',
                      subtitle: 'OCR Scanner',
                      semanticLabel: 'Scan Receipt',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ReceiptScannerScreen()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildNavActionCard(
                      context: context,
                      icon: Icons.history_rounded,
                      iconColor: const Color(0xFF0D9488),
                      title: 'Receipt History',
                      subtitle: 'Past logs',
                      semanticLabel: 'Receipt History',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ReceiptHistoryScreen()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildNavActionCard(
                      context: context,
                      icon: Icons.people_alt_rounded,
                      iconColor: const Color(0xFF7E22CE),
                      title: 'Household',
                      subtitle: 'Shared vanity',
                      semanticLabel: 'Household Sharing',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const HouseholdScreen()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildNavActionCard(
                      context: context,
                      icon: Icons.menu_book_rounded,
                      iconColor: AppTheme.primaryRose,
                      title: 'PAO Guide',
                      subtitle: 'Shelf life',
                      semanticLabel: 'PAO Reference Guide',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PaoGuideScreen()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildNavActionCard(
                      context: context,
                      icon: Icons.import_export_rounded,
                      iconColor: const Color(0xFF2563EB),
                      title: 'Backup / Restore',
                      subtitle: 'JSON data',
                      semanticLabel: 'Backup and Restore',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const BackupRestoreScreen()),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Expiry Quick Status Bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildQuickFilterCard(
                        title: 'All Active',
                        count: vanityProv.totalActiveCount.toString(),
                        color: AppTheme.textDark,
                        bgColor: Colors.white,
                        isSelected: vanityProv.selectedStatusFilter == null || vanityProv.selectedStatusFilter == 'all',
                        onTap: () => vanityProv.setStatusFilter('all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildQuickFilterCard(
                        title: 'Expiring',
                        count: vanityProv.expiringSoonCount.toString(),
                        color: AppTheme.statusAmber,
                        bgColor: AppTheme.statusAmberBg,
                        isSelected: vanityProv.selectedStatusFilter == 'expiring',
                        onTap: () => vanityProv.setStatusFilter(vanityProv.selectedStatusFilter == 'expiring' ? 'all' : 'expiring'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildQuickFilterCard(
                        title: 'Expired',
                        count: vanityProv.expiredCount.toString(),
                        color: AppTheme.statusRed,
                        bgColor: AppTheme.statusRedBg,
                        isSelected: vanityProv.selectedStatusFilter == 'expired',
                        onTap: () => vanityProv.setStatusFilter(vanityProv.selectedStatusFilter == 'expired' ? 'all' : 'expired'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Search Bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search products, brands, ingredients...',
                    prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textMuted),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              vanityProv.setSearchQuery('');
                            },
                          )
                        : null,
                    fillColor: Colors.white,
                  ),
                  onChanged: (val) => vanityProv.setSearchQuery(val),
                ),
              ),
            ),

            // Category Chips List
            SliverToBoxAdapter(
              child: SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    CategoryChip(
                      category: const CategoryModel(categoryId: 'all', categoryName: 'All Categories', defaultPaoMonths: 12),
                      isSelected: vanityProv.selectedCategoryFilter == null || vanityProv.selectedCategoryFilter == 'all',
                      onSelected: () => vanityProv.setCategoryFilter('all'),
                    ),
                    ...vanityProv.categories.map((cat) {
                      return CategoryChip(
                        category: cat,
                        isSelected: vanityProv.selectedCategoryFilter == cat.categoryId,
                        onSelected: () => vanityProv.setCategoryFilter(
                          vanityProv.selectedCategoryFilter == cat.categoryId ? 'all' : cat.categoryId,
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),

            // Products List or Empty State
            if (items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildEmptyState(context),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = items[index];
                      return VanityItemCard(
                        item: item,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProductDetailScreen(vanityItemId: item.vanityItemId),
                            ),
                          );
                        },
                        onMarkOpened: item.openedDate == null
                            // One tap starts the PAO countdown, so the confirmation offers Undo.
                            ? () => markOpenedWithFeedback(ScaffoldMessenger.of(context), vanityProv, item.vanityItemId)
                            : null,
                        onMarkFinished: () async {
                          final repurchase = await RepurchaseDialog.show(context, item);
                          if (repurchase != null && context.mounted) {
                            await vanityProv.markAsFinished(item.vanityItemId, wouldRepurchase: repurchase);
                          }
                        },
                      );
                    },
                    childCount: items.length,
                  ),
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 90)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirm == true && context.mounted) {
      context.read<HouseholdProvider>().clear();
      context.read<VanityProvider>().clear();
      context.read<WishlistProvider>().clear();
      context.read<ReceiptProvider>().clear();
      await context.read<AuthProvider>().signOut();
    }
  }

  Widget _buildNavActionCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFF1ECE8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textDark,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickFilterCard({
    required String title,
    required String count,
    required Color color,
    required Color bgColor,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? bgColor : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? color : const Color(0xFFE2E8F0),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(
              count,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? color : AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFFFDF2F4),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.spa_outlined,
                size: 48,
                color: AppTheme.primaryRose,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Your Vanity is Empty',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textDark),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add your opened serums, creams, and makeup to start tracking expiration dates and avoid duplicate purchases.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddProductScreen()),
                );
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add First Product'),
            ),
          ],
        ),
      ),
    );
  }
}
