// Barcode scanning + product lookup regression tests. HTTP is MOCKED (http.runWithClient);
// the physical camera is not exercised here (see the real-browser fake-camera check).
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/product/add_product_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/product_lookup_service.dart';
import 'package:vanity_tracker/utils/barcode_utils.dart';

/// Responds like the Open*Facts APIs: [products] maps barcode -> product JSON.
MockClient factsClient(Map<String, Map<String, dynamic>> products, {List<Uri>? log}) {
  return MockClient((req) async {
    log?.add(req.url);
    final m = RegExp(r'/product/(\d+)\.json$').firstMatch(req.url.path);
    if (req.url.host.contains('upcitemdb')) {
      return http.Response(jsonEncode({'code': 'OK', 'items': []}), 200);
    }
    if (m != null && products.containsKey(m.group(1)) && req.url.host.contains('openbeautyfacts')) {
      return http.Response(jsonEncode({'status': 1, 'product': products[m.group(1)]}), 200);
    }
    return http.Response(jsonEncode({'status': 0, 'status_verbose': 'product not found'}), 404);
  });
}

/// Shape of the real Open Beauty Facts record for 3337875597180 (fetched 2026-10-18),
/// trimmed to the fields the app reads.
const cerave = <String, dynamic>{
  'code': '3337875597180',
  'product_name': 'Hydrating Cleanser',
  'brands': 'CeraVe',
  'quantity': '236ml',
  'countries_tags': ['en:netherlands'],
  'ingredients_text': 'aqua/water, glycerin, cetearyl alcohol, peg-40 stearate, stearyl alcohol, potassium phosphate, '
      'ceramide np, ceramide ap, ceramide eop',
};

Future<ProductLookupResult> lookupWith(http.Client client, String code) =>
    http.runWithClient(() => ProductLookupService.lookupBarcode(code), () => client);

void main() {
  group('BarcodeUtils', () {
    test('normalizes retail barcodes and rejects everything else', () {
      expect(BarcodeUtils.normalize(' 3337875597180 '), '3337875597180');
      expect(BarcodeUtils.normalize('3337 8755-97180'), '3337875597180');
      expect(BarcodeUtils.normalize('041554420616'), '041554420616');
      expect(BarcodeUtils.normalize('96385074'), '96385074'); // EAN-8
      for (final bad in [null, '', 'https://example.com/x', 'ABC123', '12345', '123456789012345', '../1234567']) {
        expect(BarcodeUtils.normalize(bad), isNull, reason: '$bad');
      }
    });

    test('GS1 check digits', () {
      expect(BarcodeUtils.hasValidCheckDigit('3337875597180'), isTrue);
      expect(BarcodeUtils.hasValidCheckDigit('041554420616'), isTrue);
      expect(BarcodeUtils.hasValidCheckDigit('96385074'), isTrue);
      expect(BarcodeUtils.hasValidCheckDigit('3337875597181'), isFalse);
    });

    test('UPC-A and EAN-13 spellings are equivalent', () {
      expect(BarcodeUtils.equivalents('041554420616'), ['041554420616', '0041554420616']);
      expect(BarcodeUtils.equivalents('0041554420616'), ['0041554420616', '041554420616']);
      expect(BarcodeUtils.equivalents('3337875597180'), ['3337875597180']);
    });
  });

  group('BarcodeScanGate (repeated camera detections)', () {
    test('only the first valid detection is handled until reset', () {
      final gate = BarcodeScanGate();
      expect(gate.accept(['3337875597180']), '3337875597180');
      // The camera keeps reporting the same and other codes many times per second.
      for (var i = 0; i < 20; i++) {
        expect(gate.accept(['3337875597180']), isNull);
        expect(gate.accept(['041554420616']), isNull);
      }
      gate.reset();
      expect(gate.accept(['041554420616']), '041554420616');
    });

    test('non-product codes in a frame are skipped, the product code is used', () {
      final gate = BarcodeScanGate();
      expect(gate.accept([null, 'https://brand.example/promo', '']), isNull);
      expect(gate.isBusy, isFalse);
      expect(gate.accept(['WIFI:S:x;;', ' 3337875597180 ']), '3337875597180');
    });
  });

  group('ProductLookupService', () {
    // The built-in catalog is only an offline fallback now (one of its barcodes was shown by
    // Open Beauty Facts to belong to a different product), and it is labelled unverified.
    test('offline: catalog fallback is labelled unverified; UPC-A/EAN-13 forms both match', () async {
      final offline = MockClient((_) async => throw http.ClientException('offline'));
      final a = await lookupWith(offline, '041554420616');
      final b = await lookupWith(offline, '0041554420616');
      expect(a.found, isTrue);
      expect(b.found, isTrue);
      expect(b.product!.name, a.product!.name);
      expect(a.source, contains('unverified'));
      expect(a.errorMessage, contains('check that the name matches'));
      expect(a.product!.paoSource, PaoSource.appCatalog);
    });

    test('online: the database record wins over the catalog', () async {
      final calls = <Uri>[];
      final r = await lookupWith(
        factsClient({
          '041554420616': {'product_name': 'Real Record', 'brands': 'Real Brand'},
        }, log: calls),
        '041554420616',
      );
      expect(r.product!.name, 'Real Record');
      expect(r.source, 'Open Beauty Facts');
      expect(calls.first.host, 'world.openbeautyfacts.org');
    });

    test('online success with blank fields falls back to the next field', () async {
      final r = await lookupWith(
        factsClient({
          '4005900259615': {'product_name': '', 'generic_name': 'Sun Protection Lotion SPF50', 'brands': 'Nivea'},
        }),
        '4005900259615',
      );
      expect(r.found, isTrue);
      expect(r.source, 'Open Beauty Facts');
      expect(r.product!.name, 'Sun Protection Lotion SPF50');
      expect(r.product!.brand, 'Nivea');
      expect(r.hasMissingDetails, isFalse);
    });

    test('record without name/brand is flagged instead of filled with placeholders', () async {
      final r = await lookupWith(factsClient({'4005900259615': {'quantity': '200 ml'}}), '4005900259615');
      expect(r.found, isTrue);
      expect(r.product!.name, isEmpty);
      expect(r.product!.brand, isEmpty);
      expect(r.hasMissingDetails, isTrue);
      expect(r.product!.name, isNot(contains('Cosmetic Product')));
      expect(r.product!.brand, isNot(contains('Unknown Brand')));
    });

    test('unknown barcode is NOT reported as a found product (no prefix guessing)', () async {
      final r = await lookupWith(factsClient({}), '3000000000007');
      expect(r.found, isFalse);
      expect(r.product, isNull);
      expect(r.networkError, isFalse);
      expect(r.barcode, '3000000000007');
      expect(r.errorMessage, contains('no product record was found'));
      expect(r.errorMessage, contains('registered in France'));
    });

    test('network failures and timeouts are reported as a network error', () async {
      final offline = MockClient((_) async => throw http.ClientException('Failed host lookup'));
      final r = await lookupWith(offline, '3000000000007');
      expect(r.found, isFalse);
      expect(r.networkError, isTrue);
      expect(r.errorMessage, contains('Could not reach'));

      final timingOut = MockClient((_) async => throw TimeoutException('slow'));
      expect((await lookupWith(timingOut, '3000000000007')).networkError, isTrue);
    });

    test('malformed and error responses do not crash and are not "found"', () async {
      for (final body in ['<html>Bad gateway</html>', '[]', '{"status":1,"product":"oops"}', '{"status":1}']) {
        final r = await lookupWith(MockClient((_) async => http.Response(body, 200)), '3000000000007');
        expect(r.found, isFalse, reason: body);
        expect(r.networkError, isFalse, reason: body);
      }
      final r500 = await lookupWith(MockClient((_) async => http.Response('err', 500)), '3000000000007');
      expect(r500.found, isFalse);
    });

    test('non-barcode input never reaches the network', () async {
      final calls = <Uri>[];
      final r = await lookupWith(factsClient({}, log: calls), 'https://evil.example/../x');
      expect(r.found, isFalse);
      expect(r.errorMessage, contains('not a product barcode'));
      expect(calls, isEmpty);
      expect((await lookupWith(factsClient({}), '   ')).errorMessage, 'Empty barcode provided');
    });

    test('mistyped barcode (bad check digit) is flagged', () async {
      final r = await lookupWith(factsClient({}), '3000000000008');
      expect(r.checkDigitInvalid, isTrue);
      expect(r.errorMessage, contains('check digit'));
    });
  });

  group('AddProductScreen lookup flow (form tab, no camera)', () {
    late VanityProvider vanity;

    Finder field(String hint) =>
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
    String textOf(WidgetTester t, String hint) => t.widget<TextField>(field(hint)).controller!.text;
    const brandHint = 'e.g. CeraVe, The Ordinary, Glossier';
    const nameHint = 'e.g. Hyaluronic Acid 2% + B5';

    Future<void> pumpScreen(WidgetTester tester, String barcode) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await DatabaseService().initialize();
      vanity = VanityProvider();
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vanity),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => HouseholdProvider()),
        ],
        child: MaterialApp(home: AddProductScreen(initialBarcode: barcode)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('unknown barcode: honest message, empty fields, manual entry saves the product', (tester) async {
      await http.runWithClient(() async {
        await pumpScreen(tester, '3000000000007');

        expect(find.textContaining('no product record was found'), findsOneWidget);
        expect(find.textContaining('Found via'), findsNothing);
        expect(textOf(tester, brandHint), isEmpty);
        expect(textOf(tester, nameHint), isEmpty);

        // Manual fallback.
        await tester.enterText(field(brandHint), 'Bioderma');
        await tester.enterText(field(nameHint), 'Sensibio H2O');
        final save = find.text('Add to Vanity Shelf');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final saved = vanity.allItems.where((i) => i.product?.barcode == '3000000000007').toList();
        expect(saved, hasLength(1));
        expect(saved.single.product!.brand, 'Bioderma');
        expect(saved.single.product!.name, 'Sensibio H2O');
      }, () => factsClient({}));
    });

    testWidgets('a new barcode clears data auto-filled from the previous product', (tester) async {
      await http.runWithClient(() async {
        await pumpScreen(tester, '3337875597180'); // Open Beauty Facts: CeraVe Hydrating Cleanser
        expect(textOf(tester, brandHint), 'CeraVe');

        await tester.enterText(field('e.g. 3337875597180'), '3000000000007');
        await tester.tap(find.text('Lookup'));
        await tester.pumpAndSettle();

        expect(textOf(tester, brandHint), isEmpty, reason: 'old product data must not stay on the new barcode');
        expect(textOf(tester, nameHint), isEmpty);
      }, () => factsClient({'3337875597180': cerave}));
    });

    testWidgets('offline lookup shows a network error and keeps manual entry usable', (tester) async {
      await http.runWithClient(() async {
        await pumpScreen(tester, '3000000000007');
        expect(find.textContaining('Could not reach the product databases'), findsOneWidget);
        expect(field(brandHint), findsOneWidget);
        expect(find.text('Add to Vanity Shelf'), findsOneWidget);
      }, () => MockClient((_) async => throw http.ClientException('offline')));
    });

    testWidgets('duplicate detection still warns for an existing barcode', (tester) async {
      await http.runWithClient(() async {
        await pumpScreen(tester, '3337875597180');
        vanity.loadItemsFromList([
          const VanityItemModel(
            vanityItemId: 'existing',
            productId: 'p',
            userId: 'demo_user',
            status: 'active',
            product: ProductModel(
              productId: 'p',
              barcode: '3337875597180',
              name: 'Hyalu B5 Pure Hyaluronic Acid Serum',
              brand: 'La Roche-Posay',
              categoryId: 'serum',
              paoMonths: 12,
            ),
          ),
        ]);
        final save = find.text('Add to Vanity Shelf');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.textContaining('Duplicate'), findsWidgets);
      }, () => factsClient({'3337875597180': cerave}));
    });
  });
}
