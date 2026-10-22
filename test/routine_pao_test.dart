// Routine integration (Add to Routine), PAO source transparency, editable PAO, opening
// dates and PAO expiry. Local (non-Firebase) mode with mocked SharedPreferences only:
// nothing here touches Firestore.
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
import 'package:vanity_tracker/screens/product/product_detail_screen.dart';
import 'package:vanity_tracker/screens/routine/routine_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/ingredient_conflict_service.dart';
import 'package:vanity_tracker/services/notification_service.dart';
import 'package:vanity_tracker/services/receipt_inventory_service.dart';
import 'package:vanity_tracker/widgets/edit_pao_dialog.dart';
import 'package:vanity_tracker/widgets/vanity_item_card.dart';

const me = 'demo_user'; // AuthProvider.useDemoAccount()

int _seq = 0;

/// A product with a unique id per call (the local database is a process-wide singleton).
ProductModel product(
  String name, {
  int pao = 12,
  PaoSource source = PaoSource.categoryDefault,
  String category = 'cleanser',
  String? ingredients,
}) =>
    ProductModel(
      productId: 'prod_test_${_seq++}',
      barcode: '',
      name: name,
      brand: 'Fresh',
      categoryId: category,
      paoMonths: pao,
      paoSource: source,
      ingredients: ingredients,
    );

DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

void main() {
  late VanityProvider vanity;
  late ReceiptProvider receipts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    vanity = VanityProvider();
    receipts = ReceiptProvider();
    NotificationService.debugLog = [];
  });

  tearDown(() => NotificationService.debugLog = null);

  Future<VanityItemModel> add(String name, {ProductModel? p, DateTime? openedDate, List<String> tags = const []}) =>
      vanity.addItem(product: p ?? product(name), userId: me, openedDate: openedDate, routineTags: tags, price: 20);

  VanityItemModel current(String id) => vanity.allItems.firstWhere((i) => i.vanityItemId == id);

  // ───────────────────────────── dates and model ─────────────────────────────
  group('PAO expiry date rule (month-end and leap years)', () {
    test('same day N months later, clamped to the last day of a shorter month', () {
      DateTime exp(int y, int m, int d, int pao) => VanityItemModel.computeExpiryDate(DateTime(y, m, d), pao);
      expect(exp(2025, 1, 31, 1), DateTime(2025, 2, 28));
      expect(exp(2024, 1, 31, 1), DateTime(2024, 2, 29)); // leap year
      expect(exp(2024, 2, 29, 12), DateTime(2025, 2, 28)); // leap day + 1 year
      expect(exp(2024, 2, 29, 48), DateTime(2028, 2, 29)); // next leap year keeps the 29th
      expect(exp(2025, 8, 31, 6), DateTime(2026, 2, 28)); // crosses a year end
      expect(exp(2026, 10, 17, 12), DateTime(2027, 10, 17));
      expect(exp(2026, 3, 31, 1), DateTime(2026, 4, 30));
      expect(exp(2026, 12, 15, 1), DateTime(2027, 1, 15));
    });
  });

  group('PAO source and legacy records', () {
    test('a legacy product with pao_months but no pao_source keeps its value, marked "not recorded"', () {
      final p = ProductModel.fromMap({'product_id': 'p', 'name': 'Old', 'pao_months': 12});
      expect(p.paoMonths, 12);
      expect(p.paoSource, PaoSource.notRecorded);
      expect(p.paoSource.isVerified, isFalse);
      expect(p.knownPaoMonths, 12);
    });

    test('missing or invalid PAO is unknown and never silently used as 12 months', () {
      for (final map in [
        {'product_id': 'p', 'name': 'No PAO'},
        {'product_id': 'p', 'name': 'Zero', 'pao_months': 0},
        {'product_id': 'p', 'name': 'Huge', 'pao_months': 500},
      ]) {
        final p = ProductModel.fromMap(map);
        expect(p.paoSource, PaoSource.unknown, reason: '$map');
        expect(p.knownPaoMonths, isNull, reason: '$map');
        expect(VanityItemModel.paoExpiryFor(DateTime(2026, 1, 1), p), isNull, reason: '$map');
      }
    });

    test('pao_source round-trips for every source', () {
      for (final s in PaoSource.values.where((s) => s != PaoSource.unknown)) {
        final p = ProductModel.fromMap(product('X', source: s).toMap());
        expect(p.paoSource, s);
      }
      // An explicitly stored "unknown" stays unknown even though pao_months holds a placeholder.
      expect(ProductModel.fromMap(product('X', source: PaoSource.unknown).toMap()).knownPaoMonths, isNull);
    });

    test('only packaging and user values count as verified', () {
      expect(PaoSource.values.where((s) => s.isVerified), [PaoSource.packaging, PaoSource.user]);
      expect(PaoSource.categoryDefault.label, contains('not verified'));
    });

    test('a legacy item map without a product or new fields is still readable', () {
      final item = VanityItemModel.fromMap({
        'vanity_item_id': 'legacy',
        'user_id': me,
        'opened_date': '2025-09-01T00:00:00.000',
        'expiry_date': '2026-09-01T00:00:00.000',
        'status': 'finished',
      });
      expect(item.product, isNull);
      expect(item.openedDate, DateTime(2025, 9, 1));
      expect(item.expiryDate, DateTime(2026, 9, 1));
      expect(item.computedStatus, VanityStatus.finished);
      expect(item.routineTags, isEmpty);
    });

    test('an opened item with no known expiry is "active", not "expiring today"', () {
      final item = VanityItemModel(
        vanityItemId: 'x',
        productId: 'p',
        userId: me,
        openedDate: today(),
        product: ProductModel.fromMap({'product_id': 'p', 'name': 'No PAO'}),
      );
      expect(item.daysUntilExpiry, isNull);
      expect(item.computedStatus, VanityStatus.active);
    });
  });

  // ─────────────────────────── receipt import ───────────────────────────
  group('Receipt-imported products', () {
    Future<VanityItemModel> importFromReceipt() async {
      final header = ReceiptModel(
        receiptId: 'rec_pao_${_seq++}',
        userId: me,
        merchant: 'Beauty Store',
        purchaseDate: DateTime(2021, 7, 14),
        currency: '\$',
        subtotal: 49,
        totalAmount: 49,
        createdAt: DateTime.now(),
      );
      final report = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header,
        lines: const [
          ReceiptLineRequest(
            lineId: 'l0',
            description: 'Fresh Soy Face Cleanser 150ml',
            quantity: 1,
            unitPrice: 49,
            action: LineItemAction.createNew,
            categoryId: 'cleanser',
          ),
        ],
        userId: me,
        vanity: vanity,
        receipts: receipts,
      );
      expect(report.addedCount, 1);
      return current(report.lines.single.vanityItemId!);
    }

    test('are added unopened: no opening date, no PAO countdown, purchase date not used', () async {
      final item = await importFromReceipt();
      expect(item.openedDate, isNull);
      expect(item.expiryDate, isNull);
      expect(item.effectiveExpiryDate, isNull);
      expect(item.status, 'unopened');
      expect(item.computedStatus, VanityStatus.unopened);
      expect(item.daysUsed, 0);
      // No reminder is scheduled for an unopened product without a sealed expiry.
      expect(NotificationService.debugLog!.where((e) => e.startsWith('schedule:${item.vanityItemId}')), isEmpty);
    });

    test('their PAO is recorded as the category default, not as a verified value', () async {
      final item = await importFromReceipt();
      expect(item.product!.paoMonths, 12); // Cleanser category default
      expect(item.product!.paoSource, PaoSource.categoryDefault);
      expect(item.product!.paoSource.isVerified, isFalse);
    });

    test('purchase date and opening date stay distinct after opening', () async {
      final item = await importFromReceipt();
      await vanity.markAsOpened(item.vanityItemId, openedDate: DateTime(2026, 1, 31));
      final opened = current(item.vanityItemId);
      expect(opened.openedDate, DateTime(2026, 1, 31));
      expect(opened.expiryDate, DateTime(2027, 1, 31));
      expect(receipts.receipts.first.purchaseDate, DateTime(2021, 7, 14)); // untouched
    });
  });

  // ─────────────────────────── opening and PAO edits ───────────────────────────
  group('Opening and editing PAO', () {
    test('marking as opened uses the opening date and saved PAO; reminders follow', () async {
      final item = await add('Toner', p: product('Toner', pao: 1, source: PaoSource.user));
      final opened = DateTime(2024, 1, 31);
      await vanity.markAsOpened(item.vanityItemId, openedDate: opened);
      final updated = current(item.vanityItemId);
      expect(updated.openedDate, opened);
      expect(updated.expiryDate, DateTime(2024, 2, 29));
      expect(updated.computedStatus, VanityStatus.expired);
      expect(updated.status, 'expired');
      expect(updated.daysUsed, today().difference(opened).inDays);
    });

    test('a future opening date is rejected', () async {
      final item = await add('Serum');
      expect(
        () => vanity.markAsOpened(item.vanityItemId, openedDate: DateTime.now().add(const Duration(days: 2))),
        throwsArgumentError,
      );
      expect(current(item.vanityItemId).openedDate, isNull);
    });

    test('opening a product whose PAO is unknown does not invent an expiry', () async {
      final unknown = ProductModel.fromMap({'product_id': 'prod_unknown_${_seq++}', 'name': 'Mystery Balm'});
      final item = await add('Mystery Balm', p: unknown);
      await vanity.markAsOpened(item.vanityItemId);
      final opened = current(item.vanityItemId);
      expect(opened.openedDate, isNotNull);
      expect(opened.expiryDate, isNull);
      expect(opened.computedStatus, VanityStatus.active); // not counted as expiring
    });

    test('editing PAO of an opened product recalculates expiry, keeps dates and other fields', () async {
      final openedOn = DateTime(2026, 3, 31, 9, 30);
      final item = await add('Cleanser', openedDate: openedOn, tags: const ['PM']);
      final sameCategory = await add('Other Cleanser', openedDate: openedOn);
      NotificationService.debugLog!.clear();

      final updated = await vanity.updatePao(item.vanityItemId, 30);

      expect(updated.openedDate, openedOn); // unchanged
      expect(updated.expiryDate, DateTime(2028, 9, 30, 9, 30)); // Mar 31 + 30 months -> Sep 30
      expect(updated.product!.paoMonths, 30);
      expect(updated.product!.paoSource, PaoSource.user);
      expect(updated.price, 20);
      expect(updated.routineTags, ['PM']);
      expect(updated.productId, item.productId);
      // Old reminders replaced by ones for the new date.
      expect(NotificationService.debugLog, [
        'cancel:${item.vanityItemId}',
        'schedule:${item.vanityItemId}:${DateTime(2028, 9, 30, 9, 30).toIso8601String()}',
      ]);
      // Only the intended item changed, not other products in the same category.
      final other = current(sameCategory.vanityItemId);
      expect(other.product!.paoMonths, 12);
      expect(other.expiryDate, sameCategory.expiryDate);
    });

    test('editing PAO of an unopened product keeps it unopened with no countdown', () async {
      final item = await add('Unopened Cream');
      NotificationService.debugLog!.clear();
      final updated = await vanity.updatePao(item.vanityItemId, 6);
      expect(updated.openedDate, isNull);
      expect(updated.expiryDate, isNull);
      expect(updated.computedStatus, VanityStatus.unopened);
      expect(updated.product!.paoMonths, 6);
      expect(NotificationService.debugLog, ['cancel:${item.vanityItemId}']); // nothing scheduled
    });

    test('invalid PAO values are rejected and nothing changes', () async {
      final item = await add('Lotion');
      for (final bad in [0, -3, 121]) {
        expect(() => vanity.updatePao(item.vanityItemId, bad), throwsArgumentError);
      }
      expect(current(item.vanityItemId).product!.paoMonths, 12);
      expect(current(item.vanityItemId).product!.paoSource, PaoSource.categoryDefault);
    });

    test('the dialog validator explains invalid custom values', () {
      expect(EditPaoDialog.validate(''), 'Enter the number of months.');
      expect(EditPaoDialog.validate('abc'), contains('whole number'));
      expect(EditPaoDialog.validate('2.5'), contains('whole number'));
      expect(EditPaoDialog.validate('0'), contains('between 1 and 120'));
      expect(EditPaoDialog.validate('121'), contains('between 1 and 120'));
      expect(EditPaoDialog.validate(' 30 '), isNull);
    });

    test('an edited PAO and its expiry persist after reloading', () async {
      final openedOn = DateTime(2026, 2, 28);
      final item = await add('Persisted Serum', openedDate: openedOn);
      await vanity.updatePao(item.vanityItemId, 18);

      final reloaded = VanityProvider();
      await reloaded.loadItems(me);
      final r = reloaded.allItems.firstWhere((i) => i.vanityItemId == item.vanityItemId);
      expect(r.product!.paoMonths, 18);
      expect(r.product!.paoSource, PaoSource.user);
      expect(r.openedDate, openedOn);
      expect(r.expiryDate, DateTime(2027, 8, 28));
    });

    test('dashboard counts follow a PAO change', () async {
      // Opened 11 months + a few days ago with a 12-month PAO: expiring within 30 days.
      final n = today();
      final openedOn = DateTime(n.year - 1, n.month, n.day).add(const Duration(days: 20));
      final item = await add('Count Me', openedDate: openedOn);
      expect(current(item.vanityItemId).computedStatus, VanityStatus.expiringSoon);
      final before = vanity.expiringSoonCount;

      await vanity.updatePao(item.vanityItemId, 24);
      expect(current(item.vanityItemId).computedStatus, VanityStatus.active);
      expect(vanity.expiringSoonCount, before - 1);

      await vanity.updatePao(item.vanityItemId, 6);
      expect(current(item.vanityItemId).computedStatus, VanityStatus.expired);
    });

    test('clearing a mistaken opening removes the countdown and cancels reminders', () async {
      final item = await add('Oops', openedDate: today());
      NotificationService.debugLog!.clear();
      await vanity.markAsUnopened(item.vanityItemId);
      final u = current(item.vanityItemId);
      expect(u.openedDate, isNull);
      expect(u.expiryDate, isNull);
      expect(u.status, 'unopened');
      expect(u.product!.paoMonths, 12); // PAO kept
      expect(NotificationService.debugLog, ['cancel:${item.vanityItemId}']);
    });
  });

  // ─────────────────────────────── routines ───────────────────────────────
  group('Routine membership', () {
    test('adding an existing item to a routine reuses it and creates no inventory record', () async {
      final item = await add('Routine Cleanser');
      final countBefore = vanity.allItems.length;
      final dbBefore = (await DatabaseService().getVanityItems(me)).length;

      expect(await vanity.setRoutineMembership(item.vanityItemId, {'AM'}), isTrue);

      expect(vanity.allItems.length, countBefore);
      expect((await DatabaseService().getVanityItems(me)).length, dbBefore);
      expect(vanity.amRoutineItems.map((i) => i.vanityItemId), contains(item.vanityItemId));
      expect(current(item.vanityItemId).routineTags, ['AM']);
    });

    test('repeating or double-tapping never duplicates a routine step', () async {
      final item = await add('Tapped Twice');
      await Future.wait([
        vanity.setRoutineMembership(item.vanityItemId, {'PM'}),
        vanity.setRoutineMembership(item.vanityItemId, {'PM'}),
      ]);
      expect(await vanity.setRoutineMembership(item.vanityItemId, {'PM'}), isFalse); // no write
      expect(current(item.vanityItemId).routineTags, ['PM']);
      expect(vanity.pmRoutineItems.where((i) => i.vanityItemId == item.vanityItemId), hasLength(1));
    });

    test('several routines at once, and removal', () async {
      final item = await add('Multi');
      await vanity.setRoutineMembership(item.vanityItemId, {'Weekly', 'AM', 'PM'});
      expect(current(item.vanityItemId).routineTags, ['AM', 'PM', 'Weekly']); // display order
      for (final list in [vanity.amRoutineItems, vanity.pmRoutineItems, vanity.weeklyRoutineItems]) {
        expect(list.map((i) => i.vanityItemId), contains(item.vanityItemId));
      }
      await vanity.setRoutineMembership(item.vanityItemId, {'PM'});
      expect(current(item.vanityItemId).routineTags, ['PM']);
      expect(vanity.amRoutineItems.map((i) => i.vanityItemId), isNot(contains(item.vanityItemId)));
    });

    test('routines are not hidden by the shelf search or filters', () async {
      final item = await add('Filtered Out');
      await vanity.setRoutineMembership(item.vanityItemId, {'AM'});
      vanity.setSearchQuery('zzz-no-match');
      vanity.setStatusFilter('expired');
      expect(vanity.activeItems.map((i) => i.vanityItemId), isNot(contains(item.vanityItemId)));
      expect(vanity.amRoutineItems.map((i) => i.vanityItemId), contains(item.vanityItemId));
    });

    test('routine step order is unchanged: soonest expiry first, unopened last', () async {
      final later = await add('Later', openedDate: today().subtract(const Duration(days: 10)), tags: const ['AM']);
      final unopened = await add('Sealed', tags: const ['AM']);
      final sooner = await add('Sooner', openedDate: today().subtract(const Duration(days: 300)), tags: const ['AM']);
      final ids = vanity.amRoutineItems.map((i) => i.vanityItemId).toList();
      expect(ids.indexOf(sooner.vanityItemId), lessThan(ids.indexOf(later.vanityItemId)));
      expect(ids.indexOf(later.vanityItemId), lessThan(ids.indexOf(unopened.vanityItemId)));
    });

    test('legacy tags are kept and unknown routines are rejected', () async {
      final item = await add('Legacy', tags: const ['AM', 'Custom']);
      await vanity.setRoutineMembership(item.vanityItemId, {'PM'});
      expect(current(item.vanityItemId).routineTags, ['Custom', 'PM']);
      expect(() => vanity.setRoutineMembership(item.vanityItemId, {'Night'}), throwsArgumentError);
    });

    test('ingredient conflicts still use the existing checker; missing ingredients are reported', () async {
      final retinol = await add('Retinol Serum',
          p: product('Retinol Serum', category: 'serum', ingredients: 'Aqua, Retinol, Squalane'), tags: const ['PM']);
      final acid = await add('Glycolic Toner',
          p: product('Glycolic Toner', category: 'toner', ingredients: 'Aqua, Glycolic Acid'), tags: const ['PM']);
      final blank = await add('No List', tags: const ['PM']);
      final analysis = IngredientConflictService.analyzeRoutine(routineType: 'PM', items: vanity.pmRoutineItems);
      expect(
        analysis.conflicts.any((c) =>
            {c.itemA.vanityItemId, c.itemB.vanityItemId}.containsAll([retinol.vanityItemId, acid.vanityItemId])),
        isTrue,
      );
      expect(analysis.missingDataItems.map((i) => i.vanityItemId), contains(blank.vanityItemId));
      expect(analysis.isClean, isFalse);
    });
  });

  // ─────────────────────────────── widgets ───────────────────────────────
  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = AuthProvider();
    await auth.useDemoAccount();
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

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  group('Product Details', () {
    testWidgets('unopened receipt-style product: estimated PAO and countdown not started', (tester) async {
      final item = await add('Fresh Soy Face Cleanser 150ml');
      await pump(tester, ProductDetailScreen(vanityItemId: item.vanityItemId));
      expect(find.text('12 months after opening'), findsOneWidget);
      expect(find.textContaining('Estimated from the category default'), findsOneWidget);
      expect(find.text('Not opened yet'), findsOneWidget);
      expect(find.text('Starts when opened'), findsOneWidget);
      expect(find.byKey(const ValueKey('pao-not-started')), findsOneWidget);
      expect(find.textContaining('days left'), findsNothing);
      expect(find.text('Edit / Confirm PAO'), findsOneWidget);
    });

    testWidgets('Edit PAO: invalid input is explained, a valid value is saved without opening', (tester) async {
      final item = await add('Edit Me');
      await pump(tester, ProductDetailScreen(vanityItemId: item.vanityItemId));
      await tapKey(tester, 'edit-pao');
      expect(find.textContaining('countdown starts when you mark the product as opened'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('pao-custom-field')), 'abc');
      await tester.pump();
      expect(find.textContaining('whole number of months'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('pao-save'))).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('pao-custom-field')), '30');
      await tester.pump();
      await tapKey(tester, 'pao-save');

      expect(find.textContaining('PAO saved: 30 months'), findsOneWidget);
      expect(find.text('30 months after opening'), findsOneWidget);
      expect(find.text('Entered or confirmed by you'), findsOneWidget);
      expect(find.text('Not opened yet'), findsOneWidget);
      expect(current(item.vanityItemId).openedDate, isNull);
    });

    testWidgets('Edit PAO on an opened product shows and saves the recalculated expiry', (tester) async {
      final item = await add('Opened One', openedDate: DateTime(2026, 1, 31));
      await pump(tester, ProductDetailScreen(vanityItemId: item.vanityItemId));
      expect(find.text('January 31, 2027'), findsWidgets);
      await tapKey(tester, 'edit-pao');
      await tester.tap(find.byKey(const ValueKey('pao-chip-6')));
      await tester.pump();
      expect(find.textContaining('New PAO expiry: July 31, 2026'), findsOneWidget);
      await tapKey(tester, 'pao-save');
      expect(find.text('July 31, 2026'), findsWidgets);
      expect(find.text('January 31, 2026'), findsOneWidget); // opening date unchanged
    });

    testWidgets('opened item with unknown PAO renders on the shelf without inventing an expiry', (tester) async {
      final unknown = ProductModel.fromMap({'product_id': 'prod_unk_${_seq++}', 'name': 'Unknown PAO Balm'});
      final item = await add('Unknown PAO Balm', p: unknown);
      await vanity.markAsOpened(item.vanityItemId);
      await pump(tester, Scaffold(body: VanityItemCard(item: current(item.vanityItemId), onTap: () {})));
      expect(find.text('PAO ?'), findsOneWidget);
      expect(find.text('Expiry unknown (set PAO)'), findsOneWidget);
      expect(find.text('Opened · expiry unknown'), findsOneWidget);
    });

    testWidgets('Add to Routine: pick routines, see membership, no duplicate on repeat', (tester) async {
      await add('Morning Serum', p: product('Morning Serum', ingredients: 'Aqua, Niacinamide'), tags: const ['AM']);
      final item = await add('Routine Product'); // no ingredients listed
      final count = vanity.allItems.length;
      await pump(tester, ProductDetailScreen(vanityItemId: item.vanityItemId));

      await tapKey(tester, 'add-to-routine');
      expect(find.text('Morning Routine (AM)'), findsOneWidget);
      expect(find.text('Weekly Treatments'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('routine-option-AM')));
      await tester.tap(find.byKey(const ValueKey('routine-option-Weekly')));
      await tester.pump();
      // Missing ingredient data is reported, not shown as verified compatibility.
      expect(
        find.text('This product has no ingredients listed, so it could not be checked against this routine.'),
        findsOneWidget,
      );
      final sheet = find.byType(BottomSheet);
      // Nothing was actually checked, so no "no conflicts" or safety claim is made.
      expect(find.descendant(of: sheet, matching: find.textContaining('No known conflicts')), findsNothing);
      expect(find.descendant(of: sheet, matching: find.textContaining(RegExp('safe', caseSensitive: false))), findsNothing);
      expect(find.textContaining('ensure skin safety'), findsNothing);
      await tapKey(tester, 'routine-save');
      expect(find.textContaining('added to Morning Routine (AM) and Weekly Treatments'), findsOneWidget);
      expect(current(item.vanityItemId).routineTags, ['AM', 'Weekly']);
      expect(vanity.allItems.length, count);

      // Reopen: membership is shown; saving without changes is disabled.
      await tapKey(tester, 'add-to-routine');
      expect(find.textContaining('Already in this routine (step'), findsNWidgets(2));
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('routine-save'))).onPressed, isNull);

      // Navigate to the routines and find the product there.
      await tapKey(tester, 'open-routines');
      expect(find.byType(RoutineScreen), findsOneWidget);
      expect(find.text('Routine Product'), findsOneWidget);
      expect(current(item.vanityItemId).routineTags, ['AM', 'Weekly']);
    });

    testWidgets('Add to Routine shows existing conflict warnings for this product', (tester) async {
      await add('Night Retinol',
          p: product('Night Retinol', category: 'serum', ingredients: 'Aqua, Retinol'), tags: const ['PM']);
      final acid = await add('AHA Toner', p: product('AHA Toner', category: 'toner', ingredients: 'Aqua, Glycolic Acid'));
      await pump(tester, ProductDetailScreen(vanityItemId: acid.vanityItemId));
      await tapKey(tester, 'add-to-routine');
      await tester.tap(find.byKey(const ValueKey('routine-option-PM')));
      await tester.pump();
      expect(find.textContaining('⚠ With Night Retinol'), findsOneWidget);
    });
  });

  // ─────────────────────── end-to-end (local, mocked storage) ───────────────────────
  testWidgets(
    'receipt -> add to inventory -> unopened -> open -> PAO expiry -> edit PAO -> add to routine',
    (tester) async {
      // 1-2. Save a receipt and add its product to the inventory (as Receipt History does).
      final receiptId = 'rec_e2e_${_seq++}';
      late ReceiptSaveReport report;
      await tester.runAsync(() async {
        report = await ReceiptInventoryService.saveReceiptAndInventory(
          receiptHeader: ReceiptModel(
            receiptId: receiptId,
            userId: me,
            merchant: 'Beauty Store',
            purchaseDate: DateTime(2021, 7, 14),
            currency: '\$',
            subtotal: 49,
            totalAmount: 49,
            createdAt: DateTime.now(),
          ),
          lines: const [
            ReceiptLineRequest(
              lineId: 'l0',
              description: 'Fresh Rose Floral Toner 250ml',
              quantity: 1,
              unitPrice: 49,
              action: LineItemAction.createNew,
              categoryId: 'toner',
            ),
          ],
          userId: me,
          vanity: vanity,
          receipts: receipts,
        );
      });
      final itemId = report.lines.single.vanityItemId!;
      expect(itemId, ReceiptInventoryService.inventoryIdFor(receiptId, 'l0'));
      final inventoryCount = vanity.allItems.length;

      // 3-4. Product Details: unopened.
      await pump(tester, ProductDetailScreen(vanityItemId: itemId));
      expect(find.text('Not opened yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('pao-not-started')), findsOneWidget);

      // 5. Explicitly mark as opened.
      await tapKey(tester, 'mark-opened-today');
      final opened = current(itemId);
      expect(opened.openedDate, isNotNull);
      // 6. PAO expiry from the opening date and the (estimated) 12-month PAO.
      expect(opened.expiryDate, VanityItemModel.computeExpiryDate(opened.openedDate!, 12));
      expect(find.textContaining('PAO expiry:'), findsOneWidget);

      // Correct the PAO: expiry recalculated, opening date kept.
      await tapKey(tester, 'edit-pao');
      await tester.tap(find.byKey(const ValueKey('pao-chip-6')));
      await tester.pump();
      await tapKey(tester, 'pao-save');
      final corrected = current(itemId);
      expect(corrected.openedDate, opened.openedDate);
      expect(corrected.expiryDate, VanityItemModel.computeExpiryDate(opened.openedDate!, 6));
      expect(corrected.product!.paoSource, PaoSource.user);

      // 7. Add to a routine.
      await tapKey(tester, 'add-to-routine');
      await tester.tap(find.byKey(const ValueKey('routine-option-AM')));
      await tester.pump();
      await tapKey(tester, 'routine-save');

      // 8. Routine membership and inventory stay consistent.
      expect(vanity.allItems.length, inventoryCount);
      expect(vanity.amRoutineItems.map((i) => i.vanityItemId), contains(itemId));
      final saved = receipts.receiptById(receiptId)!;
      expect(saved.items.single.matchedVanityItemId, itemId); // receipt link intact
      expect(current(itemId).price, 49);
      expect(saved.purchaseDate, DateTime(2021, 7, 14));
    },
  );
}
