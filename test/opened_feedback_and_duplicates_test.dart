// "Marked as opened" confirmation (auto-dismiss, Undo, stale callbacks, disposal, save
// failures) and household duplicate-product warnings (matching rules, privacy, receipt
// import, Add Anyway, repeated taps). Local (non-Firebase) mode with mocked storage;
// two household members are simulated with the real HouseholdService local mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:vanity_tracker/screens/product/product_detail_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_detail_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/household_service.dart';
import 'package:vanity_tracker/services/notification_service.dart';
import 'package:vanity_tracker/services/receipt_inventory_service.dart';
import 'package:vanity_tracker/widgets/opened_feedback.dart';

const me = 'demo_user';
int _n = 0;

ProductModel product(String name, {String brand = 'CeraVe', String barcode = '', String? volume}) => ProductModel(
      productId: 'p_${_n++}',
      barcode: barcode,
      name: name,
      brand: brand,
      categoryId: 'cleanser',
      paoMonths: 12,
      paoSource: PaoSource.user,
      volume: volume,
    );

VanityItemModel shared(String id, ProductModel p, {String owner = 'user_bob', String hh = 'hh'}) => VanityItemModel(
      vanityItemId: id,
      productId: p.productId,
      userId: owner,
      product: p,
      status: 'active',
      isSharedWithHousehold: true,
      sharedHouseholdId: hh,
    );

/// Provider whose save fails (to check that no success message appears).
class FailingSaveVanity extends VanityProvider {
  final Object error;
  FailingSaveVanity(this.error);
  @override
  Future<void> markAsOpened(String vanityItemId, {DateTime? openedDate, bool throwOnSyncFailure = false}) async =>
      throw error;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    HouseholdService().clearLocalMemory();
    NotificationService.debugLog = [];
  });
  tearDown(() => NotificationService.debugLog = null);

  // ═══════════════════════ opened confirmation ═══════════════════════
  group('"Marked as opened" confirmation', () {
    late VanityProvider vanity;

    Future<VanityItemModel> pumpDetails(WidgetTester tester, {VanityProvider? provider}) async {
      vanity = provider ?? VanityProvider();
      final item = await vanity.addItem(product: product('Gentle Cleanser'), userId: me, vanityItemId: 'fb_${_n++}');
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: vanity),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => HouseholdProvider()),
          ChangeNotifierProvider(create: (_) => ReceiptProvider()),
        ],
        child: MaterialApp(home: ProductDetailScreen(vanityItemId: item.vanityItemId)),
      ));
      await tester.pumpAndSettle();
      return item;
    }

    VanityItemModel current(String id) => vanity.allItems.firstWhere((i) => i.vanityItemId == id);

    Future<void> tapOpened(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const ValueKey('mark-opened-today')));
      await tester.tap(find.byKey(const ValueKey('mark-opened-today')));
      await tester.pump(); // save
      await tester.pump(const Duration(milliseconds: 750)); // snackbar entrance
    }

    testWidgets('dismisses itself after about five seconds; the opening date stays saved', (tester) async {
      final item = await pumpDetails(tester);
      await tapOpened(tester);
      expect(find.textContaining('Marked as opened today'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      final opened = current(item.vanityItemId).openedDate;
      expect(opened, isNotNull);

      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('Marked as opened today'), findsOneWidget, reason: 'still visible at ~4 s');
      await tester.pump(const Duration(seconds: 2)); // timer fires at 5 s
      await tester.pumpAndSettle();
      expect(find.textContaining('Marked as opened today'), findsNothing);
      expect(find.text('Undo'), findsNothing);
      // Dismissal is visual only.
      expect(current(item.vanityItemId).openedDate, opened);
      expect(current(item.vanityItemId).expiryDate, isNotNull);
    });

    testWidgets('Undo inside the window reverses the opening, expiry and reminders', (tester) async {
      final item = await pumpDetails(tester);
      await tapOpened(tester);
      NotificationService.debugLog!.clear();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      final u = current(item.vanityItemId);
      expect(u.openedDate, isNull);
      expect(u.expiryDate, isNull);
      expect(u.computedStatus, VanityStatus.unopened);
      expect(NotificationService.debugLog, ['cancel:${item.vanityItemId}']);
      expect(find.textContaining('Opening undone'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // entrance finishes, its 3 s timer starts
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.textContaining('Opening undone'), findsNothing);
    });

    testWidgets('a newer message replaces an older one; a stale Undo does nothing', (tester) async {
      final item = await pumpDetails(tester);
      final messenger = tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
      final other = await vanity.addItem(product: product('Toner'), userId: me, vanityItemId: 'fb_other_${_n++}');

      await tapOpened(tester); // message A (this item)
      await markOpenedWithFeedback(messenger, vanity, other.vanityItemId); // message B
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byKey(ValueKey('opened-feedback-${other.vanityItemId}-${current(other.vanityItemId).openedDate!.toIso8601String()}')),
          findsOneWidget);
      expect(find.text('Undo'), findsOneWidget, reason: 'only the newest message is on screen');

      // The item is changed again before Undo is tapped (opened on an earlier date): the
      // old announcement's Undo must not clear the newer opening.
      await vanity.markAsOpened(other.vanityItemId, openedDate: DateTime(2026, 1, 1));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(current(other.vanityItemId).openedDate, DateTime(2026, 1, 1));
      expect(current(item.vanityItemId).openedDate, isNotNull, reason: 'message A\'s item is untouched');
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets('leaving the screen does not break the timer or Undo', (tester) async {
      final item = await pumpDetails(tester);
      await tapOpened(tester);
      // Replace the screen while the message is showing (disposes Product Details).
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pushReplacement(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Elsewhere'))));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // page transition done (taps are ignored during it)
      expect(find.text('Elsewhere'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget, reason: 'the message lives in the app-level messenger');
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(current(item.vanityItemId).openedDate, isNull);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('no success message when saving fails', (tester) async {
      await pumpDetails(tester, provider: FailingSaveVanity(Exception('disk full')));
      await tapOpened(tester);
      expect(find.textContaining('Marked as opened'), findsNothing);
      expect(find.text('Undo'), findsNothing);
      expect(find.textContaining('Not marked as opened: disk full'), findsOneWidget);
    });

    testWidgets('saved on the device but not synced: the message says so', (tester) async {
      await pumpDetails(tester, provider: _NotSyncedVanity());
      await tapOpened(tester);
      expect(find.textContaining('Marked as opened today'), findsOneWidget);
      expect(find.textContaining('not synced yet'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.textContaining('Marked as opened'), findsNothing);
    });
  });

  // ═══════════════════════ duplicate matching ═══════════════════════
  group('Duplicate matching', () {
    final vanity = VanityProvider();
    final bobCleanser = shared('bob_1', product('Hydrating Facial Cleanser', barcode: '0041554420616', volume: '236 ml'));

    List<DuplicateMatch> check({String? barcode, String? name, String? brand, String? volume, List<VanityItemModel>? items}) =>
        vanity.checkHouseholdDuplicates(
          barcode: barcode,
          name: name,
          brand: brand,
          volume: volume,
          sharedHouseholdItems: items ?? [bobCleanser],
          memberEmails: const {'user_bob': 'bob@example.com'},
        );

    test('exact barcode, including the UPC-A/EAN-13 spelling difference', () {
      final m = vanity.checkHouseholdDuplicates(
        barcode: '041554420616',
        sharedHouseholdItems: [bobCleanser],
        memberEmails: const {'user_bob': 'bob@example.com'},
      );
      expect(m.single.matchType, DuplicateMatchType.exactBarcode);
      expect(m.single.isHousehold, isTrue);
      expect(m.single.ownerEmail, 'bob@example.com');
      expect(m.single.isLikelySame, isTrue);
    });

    test('normalized brand and name (case, punctuation, size spelling)', () {
      final m = check(name: 'HYDRATING facial-cleanser', brand: ' cerave ', volume: '236ml');
      expect(m.single.matchType, DuplicateMatchType.normalizedBrandAndName);
    });

    test('different size is only a possible duplicate', () {
      final a = check(name: 'Hydrating Facial Cleanser', brand: 'CeraVe', volume: '473 ml');
      expect(a.single.matchType, DuplicateMatchType.sameNameDifferentSize);
      expect(a.single.isLikelySame, isFalse);
      // Size written in the name (receipt lines) is understood too.
      final b = check(name: 'Hydrating Facial Cleanser 473ml', brand: 'CeraVe');
      expect(b.single.matchType, DuplicateMatchType.sameNameDifferentSize);
    });

    test('different shades/variants and different barcodes are not duplicates', () {
      final lip = shared('bob_lip', product('Matte Lipstick Ruby Woo', brand: 'MAC'));
      expect(check(name: 'Matte Lipstick Velvet Teddy', brand: 'MAC', items: [lip]), isEmpty);
      expect(check(name: 'Hydrating Facial Cleanser', brand: 'CeraVe', barcode: '3337875597180'), isEmpty,
          reason: 'two different real barcodes mean two different products');
      expect(check(name: 'Hydrating Facial Cleanser', brand: 'La Roche-Posay'), isEmpty);
    });

    test('never by category or a broad word alone', () {
      final plain = shared('bob_serum', product('Serum', brand: ''));
      expect(check(name: 'Serum', brand: '', items: [plain]), isEmpty);
      expect(check(name: 'Facial', brand: 'CeraVe'), isEmpty, reason: 'partial names do not match');
    });

    test('a missing brand gives only a possible match', () {
      final m = check(name: 'Hydrating Facial Cleanser 236ml', brand: '');
      expect(m.single.matchType, DuplicateMatchType.sameNameBrandMissing);
    });

    test('own items are distinguished from household items and shelf filters do not hide them', () async {
      final v = VanityProvider();
      await v.addItem(product: product('Hydrating Facial Cleanser', volume: '236 ml'), userId: me, vanityItemId: 'own_${_n++}');
      v.setSearchQuery('zzz');
      final m = v.checkHouseholdDuplicates(
        name: 'Hydrating Facial Cleanser',
        brand: 'CeraVe',
        volume: '236 ml',
        sharedHouseholdItems: [bobCleanser],
        memberEmails: const {'user_bob': 'bob@example.com'},
      );
      expect(m.map((x) => x.source).toSet(), {DuplicateSource.personal, DuplicateSource.householdShared});
    });
  });

  // ═══════════════════════ household privacy (two members) ═══════════════════════
  group('Household privacy with two members', () {
    const alice = UserModel(userId: 'user_alice', email: 'alice@example.com', name: 'Alice');
    const bob = UserModel(userId: 'user_bob', email: 'bob@example.com', name: 'Bob');

    test('only items Bob shared can produce a warning for Alice; private items never leak', () async {
      final service = HouseholdService();
      final hh = await service.createHousehold(name: 'Flat', creator: alice);
      final invite = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      await service.acceptInvitation(invitationId: invite.invitationId, user: bob);
      final db = DatabaseService();
      await db.addVanityItem(VanityItemModel(
        vanityItemId: 'bob_private',
        productId: 'p',
        userId: bob.userId,
        status: 'active',
        product: product('Secret Night Cream'),
      ));
      await db.addVanityItem(shared('bob_shared', product('Hydrating Facial Cleanser'), hh: hh.householdId));

      final visible = await service.getSharedHouseholdItems(householdId: hh.householdId, currentUserId: alice.userId);
      expect(visible.map((i) => i.vanityItemId), ['bob_shared']);

      final vanity = VanityProvider();
      final emails = (await service.getHousehold(hh.householdId, currentUserId: alice.userId))!.memberEmails;
      expect(
        vanity.checkHouseholdDuplicates(name: 'Secret Night Cream', brand: 'CeraVe', sharedHouseholdItems: visible, memberEmails: emails),
        isEmpty,
      );
      final m = vanity.checkHouseholdDuplicates(
          name: 'Hydrating Facial Cleanser', brand: 'CeraVe', sharedHouseholdItems: visible, memberEmails: emails);
      expect(m.single.ownerEmail, bob.email);

      // Adding Alice's own unit never changes Bob's item or its sharing.
      final before = (await db.readVanityItemsForBackup(bob.userId)).records.firstWhere((i) => i.vanityItemId == 'bob_shared').toMap();
      await vanity.addItem(product: product('Hydrating Facial Cleanser'), userId: alice.userId, vanityItemId: 'alice_unit');
      final after = (await db.readVanityItemsForBackup(bob.userId)).records.firstWhere((i) => i.vanityItemId == 'bob_shared').toMap();
      expect(after, before);
      expect(vanity.allItems.single.isSharedWithHousehold, isFalse);
    });
  });

  // ═══════════════════════ receipt import ═══════════════════════
  group('Receipt import duplicate warning', () {
    late VanityProvider vanity;
    late ReceiptProvider receipts;
    late HouseholdProvider household;

    Future<String> pumpReceipt(WidgetTester tester, List<VanityItemModel> sharedItems) async {
      vanity = VanityProvider();
      receipts = ReceiptProvider();
      household = _FixedHousehold(sharedItems);
      final receipt = ReceiptModel(
        receiptId: 'rec_dup_${_n++}',
        userId: me,
        merchant: 'Pharmacy',
        purchaseDate: DateTime(2026, 10, 1),
        currency: '\$',
        currencyCode: 'USD',
        subtotal: 30,
        totalAmount: 30,
        createdAt: DateTime(2026, 10, 1),
        items: const [
          ReceiptItemModel(itemId: 'a', description: 'Hydrating Facial Cleanser 236ml', unitPrice: 15, totalPrice: 15),
          ReceiptItemModel(itemId: 'b', description: 'Rose Toner', unitPrice: 15, totalPrice: 15),
        ],
      );
      await receipts.saveReceipt(receipt);
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = AuthProvider();
      await auth.useDemoAccount();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: vanity),
          ChangeNotifierProvider.value(value: receipts),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider<HouseholdProvider>.value(value: household),
        ],
        child: MaterialApp(home: ReceiptDetailScreen(receiptId: receipt.receiptId)),
      ));
      await tester.pumpAndSettle();
      return receipt.receiptId;
    }

    Future<void> selectAllAndAdd(WidgetTester tester) async {
      for (final box in find.byType(Checkbox).evaluate().toList()) {
        await tester.tap(find.byWidget(box.widget));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('add-selected-to-inventory')));
      await tester.pumpAndSettle();
    }

    testWidgets('warns about a household member\'s shared item; "Add Anyway" adds a separate unit', (tester) async {
      final bobItem = shared('bob_rc', product('Hydrating Facial Cleanser', barcode: '', volume: '236 ml'));
      final rid = await pumpReceipt(tester, [bobItem]);
      await selectAllAndAdd(tester);
      expect(find.text('Possible duplicate product'), findsOneWidget);
      // The same match is shown inline on the line and in the dialog.
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('Shared by bob@example.com')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('view-existing-bob_rc')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('receipt-dup-add-anyway')));
      await tester.pumpAndSettle();
      expect(vanity.allItems.map((i) => i.vanityItemId).toSet(),
          {ReceiptInventoryService.inventoryIdFor(rid, 'a'), ReceiptInventoryService.inventoryIdFor(rid, 'b')});
      expect(bobItem.userId, 'user_bob'); // never merged or rewritten
      // Spending: the receipt is still recorded once with its original total.
      expect(receipts.receipts.where((r) => r.receiptId == rid), hasLength(1));
      expect(receipts.receiptById(rid)!.totalAmount, 30);
      expect(vanity.calculateUnifiedSpending(receipts: receipts.receipts).total, 30);
    });

    testWidgets('"Keep These on Receipt Only" adds the other lines; Cancel adds nothing', (tester) async {
      final rid = await pumpReceipt(tester, [shared('bob_rc2', product('Hydrating Facial Cleanser'))]);
      await selectAllAndAdd(tester);
      await tester.tap(find.byKey(const ValueKey('receipt-dup-cancel')));
      await tester.pumpAndSettle();
      expect(vanity.allItems, isEmpty);

      await tester.tap(find.byKey(const ValueKey('add-selected-to-inventory')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receipt-dup-keep')));
      await tester.pumpAndSettle();
      expect(vanity.allItems.map((i) => i.vanityItemId), [ReceiptInventoryService.inventoryIdFor(rid, 'b')]);
      expect(receipts.receiptById(rid)!.items.firstWhere((i) => i.itemId == 'a').matchedVanityItemId, isNull);
    });

    testWidgets('no warning without a match; repeated taps and retries never duplicate', (tester) async {
      final rid = await pumpReceipt(tester, const []);
      for (final box in find.byType(Checkbox).evaluate().toList()) {
        await tester.tap(find.byWidget(box.widget));
        await tester.pump();
      }
      final add = find.byKey(const ValueKey('add-selected-to-inventory'));
      await tester.tap(add);
      await tester.tap(add, warnIfMissed: false); // second tap while busy
      await tester.pumpAndSettle();
      expect(find.text('Possible duplicate product'), findsNothing);
      expect(vanity.allItems, hasLength(2));

      // A retry of the same receipt line must not warn about the item it created itself.
      final dupes = vanity.checkHouseholdDuplicates(
        name: 'Hydrating Facial Cleanser 236ml',
        brand: '',
        excludeItemIds: {ReceiptInventoryService.inventoryIdFor(rid, 'a'), ReceiptInventoryService.inventoryIdFor(rid, 'b')},
      );
      expect(dupes, isEmpty);
    });
  });
}

class _NotSyncedVanity extends VanityProvider {
  @override
  Future<void> markAsOpened(String vanityItemId, {DateTime? openedDate, bool throwOnSyncFailure = false}) async {
    await super.markAsOpened(vanityItemId, openedDate: openedDate);
    if (throwOnSyncFailure) {
      throw const VanitySyncException('Saved on this device; not synced yet (no connection).');
    }
  }
}

/// A household whose shared items are fixed (as loaded at sign-in).
class _FixedHousehold extends HouseholdProvider {
  final List<VanityItemModel> items;
  _FixedHousehold(this.items);
  @override
  List<VanityItemModel> get sharedItems => items;
  @override
  Map<String, String> get memberEmails => const {'user_bob': 'bob@example.com'};
}
