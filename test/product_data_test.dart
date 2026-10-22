// Product data quality: Open Beauty Facts lookup (HTTP MOCKED with the shapes of real API
// responses fetched 2026-10-18), PAO provenance, ingredient acquisition/normalization,
// packaging OCR review (OCR engine and picker are test doubles), merging refreshed data
// without overwriting user-confirmed values, and the reviewed conflict-checker rules.
// No live network, Firestore or camera is used here.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
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
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/product/product_detail_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/ingredient_conflict_service.dart';
import 'package:vanity_tracker/services/notification_service.dart';
import 'package:vanity_tracker/services/ocr/receipt_ocr_service.dart';
import 'package:vanity_tracker/services/packaging_ocr_service.dart';
import 'package:vanity_tracker/services/product_data_merge.dart';
import 'package:vanity_tracker/services/product_lookup_service.dart';
import 'package:vanity_tracker/utils/ingredient_normalizer.dart';
import 'package:vanity_tracker/widgets/ingredient_conflict_card.dart';

/// Real record (trimmed): has an explicit PAO and an ingredient list.
const keracnyl = <String, dynamic>{
  'code': '3282770037500',
  'product_name': 'Keracnyl Foaming Gel',
  'brands': 'Ducray',
  'quantity': '200ml',
  'periods_after_opening': '12 mois',
  'periods_after_opening_tags': ['en:12-months'],
  'countries_tags': ['en:france'],
  'last_modified_t': 1790421947,
  'ingredients_text': 'WATER (AQUA), ZINC COCETH SULFATE, LAURYL BETAINE, DECYL GLUCOSIDE, CITRIC ACID, '
      'FRAGRANCE (PARFUM), SODIUM BENZOATE, SODIUM HYDROXIDE',
};

/// Real record (trimmed): no PAO listed.
const cerave = <String, dynamic>{
  'code': '3337875597180',
  'product_name': 'Hydrating Cleanser',
  'brands': 'CeraVe',
  'quantity': '236ml',
  'countries_tags': ['en:netherlands'],
  'ingredients_text': 'aqua/water, glycerin, cetearyl alcohol, ceramide np, ceramide ap',
};

/// Like the real API: 200 + status 1 when found, 404 + status 0 otherwise.
MockClient obf(Map<String, Map<String, dynamic>> products, {List<Uri>? log}) => MockClient((req) async {
      log?.add(req.url);
      final m = RegExp(r'/product/(\d+)\.json$').firstMatch(req.url.path);
      if (m != null && products.containsKey(m.group(1)) && req.url.host.contains('openbeautyfacts')) {
        return http.Response(jsonEncode({'code': m.group(1), 'status': 1, 'product': products[m.group(1)]}), 200);
      }
      return http.Response(jsonEncode({'status': 0, 'status_verbose': 'product not found'}), 404);
    });

Future<ProductLookupResult> lookup(http.Client c, String code, {bool force = false}) =>
    http.runWithClient(() => ProductLookupService.lookupBarcode(code, forceRefresh: force), () => c);

ProductModel product({
  String name = 'Serum',
  int pao = 12,
  PaoSource paoSource = PaoSource.categoryDefault,
  String? ingredients,
  IngredientSource ingredientsSource = IngredientSource.notRecorded,
  String category = 'serum',
  String barcode = '',
}) =>
    ProductModel(
      productId: 'p_${name.hashCode}_${DateTime.now().microsecondsSinceEpoch}',
      barcode: barcode,
      name: name,
      brand: 'Brand',
      categoryId: category,
      paoMonths: pao,
      paoSource: paoSource,
      ingredients: ingredients,
      ingredientsSource: ingredientsSource,
    );

VanityItemModel item(String id, ProductModel p, {List<String> tags = const ['PM']}) =>
    VanityItemModel(vanityItemId: id, productId: p.productId, userId: 'u', product: p, routineTags: tags);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationService.debugLog = [];
  });
  tearDown(() {
    NotificationService.debugLog = null;
    PackagingOcrService.debugPicker = null;
    ReceiptOcrService.debugEngineOverride = null;
  });

  // ───────────────────────────── lookup ─────────────────────────────
  group('Open Beauty Facts lookup', () {
    test('complete record: PAO and ingredients are product data with provenance and attribution', () async {
      final r = await lookup(obf({'3282770037500': keracnyl}), '3282770037500');
      expect(r.found, isTrue);
      expect(r.source, 'Open Beauty Facts');
      final p = r.product!;
      expect(p.name, 'Keracnyl Foaming Gel');
      expect(p.brand, 'Ducray');
      expect(p.volume, '200ml');
      expect(p.paoMonths, 12);
      expect(p.paoSource, PaoSource.productDatabase);
      expect(p.ingredientsSource, IngredientSource.productDatabase);
      expect(p.ingredientsContext, contains('sold in: france'));
      expect(p.ingredientsContext, contains('3282770037500'));
      expect(p.countryOfOrigin, isNull, reason: '"countries" means sold in, not made in');
      expect(r.attribution, contains('Open Database License'));
      expect(r.sourceUrl, 'https://world.openbeautyfacts.org/product/3282770037500');
    });

    test('record without PAO: PAO is a labelled category estimate, ingredients still product data', () async {
      final r = await lookup(obf({'3337875597180': cerave}), '3337875597180');
      expect(r.product!.name, 'Hydrating Cleanser'); // not the removed catalog guess
      expect(r.product!.paoSource, PaoSource.categoryDefault);
      expect(r.product!.paoSource.isVerified, isFalse);
      expect(r.product!.ingredientsSource, IngredientSource.productDatabase);
    });

    test('record without ingredients: no list and no provenance is invented', () async {
      final r = await lookup(obf({'3337875597180': {...cerave, 'ingredients_text': ''}}), '3337875597180');
      expect(r.found, isTrue);
      expect(r.product!.ingredientList, isNull);
      expect(r.product!.ingredientsSource, IngredientSource.notRecorded);
    });

    test('PAO field variants found in real records', () {
      int? pao(Map<String, dynamic> p) => ProductLookupService.extractPao(p);
      expect(pao({'periods_after_opening_tags': ['en:6-months']}), 6);
      expect(pao({'periods_after_opening': '12 M'}), 12);
      expect(pao({'periods_after_opening': '12 mois'}), 12);
      expect(pao({'periods_after_opening': '24 months'}), 24);
      expect(pao({'periods_after_opening': ''}), isNull);
      expect(pao({'periods_after_opening': 'see pack'}), isNull);
      expect(pao({'periods_after_opening_tags': ['en:0-months']}), isNull);
      expect(pao({'pao': '12M'}), isNull, reason: 'not a field of this API');
    });

    test('not found, invalid response and timeout are distinguished', () async {
      final missing = await lookup(obf({}), '3000000000007');
      expect(missing.found, isFalse);
      expect(missing.networkError, isFalse);

      final invalid = await lookup(MockClient((_) async => http.Response('<html>', 200)), '3000000000007');
      expect(invalid.found, isFalse);
      expect(invalid.networkError, isFalse);

      final slow = await lookup(MockClient((_) async => throw TimeoutException('slow')), '3000000000007');
      expect(slow.networkError, isTrue);
    });

    test('one request per database (no duplicate v0 request)', () async {
      final calls = <Uri>[];
      await lookup(obf({}, log: calls), '3000000000007');
      final openFacts = calls.where((u) => u.host.contains('facts.org')).toList();
      expect(openFacts.map((u) => u.host).toSet().length, openFacts.length);
      expect(openFacts.first.host, 'world.openbeautyfacts.org');
    });

    test('results are cached; refresh bypasses the cache; offline uses a dated cache entry', () async {
      final calls = <Uri>[];
      final client = obf({'3282770037500': keracnyl}, log: calls);
      await lookup(client, '3282770037500');
      final first = calls.length;
      final again = await lookup(client, '3282770037500');
      expect(calls.length, first, reason: 'served from cache');
      expect(again.fromCache, isTrue);
      expect(again.product!.paoSource, PaoSource.productDatabase);

      await lookup(client, '3282770037500', force: true);
      expect(calls.length, greaterThan(first));

      final offline = await lookup(MockClient((_) async => throw http.ClientException('offline')), '3282770037500', force: true);
      expect(offline.found, isTrue);
      expect(offline.cachedAt, isNotNull, reason: 'the old result is shown with its date');
    });
  });

  // ───────────────────────────── merge ─────────────────────────────
  group('Refreshing product data', () {
    final fetched = ProductModel.fromMap({
      'product_id': 'f',
      'name': 'Keracnyl Foaming Gel',
      'pao_months': 12,
      'pao_source': 'product_database',
      'ingredients': 'Water, Glycerin, Salicylic Acid',
      'ingredients_source': 'product_database',
    });

    test('a database PAO replaces an estimate and says so', () {
      final r = ProductDataMerge.merge(current: product(pao: 6), fetched: fetched, sourceName: 'Open Beauty Facts');
      expect(r.merged.paoMonths, 12);
      expect(r.merged.paoSource, PaoSource.productDatabase);
      expect(r.changes.join(), contains('was an unverified 6 months'));
    });

    test('a user-confirmed PAO is never overwritten silently (conflicting sources)', () {
      final mine = product(pao: 6, paoSource: PaoSource.user);
      final r = ProductDataMerge.merge(current: mine, fetched: fetched, sourceName: 'Open Beauty Facts');
      expect(r.merged.paoMonths, 6);
      expect(r.merged.paoSource, PaoSource.user);
      expect(r.discrepancies.single.field, 'pao');
      expect(r.discrepancies.single.explanation, contains('you confirmed 6 months'));

      final chosen = ProductDataMerge.merge(
          current: mine, fetched: fetched, sourceName: 'Open Beauty Facts', acceptDatabasePao: true);
      expect(chosen.merged.paoMonths, 12);
    });

    test('user-edited ingredients are kept after a lookup refresh', () {
      final mine = product(ingredients: 'Water, Glycerin', ingredientsSource: IngredientSource.user);
      final r = ProductDataMerge.merge(current: mine, fetched: fetched, sourceName: 'Open Beauty Facts');
      expect(r.merged.ingredients, 'Water, Glycerin');
      expect(r.merged.ingredientsSource, IngredientSource.user);
      expect(r.discrepancies.single.field, 'ingredients');
    });

    test('missing ingredients are filled from the database with provenance', () {
      final r = ProductDataMerge.merge(current: product(), fetched: fetched, sourceName: 'Open Beauty Facts');
      expect(r.merged.ingredients, contains('Salicylic Acid'));
      expect(r.merged.ingredientsSource, IngredientSource.productDatabase);
    });

    test('a record without PAO does not replace the estimate with another estimate', () {
      final noPao = fetched.copyWith(paoSource: PaoSource.categoryDefault, paoMonths: 24);
      final r = ProductDataMerge.merge(current: product(pao: 6), fetched: noPao, sourceName: 'X');
      expect(r.merged.paoMonths, 6);
      expect(r.changes.where((c) => c.contains('PAO')), isEmpty);
    });
  });

  // ───────────────────────────── ingredients ─────────────────────────────
  group('Ingredient normalization', () {
    test('synonyms, case, percentages and repeats collapse; slash names stay whole', () {
      final list = IngredientNormalizer.parse(
          'Ingredients: AQUA/WATER/EAU, Glycerin, Caprylic/Capric Triglyceride, Salicylic Acid (2%), '
          'water, GLYCERIN, Fragrance (Parfum), Tocopherol (Vitamin E, natural)');
      expect(list.map((i) => i.key), [
        'water',
        'glycerin',
        'caprylic/capric triglyceride',
        'salicylic acid',
        'fragrance',
        'tocopherol', // identity; the descriptor stays in the displayed text
      ]);
      expect(list.last.display, 'Tocopherol (Vitamin E, natural)');
      expect(IngredientNormalizer.duplicateCount('Water, Aqua, Glycerin, glycerin'), 2);
    });

    test('chemically distinct look-alikes are not merged', () {
      final keys = IngredientNormalizer.parse('Ascorbic Acid, Sodium Ascorbyl Phosphate, Ascorbyl Glucoside')
          .map((i) => i.key)
          .toSet();
      expect(keys.length, 3);
    });

    test('ingredient section is extracted from label OCR text; cut-off lists are detected', () {
      const ocr = 'GENTLE GEL 200ml\nINGREDIENTS: Aqua, Glycerin,\nNiacinamide, Panthenol\n\nDirections: apply daily';
      expect(IngredientNormalizer.extractFromLabelText(ocr), 'Aqua, Glycerin, Niacinamide, Panthenol');
      expect(IngredientNormalizer.extractFromLabelText('Made in France 200ml'), isNull);
      expect(IngredientNormalizer.looksIncomplete('Water, Glycerin...'), isTrue);
      expect(IngredientNormalizer.looksIncomplete('Water, Glycerin'), isFalse);
    });

    test('PAO candidates are read from packaging text only when printed as a PAO', () {
      expect(PackagingOcrService.paoCandidates('Best used within 12M of opening'), [12]);
      expect(PackagingOcrService.paoCandidates('150ml  6 M  SPF 30'), [6]);
      expect(PackagingOcrService.paoCandidates('Use within 24 months after opening'), [24]);
      expect(PackagingOcrService.paoCandidates('Net wt 150ml / 5.0 fl oz'), isEmpty);
    });
  });

  group('Saving ingredients and PAO on one item', () {
    late VanityProvider vanity;
    setUp(() async {
      await DatabaseService().initialize();
      vanity = VanityProvider();
    });

    Future<VanityItemModel> add(String name) =>
        vanity.addItem(product: product(name: name), userId: 'demo_user', vanityItemId: 'pd_${name}_${DateTime.now().microsecondsSinceEpoch}');

    test('manual entry is saved as user data, de-duplicated, persisted and clearable', () async {
      final a = await add('Manual');
      final removed = await vanity.updateIngredients(a.vanityItemId, 'Water, Aqua, Niacinamide, niacinamide',
          source: IngredientSource.user);
      expect(removed, 2);
      final saved = vanity.allItems.firstWhere((i) => i.vanityItemId == a.vanityItemId).product!;
      expect(saved.ingredients, 'Water, Niacinamide');
      expect(saved.ingredientsSource, IngredientSource.user);

      final reloaded = VanityProvider();
      await reloaded.loadItems('demo_user');
      final r = reloaded.allItems.firstWhere((i) => i.vanityItemId == a.vanityItemId).product!;
      expect(r.ingredientsSource, IngredientSource.user);
      expect(r.ingredientsUpdatedAt, isNotNull);

      await vanity.updateIngredients(a.vanityItemId, '', source: IngredientSource.user);
      expect(vanity.allItems.firstWhere((i) => i.vanityItemId == a.vanityItemId).product!.ingredientList, isNull);
    });

    test('product-specific data is applied only to its own inventory item', () async {
      final a = await add('A');
      final b = await add('B');
      await vanity.applyProductData(a.vanityItemId, a.product!.copyWith(paoMonths: 3, paoSource: PaoSource.productDatabase));
      expect(vanity.allItems.firstWhere((i) => i.vanityItemId == b.vanityItemId).product!.paoMonths, 12);
      expect(vanity.allItems.firstWhere((i) => i.vanityItemId == a.vanityItemId).product!.paoMonths, 3);
    });

    test('marking PAO unknown removes the PAO expiry instead of keeping an estimate', () async {
      final a = await add('Opened');
      await vanity.markAsOpened(a.vanityItemId, openedDate: DateTime(2026, 1, 1));
      final updated = await vanity.updatePao(a.vanityItemId, 12, source: PaoSource.unknown);
      expect(updated.expiryDate, isNull);
      expect(updated.openedDate, DateTime(2026, 1, 1));
      expect(updated.computedStatus, VanityStatus.active);
    });
  });

  // ───────────────────────────── conflict checker ─────────────────────────────
  group('Reviewed conflict rules', () {
    test('every rule has a source URL, a supporting quote, limitations and a review date', () {
      for (final r in IngredientConflictService.rules) {
        expect(r.referenceUrl, startsWith('https://'), reason: r.id);
        expect(r.sourceQuote, isNotEmpty, reason: r.id);
        expect(r.limitations, isNotEmpty, reason: r.id);
        expect(r.reviewedOn, isNotEmpty, reason: r.id);
      }
      final ids = IngredientConflictService.rules.map((r) => r.id).toSet();
      expect(ids.contains('vit_c_direct_acid'), isFalse);
      expect(ids.contains('copper_peptides_acids'), isFalse);
    });

    test('retinoid + exfoliating acid gives the AAD-sourced caution', () {
      final a = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: [
        item('r', product(name: 'Retinol Serum', ingredients: 'Squalane, Retinol')),
        item('g', product(name: 'Glycolic Toner', ingredients: 'Aqua, Glycolic Acid 7%')),
      ]);
      final c = a.conflicts.single;
      expect(c.rule.id, 'retinoid_direct_acid');
      expect(c.rule.referenceUrl, contains('aad.org'));
      expect(a.isCompleteCheck, isTrue);
    });

    test('unrelated combinations and pH-adjuster acids do not produce warnings', () {
      final a = IngredientConflictService.analyzeRoutine(routineType: 'AM', items: [
        item('r', product(name: 'Retinol Cream', ingredients: 'Water, Retinol, Citric Acid, Sodium Citrate')),
        item('n', product(name: 'Niacinamide', ingredients: 'Water, Niacinamide, Zinc PCA, Citric Acid')),
        item('v', product(name: 'Vitamin C', ingredients: 'Water, Ascorbic Acid, Ferulic Acid')),
        item('h', product(name: 'HA', ingredients: 'Water, Hyaluronic Acid, Acid')),
      ]);
      expect(a.conflicts, isEmpty);
      expect(a.isClean, isTrue);
    });

    test('tretinoin label caution and the scoped benzoyl-peroxide advisory', () {
      final a = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: [
        item('t', product(name: 'Tretinoin Cream', ingredients: 'Tretinoin, Stearic Acid')),
        item('s', product(name: 'BHA', ingredients: 'Water, Salicylic Acid')),
        item('b', product(name: 'BP Wash', category: 'cleanser', ingredients: 'Benzoyl Peroxide, Glycerin')),
      ]);
      final ids = a.conflicts.map((c) => c.rule.id).toSet();
      expect(ids, containsAll(['tretinoin_keratolytic', 'retinoid_benzoyl_peroxide', 'retinoid_direct_acid']));
      final bp = a.conflicts.firstWhere((c) => c.rule.id == 'retinoid_benzoyl_peroxide');
      expect(bp.rule.severity, ConflictSeverity.info);
      expect(bp.involvesRinseOff, isTrue);
      // Adapalene was shown to be stable with benzoyl peroxide: no advisory.
      final ad = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: [
        item('a', product(name: 'Adapalene Gel', ingredients: 'Adapalene, Carbomer')),
        item('b', product(name: 'BP Wash', ingredients: 'Benzoyl Peroxide, Glycerin')),
      ]);
      expect(ad.conflicts, isEmpty);
    });

    test('missing or cut-off ingredient lists make the check incomplete, never "verified"', () {
      final a = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: [
        item('k', product(name: 'Known', ingredients: 'Water, Glycerin')),
        item('m', product(name: 'Missing')),
        item('c', product(name: 'Cut', ingredients: 'Water, Glycerin, ...')),
      ]);
      expect(a.conflicts, isEmpty);
      expect(a.missingDataItems.single.vanityItemId, 'm');
      expect(a.incompleteDataItems.single.vanityItemId, 'c');
      expect(a.isCompleteCheck, isFalse);
      expect(a.isClean, isFalse);
    });

    test('updating an ingredient list refreshes the result', () async {
      SharedPreferences.setMockInitialValues({});
      await DatabaseService().initialize();
      final vanity = VanityProvider();
      final ret = await vanity.addItem(
          product: product(name: 'Retinol', ingredients: 'Retinol, Squalane'), userId: 'u', routineTags: ['PM'], vanityItemId: 'cr_ret');
      final toner = await vanity.addItem(product: product(name: 'Toner'), userId: 'u', routineTags: ['PM'], vanityItemId: 'cr_ton');
      var a = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: vanity.pmRoutineItems);
      expect(a.conflicts, isEmpty);
      expect(a.isCompleteCheck, isFalse);

      await vanity.updateIngredients(toner.vanityItemId, 'Water, Lactic Acid', source: IngredientSource.user);
      a = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: vanity.pmRoutineItems);
      expect(a.conflicts.single.rule.id, 'retinoid_direct_acid');
      expect(a.isCompleteCheck, isTrue);
      expect(ret.vanityItemId, isNotEmpty);
    });

    testWidgets('routine card says the check is incomplete when a list is missing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: IngredientConflictCard(routineName: 'PM', items: [
            item('k', product(name: 'Known', ingredients: 'Water, Glycerin')),
            item('k2', product(name: 'Known 2', ingredients: 'Water, Squalane')),
            item('m', product(name: 'Missing One')),
          ]),
        ),
      ));
      expect(find.textContaining('NOT a complete check'), findsOneWidget);
      expect(find.textContaining('Missing One'), findsWidgets);
      expect(find.textContaining('does not mean the product contains no actives'), findsOneWidget);
    });
  });

  // ───────────────────── packaging OCR review (widgets) ─────────────────────
  group('Packaging photo review on Product Details', () {
    late VanityProvider vanity;

    Future<VanityItemModel> pump(WidgetTester tester) async {
      await DatabaseService().initialize();
      vanity = VanityProvider();
      final added = await vanity.addItem(
          product: product(name: 'Label Test', barcode: ''), userId: 'demo_user', vanityItemId: 'ocr_${DateTime.now().microsecondsSinceEpoch}');
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: vanity),
          ChangeNotifierProvider(create: (_) => ReceiptProvider()),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => HouseholdProvider()),
        ],
        child: MaterialApp(home: ProductDetailScreen(vanityItemId: added.vanityItemId)),
      ));
      await tester.pumpAndSettle();
      return added;
    }

    void fakePhoto(String text) {
      PackagingOcrService.debugPicker = () async => PickedReceiptImage(bytes: Uint8List.fromList([1, 2, 3]));
      ReceiptOcrService.debugEngineOverride = ({filePath, bytes, mimeType}) async => text;
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('ingredient label OCR is shown for review, corrected, then saved as label data', (tester) async {
      final added = await pump(tester);
      expect(find.byKey(const ValueKey('ingredients-missing')), findsOneWidget);
      fakePhoto('ACME GEL\nIngredients: Aqua, Glycerin, Retinal, Glycerin\n\nDirections: nightly');

      await tapKey(tester, 'edit-ingredients');
      await tapKey(tester, 'ingredients-scan');
      final field = find.byKey(const ValueKey('ingredients-field'));
      expect(tester.widget<TextField>(field).controller!.text, 'Aqua, Glycerin, Retinal, Glycerin');
      expect(find.textContaining('compare with the label and correct it'), findsOneWidget);
      expect(find.textContaining('1 repeated entry will be removed'), findsOneWidget);

      // The user fixes a misread name before saving.
      await tester.enterText(field, 'Aqua, Glycerin, Retinol, Glycerin');
      await tester.pump();
      await tapKey(tester, 'ingredients-save');

      final saved = vanity.allItems.firstWhere((i) => i.vanityItemId == added.vanityItemId).product!;
      expect(saved.ingredients, 'Aqua, Glycerin, Retinol');
      expect(saved.ingredientsSource, IngredientSource.packaging);
      expect(find.text(IngredientSource.packaging.label), findsOneWidget);
    });

    testWidgets('unreadable label photo is not saved as a verified list', (tester) async {
      final added = await pump(tester);
      fakePhoto('');
      await tapKey(tester, 'edit-ingredients');
      await tapKey(tester, 'ingredients-scan');
      expect(find.textContaining('No text could be read'), findsOneWidget);
      await tapKey(tester, 'ingredients-save');
      expect(vanity.allItems.firstWhere((i) => i.vanityItemId == added.vanityItemId).product!.ingredientList, isNull);
    });

    testWidgets('PAO read from a packaging photo must be picked by the user, then saved as packaging', (tester) async {
      final added = await pump(tester);
      fakePhoto('Hydra Cream 50ml  6M  Lot A12');
      await tapKey(tester, 'edit-pao');
      await tapKey(tester, 'pao-read-photo');
      expect(find.textContaining('Text recognition can misread numbers'), findsOneWidget);
      await tapKey(tester, 'pao-ocr-6');
      await tapKey(tester, 'pao-save');
      final p = vanity.allItems.firstWhere((i) => i.vanityItemId == added.vanityItemId).product!;
      expect(p.paoMonths, 6);
      expect(p.paoSource, PaoSource.packaging);
      expect(find.text(PaoSource.packaging.label), findsOneWidget);
    });

    testWidgets('a photo without a printed PAO says the symbol cannot be recognized', (tester) async {
      await pump(tester);
      fakePhoto('Hydra Cream 50ml');
      await tapKey(tester, 'edit-pao');
      await tapKey(tester, 'pao-read-photo');
      expect(find.textContaining('open-jar symbol itself cannot be recognized'), findsOneWidget);
    });
  });
}
