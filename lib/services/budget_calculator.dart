import '../models/receipt_model.dart';
import '../models/vanity_item_model.dart';
import '../utils/currency.dart';
import 'exchange_rate_service.dart';

enum AmountState {
  native, // already in the display currency: counted unchanged
  converted, // converted with a recorded historical rate
  pending, // rate not looked up yet
  unavailable, // no rate could be found: kept in its own currency, not counted
  currencyUnknown, // the record does not establish its currency: not counted
}

enum AmountKind { receipt, item }

/// One stored amount and what it is worth in the display currency (if anything).
class BudgetAmount {
  final String id;
  final AmountKind kind;
  final String label;
  final double originalAmount;

  /// ISO code of [originalAmount]; null when the record does not establish it.
  final String? originalCode;

  /// How the record shows its currency (the code's symbol, or the legacy stored symbol).
  final String originalSymbol;
  final DateTime? date;
  final AmountState state;

  /// Value in the display currency's minor units (null when not counted).
  final int? targetMinor;
  final RateQuote? quote;
  final String? reason;

  const BudgetAmount({
    required this.id,
    required this.kind,
    required this.label,
    required this.originalAmount,
    required this.originalCode,
    required this.originalSymbol,
    required this.date,
    required this.state,
    this.targetMinor,
    this.quote,
    this.reason,
  });

  bool get counted => targetMinor != null;

  String get originalText {
    final info = Currencies.byCode(originalCode);
    return info != null
        ? '${info.formatAmount(originalAmount)} $originalCode'
        : '$originalSymbol${originalAmount.toStringAsFixed(2)} (currency not recorded)';
  }
}

/// Budget figures in one display currency, built from each record's original amount and
/// currency. Every amount is converted on its own (historical rate of its own date) and
/// rounded once to the display currency's minor unit; sums are integer minor units.
/// Amounts that cannot be converted are listed, never counted as zero or as another
/// currency.
class BudgetSummary {
  final CurrencyInfo target;
  final List<BudgetAmount> receiptAmounts;

  /// Shelf items not linked to any receipt (their price is the only record of the spend).
  final List<BudgetAmount> directItemAmounts;

  /// Every priced item (linked or not), for value statistics.
  final Map<String, BudgetAmount> itemValues;
  final Set<RateRequest> rateRequests;

  const BudgetSummary({
    required this.target,
    required this.receiptAmounts,
    required this.directItemAmounts,
    required this.itemValues,
    required this.rateRequests,
  });

  static int _sum(Iterable<BudgetAmount> a) => a.fold(0, (s, x) => s + (x.targetMinor ?? 0));

  int get receiptMinor => _sum(receiptAmounts);
  int get directMinor => _sum(directItemAmounts);
  int get totalMinor => receiptMinor + directMinor;

  int get countedReceipts => receiptAmounts.where((a) => a.counted).length;
  int get countedDirectItems => directItemAmounts.where((a) => a.counted).length;

  List<BudgetAmount> get spendingAmounts => [...receiptAmounts, ...directItemAmounts];
  List<BudgetAmount> get notCounted => spendingAmounts.where((a) => !a.counted).toList();
  List<BudgetAmount> get converted => spendingAmounts.where((a) => a.state == AmountState.converted).toList();
  bool get hasPending => spendingAmounts.any((a) => a.state == AmountState.pending) ||
      itemValues.values.any((a) => a.state == AmountState.pending);

  /// Original sums of amounts that are not counted, per currency (code, or the legacy
  /// symbol when the currency is not recorded), in that currency's own minor units.
  Map<String, double> get notCountedByCurrency {
    final out = <String, double>{};
    for (final a in notCounted) {
      final key = a.originalCode ?? a.originalSymbol;
      out[key] = (out[key] ?? 0) + a.originalAmount;
    }
    return out;
  }

  /// Value of the given items in the display currency (only items whose value is known).
  int valueOf(Iterable<VanityItemModel> items) => _sum(items.map((i) => itemValues[i.vanityItemId]).whereType<BudgetAmount>());

  /// Items among [items] that have a price that could not be valued in the display currency.
  int unvaluedCount(Iterable<VanityItemModel> items) =>
      items.where((i) => itemValues[i.vanityItemId] != null && !itemValues[i.vanityItemId]!.counted).length;

  String format(int minor) => target.format(minor);
}

typedef RateLookup = RateResult? Function(RateRequest request);

class BudgetCalculator {
  /// No rates at all: only amounts already in the display currency are counted.
  static RateResult? noRates(RateRequest _) => null;

  static BudgetSummary compute({
    required List<ReceiptModel> receipts,
    required List<VanityItemModel> items,
    required CurrencyInfo target,
    RateLookup rates = noRates,
  }) {
    final requests = <RateRequest>{};

    BudgetAmount amount({
      required String id,
      required AmountKind kind,
      required String label,
      required double value,
      required String? code,
      required String symbol,
      required DateTime? date,
    }) {
      BudgetAmount make(AmountState state, {int? minor, RateQuote? quote, String? reason}) => BudgetAmount(
            id: id,
            kind: kind,
            label: label,
            originalAmount: value,
            originalCode: code,
            originalSymbol: code != null ? Currencies.symbolFor(code) : symbol,
            date: date,
            state: state,
            targetMinor: minor,
            quote: quote,
            reason: reason,
          );

      if (code == null) {
        return make(AmountState.currencyUnknown, reason: 'The currency of this amount was not recorded.');
      }
      if (code == target.code) return make(AmountState.native, minor: target.toMinor(value));
      final from = Currencies.byCode(code);
      if (from == null) return make(AmountState.unavailable, reason: '$code is not a supported currency.');
      if (date == null) {
        return make(AmountState.unavailable, reason: 'No date is recorded, so no historical rate can be chosen.');
      }
      final request = RateRequest(code, target.code, date);
      requests.add(request);
      final result = rates(request);
      if (result == null) return make(AmountState.pending, reason: 'Exchange rate not loaded yet.');
      final quote = result.quote;
      if (quote == null) return make(AmountState.unavailable, reason: result.unavailableReason);
      // Rounded once, here, to the display currency's minor unit.
      final minor = roundHalfAwayFromZero(from.toMinor(value) * quote.rate * target.minorFactor / from.minorFactor);
      return make(AmountState.converted, minor: minor, quote: quote);
    }

    // Items linked to a receipt line (in any currency) are already paid for by that receipt.
    final receiptOfItem = <String, ReceiptModel>{};
    for (final r in receipts) {
      for (final line in r.items) {
        final id = line.matchedVanityItemId;
        if (id != null && id.isNotEmpty) receiptOfItem.putIfAbsent(id, () => r);
      }
    }

    final receiptAmounts = [
      for (final r in receipts)
        amount(
          id: r.receiptId,
          kind: AmountKind.receipt,
          label: r.merchant,
          value: r.totalAmount,
          code: r.effectiveCurrencyCode,
          symbol: r.currency,
          date: r.purchaseDate,
        ),
    ];

    final itemValues = <String, BudgetAmount>{};
    for (final i in items) {
      final price = i.price;
      if (price == null || price <= 0) continue;
      final linked = receiptOfItem[i.vanityItemId];
      itemValues[i.vanityItemId] = amount(
        id: i.vanityItemId,
        kind: AmountKind.item,
        label: [i.product?.brand, i.product?.name].where((s) => s != null && s.isNotEmpty).join(' '),
        value: price,
        // A price without its own code takes the currency of the receipt it came from.
        code: Currencies.byCode(i.priceCurrency)?.code ?? i.priceCurrency ?? linked?.effectiveCurrencyCode,
        symbol: linked?.currency ?? '',
        date: linked?.purchaseDate ?? i.product?.createdAt,
      );
    }

    return BudgetSummary(
      target: target,
      receiptAmounts: receiptAmounts,
      directItemAmounts: [
        for (final i in items)
          if (!receiptOfItem.containsKey(i.vanityItemId) && itemValues[i.vanityItemId] != null)
            itemValues[i.vanityItemId]!,
      ],
      itemValues: itemValues,
      rateRequests: requests,
    );
  }
}
