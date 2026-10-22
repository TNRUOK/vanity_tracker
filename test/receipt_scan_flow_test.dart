// Receipt image -> OCR -> parse -> review -> save regression tests.
// The OCR engine and file picker are MOCKED: these tests do not prove that
// Tesseract.js or ML Kit read a real photo (that is verified separately in a browser).
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/receipt/receipt_review_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_scanner_screen.dart';
import 'package:vanity_tracker/services/ocr/receipt_ocr_service.dart';
import 'package:vanity_tracker/services/receipt_parser_service.dart';

const sephoraSample = '''
SEPHORA
2026-10-12
Hyaluronic Acid Serum \$24.00
Subtotal \$24.00
Tax \$1.92
Total \$25.92
''';

// Smallest valid PNG (1x1), so Image.memory previews decode cleanly in tests.
final onePixelPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReceiptOcrService.debugEngineOverride = null;
  });
  tearDown(() => ReceiptOcrService.debugEngineOverride = null);

  group('Parser regression: SEPHORA sample', () {
    test('merchant, date, item, line amount, subtotal, tax and total', () {
      final d = ReceiptParserService.parseReceiptText(sephoraSample, defaultCurrency: '€');
      expect(d.merchant, 'SEPHORA');
      expect(d.purchaseDate, DateTime(2026, 10, 12));
      expect(d.isDateAmbiguous, isFalse);
      expect(d.dateDetected, isTrue);
      expect(d.currency, '\$', reason: 'explicit \$ on the receipt beats the user default');
      expect(d.currencyDetected, isTrue);
      expect(d.items, hasLength(1));
      expect(d.items.single.description, 'Hyaluronic Acid Serum');
      expect(d.items.single.quantity, 1);
      expect(d.items.single.unitPrice, 24.00);
      expect(d.items.single.totalPrice, 24.00);
      expect(d.subtotal, 24.00);
      expect(d.tax, 1.92);
      expect(d.discount, 0.0);
      expect(d.total, 25.92);
      expect(d.warnings, isEmpty);
    });
  });

  group('Parser: dates', () {
    test('ambiguous numeric dates keep both readings, ordered by currency locale', () {
      final us = ReceiptParserService.parseReceiptText('SHOP\n03/04/2026\nItem \$5.00\nTotal \$5.00');
      expect(us.isDateAmbiguous, isTrue);
      expect(us.purchaseDate, DateTime(2026, 3, 4));
      expect(us.alternateDate, DateTime(2026, 4, 3));
      expect(us.warnings.any((w) => w.contains('day/month')), isTrue);

      final eu = ReceiptParserService.parseReceiptText('SHOP\n03/04/2026\nItem 5,00 €\nTotal 5,00 €');
      expect(eu.purchaseDate, DateTime(2026, 4, 3));
      expect(eu.alternateDate, DateTime(2026, 3, 4));
    });

    test('unambiguous day-first dates and impossible dates', () {
      final d = ReceiptParserService.parseReceiptText('SHOP\n25/06/2026\nTotal \$5.00');
      expect(d.purchaseDate, DateTime(2026, 6, 25));
      expect(d.isDateAmbiguous, isFalse);

      // 31/02 is not a date; it must not roll over into March.
      final bad = ReceiptParserService.parseReceiptText('SHOP\n31/02/2026\nTotal \$5.00');
      expect(bad.dateDetected, isFalse);
      expect(bad.warnings.any((w) => w.contains('No purchase date')), isTrue);
    });

    test('textual dates', () {
      expect(ReceiptParserService.parseReceiptText('SHOP\n12 Oct 2026\nTotal \$1.00').purchaseDate, DateTime(2026, 10, 12));
      expect(ReceiptParserService.parseReceiptText('SHOP\nOctober 3, 2026\nTotal \$1.00').purchaseDate, DateTime(2026, 10, 3));
    });

    test('brand names that start like months are not dates', () {
      final d = ReceiptParserService.parseReceiptText('ULTA\n1 Maybelline Mascara 12.00\nTotal 12.00');
      expect(d.dateDetected, isFalse);
      // A bare leading "1" is kept (it may be part of a name like "3 in 1"); the user can edit it.
      expect(d.items.single.description, contains('Maybelline Mascara'));
      expect(d.items.single.totalPrice, 12.00);
    });

    test('a dotted date line is not parsed as a price', () {
      final d = ReceiptParserService.parseReceiptText('DM DROGERIE\n12.10.2026\nNivea Creme 3,95 €\nSumme 3,95 €\nTotal 3,95 €');
      expect(d.purchaseDate, DateTime(2026, 10, 12));
      expect(d.items.map((i) => i.description), ['Nivea Creme']);
    });
  });

  group('Parser: currency and amounts', () {
    test('no currency marker uses the default and warns', () {
      final d = ReceiptParserService.parseReceiptText('SHOP\n2026-01-02\nSerum 10.00\nTotal 10.00', defaultCurrency: '₹');
      expect(d.currency, '₹');
      expect(d.currencyDetected, isFalse);
      expect(d.warnings.any((w) => w.contains('No currency symbol')), isTrue);
    });

    test('C\$ is not mistaken for US \$', () {
      final d = ReceiptParserService.parseReceiptText('SHOPPERS\n2026-01-02\nCleanser C\$12.00\nTotal C\$12.00');
      expect(d.currency, 'C\$');
      expect(d.items.single.unitPrice, 12.00);
    });

    test('comma decimals and thousands separators', () {
      final d = ReceiptParserService.parseReceiptText('PARFUMERIE\n2026-01-02\nParfum 1.234,50 €\nTotal 1.234,50 €');
      expect(d.total, 1234.50);
      final us = ReceiptParserService.parseReceiptText('NEIMAN\n2026-01-02\nPalette \$1,050.00\nTotal \$1,050.00');
      expect(us.items.single.totalPrice, 1050.00);
    });

    test('quantity formats', () {
      final d = ReceiptParserService.parseReceiptText(
        'SHOP\n2026-01-02\nSheet Mask 3 @ 2.50 7.50\n2x Lip Balm 8.00\nToner x2 30.00\nTotal 45.50',
      );
      expect(d.items, hasLength(3));
      expect((d.items[0].description, d.items[0].quantity, d.items[0].unitPrice, d.items[0].totalPrice),
          ('Sheet Mask', 3, 2.50, 7.50));
      expect((d.items[1].description, d.items[1].quantity, d.items[1].unitPrice), ('Lip Balm', 2, 4.00));
      expect((d.items[2].description, d.items[2].quantity, d.items[2].unitPrice), ('Toner', 2, 15.00));
    });

    test('words merely containing tax keywords are items; balance due is a total', () {
      final d = ReceiptParserService.parseReceiptText(
        'SHOP\n2026-01-02\nVatika Hair Oil 10.00\nGST 1.00\nBALANCE DUE 11.00',
      );
      expect(d.items.single.description, 'Vatika Hair Oil');
      expect(d.tax, 1.00);
      expect(d.total, 11.00);
    });
  });

  group('Parser: consistency checks', () {
    test('inconsistent totals are flagged, not silently corrected', () {
      final d = ReceiptParserService.parseReceiptText(
        'SHOP\n2026-01-02\nSerum \$24.00\nSubtotal \$24.00\nTax \$1.92\nTotal \$30.00',
      );
      expect(d.total, 30.00);
      expect(d.warnings.any((w) => w.startsWith('Totals do not add up')), isTrue);
    });

    test('line items that do not match the subtotal are flagged', () {
      final d = ReceiptParserService.parseReceiptText(
        'SHOP\n2026-01-02\nSerum \$24.00\nSubtotal \$40.00\nTotal \$40.00',
      );
      expect(d.warnings.any((w) => w.contains('Line items add up')), isTrue);
    });
  });

  group('OCR service', () {
    test('image bytes without a local path reach the engine unchanged', () async {
      String? gotPath;
      Uint8List? gotBytes;
      String? gotMime;
      ReceiptOcrService.debugEngineOverride = ({filePath, bytes, mimeType}) async {
        gotPath = filePath;
        gotBytes = bytes;
        gotMime = mimeType;
        return '  SEPHORA\nTotal \$1.00  ';
      };
      final text = await ReceiptParserService.extractText(imageBytes: onePixelPng, mimeType: 'image/png');
      expect(gotPath, isNull);
      expect(gotBytes, same(onePixelPng));
      expect(gotMime, 'image/png');
      expect(text, 'SEPHORA\nTotal \$1.00');
    });

    test('empty path string is treated as "no path"; nothing at all throws', () async {
      String? gotPath = 'unset';
      ReceiptOcrService.debugEngineOverride = ({filePath, bytes, mimeType}) async {
        gotPath = filePath;
        return '';
      };
      expect(await ReceiptParserService.extractText(imagePath: '', imageBytes: onePixelPng), '');
      expect(gotPath, isNull);
      await expectLater(ReceiptParserService.extractText(imagePath: '', imageBytes: Uint8List(0)), throwsA(isA<Exception>()));
    });

    test('engine failures propagate with their message', () async {
      ReceiptOcrService.debugEngineOverride =
          ({filePath, bytes, mimeType}) async => throw Exception('In-browser OCR failed: OCR engine could not start');
      await expectLater(
        ReceiptParserService.extractText(imageBytes: onePixelPng),
        throwsA(predicate((e) => e.toString().contains('could not start'))),
      );
    });

    test('mime types from extensions', () {
      expect(ReceiptOcrService.mimeTypeForExtension('PNG'), 'image/png');
      expect(ReceiptOcrService.mimeTypeForExtension('.webp'), 'image/webp');
      expect(ReceiptOcrService.mimeTypeForExtension(null), 'image/jpeg');
    });

    test('amount input accepts comma decimals', () {
      expect(parseAmountInput('24,50'), 24.50);
      expect(parseAmountInput(' \$1,234.50 '), 1234.50);
      expect(parseAmountInput(''), isNull);
      expect(parseAmountInput('abc'), isNull);
    });
  });

  group('Scanner and review screens', () {
    late VanityProvider vanity;
    late ReceiptProvider receipts;
    late AuthProvider auth;

    Future<void> pumpApp(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      vanity = VanityProvider();
      receipts = ReceiptProvider();
      auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vanity),
          ChangeNotifierProvider.value(value: receipts),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => home)),
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

    testWidgets('bytes-only image is OCRed and opens the review screen without saving', (tester) async {
      final calls = <(String?, int, String?)>[];
      await pumpApp(
        tester,
        ReceiptScannerScreen(
          pickImage: () async => PickedReceiptImage(bytes: onePixelPng, name: 'r.png', mimeType: 'image/png'),
          recognizeText: ({imagePath, imageBytes, mimeType}) async {
            calls.add((imagePath, imageBytes!.length, mimeType));
            return sephoraSample;
          },
        ),
      );

      await tester.tap(find.text('Select Receipt Image'));
      await tester.pumpAndSettle();

      expect(calls, [(null, onePixelPng.length, 'image/png')]);
      expect(find.byType(ReceiptReviewScreen), findsOneWidget);
      expect(find.widgetWithText(TextField, 'SEPHORA'), findsOneWidget);
      expect(find.widgetWithText(TextField, '25.92'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Hyaluronic Acid Serum'), findsOneWidget);
      // Nothing is persisted before the user confirms.
      expect(receipts.receipts, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('local_receipts'), isNull);
    });

    testWidgets('empty OCR result shows guidance and the manual-text fallback', (tester) async {
      await pumpApp(
        tester,
        ReceiptScannerScreen(
          pickImage: () async => PickedReceiptImage(bytes: onePixelPng),
          recognizeText: ({imagePath, imageBytes, mimeType}) async => '   \n ',
        ),
      );
      await tester.tap(find.text('Select Receipt Image'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('receipt-scan-error')), findsOneWidget);
      expect(find.textContaining('No text was recognized'), findsOneWidget);
      expect(find.byKey(const Key('receipt-manual-text')), findsOneWidget);
      expect(find.byType(ReceiptReviewScreen), findsNothing);

      // Manual fallback still reaches the review screen.
      await tester.enterText(find.byKey(const Key('receipt-manual-text')), sephoraSample);
      await tester.tap(find.text('Parse Text'));
      await tester.pumpAndSettle();
      expect(find.byType(ReceiptReviewScreen), findsOneWidget);
    });

    testWidgets('OCR failure shows the error and Retry rescans the same image', (tester) async {
      var attempts = 0;
      await pumpApp(
        tester,
        ReceiptScannerScreen(
          pickImage: () async => PickedReceiptImage(bytes: onePixelPng),
          recognizeText: ({imagePath, imageBytes, mimeType}) async {
            attempts++;
            if (attempts == 1) throw Exception('In-browser OCR failed: OCR engine could not start');
            return sephoraSample;
          },
        ),
      );
      await tester.tap(find.text('Select Receipt Image'));
      await tester.pumpAndSettle();
      expect(find.textContaining('OCR engine could not start'), findsOneWidget);

      await tester.tap(find.text('Retry scan'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.byType(ReceiptReviewScreen), findsOneWidget);
    });

    testWidgets('cancelling the picker does nothing', (tester) async {
      var ocrCalled = false;
      await pumpApp(
        tester,
        ReceiptScannerScreen(
          pickImage: () async => null,
          recognizeText: ({imagePath, imageBytes, mimeType}) async {
            ocrCalled = true;
            return '';
          },
        ),
      );
      await tester.tap(find.text('Select Receipt Image'));
      await tester.pumpAndSettle();
      expect(ocrCalled, isFalse);
      expect(find.byKey(const Key('receipt-scan-error')), findsNothing);
    });

    testWidgets('edits are saved only on Confirm; shelf price is preserved; spending is not double counted',
        (tester) async {
      final draft = ReceiptParserService.parseReceiptText(sephoraSample);
      await pumpApp(tester, ReceiptReviewScreen(initialDraft: draft));

      const product = ProductModel(
        productId: 'p_serum',
        barcode: '1',
        name: 'Hyaluronic Acid Serum',
        brand: 'The Ordinary',
        categoryId: 'serum',
        paoMonths: 12,
      );
      vanity.loadItemsFromList([
        const VanityItemModel(
          vanityItemId: 'shelf_serum',
          productId: 'p_serum',
          userId: 'demo_user',
          product: product,
          price: 30.00,
          status: 'active',
        ),
        const VanityItemModel(
          vanityItemId: 'other',
          productId: 'p_x',
          userId: 'demo_user',
          price: 10.00,
          priceCurrency: 'USD',
          status: 'active',
        ),
      ]);
      // Re-open so auto-matching sees the shelf items.
      Navigator.of(tester.element(find.byType(ReceiptReviewScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(receipts.receipts, isEmpty);

      await tester.enterText(find.widgetWithText(TextField, 'SEPHORA'), 'Sephora Times Square');
      await tester.enterText(find.widgetWithText(TextField, '25.92'), '25,92');
      await tester.pump();
      expect(receipts.receipts, isEmpty, reason: 'editing must not save');

      // The line shows that it matches the shelf serum; linking the purchase is the user's
      // explicit one-tap choice (lines are no longer linked silently).
      final link = find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('line-link-'));
      expect(link, findsOneWidget);
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(receipts.receipts, hasLength(1));
      final saved = receipts.receipts.single;
      expect(saved.merchant, 'Sephora Times Square');
      expect(saved.totalAmount, 25.92);
      expect(saved.taxAmount, 1.92);
      expect(saved.purchaseDate, DateTime(2026, 10, 12));
      expect(saved.items.single.unitPrice, 24.00, reason: 'historical purchase price kept on the receipt');
      expect(saved.items.single.matchedVanityItemId, 'shelf_serum');

      // Existing inventory price was NOT overwritten by the receipt price.
      expect(vanity.allItems.firstWhere((i) => i.vanityItemId == 'shelf_serum').price, 30.00);

      // Unified spending: receipt total + only the unlinked shelf item.
      final spending = vanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '\$');
      expect(spending.receiptTotal, 25.92);
      expect(spending.directItemsTotal, 10.00);
      expect(spending.total, 35.92);

      // Saving the same receipt id again is idempotent; a re-scan is flagged as a duplicate.
      expect(
        receipts.findPotentialDuplicate(merchant: 'sephora times square', date: DateTime(2026, 10, 12), total: 25.92),
        isNotNull,
      );
    });
  });
}
