// Receipt History, reopening a saved receipt, adding its products to the Vanity Inventory
// afterwards, and the per-currency spending rules. Local (non-Firebase) mode only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/receipt/receipt_detail_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_history_screen.dart';
import 'package:vanity_tracker/screens/stats/stats_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/exchange_rate_service.dart';
import 'package:vanity_tracker/services/receipt_inventory_service.dart';

import 'helpers/fake_rates.dart';

const me = 'demo_user'; // AuthProvider.useDemoAccount()

ReceiptModel usdReceipt() => ReceiptModel(
      receiptId: 'rec_usd',
      userId: me,
      merchant: 'Beauty Store',
      purchaseDate: DateTime(2021, 7, 14),
      currency: '\$',
      currencyCode: 'USD',
      subtotal: 373,
      totalAmount: 373,
      createdAt: DateTime(2026, 10, 17),
      items: const [
        ReceiptItemModel(itemId: 'a', description: 'Rose Toner 150ml', unitPrice: 49, totalPrice: 49),
        ReceiptItemModel(itemId: 'b', description: 'Gel Cream 250ml', unitPrice: 53, totalPrice: 53),
        ReceiptItemModel(itemId: 'c', description: 'Sun Shield', quantity: 3, unitPrice: 3.33, totalPrice: 10.00),
      ],
    );

ReceiptModel gbpReceipt() => ReceiptModel(
      receiptId: 'rec_gbp',
      userId: me,
      merchant: 'Chemist',
      purchaseDate: DateTime(2017, 9, 15),
      currency: '£',
      subtotal: 11.12,
      totalAmount: 11.12,
      createdAt: DateTime(2026, 10, 16),
      items: const [ReceiptItemModel(itemId: 'g', description: 'Lip Balm', unitPrice: 11.12, totalPrice: 11.12)],
    );

class FlakyVanity extends VanityProvider {
  final Set<String> failFor = {};
  int calls = 0;
  @override
  Future<VanityItemModel> addItem({
    required ProductModel product,
    required String userId,
    DateTime? openedDate,
    DateTime? sealedExpiryDate,
    DatePrecision sealedExpiryPrecision = DatePrecision.day,
    String? batchCode,
    DateTime? manufacturingDate,
    DatePrecision manufacturingDatePrecision = DatePrecision.day,
    double? price,
    String? priceCurrency,
    bool inferPriceCurrency = true,
    String? notes,
    List<String> routineTags = const [],
    bool isSharedWithHousehold = false,
    String? sharedHouseholdId,
    String? vanityItemId,
    bool throwOnSyncFailure = false,
  }) async {
    calls++;
    if (failFor.contains(product.name)) throw Exception('Simulated write failure');
    return super.addItem(
      product: product,
      userId: userId,
      price: price,
      priceCurrency: priceCurrency,
      inferPriceCurrency: inferPriceCurrency,
      notes: notes,
      vanityItemId: vanityItemId,
      throwOnSyncFailure: throwOnSyncFailure,
    );
  }
}

void main() {
  late FlakyVanity vanity;
  late ReceiptProvider receipts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    vanity = FlakyVanity();
    receipts = ReceiptProvider();
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = AuthProvider();
    await auth.useDemoAccount();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<VanityProvider>.value(value: vanity),
        ChangeNotifierProvider.value(value: receipts),
        ChangeNotifierProvider.value(value: auth),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  group('Receipt persistence and history', () {
    test('a saved receipt is persisted with all its lines and can be loaded again', () async {
      await receipts.saveReceipt(usdReceipt());
      final fresh = ReceiptProvider();
      await fresh.loadReceipts(me);
      expect(fresh.errorMessage, isNull);
      expect(fresh.hasLoadedFor(me), isTrue);
      final r = fresh.receiptById('rec_usd')!;
      expect(r.items.map((i) => i.description), ['Rose Toner 150ml', 'Gel Cream 250ml', 'Sun Shield']);
      expect(r.totalAmount, 373);
      expect(r.currency, '\$');
    });

    test('saving the same receipt again does not create a second receipt', () async {
      await receipts.saveReceipt(usdReceipt());
      await receipts.saveReceipt(usdReceipt());
      final fresh = ReceiptProvider();
      await fresh.loadReceipts(me);
      expect(fresh.receipts.where((r) => r.receiptId == 'rec_usd'), hasLength(1));
    });

    test('other users\' receipts are never loaded', () async {
      await receipts.saveReceipt(usdReceipt().copyWith(receiptId: 'rec_other', userId: 'someone_else'));
      await receipts.saveReceipt(usdReceipt());
      final fresh = ReceiptProvider();
      await fresh.loadReceipts(me);
      expect(fresh.receipts.map((r) => r.receiptId), ['rec_usd']);
    });

    testWidgets('history lists saved receipts with their status; empty state when none', (tester) async {
      await pump(tester, const ReceiptHistoryScreen());
      expect(find.text('No saved receipts yet'), findsOneWidget);

      await receipts.saveReceipt(usdReceipt());
      await receipts.saveReceipt(gbpReceipt());
      await receipts.saveReceipt(ReceiptModel(
        receiptId: 'rec_total_only',
        userId: me,
        merchant: 'Kiosk',
        purchaseDate: DateTime(2026, 1, 1),
        subtotal: 5,
        totalAmount: 5,
        createdAt: DateTime(2026, 1, 1),
      ));
      await tester.pumpAndSettle();

      expect(find.text('3 saved receipts'), findsOneWidget);
      expect(find.text('\$373.00'), findsOneWidget);
      expect(find.text('£11.12'), findsOneWidget);
      expect(find.textContaining('3 product lines · 0 in Vanity Inventory'), findsOneWidget);
      expect(find.textContaining('Total only: no product lines were saved'), findsOneWidget);
    });

    testWidgets('opening a receipt shows its saved lines and prices', (tester) async {
      await receipts.saveReceipt(usdReceipt());
      await pump(tester, const ReceiptHistoryScreen());
      await tester.tap(find.byKey(const Key('receipt-tile-rec_usd')));
      await tester.pumpAndSettle();

      expect(find.byType(ReceiptDetailScreen), findsOneWidget);
      expect(find.text('Rose Toner 150ml'), findsOneWidget);
      expect(find.text('3 × \$3.33\n\$10.00'), findsOneWidget, reason: 'stored line total shown as saved');
      expect(find.text('Receipt only'), findsNWidgets(3));
      expect(find.byKey(const Key('receipt-detail-mismatch')), findsOneWidget,
          reason: 'lines (112) do not match the total (373): the user is told');
    });
  });

  group('Adding products from a saved receipt', () {
    testWidgets('selected products become separate unopened inventory items; reopening shows them; no duplicates',
        (tester) async {
      await receipts.saveReceipt(usdReceipt());
      await pump(tester, const ReceiptDetailScreen(receiptId: 'rec_usd'));

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      expect(find.text('Add Selected Products to Vanity Inventory (2)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('add-selected-to-inventory')));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 of 2 items added to Vanity Inventory'), findsOneWidget);
      expect(vanity.allItems.map((i) => i.product!.name).toSet(), {'Rose Toner 150ml', 'Sun Shield'});
      expect(vanity.allItems.map((i) => i.vanityItemId).toSet(), {
        ReceiptInventoryService.inventoryIdFor('rec_usd', 'a'),
        ReceiptInventoryService.inventoryIdFor('rec_usd', 'c'),
      });
      for (final i in vanity.allItems) {
        expect(i.userId, me);
        expect(i.openedDate, isNull);
        expect(i.expiryDate, isNull);
        expect(i.product!.brand, isEmpty);
      }

      // The stored receipt keeps its amounts and now links the two lines.
      final saved = receipts.receiptById('rec_usd')!;
      expect(saved.items.map((i) => i.totalPrice), [49, 53, 10.00], reason: 'historical amounts unchanged');
      expect(saved.items.where((i) => i.matchedVanityItemId != null), hasLength(2));
      expect(receipts.receipts, hasLength(1));
      expect(find.text('✓ In Vanity Inventory'), findsNWidgets(2));

      // Reopen: added lines are locked; selecting the remaining one adds only that one.
      await pump(tester, const ReceiptDetailScreen(receiptId: 'rec_usd'));
      expect(find.text('✓ In Vanity Inventory'), findsNWidgets(2));
      vanity.calls = 0;
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-selected-to-inventory')));
      await tester.pumpAndSettle();
      expect(vanity.calls, 1);
      expect(vanity.allItems, hasLength(3));
      expect(find.byKey(const Key('add-selected-to-inventory')), findsNothing, reason: 'nothing left to add');
    });

    testWidgets('a failed item is reported, others are kept, Retry adds only the failed one', (tester) async {
      await receipts.saveReceipt(usdReceipt());
      vanity.failFor.add('Gel Cream 250ml');
      await pump(tester, const ReceiptDetailScreen(receiptId: 'rec_usd'));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byType(Checkbox).at(i));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-selected-to-inventory')));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 of 3 items added'), findsWidgets);
      expect(find.textContaining('✗ Not added'), findsOneWidget);
      expect(vanity.allItems, hasLength(2));
      expect(find.text('Retry failed items'), findsOneWidget);

      vanity.failFor.clear();
      vanity.calls = 0;
      await tester.tap(find.byKey(const Key('add-selected-to-inventory')));
      await tester.pumpAndSettle();
      expect(vanity.calls, 1);
      expect(vanity.allItems, hasLength(3));
      expect(vanity.allItems.map((i) => i.vanityItemId).toSet(), hasLength(3));
    });

    test('adding from history after adding from review creates no duplicate (same deterministic id)', () async {
      await receipts.saveReceipt(usdReceipt());
      Future<void> add() => ReceiptInventoryService.saveReceiptAndInventory(
            receiptHeader: receipts.receiptById('rec_usd')!,
            lines: const [
              ReceiptLineRequest(lineId: 'a', description: 'Rose Toner 150ml', quantity: 1, unitPrice: 49, action: LineItemAction.createNew),
            ],
            userId: me,
            vanity: vanity,
            receipts: receipts,
          );
      await add();
      await add();
      expect(vanity.allItems, hasLength(1));
    });

    testWidgets('a receipt without stored lines says so and offers nothing to add', (tester) async {
      await receipts.saveReceipt(ReceiptModel(
        receiptId: 'rec_total_only',
        userId: me,
        merchant: 'Kiosk',
        purchaseDate: DateTime(2026, 1, 1),
        subtotal: 5,
        totalAmount: 5,
        createdAt: DateTime(2026, 1, 1),
      ));
      await pump(tester, const ReceiptDetailScreen(receiptId: 'rec_total_only'));
      expect(find.textContaining('cannot be recovered'), findsOneWidget);
      expect(find.byKey(const Key('add-selected-to-inventory')), findsNothing);
    });

    testWidgets('another user\'s receipt id cannot be opened', (tester) async {
      await receipts.saveReceipt(usdReceipt().copyWith(receiptId: 'rec_other', userId: 'someone_else'));
      await pump(tester, const ReceiptDetailScreen(receiptId: 'rec_other'));
      expect(find.text('This receipt is not available for your account.'), findsOneWidget);
    });

    testWidgets('deleting a receipt removes its spending but keeps shelf products', (tester) async {
      await receipts.saveReceipt(usdReceipt());
      await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: usdReceipt(),
        lines: const [
          ReceiptLineRequest(lineId: 'a', description: 'Rose Toner 150ml', quantity: 1, unitPrice: 49, action: LineItemAction.createNew),
        ],
        userId: me,
        vanity: vanity,
        receipts: receipts,
      );
      await pump(tester, const ReceiptDetailScreen(receiptId: 'rec_usd'));
      await tester.tap(find.byTooltip('Delete receipt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(receipts.receipts, isEmpty);
      expect(vanity.allItems, hasLength(1));
      final s = vanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '\$');
      expect(s.total, 49, reason: 'the product\'s own price now counts once, the receipt is gone');
    });
  });

  group('Currency rules (Budget Stats)', () {
    test('receipts in other currencies are kept separate and never summed', () async {
      await receipts.saveReceipt(usdReceipt().copyWith(totalAmount: 746, subtotal: 746));
      await receipts.saveReceipt(gbpReceipt());

      final inr = vanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '₹');
      expect(inr.total, 0);
      expect(inr.matchedReceiptsCount, 0);
      expect(receipts.foreignCurrencyTotals('₹'), {'\$': 746.0, '£': 11.12});

      final usd = vanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '\$');
      expect(usd.total, 746);
      expect(usd.matchedReceiptsCount, 1);
      expect(receipts.foreignCurrencyTotals('\$'), {'£': 11.12});
      expect(usd.total, isNot(746 + 11.12));
    });

    testWidgets('Budget Stats explains which receipts are in the total and links to them', (tester) async {
      // No rate can be loaded (offline): foreign receipts are listed, never summed as ₹.
      ExchangeRateService.shared = ExchangeRateService(source: OfflineRateSource(), now: () => DateTime(2026, 10, 18));
      await receipts.saveReceipt(usdReceipt().copyWith(totalAmount: 746, subtotal: 746));
      await receipts.saveReceipt(gbpReceipt());
      await vanity.setCurrency('INR');
      await pump(tester, const StatsScreen());
      await tester.pumpAndSettle();

      expect(find.textContaining('Total Spent — INR: ₹0.00'), findsOneWidget);
      expect(find.textContaining('from 0 saved receipt(s)'), findsOneWidget);
      expect(find.textContaining('not included in the INR total'), findsOneWidget);
      expect(find.textContaining('\$746.00 USD'), findsOneWidget);
      expect(find.textContaining('£11.12 GBP'), findsOneWidget);
      expect(find.text('2 saved receipts in all currencies'), findsOneWidget);

      await tester.tap(find.text('View Receipts'));
      await tester.pumpAndSettle();
      expect(find.byType(ReceiptHistoryScreen), findsOneWidget);
    });
  });
}
