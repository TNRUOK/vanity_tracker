// Add Product: each lookup outcome shows its own next steps; user edits survive lookups.
// HTTP is mocked; the camera is not exercised (see the browser verification notes).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/screens/product/add_product_screen.dart';
import 'package:vanity_tracker/screens/product/edit_product_screen.dart';
import 'package:vanity_tracker/screens/product/product_detail_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/product_lookup_service.dart';
import 'package:vanity_tracker/widgets/product_search_dialog.dart';

const brandHint = 'e.g. CeraVe, The Ordinary, Glossier';
const nameHint = 'e.g. Hyaluronic Acid 2% + B5';

MockClient facts(Map<String, Map<String, dynamic>> products, {List<Uri>? log}) => MockClient((req) async {
      log?.add(req.url);
      final code = RegExp(r'/product/(\d+)\.json$').firstMatch(req.url.path)?.group(1);
      if (req.url.host.contains('upcitemdb')) return http.Response(jsonEncode({'code': 'OK', 'items': []}), 200);
      if (code != null && products.containsKey(code) && req.url.host.contains('openbeautyfacts')) {
        return http.Response(jsonEncode({'code': code, 'status': 1, 'product': {'code': code, ...products[code]!}}), 200);
      }
      return http.Response(jsonEncode({'code': code, 'status': 0, 'status_verbose': 'product not found'}), 404);
    });

void main() {
  late VanityProvider vanity;

  Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
  String textOf(WidgetTester t, String hint) => t.widget<TextField>(field(hint)).controller!.text;
  String status(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('lookup-status-text'))).data!;

  Future<void> pumpScreen(WidgetTester tester, {String? barcode}) async {
    tester.view.physicalSize = const Size(900, 3000);
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

  Future<void> lookupTyped(WidgetTester tester, String code) async {
    await tester.enterText(field('e.g. 3337875597180'), code);
    await tester.tap(find.text('Lookup'));
    await tester.pumpAndSettle();
  }

  tearDown(() => ProductSearchDialog.debugSearch = null);

  testWidgets('invalid check digit: explained, nothing looked up, rescan / search anyway / manual offered', (tester) async {
    final calls = <Uri>[];
    await http.runWithClient(() async {
      await pumpScreen(tester, barcode: '8809643068098');
      expect(calls, isEmpty);
      expect(status(tester), contains('not a valid EAN-13 barcode'));
      expect(find.byKey(const ValueKey('lookup-action-rescan')), findsOneWidget);
      expect(find.byKey(const ValueKey('lookup-action-anyway')), findsOneWidget);
      expect(find.byKey(const ValueKey('lookup-action-manual')), findsOneWidget);
      expect(find.textContaining('Found via'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('lookup-action-anyway')));
      await tester.pumpAndSettle();
      expect(calls, isNotEmpty);
      expect(status(tester), contains('searched exactly as entered'));

      // Manual correction: the right number is typed and looked up normally.
      await lookupTyped(tester, '3337875597180');
      expect(textOf(tester, brandHint), 'CeraVe');
    }, () => facts({'3337875597180': {'product_name': 'Hydrating Cleanser', 'brands': 'CeraVe'}}, log: calls));
  });

  testWidgets('the invalid sample barcode chip is gone; samples are verified records', (tester) async {
    await http.runWithClient(() async {
      await pumpScreen(tester);
      expect(find.text('Joseon SPF'), findsNothing);
      expect(find.text('CeraVe Hydrating Cleanser'), findsOneWidget);
    }, () => facts({}));
  });

  testWidgets('valid but unlisted: "not found" with search-by-name; picking a result fills the form', (tester) async {
    ProductSearchDialog.debugSearch = (q) async => const ProductSearchResult([
          ProductSearchCandidate(barcode: '3337875598996', name: 'Moisturising Cream', brand: 'CeraVe', quantity: '177 ml'),
        ]);
    await http.runWithClient(() async {
      await pumpScreen(tester, barcode: '3000000000007');
      expect(status(tester), contains('is valid, but no product record was found'));
      expect(status(tester), isNot(contains('invalid')));
      await tester.tap(find.byKey(const ValueKey('lookup-action-search')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-search-go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-search-result-3337875598996')));
      await tester.pumpAndSettle();
      expect(textOf(tester, brandHint), 'CeraVe');
      expect(textOf(tester, nameHint), 'Moisturising Cream');
      expect(textOf(tester, 'e.g. 3337875597180'), '3337875598996');
    }, () => facts({'3337875598996': {'product_name': 'Moisturising Cream', 'brands': 'CeraVe', 'quantity': '177 ml'}}));
  });

  testWidgets('a lookup never overwrites what the user typed; it says which fields it kept', (tester) async {
    await http.runWithClient(() async {
      await pumpScreen(tester, barcode: '3000000000007'); // not found: form stays empty
      await tester.enterText(field(brandHint), 'My Own Brand');
      await lookupTyped(tester, '3337875597180');
      expect(textOf(tester, brandHint), 'My Own Brand');
      expect(textOf(tester, nameHint), 'Hydrating Cleanser', reason: 'empty fields are filled');
      expect(tester.widget<Text>(find.byKey(const ValueKey('lookup-kept-fields'))).data, contains('Brand'));

      // A different product: fields the lookup filled are replaced, the user's are kept.
      await lookupTyped(tester, '041554420616');
      expect(textOf(tester, brandHint), 'My Own Brand');
      expect(textOf(tester, nameHint), 'Lash Sensational Mascara');
    }, () => facts({
          '3337875597180': {'product_name': 'Hydrating Cleanser', 'brands': 'CeraVe'},
          '041554420616': {'product_name': 'Lash Sensational Mascara', 'brands': 'Maybelline'},
        }));
  });

  testWidgets('a new unlisted barcode does not keep the previous product''s category or PAO', (tester) async {
    await http.runWithClient(() async {
      await pumpScreen(tester, barcode: '041554420616'); // mascara record
      expect(find.text('Mascara'), findsOneWidget);
      await lookupTyped(tester, '3000000000007'); // valid, unlisted
      expect(find.text('Mascara'), findsNothing);
      expect(find.text('Uncategorized: choose a category'), findsOneWidget);
      expect(find.textContaining('Unknown: set it from the open-jar symbol'), findsOneWidget);
    }, () => facts({'041554420616': {'product_name': 'Lash Sensational Mascara', 'brands': 'Maybelline'}}));
  });

  testWidgets('timeout: "did not answer in time" with Try again; retry succeeds', (tester) async {
    var slow = true;
    final client = MockClient((req) async {
      if (slow) throw TimeoutException('slow');
      if (req.url.host.contains('openbeautyfacts') && req.url.path.endsWith('/3337875597180.json')) {
        return http.Response(
          jsonEncode({'status': 1, 'product': {'code': '3337875597180', 'product_name': 'Hydrating Cleanser', 'brands': 'CeraVe'}}),
          200,
        );
      }
      return http.Response(jsonEncode({'status': 0}), 404);
    });
    await http.runWithClient(() async {
      await pumpScreen(tester, barcode: '3000000000007');
      expect(status(tester), contains('did not answer in time'));
      expect(find.byKey(const ValueKey('lookup-action-retry')), findsOneWidget);
      slow = false;
      await tester.enterText(field('e.g. 3337875597180'), '3337875597180');
      await tester.tap(find.byKey(const ValueKey('lookup-action-retry')));
      await tester.pumpAndSettle();
      expect(status(tester), contains('Found via Open Beauty Facts'));
    }, () => client);
  });

  testWidgets('no-match manual entry still saves the product with its barcode', (tester) async {
    await http.runWithClient(() async {
      await pumpScreen(tester, barcode: '3000000000007');
      await tester.tap(find.byKey(const ValueKey('lookup-action-manual')));
      await tester.pumpAndSettle();
      await tester.enterText(field(brandHint), 'Bioderma');
      await tester.enterText(field(nameHint), 'Sensibio H2O');
      final save = find.text('Add to Vanity Shelf');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final saved = vanity.allItems.single;
      expect(saved.product!.barcode, '3000000000007');
      expect(saved.product!.brand, 'Bioderma');
      expect(saved.openedDate == null || saved.sealedExpiryDate == null, isTrue);
      expect(saved.sealedExpiryDate, isNull, reason: 'no expiry is invented');
      expect(saved.batchCode, isNull);
    }, () => facts({}));
  });

  testWidgets('receipt-imported product: barcode added later (validated), then looked up without losing user edits',
      (tester) async {
    Future<void> pumpHome(Widget home) async {
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vanity),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => HouseholdProvider()),
        ],
        child: MaterialApp(home: home),
      ));
      await tester.pumpAndSettle();
    }

    await http.runWithClient(() async {
      await pumpScreen(tester); // sets up storage and providers
      final item = await vanity.addItem(
        vanityItemId: 'from_receipt',
        product: const ProductModel(
          productId: 'p_r',
          barcode: '', // receipts carry no barcode
          name: 'My Cleanser',
          brand: 'CeraVe',
          categoryId: 'cleanser',
          categorySource: CategorySource.user,
          paoMonths: 6,
          paoSource: PaoSource.user,
        ),
        userId: 'demo_user',
      );

      await pumpHome(EditProductScreen(item: item));
      final barcodeField = find.byKey(const ValueKey('edit-barcode'));
      await tester.enterText(barcodeField, '8809643068098');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('check digit does not match'), findsOneWidget);
      expect(vanity.allItems.single.product!.barcode, '', reason: 'invalid barcode is not saved');

      await tester.enterText(barcodeField, '3337875597180');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(vanity.allItems.single.product!.barcode, '3337875597180');

      await pumpHome(const ProductDetailScreen(vanityItemId: 'from_receipt'));
      final refresh = find.byKey(const ValueKey('refresh-product-data'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('apply-product-data')));
      await tester.pumpAndSettle();

      final p = vanity.allItems.single.product!;
      expect(p.name, 'My Cleanser', reason: 'user-edited name kept');
      expect(p.categoryId, 'cleanser', reason: 'user-chosen category kept');
      expect(p.paoMonths, 6, reason: 'user PAO kept (database value only on explicit choice)');
      expect(p.paoSource, PaoSource.user);
      expect(p.ingredients, contains('glycerin'), reason: 'missing data is added');
    }, () => facts({
          '3337875597180': {
            'product_name': 'Hydrating Cleanser',
            'brands': 'CeraVe',
            'ingredients_text': 'aqua, glycerin, ceramide np',
            'periods_after_opening_tags': ['en:12-months'],
            'categories_hierarchy': ['en:face-creams'],
          },
        }));
  });
}