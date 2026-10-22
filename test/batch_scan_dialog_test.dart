// Packaging OCR review dialog + persistence through Edit Product. The OCR engine is a
// scripted fake (no Tesseract/ML Kit in unit tests); real-engine output is covered by the
// corpus in test/fixtures/packaging_ocr.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/product/edit_product_screen.dart';
import 'package:vanity_tracker/screens/product/product_detail_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/ocr/receipt_ocr_service.dart';
import 'package:vanity_tracker/services/packaging_ocr_service.dart';

const me = 'demo_user';
final png = Uint8List.fromList(File('test/fixtures/packaging_ocr/clean_labels.png').readAsBytesSync());

class FailingSave extends VanityProvider {
  @override
  Future<void> updateItem(VanityItemModel item, {bool throwOnSyncFailure = false}) async =>
      throw Exception('disk full');
}

void main() {
  late VanityProvider vanity;
  late List<({String? path, int bytes, String? mime})> engineCalls;

  /// The engine returns [passes] in order (one per OCR pass); a null entry throws.
  void scriptOcr(List<String?> passes) {
    var i = 0;
    ReceiptOcrService.debugEngineOverride = ({String? filePath, Uint8List? bytes, String? mimeType}) async {
      engineCalls.add((path: filePath, bytes: bytes?.length ?? 0, mime: mimeType));
      final t = passes[i < passes.length ? i : passes.length - 1];
      i++;
      if (t == null) throw Exception('engine failure');
      return t;
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    engineCalls = [];
    PackagingOcrService.debugPicker = () async => PickedReceiptImage(bytes: png, name: 'label.png', mimeType: 'image/png');
    PackagingOcrService.debugPrepare = (Uint8List b, {int quarterTurns = 0, ui.Rect? crop, bool enhance = true}) async =>
        PreparedImage(Uint8List.fromList([1, 2, 3]), 1600, 368, [if (enhance) 'grayscale + contrast stretch']);
  });
  tearDown(() {
    ReceiptOcrService.debugEngineOverride = null;
    PackagingOcrService.debugPicker = null;
    PackagingOcrService.debugPrepare = null;
  });

  Future<VanityItemModel> seed({VanityProvider? provider}) async {
    vanity = provider ?? VanityProvider();
    return vanity.addItem(
      vanityItemId: 'serum_1',
      product: const ProductModel(
        productId: 'p1',
        barcode: '',
        name: 'Night Serum',
        brand: 'Brand',
        categoryId: 'serum',
        paoMonths: 6,
        paoSource: PaoSource.user,
      ),
      userId: me,
      openedDate: DateTime(2026, 9, 1),
    );
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = AuthProvider();
    await auth.useDemoAccount();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<VanityProvider>.value(value: vanity),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => HouseholdProvider()),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openDialogAndScan(WidgetTester tester) async {
    final open = find.text('Scan Packaging / Batch Code OCR 📷');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-scan-image')));
    await tester.pumpAndSettle();
  }

  String valueOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('labeled values fill the fields; Confirm & Apply + Save persists them with their precision', (tester) async {
    final item = await seed();
    scriptOcr(['LOT A7K29\nMFG 2024-10-17\nEXP 10/2027', 'LOT A7K29\nMFG 2024-10-17\nEXP 10/2027']);
    await pump(tester, EditProductScreen(item: item));
    await openDialogAndScan(tester);

    // Two passes: the original image (bytes + its own type), then the enhanced PNG.
    expect(engineCalls, hasLength(2));
    expect(engineCalls.first.mime, 'image/png');
    expect(engineCalls.last.bytes, 3);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-code-field'))).controller!.text, 'A7K29');
    expect(valueOf(tester, 'mfg-value'), '2024-10-17');
    expect(valueOf(tester, 'exp-value'), 'Oct 2027 (month only)');
    expect(find.textContaining('Filled from printed labels'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('batch-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = vanity.allItems.single;
    expect(saved.batchCode, 'A7K29');
    expect(saved.manufacturingDate, DateTime(2024, 10, 17));
    expect(saved.manufacturingDatePrecision, DatePrecision.day);
    expect(saved.sealedExpiryDate, DateTime(2027, 10, 1));
    expect(saved.sealedExpiryPrecision, DatePrecision.month);
    // Separate concepts stay separate: opening date and PAO are untouched by OCR.
    expect(saved.openedDate, DateTime(2026, 9, 1));
    expect(saved.product!.paoMonths, 6);
    expect(saved.product!.paoSource, PaoSource.user);
    expect(saved.expiryDate, VanityItemModel.computeExpiryDate(DateTime(2026, 9, 1), 6));

    // Stored and shown with the same precision.
    final reloaded = VanityProvider();
    await reloaded.loadItems(me);
    final again = reloaded.allItems.firstWhere((i) => i.vanityItemId == 'serum_1');
    expect(again.sealedExpiryPrecision, DatePrecision.month);
    expect(again.toMap()['sealed_expiry_precision'], 'month');
    await pump(tester, const ProductDetailScreen(vanityItemId: 'serum_1'));
    expect(find.text('Oct 2027 (month only)'), findsOneWidget);
    expect(find.text('2024-10-17'), findsOneWidget);
  });

  testWidgets('an ambiguous date is not applied until the user chooses a reading', (tester) async {
    final item = await seed();
    scriptOcr(['EXP 04/05/2027', 'EXP 04/05/2027']);
    await pump(tester, EditProductScreen(item: item));
    await openDialogAndScan(tester);

    expect(valueOf(tester, 'exp-value'), 'Not recorded');
    expect(find.byKey(const ValueKey('exp-note')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('exp-choice-2027-04-05')));
    await tester.pumpAndSettle();
    expect(valueOf(tester, 'exp-value'), '2027-04-05');
  });

  testWidgets('a value typed by the user is not overwritten by OCR; candidates stay available', (tester) async {
    final item = await seed();
    scriptOcr(['LOT A7K29', 'LOT A7K29']);
    await pump(tester, EditProductScreen(item: item));
    await tester.tap(find.text('Scan Packaging / Batch Code OCR 📷'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('batch-code-field')), 'MY-CODE');
    await tester.tap(find.byKey(const ValueKey('batch-scan-image')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-code-field'))).controller!.text, 'MY-CODE');
    expect(find.byKey(const ValueKey('batch-candidate-A7K29')), findsOneWidget);
    // Rerunning keeps the user's text too.
    await tester.tap(find.byKey(const ValueKey('batch-rerun')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-code-field'))).controller!.text, 'MY-CODE');
  });

  testWidgets('unlabeled dates and codes are only offered; the user assigns them', (tester) async {
    final item = await seed();
    scriptOcr(['Hydrating Toner\nK42 2027-10-17', 'Hydrating Toner\nK42 2027-10-17']);
    await pump(tester, EditProductScreen(item: item));
    await openDialogAndScan(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-code-field'))).controller!.text, isEmpty);
    expect(valueOf(tester, 'exp-value'), 'Not recorded');
    expect(find.textContaining('nothing could be filled with confidence'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('unlabeled-0-exp')));
    await tester.tap(find.byKey(const ValueKey('batch-candidate-K42')));
    await tester.pumpAndSettle();
    expect(valueOf(tester, 'exp-value'), '2027-10-17');
    expect(valueOf(tester, 'mfg-value'), 'Not recorded');
  });

  testWidgets('no text, engine failure and batch code without a decodable date are explained', (tester) async {
    final item = await seed();
    scriptOcr(['', '  ']);
    await pump(tester, EditProductScreen(item: item));
    await openDialogAndScan(tester);
    expect(find.textContaining('No text was found in this image'), findsOneWidget);
    expect(valueOf(tester, 'mfg-value'), 'Not recorded');

    scriptOcr([null, null]);
    await tester.tap(find.byKey(const ValueKey('batch-rerun')));
    await tester.pumpAndSettle();
    expect(find.textContaining('OCR could not read this image'), findsOneWidget);

    scriptOcr([null, 'LOT 4021A']); // one pass failing does not discard the other
    await tester.tap(find.byKey(const ValueKey('batch-rerun')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-code-field'))).controller!.text, '4021A');
    expect(valueOf(tester, 'mfg-value'), 'Not recorded', reason: 'no manufacturing date is derived from the code');
    expect(find.textContaining('does not derive a manufacturing date'), findsOneWidget);
  });

  testWidgets('typed text path and Cancel (nothing changes)', (tester) async {
    final item = await seed();
    await pump(tester, EditProductScreen(item: item));
    await tester.tap(find.text('Scan Packaging / Batch Code OCR 📷'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-input-text')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('batch-manual-text')), 'BATCH: 2K01\nEXP: 12/2026');
    await tester.tap(find.byKey(const ValueKey('batch-manual-analyze')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('batch-code-field'))).controller!.text, '2K01');
    expect(valueOf(tester, 'exp-value'), 'Dec 2026 (month only)');

    await tester.tap(find.byKey(const ValueKey('batch-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = vanity.allItems.single;
    expect(saved.batchCode, isNull);
    expect(saved.sealedExpiryDate, isNull);
  });

  testWidgets('a failed save is reported, not shown as success', (tester) async {
    final item = await seed(provider: FailingSave());
    scriptOcr(['LOT A7K29', 'LOT A7K29']);
    await pump(tester, EditProductScreen(item: item));
    await openDialogAndScan(tester);
    await tester.tap(find.byKey(const ValueKey('batch-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Error updating'), findsOneWidget);
    expect(find.textContaining('updated successfully'), findsNothing);
    expect(vanity.allItems.single.batchCode, isNull);
  });
}
