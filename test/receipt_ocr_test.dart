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
import 'package:vanity_tracker/screens/receipt/receipt_review_screen.dart';
import 'package:vanity_tracker/services/receipt_parser_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReceiptParserService Tests', () {
    test('Parses standard receipt with merchant, date, lines, tax, and total', () {
      const receiptRaw = '''
SEPHORA BEAUTY
Store #4210
Date: 2026-08-15
Hyaluronic Acid Serum 24.50
Ceramide Moisturizer 28.00
Subtotal: 52.50
Tax: 4.20
Total: 56.70
Thank you for shopping with us!
''';

      final draft = ReceiptParserService.parseReceiptText(receiptRaw, defaultCurrency: '\$');

      expect(draft.merchant.toUpperCase(), contains('SEPHORA'));
      expect(draft.purchaseDate.year, equals(2026));
      expect(draft.purchaseDate.month, equals(8));
      expect(draft.purchaseDate.day, equals(15));
      expect(draft.isDateAmbiguous, isFalse);
      expect(draft.currency, equals('\$'));
      expect(draft.subtotal, closeTo(52.50, 0.01));
      expect(draft.tax, closeTo(4.20, 0.01));
      expect(draft.total, closeTo(56.70, 0.01));
      expect(draft.items.length, greaterThanOrEqualTo(2));
      expect(draft.items.any((it) => it.description.contains('Serum')), isTrue);
      expect(draft.items.any((it) => it.description.contains('Moisturizer')), isTrue);
    });

    test('Detects ambiguous slash dates and flags alternate candidate', () {
      const receiptRaw = '''
BOOTS UK
Date: 06/07/2026
Sun Cream SPF50 £12.00
Total £12.00
''';

      final draft = ReceiptParserService.parseReceiptText(receiptRaw, defaultCurrency: '£');

      expect(draft.currency, equals('£'));
      expect(draft.isDateAmbiguous, isTrue);
      expect(draft.alternateDate, isNotNull);
      // One is July 6, the other is June 7
      final dates = [draft.purchaseDate, draft.alternateDate!];
      expect(dates.any((d) => d.month == 7 && d.day == 6), isTrue);
      expect(dates.any((d) => d.month == 6 && d.day == 7), isTrue);
    });

    test('Detects foreign currency symbols like Euro', () {
      const receiptRaw = '''
PHARMACIE CENTRALE
Date: 2026-09-01
Eau Thermale 300ml 14.50 €
Total 14.50 €
''';

      final draft = ReceiptParserService.parseReceiptText(receiptRaw, defaultCurrency: '\$');

      expect(draft.currency, equals('€'));
      expect(draft.total, closeTo(14.50, 0.01));
    });

    test('Handles discount line items correctly', () {
      const receiptRaw = '''
ULTA BEAUTY
2026-10-05
Lipstick Velvet 20.00
Discount -5.00
Subtotal 20.00
Tax 1.20
Total 16.20
''';

      final draft = ReceiptParserService.parseReceiptText(receiptRaw);

      expect(draft.discount, closeTo(5.00, 0.01));
      expect(draft.total, closeTo(16.20, 0.01));
    });

    test('Safely handles empty or whitespace-only receipt text', () {
      final emptyDraft = ReceiptParserService.parseReceiptText('   \n  \t  ');

      expect(emptyDraft.merchant, equals('Unidentified Merchant'));
      expect(emptyDraft.total, equals(0.0));
      expect(emptyDraft.items, isEmpty);
      expect(emptyDraft.warnings, contains('Receipt text is empty.'));
    });

    test('extractText throws clear exception when neither path nor bytes are provided', () async {
      expect(
        () => ReceiptParserService.extractText(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Spending Source of Truth & Anti-Double-Counting Tests', () {
    test('calculateUnifiedSpending avoids double counting linked items', () {
      final vanityProv = VanityProvider();

      const productA = ProductModel(
        productId: 'prod_a',
        barcode: '111',
        name: 'Serum A',
        brand: 'Brand X',
        categoryId: 'serum',
        paoMonths: 12,
      );

      const productB = ProductModel(
        productId: 'prod_b',
        barcode: '222',
        name: 'Cream B',
        brand: 'Brand Y',
        categoryId: 'moisturizer',
        paoMonths: 6,
      );

      final itemA = VanityItemModel(
        vanityItemId: 'item_linked_to_receipt',
        productId: 'prod_a',
        userId: 'u1',
        product: productA,
        price: 25.00,
        status: 'active',
      );

      final itemB = VanityItemModel(
        vanityItemId: 'item_direct_shelf_only',
        productId: 'prod_b',
        userId: 'u1',
        product: productB,
        price: 15.00,
        priceCurrency: 'USD',
        status: 'active',
      );

      // Load items into provider
      vanityProv.loadItemsFromList([itemA, itemB]);

      // Confirmed receipt of $30 that links to itemA
      final confirmedReceipt = ReceiptModel(
        receiptId: 'rec_101',
        userId: 'u1',
        merchant: 'Sephora',
        purchaseDate: DateTime(2026, 8, 10),
        currency: '\$',
        currencyCode: 'USD',
        subtotal: 25.00,
        taxAmount: 5.00,
        discountAmount: 0.0,
        totalAmount: 30.00,
        items: [
          const ReceiptItemModel(
            itemId: 'line_1',
            description: 'Serum A',
            quantity: 1,
            unitPrice: 25.00,
            totalPrice: 25.00,
            matchedVanityItemId: 'item_linked_to_receipt',
          ),
        ],
        createdAt: DateTime(2026, 8, 10),
      );

      final spending = vanityProv.calculateUnifiedSpending(
        receipts: [confirmedReceipt],
        currencySymbol: '\$',
      );

      // CRITICAL CHECK:
      // Receipt total ($30) + Unlinked itemB price ($15) = $45
      // NOT $30 + $25 + $15 ($70 double-counted!)
      expect(spending.receiptTotal, closeTo(30.00, 0.01));
      expect(spending.directItemsTotal, closeTo(15.00, 0.01));
      expect(spending.total, closeTo(45.00, 0.01));
      expect(spending.matchedReceiptsCount, equals(1));
      expect(spending.directItemsCount, equals(1));
    });

    test('Foreign currency receipts are not mixed into domestic spending', () {
      final vanityProv = VanityProvider();
      final receiptProv = ReceiptProvider();

      vanityProv.loadItemsFromList([]);

      final usdReceipt = ReceiptModel(
        receiptId: 'rec_usd',
        userId: 'u1',
        merchant: 'Target',
        purchaseDate: DateTime(2026, 5, 1),
        currency: '\$',
        currencyCode: 'USD',
        subtotal: 20.0,
        taxAmount: 0.0,
        discountAmount: 0.0,
        totalAmount: 20.0,
        items: const [],
        createdAt: DateTime(2026, 5, 1),
      );

      final eurReceipt = ReceiptModel(
        receiptId: 'rec_eur',
        userId: 'u1',
        merchant: 'Monoprix Paris',
        purchaseDate: DateTime(2026, 6, 1),
        currency: '€',
        subtotal: 45.0,
        taxAmount: 0.0,
        discountAmount: 0.0,
        totalAmount: 45.0,
        items: const [],
        createdAt: DateTime(2026, 6, 1),
      );

      receiptProv.loadReceiptsFromList([usdReceipt, eurReceipt]);

      // When primary currency is USD ($)
      final spendingUSD = vanityProv.calculateUnifiedSpending(
        receipts: receiptProv.receipts,
        currencySymbol: '\$',
      );

      // USD total should be exactly 20.0, NOT 65.0
      expect(spendingUSD.total, closeTo(20.00, 0.01));

      // Foreign currency totals should accurately register EUR 45.0
      final foreignTotals = receiptProv.foreignCurrencyTotals('\$');
      expect(foreignTotals.containsKey('€'), isTrue);
      expect(foreignTotals['€'], closeTo(45.00, 0.01));
    });

    test('a legacy receipt saved with only "\$" is not assumed to be USD', () {
      final vanityProv = VanityProvider()..loadItemsFromList([]);
      final legacy = ReceiptModel(
        receiptId: 'rec_legacy',
        userId: 'u1',
        merchant: 'Old Store',
        purchaseDate: DateTime(2025, 5, 1),
        currency: '\$',
        subtotal: 20.0,
        totalAmount: 20.0,
        createdAt: DateTime(2025, 5, 1),
      );
      expect(legacy.effectiveCurrencyCode, isNull);
      final spending = vanityProv.calculateUnifiedSpending(receipts: [legacy], currencySymbol: '\$');
      expect(spending.total, 0.0);
      expect(spending.matchedReceiptsCount, 0);
      // The record itself is untouched.
      expect(legacy.totalAmount, 20.0);
      expect(legacy.toMap().containsKey('currency_code'), isFalse);
    });
  });

  group('Duplicate Receipt Detection Tests', () {
    test('Flags potential duplicate with same merchant, date, and total', () {
      final receiptProv = ReceiptProvider();

      final existingReceipt = ReceiptModel(
        receiptId: 'rec_existing',
        userId: 'u1',
        merchant: 'Ulta Beauty',
        purchaseDate: DateTime(2026, 7, 20),
        currency: '\$',
        subtotal: 40.0,
        taxAmount: 2.50,
        discountAmount: 0.0,
        totalAmount: 42.50,
        items: const [],
        createdAt: DateTime(2026, 7, 20),
      );

      receiptProv.loadReceiptsFromList([existingReceipt]);

      final dup = receiptProv.findPotentialDuplicate(
        merchant: 'Ulta Beauty',
        date: DateTime(2026, 7, 20, 14, 30), // Same day, different time
        total: 42.50,
      );

      expect(dup, isNotNull);
      expect(dup!.receiptId, equals('rec_existing'));

      // Different date -> not a duplicate
      final diffDate = receiptProv.findPotentialDuplicate(
        merchant: 'Ulta Beauty',
        date: DateTime(2026, 7, 22),
        total: 42.50,
      );
      expect(diffDate, isNull);

      // Different total -> not a duplicate
      final diffTotal = receiptProv.findPotentialDuplicate(
        merchant: 'Ulta Beauty',
        date: DateTime(2026, 7, 20),
        total: 60.00,
      );
      expect(diffTotal, isNull);
    });

    test('Parses multi-line item where price or MRP is printed on next line', () {
      const receiptRaw = '''
NYKAA BEAUTY
Date: 2026-08-15
Kiehl's Ultra Facial Cream
MRP: 450.00
Total: 450.00
''';
      final draft = ReceiptParserService.parseReceiptText(receiptRaw, defaultCurrency: '₹');
      expect(draft.items, isNotEmpty);
      expect(draft.items.first.description, contains('Kiehl'));
      expect(draft.items.first.unitPrice, closeTo(450.00, 0.01));
    });

    test('Identifies single unpriced product with total for review screen', () {
      const receiptRaw = '''
BEAUTY BOUTIQUE
Date: 2026-09-01
Vitamin C Daily Glow
Total: 35.00
''';
      final draft = ReceiptParserService.parseReceiptText(receiptRaw, defaultCurrency: '\$');
      expect(draft.items, isNotEmpty);
      expect(draft.items.first.description, contains('Vitamin C'));
      expect(draft.total, closeTo(35.00, 0.01));
    });
  });

  group('ReceiptReviewScreen Auto-Fill Price Tests', () {
    late VanityProvider vanity;
    late ReceiptProvider receipts;
    late AuthProvider auth;

    Future<void> pumpReview(WidgetTester tester, ParsedReceiptDraft draft) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      vanity = VanityProvider();
      receipts = ReceiptProvider();
      auth = AuthProvider();
      await auth.useDemoAccount();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: vanity),
            ChangeNotifierProvider.value(value: receipts),
            ChangeNotifierProvider.value(value: auth),
          ],
          child: MaterialApp(
            home: ReceiptReviewScreen(initialDraft: draft),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Auto-fills unit price for single unpriced line when receipt has total', (tester) async {
      final draft = ParsedReceiptDraft(
        receiptId: 'rec_test_1',
        merchant: 'Glow Store',
        purchaseDate: DateTime(2026, 10, 20),
        currency: '\$',
        subtotal: 48.00,
        tax: 0.0,
        discount: 0.0,
        total: 48.00,
        items: [
          const ReceiptItemModel(
            itemId: 'item_1',
            description: 'Night Repair Serum',
            quantity: 1,
            unitPrice: 0.0,
            totalPrice: 0.0,
          ),
        ],
        rawText: 'Night Repair Serum\nTotal 48.00',
      );

      await pumpReview(tester, draft);

      final priceField = find.byKey(const Key('line-price-item_1'));
      expect(priceField, findsOneWidget);
      final widget = tester.widget<TextField>(priceField);
      expect(widget.controller?.text, '48.00');
    });

    testWidgets('Auto-creates draft line item with price prefilled when receipt items is empty', (tester) async {
      final draft = ParsedReceiptDraft(
        receiptId: 'rec_test_2',
        merchant: 'Sephora Express',
        purchaseDate: DateTime(2026, 10, 20),
        currency: '\$',
        subtotal: 65.00,
        tax: 0.0,
        discount: 0.0,
        total: 65.00,
        items: const [],
        rawText: 'Total 65.00',
      );

      await pumpReview(tester, draft);

      final priceField = find.byKey(const Key('line-price-line_initial_0'));
      expect(priceField, findsOneWidget);
      final widget = tester.widget<TextField>(priceField);
      expect(widget.controller?.text, '65.00');
    });

    testWidgets('Auto-fills unallocated remainder when user adds a new line item', (tester) async {
      final draft = ParsedReceiptDraft(
        receiptId: 'rec_test_3',
        merchant: 'Target Beauty',
        purchaseDate: DateTime(2026, 10, 20),
        currency: '\$',
        subtotal: 50.00,
        tax: 0.0,
        discount: 0.0,
        total: 50.00,
        items: [
          const ReceiptItemModel(
            itemId: 'item_1',
            description: 'Lip Gloss',
            quantity: 1,
            unitPrice: 20.00,
            totalPrice: 20.00,
          ),
        ],
        rawText: 'Lip Gloss 20.00\nTotal 50.00',
      );

      await pumpReview(tester, draft);

      // Tap Add Item button
      final addBtn = find.text('Add Item');
      expect(addBtn, findsOneWidget);
      await tester.tap(addBtn);
      await tester.pumpAndSettle();

      final matchingWidgets = find.byWidgetPredicate(
        (w) => w is TextField && w.key is Key && (w.key as Key).toString().contains('line-price-line_added_'),
      );
      expect(matchingWidgets, findsOneWidget);
      final widget = tester.widget<TextField>(matchingWidgets);
      expect(widget.controller?.text, '30.00'); // 50.00 - 20.00 = 30.00
    });
  });
}

