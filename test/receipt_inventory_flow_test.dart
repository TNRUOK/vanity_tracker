// Receipt -> review -> receipt save -> Vanity Inventory -> spending.
// Runs against the real providers in local (non-Firebase) mode. Failures are injected
// with small subclasses; nothing here touches live Firestore.
import 'dart:async';
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
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/receipt_inventory_service.dart';
import 'package:vanity_tracker/services/receipt_parser_service.dart';

const acceptanceReceipt = '''
NYKAA BEAUTY
12/10/2026
Hydrating Serum — ₹250
Lipstick — ₹400
Cleanser — ₹350
Subtotal — ₹1,000
Tax — ₹50
Total — ₹1,050
''';

/// Real VanityProvider that can be told to fail for specific product names and counts writes.
class FlakyVanityProvider extends VanityProvider {
  final Set<String> failFor;
  int addCalls = 0;
  final writtenIds = <String>[];
  FlakyVanityProvider({Set<String>? failFor}) : failFor = failFor ?? {};

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
    addCalls++;
    if (failFor.contains(product.name)) throw Exception('Simulated write failure');
    final created = await super.addItem(
      product: product,
      userId: userId,
      openedDate: openedDate,
      sealedExpiryDate: sealedExpiryDate,
      batchCode: batchCode,
      manufacturingDate: manufacturingDate,
      price: price,
      priceCurrency: priceCurrency,
      inferPriceCurrency: inferPriceCurrency,
      notes: notes,
      routineTags: routineTags,
      isSharedWithHousehold: isSharedWithHousehold,
      sharedHouseholdId: sharedHouseholdId,
      vanityItemId: vanityItemId,
      throwOnSyncFailure: throwOnSyncFailure,
    );
    writtenIds.add(created.vanityItemId);
    return created;
  }
}

class FailingReceiptProvider extends ReceiptProvider {
  bool fail = true;
  int saves = 0;
  @override
  Future<ReceiptModel> saveReceipt(ReceiptModel receipt) async {
    saves++;
    if (fail) throw Exception('disk full');
    return super.saveReceipt(receipt);
  }
}

ReceiptModel header(String id, {double total = 1050}) => ReceiptModel(
      receiptId: id,
      userId: 'user_a',
      merchant: 'NYKAA BEAUTY',
      purchaseDate: DateTime(2026, 10, 12),
      currency: '₹',
      subtotal: 1000,
      taxAmount: 50,
      totalAmount: total,
      createdAt: DateTime(2026, 10, 12),
    );

List<ReceiptLineRequest> threeNewLines() => const [
      ReceiptLineRequest(lineId: 'l0', description: 'Hydrating Serum', quantity: 1, unitPrice: 250, action: LineItemAction.createNew),
      ReceiptLineRequest(
          lineId: 'l1', description: 'Lipstick', quantity: 1, unitPrice: 400, action: LineItemAction.createNew, categoryId: 'lipstick'),
      ReceiptLineRequest(
          lineId: 'l2', description: 'Cleanser', quantity: 1, unitPrice: 350, action: LineItemAction.createNew, categoryId: 'cleanser'),
    ];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
  });

  // ---------------------------------------------------------------- parser
  group('Parser keeps every product line', () {
    test('acceptance sample: 3 products, totals excluded, whole-rupee prices', () {
      final d = ReceiptParserService.parseReceiptText(acceptanceReceipt, defaultCurrency: '\$');
      expect(d.currency, '₹');
      expect(d.items.map((i) => (i.description, i.unitPrice, i.quantity)).toList(), [
        ('Hydrating Serum', 250.0, 1),
        ('Lipstick', 400.0, 1),
        ('Cleanser', 350.0, 1),
      ]);
      expect(d.items.every((i) => i.isConfirmed), isTrue);
      expect(d.subtotal, 1000);
      expect(d.tax, 50);
      expect(d.total, 1050);
      for (final word in ['Subtotal', 'Tax', 'Total']) {
        expect(d.items.any((i) => i.description.contains(word)), isFalse);
      }
      expect(d.items.map((i) => i.itemId).toSet(), hasLength(3), reason: 'ids must be unique');
    });

    test('real Tesseract output of the acceptance receipt (₹ misread as ¥/3/%/X) is flagged, not trusted', () {
      // Exact text produced by the self-hosted Tesseract.js in Chrome for the rendered sample.
      const ocr = '''
NYKAA BEAUTY
12/10/2026
Hydrating Serum — ¥250
Lipstick — 3400
Cleanser — ¥350
Subtotal — %1,000
Tax — X50
Total — 1,050
''';
      final d = ReceiptParserService.parseReceiptText(ocr, defaultCurrency: '₹');
      expect(d.items.map((i) => i.description).toList(), ['Hydrating Serum', 'Lipstick', 'Cleanser']);
      expect(d.subtotal, 1000, reason: '"%1,000" is a misread ₹1,000');
      expect(d.tax, 50, reason: '"X50" is a misread ₹50');
      expect(d.total, 1050);
      final lipstick = d.items[1];
      expect(lipstick.totalPrice, 3400, reason: 'the read value is shown as read, never silently changed');
      expect(lipstick.isConfirmed, isFalse);
      expect(d.warnings.any((w) => w.contains('"Lipstick" was read as 3400.00') && w.contains('400.00')), isTrue);
      expect(d.warnings.any((w) => w.contains('misreads ₹ as ¥')), isTrue);
    });

    // Same layout as the real receipt behind the "Price $373 / CARDHOLDER / 7 items need
    // attention / $746" report (product and person names here are made up).
    const cardReceipt = '''
Order #000207
07.14.2021 11:11 AM
Rose Water Facial Toner                    \$49.00
150ml
Green Tea Gel Cream                        \$53.00
250ml
Daily Sun Shield                           \$89.00
5oml
Retinol Night Serum                        \$68.00
50ml
Vitamin-C Brightening Drops               \$114.00
30ml
Item Count:                                       5
Price:                                      \$373.00
CARD #: XXXX XXXX XXXX 1234
AUTH: 192837465
CARDHOLDER: A. TESTER
''';

    test('receipt with sizes, item count, "Price:" total and card details', () {
      final d = ReceiptParserService.parseReceiptText(cardReceipt, defaultCurrency: '₹');
      expect(d.items.map((i) => (i.description, i.unitPrice)).toList(), [
        ('Rose Water Facial Toner 150ml', 49.0),
        ('Green Tea Gel Cream 250ml', 53.0),
        ('Daily Sun Shield 5oml', 89.0), // kept exactly as read; the user can correct "5oml"
        ('Retinol Night Serum 50ml', 68.0),
        ('Vitamin-C Brightening Drops 30ml', 114.0),
      ]);
      expect(d.items.every((i) => i.isConfirmed), isTrue, reason: 'every price was read directly from its line');
      expect(d.total, 373.0, reason: '"Price:" under the products is the total, not a product');
      expect(d.subtotal, 373.0);
      for (final noise in ['Price', 'CARDHOLDER', 'CARD', 'AUTH', 'Item Count', '150ml']) {
        expect(d.items.any((i) => i.description == noise || i.description.startsWith('$noise:')), isFalse, reason: noise);
      }
      expect(d.purchaseDate, DateTime(2021, 7, 14));
      expect(d.currency, '\$');
      expect(d.merchant, isNot('150ml'));
      expect(d.warnings.where((w) => w.contains('without a price') || w.contains('item count')), isEmpty);
    });

    test('item count on the receipt is cross-checked', () {
      final d = ReceiptParserService.parseReceiptText('SHOP\n2026-01-02\nToner \$10.00\nItems: 3\nTotal \$10.00');
      expect(d.items, hasLength(1));
      expect(d.warnings.any((w) => w.contains('says 3 items, but 1 was found')), isTrue);
    });

    test('product names containing label words are kept', () {
      final d = ReceiptParserService.parseReceiptText(
          'SHOP\n2026-01-02\nPrice Match Serum \$10.00\nAmount Of Love Lip Oil \$12.00\nTotal \$22.00');
      expect(d.items.map((i) => i.description).toList(), ['Price Match Serum', 'Amount Of Love Lip Oil']);
    });

    test('column layout: names block then prices block are paired only when counts match', () {
      final d = ReceiptParserService.parseReceiptText('''
SHOP
2026-01-02
Item
Rose Toner
Gel Cream
Sun Shield
Price
\$49.00
\$53.00
\$89.00
Total \$191.00
''');
      expect(d.items.map((i) => (i.description, i.unitPrice)).toList(),
          [('Rose Toner', 49.0), ('Gel Cream', 53.0), ('Sun Shield', 89.0)]);
      expect(d.items.every((i) => !i.isConfirmed), isTrue, reason: 'matched by order: flagged');
      expect(d.warnings.any((w) => w.contains('matched to product names by their order')), isTrue);

      // One price missing -> no pairing guess; the stray amounts are reported instead.
      final bad = ReceiptParserService.parseReceiptText(
          'SHOP\n2026-01-02\nRose Toner\nGel Cream\nSun Shield\nPrice\n\$49.00\n\$53.00\nTotal \$191.00');
      expect(bad.items.where((i) => i.unitPrice > 0), isEmpty);
      expect(bad.warnings.any((w) => w.contains('not assigned to any product') && w.contains('49.00')), isTrue);
    });

    test('a total-like amount is never assigned to a product', () {
      final d = ReceiptParserService.parseReceiptText(cardReceipt);
      expect(d.items.any((i) => i.totalPrice == 373.0), isFalse);
    });

    test('one product', () {
      final d = ReceiptParserService.parseReceiptText('SHOP\n2026-01-02\nToner \$15.00\nTotal \$15.00');
      expect(d.items.single.description, 'Toner');
    });

    test('five or more products, repeated names on different lines are all kept', () {
      final d = ReceiptParserService.parseReceiptText('''
SHOP
2026-01-02
Sheet Mask 3.00
Sheet Mask 3.00
Lip Balm 4.50
Toner 15.00
Serum 24.00
Sunscreen 18.00
Subtotal 67.50
Total 67.50
''');
      expect(d.items.map((i) => i.description).toList(),
          ['Sheet Mask', 'Sheet Mask', 'Lip Balm', 'Toner', 'Serum', 'Sunscreen']);
      expect(d.items.fold<double>(0, (s, i) => s + i.totalPrice), 67.50);
      expect(d.warnings.where((w) => w.contains('Line items add up')), isEmpty);
    });

    test('wrapped descriptions are joined and flagged for review', () {
      final d = ReceiptParserService.parseReceiptText('''
SHOP
2026-01-02
Toner 10.00
Hydrating Facial Cleanser
For Normal Skin
350.00
Serum
2 x 12.00 24.00
Total 384.00
''');
      // A name wrapped over two lines with its price on a third line is ONE product.
      expect(d.items.map((i) => i.description).toList(), ['Toner', 'Hydrating Facial Cleanser For Normal Skin', 'Serum']);
      final wrapped = d.items[1];
      expect(wrapped.totalPrice, 350.00);
      expect(wrapped.isConfirmed, isFalse, reason: 'joined from several lines: flagged for review');
      final serum = d.items.firstWhere((i) => i.description == 'Serum');
      expect((serum.quantity, serum.unitPrice, serum.totalPrice), (2, 12.00, 24.00));
    });

    test('a line without a price is kept for review when the priced products do not account for the total', () {
      final d = ReceiptParserService.parseReceiptText('''
SEPHORA
2026-01-02
Serum \$24.00
Eye Cream
Cream \$30.00
Subtotal \$74.00
Total \$74.00
''');
      expect(d.items.map((i) => i.description).toList(), ['Serum', 'Eye Cream', 'Cream']);
      final eye = d.items[1];
      expect(eye.unitPrice, 0);
      expect(eye.isConfirmed, isFalse, reason: 'price unknown: the review screen asks for it');
      expect(d.warnings.any((w) => w.contains('without a price may be a product')), isTrue);
    });

    test('a line without a price is NOT made a product when the priced products already match the total', () {
      final d = ReceiptParserService.parseReceiptText('''
SEPHORA
Store #4210
Cashier Anna
2026-01-02
Serum \$24.00
Free Sample Pouch
Cream \$30.00
Subtotal \$54.00
Total \$54.00
Thank you
''');
      // Serum + Cream = subtotal, so "Free Sample Pouch" is reported, not turned into an item;
      // store/cashier header lines are never products.
      expect(d.items.map((i) => i.description).toList(), ['Serum', 'Cream']);
      expect(d.warnings.any((w) => w.contains('1 line without a price was not added') && w.contains('Add Item')), isTrue);
    });

    test('whole-number receipts: prices read but flagged; reference numbers ignored', () {
      final d = ReceiptParserService.parseReceiptText('''
MEDPLUS
Bill No 4471
Store 12
Cleanser 350
Moisturizer 420
Total 770
''');
      expect(d.items.map((i) => (i.description, i.unitPrice)).toList(), [('Cleanser', 350.0), ('Moisturizer', 420.0)]);
      expect(d.items.every((i) => !i.isConfirmed), isTrue);
      expect(d.total, 770);
    });

    test('expensive items are kept (flagged), not silently dropped', () {
      final d = ReceiptParserService.parseReceiptText('LUXE\n2026-01-02\nParfum ₹12,500\nTotal ₹12,500');
      expect(d.items.single.unitPrice, 12500);
      expect(d.items.single.isConfirmed, isFalse);
    });

    test('uncertain OCR text never gets an invented price', () {
      final d = ReceiptParserService.parseReceiptText('SHOP\n2026-01-02\nToner 10.00\nC1eanser ~~ 12.0O\nTotal 22.00');
      final suspect = d.items.where((i) => i.description.startsWith('C1eanser'));
      for (final s in suspect) {
        expect(s.unitPrice, 0);
        expect(s.isConfirmed, isFalse);
      }
    });

    test('discount, tax and payment lines are never products', () {
      final d = ReceiptParserService.parseReceiptText('''
SHOP
2026-01-02
Serum 20.00
Member Discount -5.00
Sales Tax 1.20
VISA ****1234 16.20
Change 0.00
Total 16.20
''');
      expect(d.items.map((i) => i.description), ['Serum']);
      expect(d.discount, 5.00);
    });

    test('empty, unreadable and malformed input do not crash', () {
      for (final raw in ['', '   ', '@@@@ ### !!!', '\u0000\u0001', '₹₹₹', '----\n====\n....', '9' * 500]) {
        final d = ReceiptParserService.parseReceiptText(raw);
        expect(d.items, isEmpty, reason: raw);
      }
    });
  });

  // ---------------------------------------------------------- persistence
  group('ReceiptInventoryService', () {
    test('three selected lines -> three separate, unopened inventory records owned by the user', () async {
      final vanity = FlakyVanityProvider();
      final receipts = ReceiptProvider();
      final report = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_A'),
        lines: threeNewLines(),
        userId: 'user_a',
        vanity: vanity,
        receipts: receipts,
      );

      expect(report.receiptSaved, isTrue);
      expect(report.message, contains('3 of 3 items added to Vanity Inventory'));
      expect(vanity.allItems, hasLength(3));
      expect(vanity.allItems.map((i) => i.vanityItemId).toSet(), hasLength(3));
      for (final item in vanity.allItems) {
        expect(item.userId, 'user_a');
        expect(item.openedDate, isNull, reason: 'purchase is not opening');
        expect(item.expiryDate, isNull);
        expect(item.status, 'unopened');
        expect(item.product!.brand, isEmpty, reason: 'store name must not become the brand');
        expect(item.product!.barcode, isEmpty);
      }
      final lipstick = vanity.allItems.firstWhere((i) => i.product!.name == 'Lipstick');
      expect(lipstick.price, 400);
      expect(lipstick.product!.categoryId, 'lipstick');

      // Receipt keeps all lines, each linked to its own record.
      final saved = receipts.receipts.single;
      expect(saved.items, hasLength(3));
      expect(saved.items.map((i) => i.matchedVanityItemId).toSet(), vanity.allItems.map((i) => i.vanityItemId).toSet());
      expect(saved.totalAmount, 1050);
    });

    test('ten quickly-created items never overwrite each other', () async {
      final vanity = VanityProvider();
      final lines = [
        for (var i = 0; i < 10; i++)
          ReceiptLineRequest(lineId: 'l$i', description: 'Item $i', quantity: 1, unitPrice: 10, action: LineItemAction.createNew),
      ];
      await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_10', total: 100),
        lines: lines,
        userId: 'user_a',
        vanity: vanity,
        receipts: ReceiptProvider(),
      );
      expect(vanity.allItems, hasLength(10));
      expect(DatabaseService().getAllCachedItems().where((i) => i.vanityItemId.contains('rec_10')), hasLength(10));

      // Also without explicit ids: items started in the same millisecond (concurrently)
      // got the same timestamp-only id under the old scheme and overwrote each other.
      final plain = VanityProvider();
      final created = await Future.wait([
        for (var i = 0; i < 20; i++)
          plain.addItem(
            product: ProductModel(productId: 'p$i', barcode: '', name: 'P$i', brand: '', categoryId: 'serum', paoMonths: 12),
            userId: 'u',
          ),
      ]);
      expect(created.map((c) => c.vanityItemId).toSet(), hasLength(20));
      expect(plain.allItems, hasLength(20));
    });

    test('one failure is reported; successful items are kept; retry adds only the failed one', () async {
      final vanity = FlakyVanityProvider(failFor: {'Lipstick'});
      final receipts = ReceiptProvider();

      final first = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_B'),
        lines: threeNewLines(),
        userId: 'user_a',
        vanity: vanity,
        receipts: receipts,
      );
      expect(first.addedCount, 2);
      expect(first.failedCount, 1);
      expect(first.isComplete, isFalse);
      expect(first.message, contains('2 of 3 items added'));
      expect(first.message, contains('Lipstick'));
      expect(vanity.allItems.map((i) => i.product!.name).toSet(), {'Hydrating Serum', 'Cleanser'});
      // Receipt is saved; the failed line is kept on it but unlinked.
      final lip = receipts.receipts.single.items.firstWhere((i) => i.description == 'Lipstick');
      expect(lip.matchedVanityItemId, isNull);

      // Retry: the UI passes the lines that already succeeded.
      vanity.failFor.clear();
      vanity.addCalls = 0;
      final retry = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_B'),
        lines: threeNewLines(),
        userId: 'user_a',
        vanity: vanity,
        receipts: receipts,
        alreadyAddedLineIds: {
          for (final r in first.lines)
            if (r.isAddedToInventory) r.lineId,
        },
      );
      expect(vanity.addCalls, 1, reason: 'only the failed line is written again');
      expect(retry.isComplete, isTrue);
      expect(retry.message, contains('3 of 3 items added'));
      expect(vanity.allItems, hasLength(3));
      expect(receipts.receipts, hasLength(1), reason: 'same receipt id: spending recorded once');
      expect(receipts.receipts.single.items.every((i) => i.matchedVanityItemId != null), isTrue);
    });

    test('replaying a whole submission (ambiguous timeout) creates no duplicates', () async {
      final vanity = FlakyVanityProvider();
      final receipts = ReceiptProvider();
      for (var attempt = 0; attempt < 3; attempt++) {
        await ReceiptInventoryService.saveReceiptAndInventory(
          receiptHeader: header('rec_C'),
          lines: threeNewLines(),
          userId: 'user_a',
          vanity: vanity,
          receipts: receipts,
        );
      }
      expect(vanity.allItems, hasLength(3));
      expect(vanity.writtenIds.toSet(), hasLength(3));
      expect(receipts.receipts, hasLength(1));
    });

    test('identical product names on separate lines are separate purchases', () async {
      final vanity = VanityProvider();
      await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_D', total: 6),
        lines: const [
          ReceiptLineRequest(lineId: 'a', description: 'Sheet Mask', quantity: 1, unitPrice: 3, action: LineItemAction.createNew),
          ReceiptLineRequest(lineId: 'b', description: 'Sheet Mask', quantity: 1, unitPrice: 3, action: LineItemAction.createNew),
        ],
        userId: 'user_a',
        vanity: vanity,
        receipts: ReceiptProvider(),
      );
      expect(vanity.allItems.where((i) => i.product!.name == 'Sheet Mask'), hasLength(2));
    });

    test('no selection: receipt saved, nothing added, honest message', () async {
      final vanity = VanityProvider();
      final receipts = ReceiptProvider();
      final r = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_E'),
        lines: [for (final l in threeNewLines()) ReceiptLineRequest(lineId: l.lineId, description: l.description, quantity: 1, unitPrice: l.unitPrice)],
        userId: 'user_a',
        vanity: vanity,
        receipts: receipts,
      );
      expect(r.isComplete, isTrue);
      expect(r.message, contains('No products were selected for Vanity Inventory'));
      expect(vanity.allItems, isEmpty);
      expect(receipts.receipts.single.items, hasLength(3));
    });

    test('receipt save failure is reported, never shown as success', () async {
      final vanity = VanityProvider();
      final receipts = FailingReceiptProvider();
      final r = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_F'),
        lines: threeNewLines(),
        userId: 'user_a',
        vanity: vanity,
        receipts: receipts,
      );
      expect(r.receiptSaved, isFalse);
      expect(r.isComplete, isFalse);
      expect(r.message, startsWith('Receipt NOT saved'));
      expect(receipts.receipts, isEmpty);
    });

    test('matching an existing shelf item links it and keeps its price unless asked', () async {
      final vanity = VanityProvider();
      vanity.loadItemsFromList([
        const VanityItemModel(vanityItemId: 'shelf_1', productId: 'p', userId: 'user_a', price: 300, status: 'unopened'),
      ]);
      final receipts = ReceiptProvider();
      await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header('rec_G', total: 250),
        lines: const [
          ReceiptLineRequest(
              lineId: 'm', description: 'Serum', quantity: 1, unitPrice: 250, action: LineItemAction.matchExisting, matchedVanityItemId: 'shelf_1'),
        ],
        userId: 'user_a',
        vanity: vanity,
        receipts: receipts,
      );
      expect(vanity.allItems.single.price, 300);
      expect(receipts.receipts.single.items.single.matchedVanityItemId, 'shelf_1');
    });

    test('a signed-in user is required', () async {
      expect(
        () => ReceiptInventoryService.saveReceiptAndInventory(
          receiptHeader: header('rec_H'),
          lines: threeNewLines(),
          userId: '',
          vanity: VanityProvider(),
          receipts: ReceiptProvider(),
        ),
        throwsArgumentError,
      );
    });

    test('spending counts the purchase exactly once', () async {
      final vanity = FlakyVanityProvider(failFor: {'Lipstick'});
      vanity.loadItemsFromList([
        const VanityItemModel(
          vanityItemId: 'older',
          productId: 'p',
          userId: 'user_a',
          price: 99,
          priceCurrency: 'INR',
          status: 'unopened',
        ),
      ]);
      final receipts = ReceiptProvider();
      Future<void> run({Set<String> done = const {}}) => ReceiptInventoryService.saveReceiptAndInventory(
            receiptHeader: header('rec_S'),
            lines: threeNewLines(),
            userId: 'user_a',
            vanity: vanity,
            receipts: receipts,
            alreadyAddedLineIds: done,
          );

      await run(); // partial
      var s = vanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '₹');
      expect(s.total, 1050 + 99, reason: 'receipt once + the unrelated older item');

      vanity.failFor.clear();
      await run(done: {'l0', 'l2'}); // retry
      await run(done: {'l0', 'l1', 'l2'}); // accidental replay
      s = vanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '₹');
      expect(s.receiptTotal, 1050);
      expect(s.directItemsTotal, 99, reason: 'items created from the receipt are not counted again');
      expect(s.total, 1149);
    });
  });

  testWidgets('offline cloud writes time out once, then later writes do not wait', (tester) async {
    final never = Completer<void>(); // an offline Firestore write never completes
    Object? first;
    DatabaseService.awaitCloudWrite(never.future).catchError((Object e) => first = e);
    await tester.pump(DatabaseService.cloudWriteTimeout + const Duration(seconds: 1));
    expect(first, isA<TimeoutException>());

    // Next write while still unreachable fails fast (no second 10 s wait).
    Object? second;
    DatabaseService.awaitCloudWrite(Completer<void>().future).catchError((Object e) => second = e);
    await tester.pump();
    expect(second, isA<TimeoutException>());

    // When the queued write finally completes, writes are awaited normally again.
    never.complete();
    await tester.pump();
    var ok = false;
    await DatabaseService.awaitCloudWrite(Future.value()).then((_) => ok = true);
    expect(ok, isTrue);
  });

  // ------------------------------------------------------------ review UI
  group('Receipt review screen', () {
    late FlakyVanityProvider vanity;
    late ReceiptProvider receipts;

    Future<void> openReview(WidgetTester tester, {Set<String>? failFor}) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      vanity = FlakyVanityProvider(failFor: failFor);
      receipts = ReceiptProvider();
      final auth = AuthProvider();
      await auth.useDemoAccount();
      final draft = ReceiptParserService.parseReceiptText(acceptanceReceipt, defaultCurrency: '₹');
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: vanity),
          ChangeNotifierProvider.value(value: receipts),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ReceiptReviewScreen(initialDraft: draft)),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder lineNames() => find.byWidgetPredicate((w) => w is TextField && (w.key as ValueKey?)?.value.toString().startsWith('line-name-') == true);

    Future<void> chooseAddNew(WidgetTester tester, int lineIndex) async {
      final actions = find.byWidgetPredicate(
          (w) => w is DropdownButton<LineItemAction> && (w.key as ValueKey?)?.value.toString().startsWith('line-action-') == true);
      await tester.tap(actions.at(lineIndex));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Add as new item to shelf').last);
      await tester.pumpAndSettle();
    }

    testWidgets('shows every product line and none of the totals', (tester) async {
      await openReview(tester);
      expect(find.text('Purchased Items (3)'), findsOneWidget);
      final names = tester.widgetList<TextField>(lineNames()).map((t) => t.controller!.text).toList();
      expect(names, ['Hydrating Serum', 'Lipstick', 'Cleanser']);
    });

    testWidgets('only the selected lines are added, each once', (tester) async {
      await openReview(tester);
      await chooseAddNew(tester, 0);
      await chooseAddNew(tester, 2);
      await tester.tap(find.text('Confirm & Save Receipt'));
      await tester.pumpAndSettle();

      expect(vanity.allItems.map((i) => i.product!.name).toSet(), {'Hydrating Serum', 'Cleanser'});
      expect(receipts.receipts.single.items, hasLength(3));
      expect(find.textContaining('2 of 2 items added to Vanity Inventory'), findsOneWidget);
      expect(find.byType(ReceiptReviewScreen), findsNothing, reason: 'complete save closes the review');
    });

    testWidgets('invalid line data blocks saving with field errors', (tester) async {
      await openReview(tester);
      final price = find.byWidgetPredicate((w) => w is TextField && (w.key as ValueKey?)?.value.toString().startsWith('line-price-') == true);
      await tester.enterText(price.at(1), '');
      await tester.enterText(lineNames().at(2), '');
      await tester.tap(find.text('Confirm & Save Receipt'));
      await tester.pumpAndSettle();
      expect(find.text('Enter the price (0 if free), or remove the line if it is not a product'), findsOneWidget);
      expect(find.text('Enter a product name'), findsOneWidget);
      expect(find.textContaining('2 items need attention'), findsOneWidget);
      expect(receipts.receipts, isEmpty);
    });

    testWidgets('a double tap saves once', (tester) async {
      await openReview(tester);
      await chooseAddNew(tester, 0);
      final confirm = find.text('Confirm & Save Receipt');
      await tester.tap(confirm);
      await tester.tap(confirm, warnIfMissed: false);
      await tester.tap(find.text('Confirm'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(vanity.addCalls, 1);
      expect(receipts.receipts, hasLength(1));
    });

    testWidgets('partial failure is shown per item and Retry adds only the failed item', (tester) async {
      await openReview(tester, failFor: {'Lipstick'});
      for (var i = 0; i < 3; i++) {
        await chooseAddNew(tester, i);
      }
      await tester.tap(find.text('Confirm & Save Receipt'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('receipt-save-report')), findsOneWidget);
      expect(find.textContaining('2 of 3 items added'), findsWidgets);
      expect(find.textContaining('✗ Not added'), findsOneWidget);
      expect(find.text('✓ Added to Vanity Inventory'), findsNWidgets(2));
      expect(find.byType(ReceiptReviewScreen), findsOneWidget, reason: 'stays open for retry');

      vanity.failFor.clear();
      vanity.addCalls = 0;
      await tester.tap(find.text('Retry failed items').first);
      await tester.pumpAndSettle();

      expect(vanity.addCalls, 1);
      expect(vanity.allItems, hasLength(3));
      expect(receipts.receipts, hasLength(1));
      expect(find.byType(ReceiptReviewScreen), findsNothing);
    });
  });
}
