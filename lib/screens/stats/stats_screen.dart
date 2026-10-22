import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/receipt_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/receipt_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../services/budget_calculator.dart';
import '../../services/exchange_rate_service.dart';
import '../../services/receipt_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/currency.dart';
import '../receipt/receipt_history_screen.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  int _touchedIndex = -1;

  /// Rates looked up so far (kept across rebuilds and currency switches).
  final Map<RateRequest, RateResult> _rates = {};
  bool _loadingRates = false;
  bool _showConversions = false;

  static const Map<String, Color> _categoryColors = {
    'serum': Color(0xFFE05780),
    'sunscreen': Color(0xFFF59E0B),
    'mascara': Color(0xFF6366F1),
    'foundation': Color(0xFFFF9F1C),
    'lipstick': Color(0xFFEC4899),
    'moisturizer': Color(0xFF06B6D4),
    'cleanser': Color(0xFF3B82F6),
    'toner': Color(0xFF10B981),
    'eye_cream': Color(0xFF8B5CF6),
    'fragrance': Color(0xFFD946EF),
    'other': Color(0xFF94A3B8),
  };

  Color _getCategoryColor(String categoryId, int index) {
    if (_categoryColors.containsKey(categoryId)) {
      return _categoryColors[categoryId]!;
    }
    final palette = [
      const Color(0xFFE05780),
      const Color(0xFF06B6D4),
      const Color(0xFFF59E0B),
      const Color(0xFF10B981),
      const Color(0xFF8B5CF6),
      const Color(0xFFFF9F1C),
      const Color(0xFFEC4899),
    ];
    return palette[index % palette.length];
  }

  /// Looks up the rates [needed] that are not known yet, at most one batch at a time.
  /// Rebuilds with the same data ask for nothing new, so they cause no requests.
  void _ensureRates(Set<RateRequest> needed) {
    final missing = needed.where((r) => !_rates.containsKey(r)).toSet();
    if (missing.isEmpty || _loadingRates) return;
    _loadingRates = true;
    ExchangeRateService.shared.resolveAll(missing).then((found) {
      if (!mounted) return;
      setState(() {
        _rates.addAll(found);
        _loadingRates = false;
      });
    });
  }

  void _retryUnavailableRates() {
    setState(() => _rates.removeWhere((_, r) => !r.isAvailable));
  }

  void _showCurrencyDialog(BuildContext context, VanityProvider vanityProv) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Budget display currency'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Totals are converted into this currency. Your receipts and prices keep their own currency.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 8),
            ...Currencies.supported.map((curr) {
              final isSelected = vanityProv.budgetCurrencyCode == curr.code;
              return ListTile(
                key: Key('budget-currency-${curr.code}'),
                dense: true,
                title: Text(curr.label, style: TextStyle(fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                trailing: isSelected ? const Icon(Icons.check, color: AppTheme.primaryRose) : null,
                onTap: () {
                  vanityProv.setCurrency(curr.code);
                  Navigator.of(ctx).pop();
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<String?> _pickCurrency(BuildContext context, String title) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final c in Currencies.supported)
            SimpleDialogOption(
              key: Key('pick-currency-${c.code}'),
              onPressed: () => Navigator.of(ctx).pop(c.code),
              child: Text(c.label),
            ),
        ],
      ),
    );
  }

  /// Records the currency of receipts saved with only an ambiguous symbol. Only the
  /// currency code is added; amounts, items and dates are unchanged.
  Future<void> _confirmReceiptCurrency(List<ReceiptModel> receipts, String code) async {
    final prov = context.read<ReceiptProvider>();
    var notSynced = 0;
    for (final r in receipts) {
      try {
        await prov.saveReceipt(r.copyWith(currencyCode: code));
      } on ReceiptSyncException {
        notSynced++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${receipts.length} receipt${receipts.length == 1 ? '' : 's'} recorded as $code.'
          '${notSynced > 0 ? ' $notSynced saved on this device only (not synced yet).' : ''}',
        ),
      ),
    );
  }

  /// Records the currency of shelf prices saved without one. Only the code is added.
  Future<void> _confirmItemCurrency(List<VanityItemModel> items, String code) async {
    final vanity = context.read<VanityProvider>();
    for (final i in items) {
      await vanity.updateItem(i.copyWith(priceCurrency: code));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${items.length} shelf price${items.length == 1 ? '' : 's'} recorded as $code.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();
    final receiptProv = context.watch<ReceiptProvider>();
    final target = vanityProv.budgetCurrency;

    final summary = vanityProv.budgetSummary(receipts: receiptProv.receipts, rates: (r) => _rates[r]);
    if (summary.rateRequests.any((r) => !_rates.containsKey(r))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureRates(summary.rateRequests);
      });
    }

    final activeItems = vanityProv.allActiveItems;
    final empties = vanityProv.empties;
    final activeValue = summary.valueOf(activeItems);
    final emptiesValue = summary.valueOf(empties);
    final avgCostPerDay = _averageCostPerDay(summary, empties);
    final repurchaseYes = vanityProv.repurchaseYesCount;
    final repurchaseNo = vanityProv.repurchaseNoCount;
    final totalFinished = vanityProv.emptiesCount;

    // Active value per category, in the display currency (only items with a known value).
    final categoryTotals = <String, int>{};
    for (final item in activeItems) {
      final v = summary.itemValues[item.vanityItemId];
      if (v == null || !v.counted) continue;
      final catId = item.product?.categoryId ?? 'other';
      categoryTotals[catId] = (categoryTotals[catId] ?? 0) + v.targetMinor!;
    }
    final unvaluedActive = summary.unvaluedCount(activeItems);

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Vanity & Budget Stats'),
        actions: [
          Tooltip(
            message: 'Change budget display currency',
            child: TextButton.icon(
              key: const Key('budget-currency-button'),
              icon: const Icon(Icons.currency_exchange, size: 16, color: AppTheme.primaryRose),
              label: Text(
                '${target.code} ${target.symbol}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppTheme.primaryRose),
              ),
              onPressed: () => _showCurrencyDialog(context, vanityProv),
            ),
          ),
        ],
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
                  Text(
                    'Active Vanity Value (${target.code})',
                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    target.format(activeValue),
                    key: const Key('active-value'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  if (unvaluedActive > 0)
                    Text(
                      '$unvaluedActive priced item${unvaluedActive == 1 ? '' : 's'} not included (see below)',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: _buildMetricColumn('Total Spent — ${target.code}', target.format(summary.totalMinor))),
                      Flexible(child: _buildMetricColumn('Empties Value', target.format(emptiesValue))),
                      Flexible(
                        child: _buildMetricColumn(
                          'Avg Cost/Day',
                          avgCostPerDay == null ? '—' : target.formatAmount(avgCostPerDay),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            if (receiptProv.receipts.isNotEmpty || summary.directItemAmounts.isNotEmpty) ...[
              _buildSpendingCard(context, summary, receiptProv, vanityProv),
              const SizedBox(height: 16),
            ],

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

            _buildRepurchaseCard(repurchaseYes, repurchaseNo),
            const SizedBox(height: 20),

            if (categoryTotals.isNotEmpty && activeValue > 0) ...[
              _buildCategoryCard(categoryTotals, activeValue, target, vanityProv),
              const SizedBox(height: 30),
            ],
          ],
        ),
      ),
    );
  }

  /// Mean cost per day of finished items whose value is known in the display currency.
  double? _averageCostPerDay(BudgetSummary summary, List<VanityItemModel> empties) {
    final perDay = <double>[];
    for (final i in empties) {
      final v = summary.itemValues[i.vanityItemId];
      if (v == null || !v.counted || i.daysUsed <= 0) continue;
      perDay.add(summary.target.fromMinor(v.targetMinor!) / i.daysUsed);
    }
    if (perDay.isEmpty) return null;
    return perDay.reduce((a, b) => a + b) / perDay.length;
  }

  Widget _buildSpendingCard(
    BuildContext context,
    BudgetSummary summary,
    ReceiptProvider receiptProv,
    VanityProvider vanityProv,
  ) {
    final target = summary.target;
    final converted = summary.converted;
    final unavailable = summary.notCounted.where((a) => a.state == AmountState.unavailable).toList();
    final pending = summary.notCounted.where((a) => a.state == AmountState.pending).toList();

    // Records whose currency is not established, grouped for a deliberate correction.
    final unknownReceiptIds = summary.receiptAmounts
        .where((a) => a.state == AmountState.currencyUnknown)
        .map((a) => a.id)
        .toSet();
    final unknownReceipts = receiptProv.receipts.where((r) => unknownReceiptIds.contains(r.receiptId)).toList();
    final unknownBySymbol = <String, List<ReceiptModel>>{};
    for (final r in unknownReceipts) {
      (unknownBySymbol[r.currency] ??= []).add(r);
    }
    final unknownItemIds = summary.itemValues.values
        .where((a) => a.state == AmountState.currencyUnknown)
        .map((a) => a.id)
        .toSet();
    final unknownItems = vanityProv.allItems.where((i) => unknownItemIds.contains(i.vanityItemId)).toList();

    final dateFmt = DateFormat('yyyy-MM-dd');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined, size: 18, color: AppTheme.primaryRose),
              SizedBox(width: 8),
              Text(
                'Spending Source of Truth',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textDark),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Total Spent — ${target.code}: ${target.format(summary.totalMinor)} = '
            '${target.format(summary.receiptMinor)} from ${summary.countedReceipts} saved receipt(s) + '
            '${target.format(summary.directMinor)} from ${summary.countedDirectItems} shelf item(s) '
            'not linked to a receipt.',
            key: const Key('spending-breakdown'),
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
          ),
          const SizedBox(height: 6),
          const Text(
            '✓ Anti-double-counting: products linked to a receipt line are counted once, by the receipt.',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.statusGreen),
          ),

          if (_loadingRates || pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              key: const Key('rates-loading'),
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Loading exchange rates for ${pending.length} amount${pending.length == 1 ? '' : 's'}…',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
                ),
              ],
            ),
          ],

          if (converted.isNotEmpty) ...[
            const Divider(height: 16),
            InkWell(
              key: const Key('toggle-conversions'),
              onTap: () => setState(() => _showConversions = !_showConversions),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${converted.length} amount${converted.length == 1 ? ' was' : 's were'} converted to ${target.code} '
                      'with the ECB reference rate for each purchase date.',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                    ),
                  ),
                  Icon(_showConversions ? Icons.expand_less : Icons.expand_more, size: 18),
                ],
              ),
            ),
            if (_showConversions)
              for (final a in converted)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '• ${a.label.isEmpty ? 'Shelf item' : a.label} (${a.date != null ? dateFmt.format(a.date!) : 'no date'}): '
                    '${a.originalText} → ${target.format(a.targetMinor!)}\n'
                    '   1 ${a.quote!.from} = ${_rateText(a.quote!.rate)} ${a.quote!.to}, rate of ${dateFmt.format(a.quote!.rateDate)}'
                    '${a.quote!.isEarlierDateFallback ? ' (no rate published on the purchase date; latest earlier rate used)' : ''}',
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted, height: 1.35),
                  ),
                ),
            const SizedBox(height: 6),
            const Text(
              'Source: European Central Bank reference rates (via the Frankfurter API). These are reference '
              'rates, not the amount your bank or card provider actually charged.',
              style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted, fontStyle: FontStyle.italic),
            ),
          ],

          if (unavailable.isNotEmpty) ...[
            const Divider(height: 16),
            Text(
              'Not converted (kept in their own currency, not included in the ${target.code} total):',
              key: const Key('not-converted'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textDark),
            ),
            for (final a in unavailable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '• ${a.label.isEmpty ? 'Shelf item' : a.label}: ${a.originalText}. ${a.reason ?? ''}',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.primaryRose, fontWeight: FontWeight.w600),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('retry-rates'),
                onPressed: _loadingRates ? null : _retryUnavailableRates,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Try loading rates again'),
              ),
            ),
          ],

          if (unknownBySymbol.isNotEmpty) ...[
            const Divider(height: 16),
            for (final e in unknownBySymbol.entries) ...[
              Text(
                '${e.value.length} receipt${e.value.length == 1 ? ' was' : 's were'} saved with "${e.key}" but without a '
                'currency code (${e.value.fold<double>(0, (s, r) => s + r.totalAmount).toStringAsFixed(2)} in total). '
                '"${e.key}" can mean more than one currency, so ${e.value.length == 1 ? 'it is' : 'they are'} '
                'not counted until you confirm it.',
                key: Key('unknown-receipt-currency-${e.key}'),
                style: const TextStyle(fontSize: 12, color: AppTheme.textDark),
              ),
              Wrap(
                spacing: 8,
                children: [
                  if (Currencies.suggestedCodeForLegacySymbol(e.key) != null)
                    TextButton(
                      key: Key('confirm-receipts-${e.key}'),
                      onPressed: () => _confirmReceiptCurrency(e.value, Currencies.suggestedCodeForLegacySymbol(e.key)!),
                      child: Text('They are ${Currencies.suggestedCodeForLegacySymbol(e.key)}'),
                    ),
                  TextButton(
                    onPressed: () async {
                      final code = await _pickCurrency(context, 'Currency of these receipts');
                      if (code != null) await _confirmReceiptCurrency(e.value, code);
                    },
                    child: const Text('Choose currency…'),
                  ),
                ],
              ),
            ],
          ],

          if (unknownItems.isNotEmpty) ...[
            const Divider(height: 16),
            Text(
              '${unknownItems.length} shelf price${unknownItems.length == 1 ? ' has' : 's have'} no recorded currency '
              '(saved before currencies were recorded), so ${unknownItems.length == 1 ? 'it is' : 'they are'} not counted.',
              key: const Key('unknown-item-currency'),
              style: const TextStyle(fontSize: 12, color: AppTheme.textDark),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('confirm-items-budget'),
                  onPressed: () => _confirmItemCurrency(unknownItems, target.code),
                  child: Text('They are ${target.code}'),
                ),
                TextButton(
                  onPressed: () async {
                    final code = await _pickCurrency(context, 'Currency of these prices');
                    if (code != null) await _confirmItemCurrency(unknownItems, code);
                  },
                  child: const Text('Choose currency…'),
                ),
              ],
            ),
            const Text(
              'You can also set each price\'s currency in Edit Product.',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ],

          const Divider(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${receiptProv.receipts.length} saved receipt${receiptProv.receipts.length == 1 ? '' : 's'} in all currencies',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReceiptHistoryScreen())),
                icon: const Icon(Icons.receipt_long_rounded, size: 16),
                label: const Text('View Receipts'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _rateText(double rate) {
    final digits = rate >= 100 ? 2 : (rate >= 1 ? 4 : 6);
    return rate.toStringAsFixed(digits);
  }

  Widget _buildRepurchaseCard(int repurchaseYes, int repurchaseNo) {
    Widget tile(int count, String label, IconData icon, Color color, Color bg) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$count', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
                    Text(
                      label,
                      style: const TextStyle(fontSize: 11, color: AppTheme.textDark, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

    return Container(
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
              tile(repurchaseYes, 'Loved It', Icons.thumb_up_rounded, AppTheme.statusGreen, AppTheme.statusGreenBg),
              const SizedBox(width: 12),
              tile(repurchaseNo, 'Skipping', Icons.thumb_down_rounded, AppTheme.statusRed, AppTheme.statusRedBg),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryCard(
    Map<String, int> categoryTotals,
    int activeValue,
    CurrencyInfo target,
    VanityProvider vanityProv,
  ) {
    return Container(
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
            'Category Investment Distribution',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
          ),
          const SizedBox(height: 6),
          Text(
            'Visual breakdown of your active vanity budget (${target.code})',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 190,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    pieTouchData: PieTouchData(
                      touchCallback: (FlTouchEvent event, pieTouchResponse) {
                        setState(() {
                          if (!event.isInterestedForInteractions ||
                              pieTouchResponse == null ||
                              pieTouchResponse.touchedSection == null) {
                            _touchedIndex = -1;
                            return;
                          }
                          _touchedIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
                        });
                      },
                    ),
                    borderData: FlBorderData(show: false),
                    sectionsSpace: 3,
                    centerSpaceRadius: 52,
                    sections: List.generate(categoryTotals.length, (i) {
                      final isTouched = i == _touchedIndex;
                      final entry = categoryTotals.entries.elementAt(i);
                      final pct = ((entry.value / activeValue) * 100).toInt();
                      return PieChartSectionData(
                        color: _getCategoryColor(entry.key, i),
                        value: entry.value.toDouble(),
                        title: '$pct%',
                        radius: isTouched ? 48.0 : 40.0,
                        titleStyle: TextStyle(
                          fontSize: isTouched ? 14.0 : 11.0,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      );
                    }),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${categoryTotals.length}',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppTheme.textDark),
                    ),
                    const Text(
                      'Categories',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ...categoryTotals.entries.toList().asMap().entries.map((indexedEntry) {
            final i = indexedEntry.key;
            final entry = indexedEntry.value;
            final cat = vanityProv.categories.firstWhere(
              (c) => c.categoryId == entry.key,
              orElse: () => vanityProv.categories.last,
            );
            final percentage = ((entry.value / activeValue) * 100).toStringAsFixed(0);
            final color = _getCategoryColor(entry.key, i);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            cat.categoryName,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                          ),
                        ],
                      ),
                      Text(
                        '${target.format(entry.value)} ($percentage%)',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: entry.value / activeValue,
                      backgroundColor: const Color(0xFFF1F5F9),
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildMetricColumn(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500),
        ),
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
