import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/wishlist_item_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../providers/wishlist_provider.dart';
import '../../theme/app_theme.dart';
import '../product/add_product_screen.dart';

class WishlistScreen extends StatefulWidget {
  const WishlistScreen({super.key});

  @override
  State<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.currentUser != null) {
        context.read<WishlistProvider>().loadWishlist(auth.currentUser!.userId);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wishlistProv = context.watch<WishlistProvider>();
    final vanityProv = context.watch<VanityProvider>();
    final householdProv = context.watch<HouseholdProvider>();
    final auth = context.watch<AuthProvider>();
    final user = auth.currentUser;

    final items = wishlistProv.filteredItems;
    final categories = vanityProv.categories;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('My Beauty Wishlist'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              if (user != null) {
                wishlistProv.loadWishlist(user.userId);
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditWishlistDialog(context),
        backgroundColor: AppTheme.primaryRose,
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('Add Item', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: user == null
          ? const Center(child: Text('Please sign in to view your wishlist.'))
          : Column(
              children: [
                // Search & Filter Header
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    children: [
                      // Search bar
                      TextField(
                        controller: _searchController,
                        onChanged: (val) => wishlistProv.setSearchQuery(val),
                        decoration: InputDecoration(
                          hintText: 'Search wishlist by name, brand...',
                          prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textMuted),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    wishlistProv.setSearchQuery('');
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Category Filter Chips
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: categories.length + 1,
                          separatorBuilder: (context, index) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              final isSelected = wishlistProv.selectedCategoryFilter == null ||
                                  wishlistProv.selectedCategoryFilter == 'all';
                              return ChoiceChip(
                                label: const Text('All'),
                                selected: isSelected,
                                onSelected: (_) => wishlistProv.setCategoryFilter('all'),
                                selectedColor: AppTheme.primaryRose.withValues(alpha: 0.15),
                                labelStyle: TextStyle(
                                  color: isSelected ? AppTheme.primaryRose : AppTheme.textDark,
                                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                  fontSize: 12,
                                ),
                              );
                            }

                            final cat = categories[index - 1];
                            final isSelected = wishlistProv.selectedCategoryFilter == cat.categoryId;
                            return ChoiceChip(
                              label: Text(cat.name),
                              selected: isSelected,
                              onSelected: (_) => wishlistProv.setCategoryFilter(cat.categoryId),
                              selectedColor: AppTheme.primaryRose.withValues(alpha: 0.15),
                              labelStyle: TextStyle(
                                color: isSelected ? AppTheme.primaryRose : AppTheme.textDark,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                fontSize: 12,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // Wishlist Items List
                Expanded(
                  child: wishlistProv.isLoading
                      ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryRose))
                      : items.isEmpty
                          ? _buildEmptyState(context)
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                              itemCount: items.length,
                              separatorBuilder: (context, index) => const SizedBox(height: 12),
                              itemBuilder: (context, index) {
                                final wishItem = items[index];
                                final match = wishlistProv.checkOwnership(
                                  wishItem,
                                  vanityProv,
                                  sharedHouseholdItems: householdProv.sharedItems,
                                  memberEmails: householdProv.memberEmails,
                                );

                                return _buildWishlistCard(
                                  context: context,
                                  item: wishItem,
                                  match: match,
                                  currency: vanityProv.currencySymbol,
                                  userId: user.userId,
                                );
                              },
                            ),
                ),
              ],
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
                color: Color(0xFFFDF2F8),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.bookmark_border_rounded, size: 48, color: AppTheme.primaryRose),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your Wishlist is Empty',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textDark),
            ),
            const SizedBox(height: 8),
            const Text(
              'Save products you want to buy later. We will even warn you if you or a household member already owns them!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _showAddEditWishlistDialog(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add First Wishlist Item'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryRose,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWishlistCard({
    required BuildContext context,
    required WishlistItemModel item,
    required DuplicateMatch? match,
    required String currency,
    required String userId,
  }) {
    final hasMatch = match != null;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: hasMatch ? const Color(0xFFFDE68A) : const Color(0xFFF1ECE8),
          width: hasMatch ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Already-owned warning banner if product is already in vanity
            if (hasMatch) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: match.isHousehold ? const Color(0xFFFAF5FF) : const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: match.isHousehold ? const Color(0xFFD8B4FE) : const Color(0xFFFCD34D),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      match.isHousehold ? Icons.people_alt_rounded : Icons.info_outline_rounded,
                      size: 16,
                      color: match.isHousehold ? const Color(0xFF7E22CE) : const Color(0xFFD97706),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        match.isHousehold
                            ? 'Already owned in Household (${match.ownerEmail ?? "Member"})'
                            : 'Already in your active vanity shelf!',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: match.isHousehold ? const Color(0xFF7E22CE) : const Color(0xFFB45309),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Item Title & Brand
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.brand.isNotEmpty)
                        Text(
                          item.brand.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      Text(
                        item.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textDark,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      button: true,
                      label: 'Edit ${item.name}',
                      child: IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20, color: AppTheme.textMuted),
                        tooltip: 'Edit details',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () => _showAddEditWishlistDialog(context, existingItem: item),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Remove ${item.name} from wishlist',
                      child: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppTheme.statusRed),
                        tooltip: 'Remove from wishlist',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Remove from Wishlist'),
                              content: Text('Are you sure you want to remove "${item.name}" from your wishlist?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusRed),
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('Remove'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true && context.mounted) {
                            await context.read<WishlistProvider>().deleteItem(item.wishlistId, userId);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Metadata Row: Category & Target Price
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    item.categoryId.toUpperCase(),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                  ),
                ),
                if (item.targetPrice != null && item.targetPrice! > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '🎯 Target: $currency${item.targetPrice!.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF059669)),
                    ),
                  ),
                ],
                if (item.barcode != null && item.barcode!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    'Barcode: ${item.barcode}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  ),
                ],
              ],
            ),

            if (item.notes != null && item.notes!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                item.notes!,
                style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, fontStyle: FontStyle.italic),
              ),
            ],

            const SizedBox(height: 14),

            // "Bought this! Move to Vanity Shelf" Action Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _handleMoveToVanityShelf(context, item),
                icon: const Icon(Icons.check_circle_outline_rounded, size: 16),
                label: const Text('I bought this! Move to Shelf'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryRose,
                  side: const BorderSide(color: AppTheme.primaryRose),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleMoveToVanityShelf(BuildContext context, WishlistItemModel wishItem) {
    // Navigate to AddProductScreen pre-filled with wishlist details
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddProductScreen(
          initialBarcode: wishItem.barcode,
        ),
      ),
    );
  }

  void _showAddEditWishlistDialog(BuildContext context, {WishlistItemModel? existingItem}) {
    final auth = context.read<AuthProvider>();
    final userId = auth.currentUser?.userId ?? 'demo_user';
    final isEditing = existingItem != null;

    final nameController = TextEditingController(text: existingItem?.name ?? '');
    final brandController = TextEditingController(text: existingItem?.brand ?? '');
    final barcodeController = TextEditingController(text: existingItem?.barcode ?? '');
    final priceController = TextEditingController(
      text: existingItem?.targetPrice != null ? existingItem!.targetPrice!.toStringAsFixed(2) : '',
    );
    final notesController = TextEditingController(text: existingItem?.notes ?? '');
    String selectedCategory = existingItem?.categoryId ?? 'serum';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(isEditing ? 'Edit Wishlist Item' : 'Add to Wishlist'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: !isEditing,
                  decoration: const InputDecoration(
                    labelText: 'Product Name *',
                    hintText: 'e.g. Niacinamide 10% + Zinc 1%',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: brandController,
                  decoration: const InputDecoration(
                    labelText: 'Brand',
                    hintText: 'e.g. The Ordinary',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: barcodeController,
                  decoration: const InputDecoration(
                    labelText: 'Barcode (Optional)',
                    hintText: 'e.g. 769915190600',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: priceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Target Price (Optional)',
                    hintText: 'e.g. 10.50',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const [
                    DropdownMenuItem(value: 'serum', child: Text('Serum')),
                    DropdownMenuItem(value: 'moisturizer', child: Text('Moisturizer')),
                    DropdownMenuItem(value: 'cleanser', child: Text('Cleanser')),
                    DropdownMenuItem(value: 'sunscreen', child: Text('Sunscreen')),
                    DropdownMenuItem(value: 'toner', child: Text('Toner')),
                    DropdownMenuItem(value: 'mascara', child: Text('Mascara')),
                    DropdownMenuItem(value: 'lipstick', child: Text('Lipstick')),
                    DropdownMenuItem(value: 'other', child: Text('Other')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => selectedCategory = val);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notes (Optional)',
                    hintText: 'e.g. Wait for summer sale, shade #02',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) return;

                final priceVal = double.tryParse(priceController.text.trim().replaceAll('\$', ''));
                final barcodeVal = barcodeController.text.trim().isNotEmpty ? barcodeController.text.trim() : null;
                final notesVal = notesController.text.trim().isNotEmpty ? notesController.text.trim() : null;

                if (isEditing) {
                  final updated = existingItem.copyWith(
                    name: name,
                    brand: brandController.text.trim(),
                    categoryId: selectedCategory,
                    barcode: barcodeVal,
                    clearBarcode: barcodeVal == null,
                    targetPrice: priceVal,
                    clearTargetPrice: priceVal == null,
                    notes: notesVal,
                    clearNotes: notesVal == null,
                  );
                  await context.read<WishlistProvider>().updateItem(updated);
                } else {
                  final newItem = WishlistItemModel(
                    wishlistId: 'wish_${DateTime.now().millisecondsSinceEpoch}',
                    userId: userId,
                    name: name,
                    brand: brandController.text.trim(),
                    categoryId: selectedCategory,
                    barcode: barcodeVal,
                    targetPrice: priceVal,
                    notes: notesVal,
                    createdAt: DateTime.now(),
                  );
                  await context.read<WishlistProvider>().addItem(newItem);
                }

                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(isEditing ? 'Save Changes' : 'Add to Wishlist'),
            ),
          ],
        ),
      ),
    );
  }
}
