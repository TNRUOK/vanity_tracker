import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();
    final activeValue = vanityProv.totalActiveVanityValue;
    final totalSpent = vanityProv.totalOverallInvestment;
    final emptiesValue = vanityProv.totalEmptiesValue;
    final avgCostPerDay = vanityProv.averageCostPerDayUsed;
    final repurchaseYes = vanityProv.repurchaseYesCount;
    final repurchaseNo = vanityProv.repurchaseNoCount;
    final totalFinished = vanityProv.emptiesCount;

    // Group active items by category
    final categoryTotals = <String, double>{};
    for (var item in vanityProv.activeItems) {
      final catId = item.product?.categoryId ?? 'other';
      categoryTotals[catId] = (categoryTotals[catId] ?? 0.0) + (item.price ?? 0.0);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Vanity & Budget Stats'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Investment Summary Card
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryRose, Color(0xFFC73E66)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryRose.withValues(alpha: 0.3),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Active Vanity Value',
                    style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '\$${activeValue.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildMetricColumn('Total Spent', '\$${totalSpent.toStringAsFixed(2)}'),
                      _buildMetricColumn('Empties Value', '\$${emptiesValue.toStringAsFixed(2)}'),
                      _buildMetricColumn('Avg Cost/Day', '\$${avgCostPerDay.toStringAsFixed(2)}'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Products Overview Grid
            Row(
              children: [
                Expanded(
                  child: _buildCountCard(
                    title: 'Active Products',
                    count: vanityProv.totalActiveCount.toString(),
                    icon: Icons.inventory_2_outlined,
                    color: AppTheme.statusGreen,
                    bgColor: AppTheme.statusGreenBg,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildCountCard(
                    title: 'Finished Empties',
                    count: totalFinished.toString(),
                    icon: Icons.recycling_rounded,
                    color: AppTheme.statusFinished,
                    bgColor: AppTheme.statusFinishedBg,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildCountCard(
                    title: 'Expiring Soon',
                    count: vanityProv.expiringSoonCount.toString(),
                    icon: Icons.access_time_filled,
                    color: AppTheme.statusAmber,
                    bgColor: AppTheme.statusAmberBg,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildCountCard(
                    title: 'Expired Items',
                    count: vanityProv.expiredCount.toString(),
                    icon: Icons.warning_amber_rounded,
                    color: AppTheme.statusRed,
                    bgColor: AppTheme.statusRedBg,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Repurchase Satisfaction Rate
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Repurchase Satisfaction',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Rate of finished products you would buy again',
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppTheme.statusGreenBg,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.thumb_up_rounded, color: AppTheme.statusGreen, size: 22),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$repurchaseYes',
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.statusGreen),
                                  ),
                                  const Text('Loved It', style: TextStyle(fontSize: 11, color: AppTheme.textDark, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppTheme.statusRedBg,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.thumb_down_rounded, color: AppTheme.statusRed, size: 22),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$repurchaseNo',
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.statusRed),
                                  ),
                                  const Text('Skipping', style: TextStyle(fontSize: 11, color: AppTheme.textDark, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Category Investment Breakdown
            if (categoryTotals.isNotEmpty && activeValue > 0) ...[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFF1ECE8)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Category Investment',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                    ),
                    const SizedBox(height: 16),
                    ...categoryTotals.entries.map((entry) {
                      final cat = vanityProv.categories.firstWhere(
                        (c) => c.categoryId == entry.key,
                        orElse: () => vanityProv.categories.last,
                      );
                      final percentage = ((entry.value / activeValue) * 100).toStringAsFixed(0);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(cat.categoryName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                                Text('\$${entry.value.toStringAsFixed(2)} ($percentage%)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primaryRose)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: entry.value / activeValue,
                                backgroundColor: const Color(0xFFF1F5F9),
                                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryRose),
                                minHeight: 6,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricColumn(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildCountCard({
    required String title,
    required String count,
    required IconData icon,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          Text(
            count,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
