import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/product/edit_product_screen.dart';
import 'package:vanity_tracker/screens/product/product_detail_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_review_screen.dart';
import 'package:vanity_tracker/screens/stats/stats_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/exchange_rate_service.dart';
import 'package:vanity_tracker/services/product_data_merge.dart';
import 'package:vanity_tracker/services/receipt_inventory_service.dart';
import 'package:vanity_tracker/services/receipt_parser_service.dart';

import 'helpers/fake_rates.dart';

const me = 'demo_user';

const receiptText = '''
GLOW BEAUTY STORE
2026-10-15
Fresh Soy Face Cleanser 150ml ₹1,500.00
SPF 50 Facial Sunscreen ₹900.00
Hydrating Serum ₹1,200.00
Ruby Woo Lipstick ₹1,100.00
Daily Defense ₹500.00
Subtotal ₹5,200.00
Total ₹5,200.00
''';

ProductModel product(String name, {String category = 'serum', int pao = 12, PaoSource paoSource = PaoSource.user}) =>
    ProductModel(
      productId: 'p_$name',
      barcode: '',
      name: name,
      brand: 'Brand',
      categoryId: category,
      categorySource: CategorySource.user,
      paoMonths: pao,
      paoSource: paoSource,
      createdAt: DateTime(2026, 9, 1),
    );

void main() {
  late VanityProvider vanity;
  late ReceiptProvider receipts;
  late AuthProvider auth;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    vanity = VanityProvider();
    receipts = ReceiptProvider();
    auth = AuthProvider();
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1000, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await auth.useDemoAccount();
    await tester.pumpWidget(const SizedBox()); // fresh tree (the previous screen may have popped itself)
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<VanityProvider>.value(value: vanity),
        ChangeNotifierProvider.value(value: receipts),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => HouseholdProvider()),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, Finder dropdown, String option) async {
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  group('Receipt review → inventory → Product Details', () {
    testWidgets('categories are suggested, corrected, persisted and shown again', (tester) async {
      final draft = ReceiptParserService.parseReceiptText(receiptText, defaultCurrency: '₹');
      await pump(tester, ReceiptReviewScreen(initialDraft: draft));
      String idOf(String name) => draft.items.firstWhere((i) => i.description.contains(name)).itemId;
      final cleanser = idOf('Cleanser'), sunscreen = idOf('Sunscreen'), serum = idOf('Serum');
      final lipstick = idOf('Lipstick'), unknown = idOf('Daily Defense');

      // Suggestions are visible on every line before anything is added.
      expect(find.byKey(Key('line-category-$cleanser-cleanser')), findsOneWidget);
      expect(find.byKey(Key('line-category-$sunscreen-sunscreen')), findsOneWidget);
      expect(find.byKey(Key('line-category-$serum-serum')), findsOneWidget);
      expect(find.byKey(Key('line-category-$lipstick-lipstick')), findsOneWidget);
      expect(find.byKey(Key('line-category-$unknown-null')), findsOneWidget, reason: 'not defaulted to Serum');
      expect(
        tester.widget<Text>(find.byKey(Key('line-category-hint-$cleanser'))).data,
        contains('Suggested from "cleanser" in the name'),
      );
      expect(tester.widget<Text>(find.byKey(Key('line-category-hint-$unknown'))).data, contains('Not recognised'));

      // Correct one suggestion before saving.
      await choose(tester, find.byKey(Key('line-category-$serum-serum')), 'Treatment');
      expect(tester.widget<Text>(find.byKey(Key('line-category-hint-$serum'))).data, 'Chosen by you');

      // Everything to the shelf except the unrecognised line (receipt only).
      await tester.ensureVisible(find.byKey(const ValueKey('add-all-to-inventory')));
      await tester.tap(find.byKey(const ValueKey('add-all-to-inventory')));
      await tester.pumpAndSettle();
      await choose(tester, find.byKey(Key('line-action-$unknown')), 'Keep on receipt only');
      await tester.ensureVisible(find.text('Confirm & Save Receipt'));
      await tester.tap(find.text('Confirm & Save Receipt'));
      await tester.pumpAndSettle();

      final rid = draft.receiptId;
      VanityItemModel inv(String line) =>
          vanity.allItems.firstWhere((i) => i.vanityItemId == ReceiptInventoryService.inventoryIdFor(rid, line));
      expect(vanity.allItems, hasLength(4), reason: 'receipt-only line creates no inventory record');
      expect(inv(cleanser).product!.categoryId, 'cleanser');
      expect(inv(cleanser).product!.categorySource, CategorySource.nameClassifier);
      expect(inv(sunscreen).product!.categoryId, 'sunscreen');
      expect(inv(lipstick).product!.categoryId, 'lipstick');
      expect(inv(serum).product!.categoryId, 'treatment');
      expect(inv(serum).product!.categorySource, CategorySource.user);
      for (final line in [cleanser, sunscreen, serum, lipstick]) {
        final i = inv(line);
        expect(i.openedDate, isNull, reason: 'buying is not opening');
        expect(i.expiryDate, isNull);
        expect(i.product!.paoSource, PaoSource.categoryDefault);
        expect(i.priceCurrency, 'INR');
      }
      final saved = receipts.receipts.single;
      expect(saved.currencyCode, 'INR');
      expect(saved.totalAmount, 5200);
      expect(saved.items.firstWhere((l) => l.itemId == unknown).matchedVanityItemId, isNull);

      // Reload from storage: the same categories come back.
      final reloaded = VanityProvider();
      await reloaded.loadItems(me);
      expect(
        reloaded.allItems.firstWhere((i) => i.vanityItemId == inv(serum).vanityItemId).product!.categoryId,
        'treatment',
      );

      // Product Details shows the saved category and its source.
      await pump(tester, ProductDetailScreen(vanityItemId: inv(serum).vanityItemId));
      expect(tester.widget<Text>(find.byKey(const ValueKey('detail-category'))).data, 'Treatment · Chosen by you');
      await pump(tester, ProductDetailScreen(vanityItemId: inv(cleanser).vanityItemId));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('detail-category'))).data,
        'Cleanser · Suggested from the product name',
      );
    });

    test('an uncategorized line is saved as such, with PAO unknown', () async {
      final v = VanityProvider();
      final r = ReceiptProvider();
      final report = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: ReceiptModel(
          receiptId: 'rec_u',
          userId: me,
          merchant: 'M',
          purchaseDate: DateTime(2026, 10, 1),
          currency: '₹',
          currencyCode: 'INR',
          subtotal: 10,
          totalAmount: 10,
          createdAt: DateTime(2026, 10, 1),
        ),
        lines: const [
          ReceiptLineRequest(lineId: 'x', description: 'Daily Defense', quantity: 1, unitPrice: 10, action: LineItemAction.createNew),
        ],
        userId: me,
        vanity: v,
        receipts: r,
      );
      expect(report.addedCount, 1);
      final p = v.allItems.single.product!;
      expect(p.categoryId, 'other');
      expect(p.categorySource, CategorySource.unknown);
      expect(p.paoSource, PaoSource.unknown);
      expect(p.knownPaoMonths, isNull);
    });

    test('retrying a receipt does not duplicate items, products or categories', () async {
      final v = VanityProvider();
      final r = ReceiptProvider();
      Future<void> run() => ReceiptInventoryService.saveReceiptAndInventory(
            receiptHeader: ReceiptModel(
              receiptId: 'rec_retry',
              userId: me,
              merchant: 'M',
              purchaseDate: DateTime(2026, 10, 1),
              currency: '₹',
              currencyCode: 'INR',
              subtotal: 10,
              totalAmount: 10,
              createdAt: DateTime(2026, 10, 1),
            ),
            lines: const [
              ReceiptLineRequest(
                lineId: 'a',
                description: 'Face Cleanser',
                quantity: 1,
                unitPrice: 10,
                action: LineItemAction.createNew,
                categoryId: 'cleanser',
              ),
            ],
            userId: me,
            vanity: v,
            receipts: r,
          );
      await run();
      await run();
      expect(v.allItems, hasLength(1));
      expect(v.allItems.single.product!.productId, 'prod_${ReceiptInventoryService.inventoryIdFor('rec_retry', 'a')}');
      expect(r.receipts, hasLength(1));
      expect(v.categories.where((c) => c.categoryId == 'cleanser'), hasLength(1));
    });

    test('a later product lookup never overwrites the saved category', () {
      final current = product('Gentle Cleanser', category: 'cleanser');
      final fetched = current.copyWith(categoryId: 'moisturizer', categorySource: CategorySource.productDatabase);
      final merged = ProductDataMerge.merge(current: current, fetched: fetched, sourceName: 'Open Beauty Facts').merged;
      expect(merged.categoryId, 'cleanser');
      expect(merged.categorySource, CategorySource.user);
    });

    testWidgets('an old "Serum" default is only corrected when the user accepts the suggestion', (tester) async {
      Future<VanityItemModel> legacy(String id, PaoSource paoSource, DateTime? opened) => vanity.addItem(
            vanityItemId: id,
            product: ProductModel(
              productId: 'p_$id',
              barcode: '',
              name: 'Gentle Face Cleanser',
              brand: 'Brand',
              categoryId: 'serum', // the old receipt default
              paoMonths: 6,
              paoSource: paoSource,
            ),
            userId: me,
            openedDate: opened,
          );
      final kept = await legacy('legacy_verified', PaoSource.packaging, DateTime(2026, 8, 1));
      await pump(tester, ProductDetailScreen(vanityItemId: kept.vanityItemId));
      expect(tester.widget<Text>(find.byKey(const ValueKey('detail-category'))).data, 'Serum · Source not recorded');
      expect(vanity.allItems.firstWhere((i) => i.vanityItemId == kept.vanityItemId).product!.categoryId, 'serum',
          reason: 'nothing changes by itself');
      await tester.tap(find.byKey(const ValueKey('detail-category-suggestion')));
      await tester.pumpAndSettle();
      final after = vanity.allItems.firstWhere((i) => i.vanityItemId == kept.vanityItemId);
      expect(after.product!.categoryId, 'cleanser');
      expect(after.product!.categorySource, CategorySource.user);
      expect(after.product!.paoMonths, 6, reason: 'PAO from the packaging is kept');
      expect(after.product!.paoSource, PaoSource.packaging);
      expect(after.openedDate, DateTime(2026, 8, 1));
      expect(after.expiryDate, kept.expiryDate);
      expect(find.byKey(const ValueKey('detail-category-suggestion')), findsNothing);

      final estimate = await legacy('legacy_estimate', PaoSource.categoryDefault, DateTime(2026, 8, 1));
      await pump(tester, ProductDetailScreen(vanityItemId: estimate.vanityItemId));
      await tester.tap(find.byKey(const ValueKey('detail-category-suggestion')));
      await tester.pumpAndSettle();
      final est = vanity.allItems.firstWhere((i) => i.vanityItemId == estimate.vanityItemId);
      expect(est.product!.paoMonths, 12, reason: 'an estimate follows the new category');
      expect(est.product!.paoSource, PaoSource.categoryDefault);
      expect(est.openedDate, DateTime(2026, 8, 1));
      expect(est.expiryDate, VanityItemModel.computeExpiryDate(DateTime(2026, 8, 1), 12));
    });

    test('legacy products without a category source stay readable', () {
      final p = ProductModel.fromMap({'product_id': 'x', 'name': 'Old', 'category_id': 'serum', 'pao_months': 12});
      expect(p.categoryId, 'serum');
      expect(p.categorySource, CategorySource.notRecorded);
      final none = ProductModel.fromMap({'product_id': 'y', 'name': 'Older'});
      expect(none.categoryId, 'other');
    });
  });

  group('Edit Product: category changes protect PAO and dates', () {
    Future<VanityItemModel> seed(PaoSource paoSource, int pao) async {
      final opened = DateTime(2026, 9, 1);
      return vanity.addItem(
        vanityItemId: 'edit_me',
        product: product('Night Repair', category: 'serum', pao: pao, paoSource: paoSource),
        userId: me,
        openedDate: opened,
        price: 30,
        priceCurrency: 'USD',
      );
    }

    testWidgets('a verified PAO and the opening date are kept when the category changes', (tester) async {
      final item = await seed(PaoSource.user, 6);
      final expiryBefore = item.expiryDate;
      await pump(tester, EditProductScreen(item: item));
      expect(find.text('Serum'), findsWidgets, reason: 'Edit loads the saved category');

      await choose(tester, find.byKey(const Key('edit-category')), 'Cleanser');
      expect(find.byKey(const Key('edit-pao-kept-note')), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = vanity.allItems.single;
      expect(saved.product!.categoryId, 'cleanser');
      expect(saved.product!.categorySource, CategorySource.user);
      expect(saved.product!.paoMonths, 6);
      expect(saved.product!.paoSource, PaoSource.user);
      expect(saved.openedDate, DateTime(2026, 9, 1));
      expect(saved.expiryDate, expiryBefore);
      expect(saved.price, 30);
      expect(saved.priceCurrency, 'USD');

      final reloaded = VanityProvider();
      await reloaded.loadItems(me);
      final again = reloaded.allItems.firstWhere((i) => i.vanityItemId == 'edit_me');
      expect(again.product!.categoryId, 'cleanser');
      expect(again.product!.paoMonths, 6);
    });

    testWidgets('a category-estimate PAO follows the new category (stays an estimate)', (tester) async {
      final item = await seed(PaoSource.categoryDefault, 12);
      await pump(tester, EditProductScreen(item: item));
      await choose(tester, find.byKey(const Key('edit-category')), 'Mascara');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = vanity.allItems.single;
      expect(saved.product!.paoMonths, 3);
      expect(saved.product!.paoSource, PaoSource.categoryDefault);
      expect(saved.openedDate, DateTime(2026, 9, 1), reason: 'opening date unchanged');
      expect(saved.expiryDate, VanityItemModel.computeExpiryDate(DateTime(2026, 9, 1), 3));
    });
  });

  group('Budget Stats display currency', () {
    // 2026-10-15: 1 EUR = 1.25 USD = 100 INR = 0.8 GBP -> 1 USD = 80 INR, 1 GBP = 125 INR.
    final table = {
      '2026-10-15': {'USD': 1.25, 'INR': 100.0, 'GBP': 0.8},
    };

    ReceiptModel r(String id, double total, String code, String symbol) => ReceiptModel(
          receiptId: id,
          userId: me,
          merchant: 'Shop $id',
          purchaseDate: DateTime(2026, 10, 17), // weekend: uses the 10-15 rate
          currency: symbol,
          currencyCode: code,
          subtotal: total,
          totalAmount: total,
          createdAt: DateTime(2026, 10, 17),
        );

    testWidgets('changing the currency converts totals; records are not modified; no repeat requests', (tester) async {
      final src = FixedEcbRateSource(table);
      ExchangeRateService.shared = ExchangeRateService(source: src, now: () => DateTime(2026, 10, 18));
      receipts.loadReceiptsFromList([r('usd', 10, 'USD', '\$'), r('gbp', 4, 'GBP', '£'), r('inr', 100, 'INR', '₹')]);
      final before = receipts.receipts.map((x) => x.toMap().toString()).toList();
      await vanity.setCurrency('INR');
      await pump(tester, const StatsScreen());

      // ₹800 + ₹500 + ₹100, each converted on its own.
      expect(find.textContaining('Total Spent — INR: ₹1,400.00'), findsOneWidget);
      final callsAfterFirstLoad = src.calls.length;
      expect(callsAfterFirstLoad, 1);

      // Rebuilds do not request rates again.
      for (var i = 0; i < 5; i++) {
        vanity.setSearchQuery('x$i');
        await tester.pumpAndSettle();
      }
      expect(src.calls.length, callsAfterFirstLoad);

      // Switch to USD: ₹100 × (1.25/100) = $1.25, £4 × (1.25/0.8) = $6.25, $10 native.
      await tester.tap(find.byKey(const Key('budget-currency-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('budget-currency-USD')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Total Spent — USD: \$17.50'), findsOneWidget);

      // Conversion details show the original amount, the rate and its date.
      await tester.tap(find.byKey(const Key('toggle-conversions')));
      await tester.pumpAndSettle();
      expect(find.textContaining('£4.00 GBP → \$6.25'), findsOneWidget);
      expect(find.textContaining('rate of 2026-10-15 (no rate published on the purchase date'), findsWidgets);

      expect(receipts.receipts.map((x) => x.toMap().toString()).toList(), before, reason: 'records unchanged');
    });

    testWidgets('legacy "\$" receipts are listed and only counted after the user confirms the currency',
        (tester) async {
      ExchangeRateService.shared = ExchangeRateService(source: FixedEcbRateSource(table), now: () => DateTime(2026, 10, 18));
      final legacy = ReceiptModel(
        receiptId: 'legacy',
        userId: me,
        merchant: 'Old Shop',
        purchaseDate: DateTime(2026, 10, 15),
        currency: '\$',
        subtotal: 10,
        totalAmount: 10,
        createdAt: DateTime(2026, 10, 15),
      );
      receipts.loadReceiptsFromList([legacy]);
      await vanity.setCurrency('INR');
      await pump(tester, const StatsScreen());
      expect(find.textContaining('Total Spent — INR: ₹0.00'), findsOneWidget);
      expect(find.byKey(const Key('unknown-receipt-currency-\$')), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirm-receipts-\$')));
      await tester.pumpAndSettle();
      final updated = receipts.receipts.single;
      expect(updated.currencyCode, 'USD');
      expect(updated.currency, '\$', reason: 'original symbol kept');
      expect(updated.totalAmount, 10, reason: 'amount unchanged');
      expect(find.textContaining('Total Spent — INR: ₹800.00'), findsOneWidget);
    });

    testWidgets('offline: foreign amounts are shown in their own currency, not as zero-valued conversions',
        (tester) async {
      ExchangeRateService.shared = ExchangeRateService(source: OfflineRateSource(), now: () => DateTime(2026, 10, 18));
      receipts.loadReceiptsFromList([r('usd', 10, 'USD', '\$'), r('inr', 100, 'INR', '₹')]);
      await vanity.setCurrency('INR');
      await pump(tester, const StatsScreen());
      expect(find.textContaining('Total Spent — INR: ₹100.00'), findsOneWidget);
      expect(find.byKey(const Key('not-converted')), findsOneWidget);
      expect(find.textContaining('\$10.00 USD'), findsOneWidget);
      expect(find.textContaining('offline'), findsWidgets);
    });
  });
}
