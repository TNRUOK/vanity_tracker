import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/product_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/countdown_badge.dart';
import '../../widgets/repurchase_dialog.dart';
import 'edit_product_screen.dart';

class ProductDetailScreen extends StatelessWidget {
  final String vanityItemId;

  const ProductDetailScreen({super.key, required this.vanityItemId});

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();
    final item = vanityProv.allItems.firstWhere(
      (i) => i.vanityItemId == vanityItemId,
      orElse: () => const VanityItemModel(vanityItemId: '', productId: '', userId: ''),
    );

    if (item.vanityItemId.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Product not found')),
      );
    }

    final product = item.product;
    final brand = product?.brand ?? '';
    final name = product?.name ?? 'Cosmetic Product';
    final pao = product?.paoMonths ?? 12;
    final statusColor = AppTheme.getStatusColor(item.daysUntilExpiry, isUnopened: item.openedDate == null, isFinished: item.status == 'finished');
    final isFinished = item.status == 'finished' || item.finishedDate != null;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: Text(brand.isNotEmpty ? brand : 'Product Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: AppTheme.textDark),
            tooltip: 'Edit Details',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EditProductScreen(item: item),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppTheme.statusRed),
            tooltip: 'Delete',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete Product?'),
                  content: const Text('This will permanently remove this item from your vanity.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusRed),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                if (!context.mounted) return;
                await context.read<VanityProvider>().deleteItem(item.vanityItemId);
                if (!context.mounted) return;
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hero Visual Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 15,
                    offset: const Offset(0, 6),
                  ),
                ],
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                children: [
                  if (product?.imageUrl != null && product!.imageUrl!.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        product.imageUrl!,
                        height: 160,
                        fit: BoxFit.contain,
                        errorBuilder: (ctx, err, stack) => _buildHeroPlaceholder(statusColor),
                      ),
                    )
                  else
                    _buildHeroPlaceholder(statusColor),

                  const SizedBox(height: 18),
                  if (brand.isNotEmpty)
                    Text(
                      brand.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textDark,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CountdownBadge(item: item, isCompact: false),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Product Intelligence Card (Full Product Details)
            if (product != null && (product.keyActives != null ||
                product.countryOfOrigin != null ||
                product.packagingType != null ||
                product.skinClaims.isNotEmpty ||
                product.skinType != null ||
                product.texture != null ||
                product.allergens != null ||
                product.certifications.isNotEmpty ||
                product.warnings.isNotEmpty ||
                product.preservatives != null ||
                product.scent != null ||
                product.pH != null)) ...[
              _buildIntelligenceCard(product),
              const SizedBox(height: 16),
            ],

            // Expiry & Timeline Card
            _buildTimelineCard(item, pao, context),
            const SizedBox(height: 16),

            // Financial & Budget Card
            if (item.price != null && item.price! > 0)
              _buildBudgetCard(item),

            if (item.notes != null && item.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildNotesCard(item.notes!),
            ],

            if (product?.ingredients != null && product!.ingredients!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildIngredientsCard(product.ingredients!),
            ],

            const SizedBox(height: 32),

            // Action Buttons
            if (!isFinished) ...[
              if (item.openedDate == null)
                ElevatedButton.icon(
                  onPressed: () async {
                    await context.read<VanityProvider>().markAsOpened(item.vanityItemId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✨ Product marked as opened today!'),
                          backgroundColor: AppTheme.statusGreen,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Mark as Opened Today'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.statusGreen,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: () async {
                    final repurchase = await RepurchaseDialog.show(context, item);
                    if (repurchase != null) {
                      if (!context.mounted) return;
                      await context.read<VanityProvider>().markAsFinished(
                            item.vanityItemId,
                            wouldRepurchase: repurchase,
                          );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('🎉 Product marked as finished and moved to Empties!'),
                          backgroundColor: AppTheme.statusFinished,
                        ),
                      );
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Mark as Finished (Empty)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.statusFinished,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineCard(VanityItemModel item, int paoMonths, BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Timeline & PAO',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
          ),
          const SizedBox(height: 14),
          _buildInfoRow('PAO Guideline', '$paoMonths Months after opening', icon: Icons.av_timer),
          const Divider(height: 16),
          _buildInfoRow(
            'Opened Date',
            item.openedDate != null ? DateFormat('MMMM d, yyyy').format(item.openedDate!) : 'Not opened yet',
            icon: Icons.calendar_today_outlined,
          ),
          const Divider(height: 16),
          _buildInfoRow(
            'Expiry Date',
            item.expiryDate != null ? DateFormat('MMMM d, yyyy').format(item.expiryDate!) : 'Will calculate on open',
            icon: Icons.event_busy_outlined,
          ),
          if (item.finishedDate != null) ...[
            const Divider(height: 16),
            _buildInfoRow(
              'Finished Date',
              DateFormat('MMMM d, yyyy').format(item.finishedDate!),
              icon: Icons.task_alt,
            ),
          ],
          if (item.openedDate != null) ...[
            const Divider(height: 16),
            _buildInfoRow(
              'Days in Use',
              '${item.daysUsed} days',
              icon: Icons.timelapse,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBudgetCard(VanityItemModel item) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Budget & Cost Analysis',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
          ),
          const SizedBox(height: 14),
          _buildInfoRow('Purchase Price', '\$${item.price!.toStringAsFixed(2)}', icon: Icons.attach_money),
          if (item.openedDate != null && item.costPerDay != null) ...[
            const Divider(height: 16),
            _buildInfoRow(
              'Cost Per Day',
              '\$${item.costPerDay!.toStringAsFixed(2)} / day',
              icon: Icons.trending_down,
              highlight: true,
            ),
          ],
          if (item.wouldRepurchase != null) ...[
            const Divider(height: 16),
            _buildInfoRow(
              'Would Repurchase?',
              item.wouldRepurchase! ? 'Yes, Loved It! 👍' : 'No, Skipping 👎',
              icon: Icons.rate_review_outlined,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNotesCard(String notes) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your Notes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
          const SizedBox(height: 8),
          Text(notes, style: const TextStyle(fontSize: 14, color: AppTheme.textDark, height: 1.4)),
        ],
      ),
    );
  }

  Widget _buildIngredientsCard(String ingredients) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Ingredients', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
          const SizedBox(height: 8),
          Text(
            ingredients,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {required IconData icon, bool highlight = false}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: highlight ? AppTheme.primaryRose : AppTheme.textMuted),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
            color: highlight ? AppTheme.primaryRose : AppTheme.textDark,
          ),
        ),
      ],
    );
  }

  Widget _buildIntelligenceCard(ProductModel product) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 16, color: AppTheme.primaryRose),
              const SizedBox(width: 6),
              const Text(
                'Product Details & Intelligence',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
              ),
              const Spacer(),
              if (product.sourceDatabase != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    product.sourceDatabase!,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.textMuted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Primary Metadata Row: Origin, Packaging, Skin Type
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (product.countryOfOrigin != null)
                _buildMetaChip(Icons.public, 'Origin: ${product.countryOfOrigin!}', const Color(0xFFF8FAFC)),
              if (product.packagingType != null)
                _buildMetaChip(Icons.inventory_2_outlined, product.packagingType!, const Color(0xFFF8FAFC)),
              if (product.skinType != null)
                _buildMetaChip(Icons.face_retouching_natural, product.skinType!, const Color(0xFFF3FEF5)),
              if (product.applicationArea != null)
                _buildMetaChip(Icons.place_outlined, product.applicationArea!, const Color(0xFFF0F7FF)),
              if (product.texture != null)
                _buildMetaChip(Icons.water_drop_outlined, product.texture!, const Color(0xFFFFF8F0)),
              if (product.scent != null)
                _buildMetaChip(Icons.air, product.scent!, const Color(0xFFFDF4FF)),
              if (product.pH != null)
                _buildMetaChip(Icons.science, product.pH!, const Color(0xFFF0F4FF)),
            ],
          ),

          // Skin Claims
          if (product.skinClaims.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: product.skinClaims.map((claim) => Chip(
                    avatar: const Icon(Icons.check_circle_outline, size: 14, color: AppTheme.statusGreen),
                    label: Text(claim, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    backgroundColor: AppTheme.statusGreenBg,
                  )).toList(),
            ),
          ],

          // Certifications
          if (product.certifications.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_outlined, size: 15, color: Color(0xFF4CAF50)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Certifications', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: product.certifications.map((cert) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3FEF5),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFF4CAF50).withValues(alpha: 0.3)),
                          ),
                          child: Text(cert, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF2E7D32))),
                        )).toList(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],

          // Key Active Ingredients
          if (product.keyActives != null && product.keyActives!.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.science_outlined, size: 16, color: AppTheme.primaryRose),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Key Active Ingredients', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
                      const SizedBox(height: 2),
                      Text(
                        product.keyActives!,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textDark, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],

          // Preservatives
          if (product.preservatives != null && product.preservatives!.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 10),
            _buildDetailRow(Icons.shield_outlined, 'Preservatives', product.preservatives!, const Color(0xFF6B7280)),
          ],

          // Allergens
          if (product.allergens != null && product.allergens!.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildDetailRow(Icons.warning_amber_outlined, 'Potential Allergens', product.allergens!, const Color(0xFFD97706)),
          ],

          // Fragrance Components
          if (product.fragranceIngredients != null && product.fragranceIngredients!.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildDetailRow(Icons.air, 'Fragrance Components', product.fragranceIngredients!, const Color(0xFF7C3AED)),
          ],

          // Warnings
          if (product.warnings.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 15, color: Color(0xFFD97706)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Usage Warnings', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
                      const SizedBox(height: 4),
                      ...product.warnings.map((w) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('• $w', style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
                      )),
                    ],
                  ),
                ),
              ],
            ),
          ],

          // Source Link
          if (product.barcodeScanUrl != null) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.link, size: 13, color: AppTheme.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Source: ${product.barcodeScanUrl}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetaChip(IconData icon, String label, Color bgColor) {
    return Chip(
      avatar: Icon(icon, size: 13, color: AppTheme.textDark),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      backgroundColor: bgColor,
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value, Color iconColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
              const SizedBox(height: 1),
              Text(value, style: const TextStyle(fontSize: 12, color: AppTheme.textDark, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }



  Widget _buildHeroPlaceholder(Color color) {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(Icons.auto_awesome, color: color, size: 44),
      ),
    );
  }
}
