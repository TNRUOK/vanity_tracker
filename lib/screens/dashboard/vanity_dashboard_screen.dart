import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/category_chip.dart';
import '../../widgets/repurchase_dialog.dart';
import '../../widgets/vanity_item_card.dart';
import '../product/add_product_screen.dart';
import '../product/product_detail_screen.dart';

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
                    IconButton(
                      icon: const Icon(Icons.logout_rounded, color: AppTheme.textMuted),
                      tooltip: 'Sign Out',
                      onPressed: () async {
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
                          await context.read<AuthProvider>().signOut();
                        }
                      },
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
                            ? () async {
                                await vanityProv.markAsOpened(item.vanityItemId);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('✨ Product marked as opened today!'),
                                      backgroundColor: AppTheme.statusGreen,
                                    ),
                                  );
                                }
                              }
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
