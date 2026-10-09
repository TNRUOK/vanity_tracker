import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../product/product_detail_screen.dart';

class EmptiesScreen extends StatelessWidget {
  const EmptiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();
    final empties = vanityProv.empties;
    final repurchaseYes = vanityProv.repurchaseYesCount;
    final totalFinished = empties.length;
    final repurchaseRate = totalFinished > 0 ? ((repurchaseYes / totalFinished) * 100).toInt() : 0;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Empties & History'),
      ),
      body: empties.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppTheme.statusFinishedBg,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.recycling_rounded,
                        size: 48,
                        color: AppTheme.statusFinished,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'No Finished Products Yet',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'When you finish a skincare or beauty product, tap "Mark as Finished" to track your empties and cost-per-use!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : CustomScrollView(
              slivers: [
                // Top Summary Header Card
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF8B5CF6).withValues(alpha: 0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.auto_awesome, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Empties Hall of Fame',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _buildHeaderMetric('Finished', '$totalFinished items'),
                              Container(width: 1, height: 36, color: Colors.white24),
                              _buildHeaderMetric('Repurchase', '$repurchaseRate%'),
                              Container(width: 1, height: 36, color: Colors.white24),
                              _buildHeaderMetric(
                                'Avg Cost/Day',
                                '\$${vanityProv.averageCostPerDayUsed.toStringAsFixed(2)}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Empties List
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = empties[index];
                        return _buildEmptyCard(context, item);
                      },
                      childCount: empties.length,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
    );
  }

  Widget _buildHeaderMetric(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyCard(BuildContext context, VanityItemModel item) {
    final product = item.product;
    final brand = product?.brand ?? '';
    final name = product?.name ?? 'Cosmetic Product';
    final finishedStr = item.finishedDate != null
        ? DateFormat('MMM d, yyyy').format(item.finishedDate!)
        : 'Finished';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProductDetailScreen(vanityItemId: item.vanityItemId),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (brand.isNotEmpty)
                            Text(
                              brand.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          const SizedBox(height: 2),
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textDark,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Repurchase Badge
                    if (item.wouldRepurchase != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: item.wouldRepurchase!
                              ? AppTheme.statusGreenBg
                              : AppTheme.statusRedBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              item.wouldRepurchase!
                                  ? Icons.thumb_up_rounded
                                  : Icons.thumb_down_rounded,
                              size: 13,
                              color: item.wouldRepurchase!
                                  ? AppTheme.statusGreen
                                  : AppTheme.statusRed,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              item.wouldRepurchase! ? 'Repurchase' : 'Pass',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: item.wouldRepurchase!
                                    ? AppTheme.statusGreen
                                    : AppTheme.statusRed,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                const SizedBox(height: 10),

                // Stats Row: Days used, Finished date, Cost per day
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.history_toggle_off, size: 14, color: AppTheme.textMuted),
                        const SizedBox(width: 4),
                        Text(
                          '${item.daysUsed} days used',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (item.costPerDay != null)
                      Text(
                        '\$${item.costPerDay!.toStringAsFixed(2)} / day',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryRose,
                        ),
                      ),
                    Text(
                      finishedStr,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
