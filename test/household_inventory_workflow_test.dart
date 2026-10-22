// Household Sharing (Shared by Me / Shared with Me / Private), personal vs shared
// destinations, pre-commit duplicate decisions in the barcode/Add Product flow, and
// per-line resolution in receipt review. Two household members (Alice, Bob) are simulated
// with the real HouseholdService local mode; HTTP lookups are mocked; nothing touches
// Firestore. These tests do not prove server-side security rules (see the report).
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/user_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/household/household_screen.dart';
import 'package:vanity_tracker/screens/product/add_product_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_review_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/household_service.dart';
import 'package:vanity_tracker/services/receipt_inventory_service.dart';
import 'package:vanity_tracker/services/receipt_parser_service.dart';

const alice = UserModel(userId: 'demo_user', name: 'Alice', email: 'alice@example.com'); // demo account id
const bob = UserModel(userId: 'user_bob', name: 'Bob', email: 'bob@example.com');
int _n = 0;

ProductModel product(String name, {String brand = 'CeraVe', String barcode = '', String? volume, String category = 'cleanser'}) =>
    ProductModel(
      productId: 'p_${_n++}',
      barcode: barcode,
      name: name,
      brand: brand,
      categoryId: category,
      paoMonths: 12,
      paoSource: PaoSource.user,
      volume: volume,
    );

class Household {
  late VanityProvider aliceVanity;
  late HouseholdProvider aliceHh;
  late HouseholdProvider bobHh;
  late String householdId;

  /// Alice creates a household, Bob joins. Bob owns one shared and one private cleanser.
  Future<void> setUp() async {
    final service = HouseholdService();
    aliceHh = HouseholdProvider();
    await aliceHh.createHousehold('Flat', alice);
    householdId = aliceHh.currentHousehold!.householdId;
    final invite = await service.sendInvitation(household: aliceHh.currentHousehold!, sender: alice, recipientEmail: bob.email);
    await service.acceptInvitation(invitationId: invite.invitationId, user: bob);

    final db = DatabaseService();
    await db.addVanityItem(VanityItemModel(
      vanityItemId: 'bob_shared_cleanser',
      productId: 'pb1',
      userId: bob.userId,
      status: 'active',
      price: 15,
      notes: 'Bob private note',
      product: product('Hydrating Facial Cleanser', barcode: '0041554420616', volume: '236 ml'),
      isSharedWithHousehold: true,
      sharedHouseholdId: householdId,
    ));
    await db.addVanityItem(VanityItemModel(
      vanityItemId: 'bob_private_cream',
      productId: 'pb2',
      userId: bob.userId,
      status: 'active',
      product: product('Secret Night Cream', brand: 'Brand X'),
    ));

    await aliceHh.loadHousehold(alice);
    bobHh = HouseholdProvider();
    await bobHh.loadHousehold(bob);
    aliceVanity = VanityProvider();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    HouseholdService().clearLocalMemory();
  });

  // ═══════════════════════ sharing semantics ═══════════════════════
  group('Shared by Me / Shared with Me / Private', () {
    test('lists come from authorized records; private items never appear for others', () async {
      final h = Household();
      await h.setUp();
      final mine = await h.aliceVanity.addItem(product: product('Rose Toner'), userId: alice.userId, vanityItemId: 'a_toner');
      await h.aliceVanity.addItem(
        product: product('Gel Cream'),
        userId: alice.userId,
        vanityItemId: 'a_gel',
        isSharedWithHousehold: true,
        sharedHouseholdId: h.householdId,
      );

      final all = h.aliceVanity.allActiveItems;
      expect(h.aliceHh.sharedByMe(all).map((i) => i.vanityItemId), ['a_gel']);
      expect(h.aliceHh.privateItems(all).map((i) => i.vanityItemId), [mine.vanityItemId]);
      expect(h.aliceHh.sharedWithMe.map((i) => i.vanityItemId), ['bob_shared_cleanser']);

      // Bob sees Alice's shared item, not her private toner.
      await h.bobHh.loadHousehold(bob);
      expect(h.bobHh.sharedWithMe.map((i) => i.vanityItemId), ['a_gel']);

      // Shelf search/filters do not change these lists.
      h.aliceVanity.setSearchQuery('zzz');
      expect(h.aliceHh.sharedByMe(h.aliceVanity.allActiveItems), hasLength(1));
    });

    test('stop sharing / share change only visibility; owner, price, links and record stay', () async {
      final h = Household();
      await h.setUp();
      final gel = await h.aliceVanity.addItem(
        product: product('Gel Cream'),
        userId: alice.userId,
        vanityItemId: 'a_gel2',
        price: 30,
        isSharedWithHousehold: true,
        sharedHouseholdId: h.householdId,
      );
      final before = gel.toMap();

      final privateNow =
          await h.aliceHh.setItemSharing(vanity: h.aliceVanity, item: gel, share: false, currentUserId: alice.userId);
      expect(privateNow.isSharedWithHousehold, isFalse);
      expect(privateNow.sharedHouseholdId, isNull);
      final after = privateNow.toMap()
        ..remove('is_shared_with_household')
        ..remove('shared_household_id');
      expect(after, Map.of(before)..remove('is_shared_with_household')..remove('shared_household_id'));
      expect(h.aliceVanity.allItems.where((i) => i.vanityItemId == 'a_gel2'), hasLength(1));

      await h.bobHh.loadHousehold(bob);
      expect(h.bobHh.sharedWithMe.map((i) => i.vanityItemId), isNot(contains('a_gel2')));

      await h.aliceHh.setItemSharing(vanity: h.aliceVanity, item: privateNow, share: true, currentUserId: alice.userId);
      await h.bobHh.loadHousehold(bob);
      expect(h.bobHh.sharedWithMe.map((i) => i.vanityItemId), contains('a_gel2'));
    });

    test('only the owner can change sharing; sharing needs a household', () async {
      final h = Household();
      await h.setUp();
      final bobsItem = h.aliceHh.sharedWithMe.single;
      expect(
        () => h.aliceHh.setItemSharing(vanity: h.aliceVanity, item: bobsItem, share: false, currentUserId: alice.userId),
        throwsException,
      );
      final loner = HouseholdProvider();
      final v = VanityProvider();
      final item = await v.addItem(product: product('Solo'), userId: 'solo', vanityItemId: 'solo_1');
      expect(() => loner.setItemSharing(vanity: v, item: item, share: true, currentUserId: 'solo'), throwsException);
    });

    test('leaving the household keeps ownership; same product can be owned twice', () async {
      final h = Household();
      await h.setUp();
      await h.aliceVanity.addItem(
        product: product('Hydrating Facial Cleanser', barcode: '0041554420616', volume: '236 ml'),
        userId: alice.userId,
        vanityItemId: 'a_own_cleanser',
      );
      final bobs = (await DatabaseService().readVanityItemsForBackup(bob.userId)).records;
      expect(bobs.where((i) => i.vanityItemId == 'bob_shared_cleanser'), hasLength(1));
      expect(h.aliceVanity.allItems.where((i) => i.vanityItemId == 'a_own_cleanser'), hasLength(1));

      await HouseholdService().leaveHousehold(householdId: h.householdId, user: bob);
      final bobsAfter = (await DatabaseService().readVanityItemsForBackup(bob.userId)).records;
      final cleanser = bobsAfter.firstWhere((i) => i.vanityItemId == 'bob_shared_cleanser');
      expect(cleanser.userId, bob.userId);
      expect(cleanser.isSharedWithHousehold, isFalse);
    });
  });

  // ═══════════════════════ matcher additions ═══════════════════════
  group('Matcher labels', () {
    test('own private vs own shared vs member\'s shared; brand-prefixed receipt names', () async {
      final h = Household();
      await h.setUp();
      await h.aliceVanity.addItem(
        product: product('Hydrating Facial Cleanser', volume: '236 ml'),
        userId: alice.userId,
        vanityItemId: 'a_shared_c',
        isSharedWithHousehold: true,
        sharedHouseholdId: h.householdId,
      );
      final m = h.aliceVanity.checkHouseholdDuplicates(
        name: 'CeraVe Hydrating Facial Cleanser 236ml', // receipt-style: brand inside the name
        brand: '',
        sharedHouseholdItems: h.aliceHh.sharedWithMe,
        memberEmails: h.aliceHh.memberEmails,
      );
      expect(m.map((x) => x.whoseLabel).toSet(), {'Yours (shared with your household)', 'Shared by bob@example.com'});
      expect(m.every((x) => x.strengthLabel == 'Possible match'), isTrue, reason: 'brand missing on the receipt line');
      expect(
        h.aliceVanity.checkHouseholdDuplicates(name: 'Secret Night Cream', brand: 'Brand X',
            sharedHouseholdItems: h.aliceHh.sharedWithMe),
        isEmpty,
        reason: 'Bob\'s private item is never loaded, so it cannot match',
      );
    });
  });

  // ═══════════════════════ barcode / Add Product ═══════════════════════
  group('Barcode scan: duplicate decision before creating anything', () {
    late Household h;

    Future<void> pumpScan(WidgetTester tester, String barcode, Map<String, dynamic> record) async {
      await http.runWithClient(() async {
        h = Household();
        await h.setUp();
        tester.view.physicalSize = const Size(900, 2800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final auth = AuthProvider();
        await auth.useDemoAccount();
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<VanityProvider>.value(value: h.aliceVanity),
            ChangeNotifierProvider<HouseholdProvider>.value(value: h.aliceHh),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider(create: (_) => ReceiptProvider()),
          ],
          child: MaterialApp(home: AddProductScreen(initialBarcode: barcode)),
        ));
        await tester.pumpAndSettle();
      }, () => MockClient((req) async {
            if (req.url.path.endsWith('/$barcode.json') && req.url.host.contains('openbeautyfacts')) {
              return http.Response(jsonEncode({'status': 1, 'product': record}), 200);
            }
            return http.Response(jsonEncode({'status': 0}), 404);
          }));
    }

    Future<void> tapSave(WidgetTester tester) async {
      final save = find.text('Add to Vanity Shelf');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
    }

    const cerave = {'product_name': 'Hydrating Facial Cleanser', 'brands': 'CeraVe', 'quantity': '236 ml'};

    testWidgets('strong match: warned before saving; "Add to Shared" creates a separate item owned by Alice',
        (tester) async {
      await pumpScan(tester, '041554420616', cerave); // UPC-A form of Bob's EAN-13
      expect(find.byKey(const ValueKey('add-duplicate-banner')), findsOneWidget);
      expect(find.textContaining('Strong match'), findsOneWidget);
      expect(h.aliceVanity.allItems, isEmpty, reason: 'scanning alone creates nothing');

      await tapSave(tester);
      expect(find.text('A Household Member Has This'), findsOneWidget);
      expect(find.textContaining('Shared by bob@example.com'), findsWidgets);
      expect(find.textContaining('Bob private note'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('duplicate-add-shared')));
      await tester.pumpAndSettle();

      final created = h.aliceVanity.allItems.single;
      expect(created.userId, alice.userId);
      expect(created.isSharedWithHousehold, isTrue);
      expect(created.sharedHouseholdId, h.householdId);
      final bobs = (await DatabaseService().readVanityItemsForBackup(bob.userId)).records
          .firstWhere((i) => i.vanityItemId == 'bob_shared_cleanser');
      expect(bobs.userId, bob.userId, reason: 'Bob\'s item is untouched');
      expect(bobs.notes, 'Bob private note');
    });

    testWidgets('"Add to Personal" is private; "Don\'t Add" creates nothing; View opens the shared item read-only',
        (tester) async {
      await pumpScan(tester, '041554420616', cerave);
      await tapSave(tester);
      await tester.tap(find.byKey(const ValueKey('view-existing-bob_shared_cleanser')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shared-item-view-bob_shared_cleanser')), findsOneWidget);
      expect(find.textContaining('\$15'), findsNothing, reason: 'no price shown for another member');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('duplicate-cancel')));
      await tester.pumpAndSettle();
      expect(h.aliceVanity.allItems, isEmpty);

      await tapSave(tester);
      await tester.tap(find.byKey(const ValueKey('duplicate-add-personal')));
      await tester.pumpAndSettle();
      final created = h.aliceVanity.allItems.single;
      expect(created.isSharedWithHousehold, isFalse);
      expect(created.sharedHouseholdId, isNull);
    });

    testWidgets('no match: standard flow; double tap creates one item', (tester) async {
      await pumpScan(tester, '4005900259615', {'product_name': 'Sun Lotion SPF50', 'brands': 'Nivea'});
      expect(find.byKey(const ValueKey('add-duplicate-banner')), findsNothing);
      final save = find.text('Add to Vanity Shelf');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.tap(save, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(h.aliceVanity.allItems, hasLength(1));
      expect(h.aliceVanity.allItems.single.isSharedWithHousehold, isFalse, reason: 'private unless chosen');
    });
  });

  // ═══════════════════════ receipt review: per-line decisions ═══════════════════════
  group('Receipt review: each line resolved independently', () {
    const text = '''
BEAUTY HALL
2026-10-15
Hydrating Facial Cleanser \$15.00
Niacinamide Serum \$20.00
Matte Lipstick Ruby Woo \$18.00
XJ447 SCAN CODE \$3.00
Rose Toner \$12.00
Subtotal \$68.00
Total \$68.00
''';

    testWidgets('different destinations, receipt-only, removed OCR line; spending counted once; retry safe',
        (tester) async {
      final h = Household();
      await h.setUp();
      await h.aliceVanity.addItem(
        product: product('Matte Lipstick Ruby Woo', brand: 'MAC', category: 'lipstick'),
        userId: alice.userId,
        vanityItemId: 'a_lipstick',
      );
      final receipts = ReceiptProvider();
      final draft = ReceiptParserService.parseReceiptText(text, defaultCurrency: '\$');
      tester.view.physicalSize = const Size(900, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: h.aliceVanity),
          ChangeNotifierProvider<HouseholdProvider>.value(value: h.aliceHh),
          ChangeNotifierProvider.value(value: receipts),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: MaterialApp(home: ReceiptReviewScreen(initialDraft: draft)),
      ));
      await tester.pumpAndSettle();

      String idOf(String name) => draft.items.firstWhere((i) => i.description.contains(name)).itemId;
      final cleanser = idOf('Cleanser'), serum = idOf('Serum'), lipstick = idOf('Lipstick'), junk = idOf('XJ447'), toner = idOf('Toner');

      // Inline matches appear before anything is saved; nothing was auto-linked.
      expect(find.byKey(Key('line-matches-$cleanser')), findsOneWidget);
      expect(find.byKey(Key('line-matches-$lipstick')), findsOneWidget);
      expect(find.byKey(Key('line-matches-$serum')), findsNothing);

      // Remove the misread OCR line.
      await tester.tap(find.byKey(Key('line-remove-$junk')));
      await tester.pumpAndSettle();

      // Add all remaining lines as new items, then refine each one.
      await tester.ensureVisible(find.byKey(const ValueKey('add-all-to-inventory')));
      await tester.tap(find.byKey(const ValueKey('add-all-to-inventory')));
      await tester.pumpAndSettle();

      Future<void> setAction(String id, String label) async {
        await tester.ensureVisible(find.byKey(Key('line-action-$id')));
        await tester.tap(find.byKey(Key('line-action-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await setAction(lipstick, 'Keep on receipt only');
      // Cleanser: another physical unit, shared with the household (acknowledged inline).
      await tester.ensureVisible(find.byKey(Key('line-dup-ack-$cleanser')));
      await tester.tap(find.byKey(Key('line-dup-ack-$cleanser')));
      await tester.tap(find.descendant(of: find.byKey(Key('line-dest-$cleanser')), matching: find.text('Shared household')));
      await tester.ensureVisible(find.byKey(Key('line-dest-$toner')));
      await tester.tap(find.descendant(of: find.byKey(Key('line-dest-$toner')), matching: find.text('Shared household')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Confirm & Save Receipt'));
      await tester.tap(find.text('Confirm & Save Receipt'));
      await tester.pumpAndSettle();
      expect(find.text('Possible duplicate product'), findsNothing, reason: 'all duplicates were resolved inline');

      final rid = draft.receiptId;
      String inv(String line) => ReceiptInventoryService.inventoryIdFor(rid, line);
      final items = {for (final i in h.aliceVanity.allItems) i.vanityItemId: i};
      expect(items.keys.toSet(), {'a_lipstick', inv(cleanser), inv(serum), inv(toner)});
      expect(items[inv(cleanser)]!.isSharedWithHousehold, isTrue);
      expect(items[inv(toner)]!.sharedHouseholdId, h.householdId);
      expect(items[inv(serum)]!.isSharedWithHousehold, isFalse);
      for (final id in [inv(cleanser), inv(serum), inv(toner)]) {
        expect(items[id]!.userId, alice.userId);
      }

      final saved = receipts.receipts.single;
      expect(saved.items.map((l) => l.itemId).toSet(), {cleanser, serum, lipstick, toner});
      expect(saved.items.firstWhere((l) => l.itemId == lipstick).matchedVanityItemId, isNull, reason: 'receipt only');
      expect(saved.items.firstWhere((l) => l.itemId == lipstick).unitPrice, 18);
      expect(saved.totalAmount, 68, reason: 'removing a misread line does not change the receipt total');
      final spending = h.aliceVanity.calculateUnifiedSpending(receipts: receipts.receipts, currencySymbol: '\$');
      // Receipt once + the pre-existing lipstick (not linked) with no price.
      expect(spending.receiptTotal, 68);
      expect(spending.matchedReceiptsCount, 1);
    });

    test('a failed line does not cancel the others, and a retry writes only the failed one', () async {
      final h = Household();
      await h.setUp();
      final receipts = ReceiptProvider();
      final failing = _FailOnce({'Rose Toner'});
      final header = ReceiptParserService.parseReceiptText(text, defaultCurrency: '\$');
      final lines = [
        for (final i in header.items.where((i) => !i.description.contains('XJ447')))
          ReceiptLineRequest(
            lineId: i.itemId,
            description: i.description,
            quantity: 1,
            unitPrice: i.unitPrice,
            action: LineItemAction.createNew,
            shareWithHousehold: i.description.contains('Toner'),
          ),
      ];
      final receipt = header.toReceipt(userId: alice.userId);
      final first = await ReceiptInventoryService.saveReceiptAndInventory(
          receiptHeader: receipt, lines: lines, userId: alice.userId, vanity: failing, receipts: receipts,
          householdId: h.householdId);
      expect(first.failedCount, 1);
      expect(first.addedCount, 3);
      final retry = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: receipt,
        lines: lines,
        userId: alice.userId,
        vanity: failing,
        receipts: receipts,
        householdId: h.householdId,
        alreadyAddedLineIds: {for (final l in first.lines) if (l.isAddedToInventory) l.lineId},
      );
      expect(retry.failedCount, 0);
      expect(failing.writes, 4 + 1, reason: '4 attempts first time, only the toner on retry');
      expect(failing.allItems, hasLength(4));
      expect(receipts.receipts, hasLength(1));
      expect(failing.allItems.firstWhere((i) => i.product!.name == 'Rose Toner').isSharedWithHousehold, isTrue);
    });

    test('"shared" without a household is reported, not silently made personal', () async {
      final receipts = ReceiptProvider();
      final v = VanityProvider();
      final header = ReceiptParserService.parseReceiptText(text, defaultCurrency: '\$');
      final r = await ReceiptInventoryService.saveReceiptAndInventory(
        receiptHeader: header.toReceipt(userId: 'solo_user'),
        lines: [
          ReceiptLineRequest(
            lineId: header.items.first.itemId,
            description: 'Hydrating Facial Cleanser',
            quantity: 1,
            unitPrice: 15,
            action: LineItemAction.createNew,
            shareWithHousehold: true,
          ),
        ],
        userId: 'solo_user',
        vanity: v,
        receipts: receipts,
      );
      expect(r.failedCount, 1);
      expect(r.lines.single.error, contains('needs a household'));
      expect(v.allItems, isEmpty);
      expect(receipts.receipts, hasLength(1), reason: 'the receipt itself is still saved');
    });
  });

  // ═══════════════════════ Household screen ═══════════════════════
  group('Household Sharing screen', () {
    testWidgets('three views with real counts; share/stop sharing; Shared with Me opens read-only', (tester) async {
      final h = Household();
      await h.setUp();
      await h.aliceVanity.addItem(product: product('Rose Toner'), userId: alice.userId, vanityItemId: 'scr_toner');
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: h.aliceVanity),
          ChangeNotifierProvider<HouseholdProvider>.value(value: h.aliceHh),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => ReceiptProvider()),
        ],
        child: const MaterialApp(home: HouseholdScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Shared by Me (0)'), findsOneWidget);
      expect(find.text('Shared with Me (1)'), findsOneWidget);
      expect(find.text('Private (1)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tab-shared-with-me')));
      await tester.pumpAndSettle();
      expect(find.text('Hydrating Facial Cleanser'), findsOneWidget);
      expect(find.text('Secret Night Cream'), findsNothing);
      expect(find.text('Shared by bob@example.com'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('household-item-bob_shared_cleanser')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shared-item-view-bob_shared_cleanser')), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('tab-private')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-scr_toner')));
      await tester.pumpAndSettle();
      expect(find.text('Shared by Me (1)'), findsOneWidget);
      expect(find.text('Private (0)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tab-shared-by-me')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stop-sharing-scr_toner')));
      await tester.pumpAndSettle();
      expect(find.text('Shared by Me (0)'), findsOneWidget);
      expect(h.aliceVanity.allItems.where((i) => i.vanityItemId == 'scr_toner'), hasLength(1),
          reason: 'stopping sharing never deletes the item');
    });
  });
}

extension on ParsedReceiptDraft {
  ReceiptModel toReceipt({required String userId}) => ReceiptModel(
        receiptId: receiptId,
        userId: userId,
        merchant: merchant,
        purchaseDate: purchaseDate,
        currency: currency,
        subtotal: subtotal,
        totalAmount: total,
        createdAt: DateTime(2026, 10, 15),
      );
}

/// Fails the first write for the named products, then succeeds (simulated write failure).
class _FailOnce extends VanityProvider {
  final Set<String> failNames;
  int writes = 0;
  _FailOnce(this.failNames);
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
    writes++;
    if (failNames.remove(product.name)) throw Exception('Simulated write failure');
    return super.addItem(
      product: product,
      userId: userId,
      price: price,
      priceCurrency: priceCurrency,
      inferPriceCurrency: inferPriceCurrency,
      notes: notes,
      vanityItemId: vanityItemId,
      throwOnSyncFailure: throwOnSyncFailure,
      isSharedWithHousehold: isSharedWithHousehold,
      sharedHouseholdId: sharedHouseholdId,
    );
  }
}
