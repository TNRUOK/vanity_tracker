import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/product_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/household_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/category_classifier.dart';
import '../../services/database_service.dart';
import '../../services/ingredient_conflict_service.dart';
import '../../services/product_data_merge.dart';
import '../../services/product_lookup_service.dart';
import '../../utils/currency.dart';
import '../../utils/ingredient_normalizer.dart';
import '../../widgets/add_to_routine_sheet.dart';
import '../../widgets/countdown_badge.dart';
import '../../widgets/edit_pao_dialog.dart';
import '../../widgets/opened_feedback.dart';
import '../../widgets/sharing_actions.dart';
import '../../widgets/edit_ingredients_dialog.dart';
import '../../widgets/repurchase_dialog.dart';
import 'edit_product_screen.dart';

class ProductDetailScreen extends StatelessWidget {
  final String vanityItemId;

  const ProductDetailScreen({super.key, required this.vanityItemId});

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();
    final householdProv = context.watch<HouseholdProvider>();
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
                  if (product != null) ...[
                    const SizedBox(height: 8),
                    _buildCategoryLine(context, item, product, vanityProv),
                  ],
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
            _buildTimelineCard(item, context),
            const SizedBox(height: 16),

            // Financial & Budget Card
            if (item.price != null && item.price! > 0)
              _buildBudgetCard(item, vanityProv),

            if (item.notes != null && item.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildNotesCard(item.notes!),
            ],

            const SizedBox(height: 16),
            _buildIngredientsCard(context, item, vanityProv),

            if (householdProv.hasHousehold || item.isSharedWithHousehold) ...[
              const SizedBox(height: 16),
              _buildHouseholdSharingCard(context, item, householdProv),
            ],

            const SizedBox(height: 32),

            // Action Buttons
            if (!isFinished) ...[
              OutlinedButton.icon(
                key: const ValueKey('add-to-routine'),
                onPressed: () async {
                  final message = await AddToRoutineSheet.show(context, item.vanityItemId);
                  if (message != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
                  }
                },
                icon: const Icon(Icons.playlist_add_rounded, color: AppTheme.primaryRose),
                label: Text(
                  item.routineTags.any(VanityProvider.routineTagOrder.contains) ? 'Edit Routines' : 'Add to Routine',
                  style: const TextStyle(color: AppTheme.primaryRose, fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: AppTheme.primaryRose),
                ),
              ),
              const SizedBox(height: 12),
              if (item.openedDate == null) ...[
                ElevatedButton.icon(
                  key: const ValueKey('mark-opened-today'),
                  onPressed: () => _markOpened(context, item, null),
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Mark as Opened Today'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.statusGreen,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                TextButton(
                  key: const ValueKey('mark-opened-earlier'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: now,
                      firstDate: DateTime(now.year - 10),
                      lastDate: now,
                      helpText: 'When did you open it?',
                    );
                    if (picked != null && context.mounted) await _markOpened(context, item, picked);
                  },
                  child: const Text('Opened on an earlier date?'),
                ),
              ] else ...[
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
                TextButton(
                  key: const ValueKey('undo-opening'),
                  onPressed: () => _confirmUndoOpening(context, item),
                  child: const Text('Not opened yet? Clear the opening date'),
                ),
              ],
            ] else ...[
              ElevatedButton.icon(
                onPressed: () async {
                  await context.read<VanityProvider>().restoreFromEmpties(item.vanityItemId);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('✨ Product restored to your active Vanity Shelf!'),
                        backgroundColor: AppTheme.statusGreen,
                      ),
                    );
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(Icons.undo_rounded),
                label: const Text('Restore to Active Shelf'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryRose,
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

  /// Explicitly mark as opened (today when [date] is null), with an Undo for a mistaken tap.
  Future<void> _markOpened(BuildContext context, VanityItemModel item, DateTime? date) =>
      markOpenedWithFeedback(ScaffoldMessenger.of(context), context.read<VanityProvider>(), item.vanityItemId,
          openedDate: date);

  Future<void> _confirmUndoOpening(BuildContext context, VanityItemModel item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the opening date?'),
        content: Text(
          'Use this only if the product has not been opened. The opening date '
          '(${DateFormat('MMMM d, yyyy').format(item.openedDate!)}) and the PAO expiry calculated from it will be '
          'removed, and expiry reminders cancelled. The PAO, price and receipt link are kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            key: const ValueKey('confirm-undo-opening'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear Opening Date'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    await context.read<VanityProvider>().markAsUnopened(item.vanityItemId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Opening date cleared. The product is unopened again.')),
    );
  }

  Future<void> _editPao(BuildContext context, VanityItemModel item) async {
    final result = await EditPaoDialog.show(context, item);
    if (result == null || !context.mounted) return;
    final months = result.months;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await context.read<VanityProvider>().updatePao(item.vanityItemId, months, source: result.source);
      final expiry = updated.expiryDate;
      final String text;
      if (result.source == PaoSource.unknown) {
        text = 'PAO marked as unknown. No PAO expiry is calculated until you enter one.';
      } else if (updated.openedDate == null) {
        text = 'PAO saved: $months months. The countdown starts when you mark the product as opened.';
      } else {
        text = 'PAO saved: $months months. PAO expiry recalculated: ${DateFormat('MMM d, yyyy').format(expiry!)}.';
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(text),
          backgroundColor: AppTheme.statusGreen,
        ),
      );
    } on VanitySyncException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('PAO saved: $months months. ${e.message}')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('PAO not saved: ${e.toString().replaceAll(RegExp(r'^\w+Error: '), '')}'), backgroundColor: AppTheme.statusRed),
      );
    }
  }

  /// Look the product up again by barcode and offer the differences for confirmation.
  /// Values the user confirmed are never replaced unless the user ticks that they want the
  /// database value.
  Future<void> _refreshProductData(BuildContext context, VanityItemModel item) async {
    final product = item.product;
    if (product == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final prov = context.read<VanityProvider>();
    messenger.showSnackBar(const SnackBar(content: Text('Looking up the product...'), duration: Duration(seconds: 2)));
    final result = await ProductLookupService.lookupBarcode(product.barcode, forceRefresh: true);
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    if (!result.found || result.product == null || result.source?.startsWith('Offline') == true) {
      messenger.showSnackBar(SnackBar(
        content: Text(result.errorMessage ??
            'No online record was found for this barcode. You can scan the label or enter the details yourself.'),
      ));
      return;
    }
    final sourceName = result.source ?? 'the product database';
    var acceptPao = false;
    var acceptIngredients = false;
    ProductMergeResult merge() => ProductDataMerge.merge(
          current: product,
          fetched: result.product!,
          sourceName: sourceName,
          acceptDatabasePao: acceptPao,
          acceptDatabaseIngredients: acceptIngredients,
        );
    final initial = merge();
    if (!initial.hasChanges && initial.discrepancies.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text('$sourceName has nothing new for this product'
            '${result.product!.paoSource != PaoSource.productDatabase ? ' (it lists no PAO)' : ''}.'),
      ));
      return;
    }

    final apply = await showDialog<ProductMergeResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final current = merge();
          return AlertDialog(
            title: Text('Update from $sourceName?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (current.changes.isEmpty) const Text('No changes would be made.'),
                  for (final c in current.changes)
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $c', style: const TextStyle(fontSize: 13))),
                  if (result.product!.paoSource != PaoSource.productDatabase)
                    const Text('This record lists no PAO, so the PAO is not changed.', style: TextStyle(fontSize: 12)),
                  for (final d in initial.discrepancies) ...[
                    const Divider(),
                    Text(d.explanation, style: const TextStyle(fontSize: 12.5, color: AppTheme.statusAmber)),
                    CheckboxListTile(
                      key: ValueKey('accept-db-${d.field}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: d.field == 'pao' ? acceptPao : acceptIngredients,
                      onChanged: (v) => setDialogState(() {
                        if (d.field == 'pao') {
                          acceptPao = v ?? false;
                        } else {
                          acceptIngredients = v ?? false;
                        }
                      }),
                      title: Text('Use the database value (${d.fetchedValue}) instead of ${d.currentValue}',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(result.attribution ?? '', style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
              ElevatedButton(
                key: const ValueKey('apply-product-data'),
                onPressed: current.hasChanges ? () => Navigator.of(ctx).pop(current) : null,
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (apply == null) return;
    try {
      await prov.applyProductData(item.vanityItemId, apply.merged);
      messenger.showSnackBar(SnackBar(content: Text('Updated from $sourceName.'), backgroundColor: AppTheme.statusGreen));
    } on VanitySyncException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Updated from $sourceName. ${e.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Not updated: $e'), backgroundColor: AppTheme.statusRed));
    }
  }

  Widget _buildTimelineCard(VanityItemModel item, BuildContext context) {
    final product = item.product;
    final source = product?.paoSource ?? PaoSource.unknown;
    final paoMonths = product?.knownPaoMonths;
    final fmt = DateFormat('MMMM d, yyyy');
    final isFinished = item.status == 'finished' || item.finishedDate != null;

    final String paoExpiryText;
    if (item.openedDate == null) {
      paoExpiryText = paoMonths != null ? 'Starts when opened' : 'Set PAO, then open';
    } else if (item.expiryDate != null) {
      paoExpiryText = fmt.format(item.expiryDate!);
    } else {
      paoExpiryText = 'Set the PAO to calculate';
    }

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
          _buildInfoRow(
            'PAO',
            paoMonths != null ? '$paoMonths months after opening' : 'Unknown',
            icon: Icons.av_timer,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    source == PaoSource.categoryDefault && product != null
                        ? '${source.label}: the usual PAO for this category, not read from your product.'
                        : source.label,
                    key: const ValueKey('pao-source'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: source.isVerified ? AppTheme.textMuted : AppTheme.statusAmber,
                      fontWeight: source.isVerified ? FontWeight.w500 : FontWeight.w600,
                    ),
                  ),
                ),
                if (!isFinished)
                  TextButton.icon(
                    key: const ValueKey('edit-pao'),
                    onPressed: () => _editPao(context, item),
                    icon: const Icon(Icons.edit_outlined, size: 14, color: AppTheme.primaryRose),
                    label: Text(
                      source.isVerified || source == PaoSource.unknown ? 'Edit PAO' : 'Edit / Confirm PAO',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primaryRose),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 16),
          if (item.batchCode != null && item.batchCode!.isNotEmpty) ...[
            _buildInfoRow('Batch Code', item.batchCode!, icon: Icons.tag),
            const Divider(height: 16),
          ],
          if (item.manufacturingDate != null) ...[
            _buildInfoRow(
              'Manufacturing Date',
              formatPackagingDate(item.manufacturingDate!, item.manufacturingDatePrecision),
              icon: Icons.precision_manufacturing_outlined,
            ),
            const Divider(height: 16),
          ],
          if (item.sealedExpiryDate != null) ...[
            _buildInfoRow(
              'Sealed Batch Expiry',
              formatPackagingDate(item.sealedExpiryDate!, item.sealedExpiryPrecision),
              icon: Icons.inventory_2_outlined,
            ),
            const Divider(height: 16),
          ],
          _buildInfoRow(
            'Opened Date',
            item.openedDate != null ? DateFormat('MMMM d, yyyy').format(item.openedDate!) : 'Not opened yet',
            icon: Icons.calendar_today_outlined,
          ),
          const Divider(height: 16),
          _buildInfoRow('PAO Expiry', paoExpiryText, icon: Icons.av_timer_outlined),
          const Divider(height: 16),
          _buildInfoRow(
            'Effective Expiry',
            item.effectiveExpiryDate != null
                ? DateFormat('MMMM d, yyyy').format(item.effectiveExpiryDate!)
                : (item.openedDate == null ? 'Calculated when opened' : 'Unknown (no PAO)'),
            icon: Icons.event_busy_outlined,
          ),
          if (item.openedDate == null && !isFinished)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 6),
              child: Text(
                paoMonths != null
                    ? 'The PAO countdown has not started. It starts when you mark the product as opened.'
                    : 'Set the PAO and mark the product as opened to get a PAO expiry date.',
                key: const ValueKey('pao-not-started'),
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
              ),
            ),
          if (item.sealedExpiryDate != null)
            const Padding(
              padding: EdgeInsets.only(left: 28, top: 6),
              child: Text(
                'Effective expiry is the earlier of the PAO expiry and the sealed batch expiry printed on the pack.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
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
          if (item.routineTags.isNotEmpty) ...[
            const Divider(height: 16),
            _buildInfoRow(
              'Routine Tags',
              item.routineTags.map((t) => t == 'AM' ? '☀️ Morning (AM)' : (t == 'PM' ? '🌙 Evening (PM)' : '📅 Weekly')).join(', '),
              icon: Icons.schedule_rounded,
            ),
          ],
        ],
      ),
    );
  }

  /// The saved category and where it came from (a suggestion is labelled as one). For a
  /// category nobody confirmed (e.g. older items saved with the old "Serum" default), a
  /// clearly different category suggested by the name is offered; it is only applied when
  /// the user taps it.
  Widget _buildCategoryLine(BuildContext context, VanityItemModel item, ProductModel product, VanityProvider vanityProv) {
    final cat = vanityProv.categories.where((c) => c.categoryId == product.categoryId).firstOrNull;
    final uncategorized = product.categorySource == CategorySource.unknown;
    final name = uncategorized ? 'Uncategorized' : (cat?.categoryName ?? product.categoryId);
    final note = uncategorized ? 'choose one in Edit' : product.categorySource.label;
    final confirmed = product.categorySource == CategorySource.user || product.categorySource == CategorySource.productDatabase;
    final suggestion = confirmed ? null : CategoryClassifier.fromName('${product.brand} ${product.name}');
    final offer = suggestion != null && !suggestion.weak && suggestion.categoryId != product.categoryId
        ? vanityProv.categories.where((c) => c.categoryId == suggestion.categoryId).firstOrNull
        : null;
    return Column(
      children: [
        Text(
          '$name · $note',
          key: const ValueKey('detail-category'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: product.categorySource.isConfirmed ? AppTheme.textMuted : AppTheme.statusAmber,
          ),
        ),
        if (offer != null)
          TextButton.icon(
            key: const ValueKey('detail-category-suggestion'),
            icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
            label: Text('The name suggests ${offer.categoryName}: use it'),
            onPressed: () async {
              // PAO follows only when it was the old category's estimate.
              final estimate = product.paoSource == PaoSource.categoryDefault;
              final updated = item.copyWith(
                product: product.copyWith(
                  categoryId: offer.categoryId,
                  categorySource: CategorySource.user,
                  paoMonths: estimate ? offer.defaultPaoMonths : null,
                ),
              );
              await vanityProv.updateItem(estimate ? updated.withRecalculatedExpiry() : updated);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Category set to ${offer.categoryName}.')),
                );
              }
            },
          ),
      ],
    );
  }

  Widget _buildBudgetCard(VanityItemModel item, VanityProvider vanityProv) {
    // The price is shown in its own currency, never relabelled with the budget currency.
    final info = Currencies.byCode(item.priceCurrency);
    String money(double v) => info != null ? info.formatAmount(v) : v.toStringAsFixed(2);
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
          _buildInfoRow(
            'Purchase Price',
            info != null ? '${money(item.price!)} ${info.code}' : '${money(item.price!)} (currency not recorded)',
            icon: Icons.attach_money,
          ),
          if (item.openedDate != null && item.costPerDay != null) ...[
            const Divider(height: 16),
            _buildInfoRow(
              'Cost Per Day',
              '${money(item.costPerDay!)} / day',
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

  Widget _buildIngredientsCard(BuildContext context, VanityItemModel item, VanityProvider vanityProv) {
    final product = item.product;
    final ingredients = product?.ingredientList;
    final hasIngredients = ingredients != null;
    final source = product?.ingredientsSource ?? IngredientSource.notRecorded;
    final canLookUp = (product?.barcode ?? '').trim().isNotEmpty;

    // Check conflicts for this product across routines it belongs to
    final relevantConflicts = <String, List<DetectedConflict>>{};
    final incompleteRoutines = <String>[];
    for (final tag in item.routineTags) {
      List<VanityItemModel> routineItems = [];
      if (tag == 'AM') routineItems = vanityProv.amRoutineItems;
      if (tag == 'PM') routineItems = vanityProv.pmRoutineItems;
      if (tag == 'Weekly') routineItems = vanityProv.weeklyRoutineItems;

      if (routineItems.length > 1) {
        final analysis = IngredientConflictService.analyzeRoutine(
          routineType: tag,
          items: routineItems,
        );
        final itemConflicts = analysis.conflicts.where(
          (c) => c.itemA.vanityItemId == item.vanityItemId || c.itemB.vanityItemId == item.vanityItemId,
        ).toList();
        if (itemConflicts.isNotEmpty) {
          relevantConflicts[tag] = itemConflicts;
        }
        if (!analysis.isCompleteCheck) incompleteRoutines.add(tag);
      }
    }

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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Ingredients', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
              TextButton.icon(
                key: const ValueKey('edit-ingredients'),
                icon: Icon(hasIngredients ? Icons.edit_outlined : Icons.add_circle_outline, size: 15, color: AppTheme.primaryRose),
                label: Text(
                  hasIngredients ? 'Edit / Scan' : 'Add Ingredients',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryRose),
                ),
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (ctx) => EditIngredientsDialog(item: item),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hasIngredients) ...[
            Text(
              source.label + (source.isConfirmed ? '' : ' · not confirmed against your product'),
              key: const ValueKey('ingredients-source'),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: source.isConfirmed ? AppTheme.textMuted : AppTheme.statusAmber,
              ),
            ),
            if (product?.ingredientsContext != null)
              Text(product!.ingredientsContext!, style: const TextStyle(fontSize: 10.5, color: AppTheme.textMuted)),
            const SizedBox(height: 6),
            Text(
              ingredients,
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.5),
            ),
            if (IngredientNormalizer.looksIncomplete(ingredients))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'This list looks cut off, so conflict checks for this product are incomplete.',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.statusAmber),
                ),
              ),
            if (source == IngredientSource.productDatabase)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Data: Open Beauty Facts contributors (ODbL). Not for medical use.',
                  style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
                ),
              ),
          ] else
            Text(
              'No ingredients listed, so routine conflicts cannot be checked for this product. '
              'Scan the label, ${canLookUp ? 'look the product up online, ' : ''}or type the list.',
              key: const ValueKey('ingredients-missing'),
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey.shade600),
            ),
          if (canLookUp && !(item.status == 'finished' || item.finishedDate != null))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('refresh-product-data'),
                onPressed: () => _refreshProductData(context, item),
                icon: const Icon(Icons.cloud_sync_outlined, size: 15, color: AppTheme.primaryRose),
                label: const Text(
                  'Look up PAO & ingredients online',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryRose),
                ),
              ),
            ),
          if (incompleteRoutines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Conflict check for your ${incompleteRoutines.join(' / ')} routine is incomplete: some products there have '
                'no or incomplete ingredient lists.',
                key: const ValueKey('routine-check-incomplete'),
                style: const TextStyle(fontSize: 11.5, color: AppTheme.statusAmber),
              ),
            ),
          if (relevantConflicts.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber.shade900),
                      const SizedBox(width: 6),
                      Text(
                        'Routine Conflict Warning',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.amber.shade900),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ...relevantConflicts.entries.expand((entry) => entry.value.map((c) {
                    final otherProduct = c.itemA.vanityItemId == item.vanityItemId ? c.itemB : c.itemA;
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '• In ${entry.key} Routine with ${otherProduct.product?.name ?? "Companion product"}: ${c.rule.description} (${c.rule.recommendation})',
                        style: TextStyle(fontSize: 11.5, color: Colors.brown.shade900, height: 1.3),
                      ),
                    );
                  })),
                ],
              ),
            ),
          ],
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



  Widget _buildHouseholdSharingCard(
    BuildContext context,
    VanityItemModel item,
    HouseholdProvider householdProv,
  ) {
    final isShared = item.isSharedWithHousehold;
    final hhName = householdProv.currentHousehold?.name ?? 'Household';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isShared ? const Color(0xFFFAF5FF) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isShared ? const Color(0xFFD8B4FE) : const Color(0xFFF1ECE8),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isShared ? const Color(0xFFF3E8FF) : const Color(0xFFF1F5F9),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.people_alt_rounded,
              color: isShared ? const Color(0xFF7E22CE) : AppTheme.textMuted,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isShared ? 'Shared with Household 👥' : 'Private to You',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isShared
                      ? 'Visible to "$hhName" members'
                      : 'Not shared with anyone',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('detail-toggle-sharing'),
            onPressed: () => changeSharingWithFeedback(context, item, !isShared),
            child: Text(
              isShared ? 'Stop Sharing' : 'Share',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isShared ? AppTheme.statusRed : const Color(0xFF7E22CE),
              ),
            ),
          ),
        ],
      ),
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
