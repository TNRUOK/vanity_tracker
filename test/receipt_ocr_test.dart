import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
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
  });
}
