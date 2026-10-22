import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/services/budget_calculator.dart';
import 'package:vanity_tracker/services/exchange_rate_service.dart';
import 'package:vanity_tracker/utils/currency.dart';

import 'helpers/fake_rates.dart';

// Fixed test rates (units per 1 EUR). 2024-01-13/14 is a weekend: no rows, like the ECB.
final table = {
  '2024-01-10': {'USD': 1.1000, 'INR': 91.00, 'GBP': 0.8600, 'JPY': 160.00},
  '2024-01-11': {'USD': 1.0000, 'INR': 90.00, 'GBP': 0.8000, 'JPY': 150.00},
  '2024-01-12': {'USD': 1.2500, 'INR': 100.00, 'GBP': 0.8000, 'JPY': 160.00},
  '2024-01-15': {'USD': 1.0000, 'INR': 80.00, 'GBP': 0.5000, 'JPY': 100.00},
};

ReceiptModel receipt(String id, double total, String? code, DateTime date, {String symbol = '\$', List<ReceiptItemModel> items = const []}) =>
    ReceiptModel(
      receiptId: id,
      userId: 'u',
      merchant: 'Store $id',
      purchaseDate: date,
      currency: symbol,
      currencyCode: code,
      subtotal: total,
      totalAmount: total,
      createdAt: date,
      items: items,
    );

VanityItemModel item(String id, double price, String? code, {DateTime? added}) => VanityItemModel(
      vanityItemId: id,
      productId: 'p_$id',
      userId: 'u',
      price: price,
      priceCurrency: code,
      product: ProductModel(
        productId: 'p_$id',
        barcode: '',
        name: 'Item $id',
        brand: '',
        categoryId: 'serum',
        paoMonths: 12,
        createdAt: added,
      ),
    );

Future<Map<RateRequest, RateResult>> resolve(ExchangeRateService s, List<RateRequest> r) => s.resolveAll(r);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final today = DateTime(2024, 3, 1);

  group('Currency codes, minor units, formatting', () {
    test('ISO codes and minor units', () {
      expect(Currencies.inr.minorDigits, 2);
      expect(Currencies.jpy.minorDigits, 0);
      expect(Currencies.usd.toMinor(24.35), 2435);
      expect(Currencies.jpy.toMinor(1500), 1500);
      expect(Currencies.inr.format(123456789), '₹1,234,567.89');
      expect(Currencies.jpy.format(1500), '¥1,500');
      expect(Currencies.usd.format(-1050), '-\$10.50');
    });

    test('symbols: only unambiguous ones establish a currency', () {
      expect(Currencies.codeFromStored('₹'), 'INR');
      expect(Currencies.codeFromStored('£'), 'GBP');
      expect(Currencies.codeFromStored('€'), 'EUR');
      expect(Currencies.codeFromStored('USD'), 'USD');
      expect(Currencies.codeFromStored('\$'), isNull);
      expect(Currencies.codeFromStored('¥'), isNull);
      expect(Currencies.suggestedCodeForLegacySymbol('\$'), 'USD'); // offered for confirmation only
    });

    test('rounding is half away from zero at the minor unit', () {
      expect(roundHalfAwayFromZero(2.5), 3);
      expect(roundHalfAwayFromZero(-2.5), -3);
      expect(roundHalfAwayFromZero(2.4999), 2);
    });
  });

  group('ExchangeRateService (fixed test rates, no network)', () {
    test('rate on the purchase date, as a cross rate via EUR', () async {
      final s = ExchangeRateService(source: FixedEcbRateSource(table), now: () => today);
      final r = RateRequest('USD', 'INR', DateTime(2024, 1, 12));
      final q = (await resolve(s, [r]))[r]!.quote!;
      expect(q.rate, closeTo(80.0, 1e-9)); // 100 / 1.25
      expect(q.rateDate, DateTime(2024, 1, 12));
      expect(q.isEarlierDateFallback, isFalse);
      expect(q.source, 'Test ECB table');
    });

    test('weekend purchase uses the latest earlier rate, labelled as such', () async {
      final s = ExchangeRateService(source: FixedEcbRateSource(table), now: () => today);
      final r = RateRequest('GBP', 'INR', DateTime(2024, 1, 14)); // Sunday
      final q = (await resolve(s, [r]))[r]!.quote!;
      expect(q.rateDate, DateTime(2024, 1, 12));
      expect(q.isEarlierDateFallback, isTrue);
      expect(q.rate, closeTo(125.0, 1e-9));
    });

    test('a later rate is never used for an earlier purchase', () async {
      final src = FixedEcbRateSource(table);
      final s = ExchangeRateService(source: src, now: () => today);
      final r = RateRequest('USD', 'INR', DateTime(2024, 1, 9)); // before every table row
      final res = (await resolve(s, [r]))[r]!;
      expect(res.isAvailable, isFalse);
      expect(src.calls.single.to, DateTime(2024, 1, 9), reason: 'request never asks past the purchase date');
    });

    test('future purchase dates and unsupported currencies are unavailable without a request', () async {
      final src = FixedEcbRateSource(table);
      final s = ExchangeRateService(source: src, now: () => today);
      final future = RateRequest('USD', 'INR', DateTime(2024, 6, 1));
      final unsupported = RateRequest('AED', 'INR', DateTime(2024, 1, 12));
      final res = await resolve(s, [future, unsupported]);
      expect(res[future]!.unavailableReason, contains('future'));
      expect(res[unsupported]!.unavailableReason, contains('not a supported'));
      expect(src.calls, isEmpty);
    });

    test('cache hit: no second request; different dates are kept apart', () async {
      final src = FixedEcbRateSource(table);
      final s = ExchangeRateService(source: src, now: () => today);
      final a = RateRequest('USD', 'INR', DateTime(2024, 1, 11));
      final b = RateRequest('USD', 'INR', DateTime(2024, 1, 12));
      final first = await resolve(s, [a, b]);
      expect(src.calls, hasLength(1), reason: 'one batched request');
      expect(first[a]!.quote!.rate, closeTo(90.0, 1e-9));
      expect(first[b]!.quote!.rate, closeTo(80.0, 1e-9));
      final again = await resolve(s, [a, b]);
      expect(src.calls, hasLength(1), reason: 'served from the cache');
      expect(again[a]!.quote!.rate, first[a]!.quote!.rate);
    });

    test('pairs are kept apart (USD→INR is not reused for GBP→INR)', () async {
      final s = ExchangeRateService(source: FixedEcbRateSource(table), now: () => today);
      final usd = RateRequest('USD', 'INR', DateTime(2024, 1, 15));
      final gbp = RateRequest('GBP', 'INR', DateTime(2024, 1, 15));
      final res = await resolve(s, [usd, gbp]);
      expect(res[usd]!.quote!.rate, closeTo(80.0, 1e-9));
      expect(res[gbp]!.quote!.rate, closeTo(160.0, 1e-9));
    });

    test('cache miss after a cached range: a new date is fetched', () async {
      final src = FixedEcbRateSource(table);
      final s = ExchangeRateService(source: src, now: () => today);
      await resolve(s, [RateRequest('USD', 'INR', DateTime(2024, 1, 11))]);
      final later = RateRequest('USD', 'INR', DateTime(2024, 1, 15));
      final res = await resolve(s, [later]);
      expect(src.calls, hasLength(2));
      expect(res[later]!.quote!.rateDate, DateTime(2024, 1, 15), reason: 'not the cached 01-11 rate');
    });

    test('cached rates survive a restart (stored on the device) and work offline', () async {
      await resolve(ExchangeRateService(source: FixedEcbRateSource(table), now: () => today),
          [RateRequest('USD', 'INR', DateTime(2024, 1, 12))]);
      final offline = OfflineRateSource();
      final s2 = ExchangeRateService(source: offline, now: () => today);
      final r = RateRequest('USD', 'INR', DateTime(2024, 1, 12));
      final res = await resolve(s2, [r]);
      expect(res[r]!.quote!.rate, closeTo(80.0, 1e-9));
      expect(res[r]!.quote!.retrievedAt, isNotNull);
      expect(offline.calls, 0);
    });

    test('offline without a cached rate: unavailable with the reason', () async {
      final s = ExchangeRateService(source: OfflineRateSource(), now: () => today);
      final r = RateRequest('USD', 'INR', DateTime(2024, 1, 12));
      final res = await resolve(s, [r]);
      expect(res[r]!.isAvailable, isFalse);
      expect(res[r]!.unavailableReason, contains('offline'));
      expect(s.lastError, isNotNull);
    });

    test('concurrent identical lookups share one request', () async {
      final src = FixedEcbRateSource(table);
      final s = ExchangeRateService(source: src, now: () => today);
      final r = RateRequest('USD', 'INR', DateTime(2024, 1, 12));
      await Future.wait([resolve(s, [r]), resolve(s, [r]), resolve(s, [r])]);
      expect(src.calls, hasLength(1));
    });

    test('same currency needs no rate', () async {
      final src = FixedEcbRateSource(table);
      final summary = BudgetCalculator.compute(
        receipts: [receipt('a', 10, 'INR', DateTime(2024, 1, 12), symbol: '₹')],
        items: const [],
        target: Currencies.inr,
      );
      expect(summary.rateRequests, isEmpty);
      expect(summary.totalMinor, 1000);
      expect(src.calls, isEmpty);
    });
  });

  group('FrankfurterEcbSource (mocked HTTP)', () {
    test('requests ECB rates with base EUR for the needed currencies and date range', () async {
      late Uri seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response(
          jsonEncode([
            {'date': '2024-01-12', 'base': 'EUR', 'quote': 'INR', 'rate': 90.9195},
            {'date': '2024-01-12', 'base': 'EUR', 'quote': 'USD', 'rate': 1.094},
          ]),
          200,
        );
      });
      final rows = await FrankfurterEcbSource(client: client)
          .fetchEurRates(from: DateTime(2024, 1, 2), to: DateTime(2024, 1, 12), codes: {'USD', 'INR', 'EUR'});
      expect(seen.host, 'api.frankfurter.dev');
      expect(seen.path, '/v2/rates');
      expect(seen.queryParameters, {
        'from': '2024-01-02',
        'to': '2024-01-12',
        'base': 'EUR',
        'quotes': 'INR,USD',
        'providers': 'ecb',
      });
      expect(rows['2024-01-12'], {'INR': 90.9195, 'USD': 1.094});
      expect(seen.queryParameters.keys.any((k) => k.contains('key')), isFalse, reason: 'no API key');
    });

    test('rows that do not answer the request are ignored', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode([
              {'date': '2024-01-12', 'base': 'USD', 'quote': 'INR', 'rate': 83.0}, // wrong base
              {'date': '2024-02-01', 'base': 'EUR', 'quote': 'INR', 'rate': 90.0}, // outside range
              {'date': '2024-01-11', 'base': 'EUR', 'quote': 'INR', 'rate': -1}, // invalid
              {'date': '2024-01-11', 'base': 'EUR', 'quote': 'GBP', 'rate': 0.86}, // not asked for
              {'date': 'x', 'base': 'EUR', 'quote': 'INR', 'rate': 90.0},
              {'date': '2024-01-10', 'base': 'EUR', 'quote': 'INR', 'rate': 91.0}, // valid
            ]),
            200,
          ));
      final rows = await FrankfurterEcbSource(client: client)
          .fetchEurRates(from: DateTime(2024, 1, 2), to: DateTime(2024, 1, 12), codes: {'INR'});
      expect(rows, {'2024-01-10': {'INR': 91.0}});
    });

    test('HTTP errors and unreadable bodies are reported, not turned into rates', () async {
      Future<Object?> run(http.Response res) async {
        try {
          await FrankfurterEcbSource(client: MockClient((_) async => res))
              .fetchEurRates(from: DateTime(2024, 1, 2), to: DateTime(2024, 1, 12), codes: {'INR'});
          return null;
        } catch (e) {
          return e;
        }
      }

      expect(await run(http.Response('{"status":422,"message":"invalid currency: ABC"}', 422)), isA<RateFetchException>());
      expect(await run(http.Response('not json', 200)), isA<RateFetchException>());
      expect(await run(http.Response('{"rates":{}}', 200)), isA<RateFetchException>());
    });
  });

  group('BudgetCalculator (fixed rates)', () {
    late ExchangeRateService service;
    setUp(() => service = ExchangeRateService(source: FixedEcbRateSource(table), now: () => today));

    Future<BudgetSummary> summarize(List<ReceiptModel> receipts, List<VanityItemModel> items, CurrencyInfo target) async {
      final first = BudgetCalculator.compute(receipts: receipts, items: items, target: target);
      final rates = await service.resolveAll(first.rateRequests);
      return BudgetCalculator.compute(receipts: receipts, items: items, target: target, rates: (r) => rates[r]);
    }

    test('native amounts are kept exactly', () async {
      final s = await summarize([receipt('a', 24.35, 'USD', DateTime(2024, 1, 12))], const [], Currencies.usd);
      expect(s.totalMinor, 2435);
      expect(s.receiptAmounts.single.state, AmountState.native);
    });

    test('USD receipt in INR, GBP receipt in INR, INR receipt in USD', () async {
      final day = DateTime(2024, 1, 12); // USD 1.25, INR 100, GBP 0.80 per EUR
      final usdInInr = await summarize([receipt('a', 10.00, 'USD', day)], const [], Currencies.inr);
      expect(usdInInr.totalMinor, 80000); // 10 USD × 80 = ₹800.00
      final gbpInInr = await summarize([receipt('b', 10.00, 'GBP', day, symbol: '£')], const [], Currencies.inr);
      expect(gbpInInr.totalMinor, 125000); // 10 GBP × 125 = ₹1,250.00
      final inrInUsd = await summarize([receipt('c', 1000.00, 'INR', day, symbol: '₹')], const [], Currencies.usd);
      expect(inrInUsd.totalMinor, 1250); // ₹1000 × 0.0125 = $12.50
      expect(inrInUsd.receiptAmounts.single.quote!.rateDate, day);
    });

    test('mixed currencies are converted individually, then summed in minor units', () async {
      final s = await summarize([
        receipt('usd', 10.00, 'USD', DateTime(2024, 1, 12)), // ₹800.00
        receipt('gbp', 3.33, 'GBP', DateTime(2024, 1, 11), symbol: '£'), // 3.33 × 112.5 = ₹374.625 -> ₹374.63
        receipt('inr', 100.10, 'INR', DateTime(2024, 1, 11), symbol: '₹'), // native
      ], const [], Currencies.inr);
      expect(s.receiptAmounts.map((a) => a.targetMinor), [80000, 37463, 10010]);
      expect(s.totalMinor, 80000 + 37463 + 10010);
      expect(s.totalMinor, isNot(Currencies.inr.toMinor(10.00 + 3.33 + 100.10)), reason: 'never raw-summed');
    });

    test('rounding to zero-decimal currencies (JPY)', () async {
      // 0.99 USD on 2024-01-11: 1 USD = 150 JPY -> 148.5 -> ¥149 (half away from zero)
      final s = await summarize([receipt('a', 0.99, 'USD', DateTime(2024, 1, 11))], const [], Currencies.jpy);
      expect(s.totalMinor, 149);
      expect(s.format(s.totalMinor), '¥149');
    });

    test('identical pairs on different dates use their own dates\' rates', () async {
      final s = await summarize([
        receipt('a', 10, 'USD', DateTime(2024, 1, 11)), // 90
        receipt('b', 10, 'USD', DateTime(2024, 1, 12)), // 80
      ], const [], Currencies.inr);
      expect(s.receiptAmounts.map((a) => a.targetMinor), [90000, 80000]);
    });

    test('missing rates and unknown currencies are never counted as zero or as another currency', () async {
      final s = await summarize([
        receipt('early', 10, 'USD', DateTime(2024, 1, 2)), // no rate in the table window
        receipt('legacy', 25, null, DateTime(2024, 1, 12)), // "$" only
        receipt('ok', 5, 'INR', DateTime(2024, 1, 12), symbol: '₹'),
      ], const [], Currencies.inr);
      expect(s.totalMinor, 500);
      expect(s.notCounted.map((a) => a.id).toSet(), {'early', 'legacy'});
      expect(s.notCounted.firstWhere((a) => a.id == 'early').state, AmountState.unavailable);
      expect(s.notCounted.firstWhere((a) => a.id == 'legacy').state, AmountState.currencyUnknown);
      expect(s.notCountedByCurrency, {'USD': 10.0, '\$': 25.0});
    });

    test('a linked item is counted once (by its receipt), even across currencies', () async {
      final r = receipt('usd', 30, 'USD', DateTime(2024, 1, 12), items: const [
        ReceiptItemModel(itemId: 'l', description: 'Serum', unitPrice: 30, totalPrice: 30, matchedVanityItemId: 'linked'),
      ]);
      final s = await summarize(
        [r],
        [item('linked', 30, 'USD'), item('direct', 500, 'INR')],
        Currencies.inr,
      );
      expect(s.receiptMinor, 240000); // $30 × 80
      expect(s.directItemAmounts.map((a) => a.id), ['direct']);
      expect(s.totalMinor, 240000 + 50000);
      // The linked item still has a value for statistics (from the receipt date).
      expect(s.itemValues['linked']!.targetMinor, 240000);
    });

    test('an item price without its own currency takes its receipt\'s currency', () async {
      final r = receipt('gbp', 10, 'GBP', DateTime(2024, 1, 12), symbol: '£', items: const [
        ReceiptItemModel(itemId: 'l', description: 'x', unitPrice: 10, totalPrice: 10, matchedVanityItemId: 'old'),
      ]);
      final s = await summarize([r], [item('old', 10, null)], Currencies.inr);
      expect(s.itemValues['old']!.originalCode, 'GBP');
      expect(s.itemValues['old']!.targetMinor, 125000);
    });

    test('an unlinked legacy price with no currency is listed, not counted', () async {
      final s = await summarize(const [], [item('legacy', 40, null, added: DateTime(2024, 1, 12))], Currencies.inr);
      expect(s.totalMinor, 0);
      expect(s.directItemAmounts.single.state, AmountState.currencyUnknown);
    });

    test('changing the display currency never changes stored records', () async {
      final r = receipt('a', 10, 'USD', DateTime(2024, 1, 12));
      final before = r.toMap().toString();
      await summarize([r], const [], Currencies.inr);
      await summarize([r], const [], Currencies.gbp);
      expect(r.toMap().toString(), before);
      expect(r.totalAmount, 10);
      expect(r.currencyCode, 'USD');
    });

    test('rate metadata is kept with each converted amount', () async {
      final s = await summarize([receipt('a', 10, 'USD', DateTime(2024, 1, 13))], const [], Currencies.inr);
      final q = s.converted.single.quote!;
      expect(q.toMap(), {
        'from': 'USD',
        'to': 'INR',
        'rate': 80.0,
        'rate_date': '2024-01-12',
        'requested_date': '2024-01-13',
        'source': 'Test ECB table',
        'retrieved_at': q.retrievedAt!.toIso8601String(),
      });
    });
  });

  group('Stored currency fields', () {
    test('receipt currency code and item price currency round-trip (backup format)', () {
      final r = receipt('a', 10, 'GBP', DateTime(2024, 1, 12), symbol: '£');
      final back = ReceiptModel.fromMap(r.toMap());
      expect(back.currencyCode, 'GBP');
      expect(back.currency, '£');
      expect(back.totalAmount, 10);
      final i = item('x', 12.5, 'INR');
      expect(VanityItemModel.fromMap(i.toMap()).priceCurrency, 'INR');
    });

    test('older records without the new fields stay readable and unchanged', () {
      final legacyReceipt = ReceiptModel.fromMap({
        'receipt_id': 'r1',
        'user_id': 'u',
        'merchant': 'M',
        'purchase_date': '2023-05-01T00:00:00.000',
        'currency': '\$',
        'subtotal': 5,
        'total_amount': 5,
        'created_at': '2023-05-01T00:00:00.000',
      });
      expect(legacyReceipt.currencyCode, isNull);
      expect(legacyReceipt.effectiveCurrencyCode, isNull);
      expect(legacyReceipt.toMap().containsKey('currency_code'), isFalse, reason: 'nothing is invented on save');
      final legacyItem = VanityItemModel.fromMap({'vanity_item_id': 'i', 'product_id': 'p', 'user_id': 'u', 'price': 9});
      expect(legacyItem.priceCurrency, isNull);
      expect(legacyItem.toMap().containsKey('price_currency'), isFalse);
    });
  });
}
