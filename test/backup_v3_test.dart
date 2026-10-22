// Backup & Restore v3: export completeness, file validation, restore planning (safe
// merge), execution with verification, partial failure and recovery, and the screen's
// save/pick handling. Local (non-Firebase) mode with mocked SharedPreferences; the platform
// file dialogs are replaced by test doubles (real browser download/upload is checked
// separately). Nothing here touches Firestore.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/models/wishlist_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/providers/wishlist_provider.dart';
import 'package:vanity_tracker/screens/backup/backup_restore_screen.dart';
import 'package:vanity_tracker/services/backup_restore_service.dart';
import 'package:vanity_tracker/services/backup_service.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/notification_service.dart';

int _n = 0;
String uniqueUser() => 'bk_user_${DateTime.now().microsecondsSinceEpoch}_${_n++}';

ProductModel product(String name, {String barcode = ''}) => ProductModel(
      productId: 'prod_$name',
      barcode: barcode,
      name: name,
      brand: 'Brand',
      categoryId: 'serum',
      paoMonths: 6,
      paoSource: PaoSource.user,
      ingredients: 'Water, Retinol',
      ingredientsSource: IngredientSource.packaging,
    );

/// A provider whose writes fail for chosen products (to simulate a partial restore).
class FailingVanity extends VanityProvider {
  final Set<String> failNames;
  FailingVanity(this.failNames);
  @override
  Future<VanityItemModel> restoreItem(VanityItemModel item) async {
    if (failNames.contains(item.product?.name)) throw Exception('Simulated write failure');
    return super.restoreItem(item);
  }
}

class Account {
  final String userId;
  final VanityProvider vanity;
  final ReceiptProvider receipts = ReceiptProvider();
  final WishlistProvider wishlist = WishlistProvider();
  Account(this.userId, {VanityProvider? vanity}) : vanity = vanity ?? VanityProvider();

  Future<BackupSnapshot> snapshot() => BackupExportService.collect(userId: userId, currencySymbol: '\$');

  Future<RestorePlan> plan(String json, {bool replace = false, bool dupes = false}) async {
    final current = await snapshot();
    return BackupRestoreService.plan(
      backup: BackupService.validateBackup(json, const []),
      targetUserId: userId,
      currentItems: current.items,
      currentReceipts: current.receipts,
      currentWishlist: current.wishlist,
      replaceConflicts: replace,
      importPossibleDuplicates: dupes,
    );
  }

  Future<RestoreReport> restore(String json, {bool replace = false}) async =>
      BackupRestoreService.execute(await plan(json, replace: replace), vanity: vanity, receipts: receipts, wishlist: wishlist);
}

/// Creates representative data: opened product with PAO/ingredients/routines, a finished
/// product with repurchase answer, a receipt linked to a product, and a wishlist entry.
Future<Account> seededAccount() async {
  final a = Account(uniqueUser());
  final serum = await a.vanity.addItem(
    product: product('Night Serum', barcode: '3282770037500'),
    userId: a.userId,
    openedDate: DateTime(2026, 1, 31),
    price: 25.5,
    routineTags: const ['PM'],
    vanityItemId: 'item_serum_${a.userId}',
  );
  final cleanser = await a.vanity.addItem(
    product: product('Gentle Cleanser'),
    userId: a.userId,
    openedDate: DateTime(2025, 6, 1),
    price: 12,
    vanityItemId: 'item_cleanser_${a.userId}',
  );
  await a.vanity.markAsFinished(cleanser.vanityItemId, wouldRepurchase: true, finishedDate: DateTime(2026, 2, 1));
  await a.receipts.saveReceipt(ReceiptModel(
    receiptId: 'rec_${a.userId}',
    userId: a.userId,
    merchant: 'Beauty Store',
    purchaseDate: DateTime(2026, 1, 20),
    currency: '£',
    subtotal: 25.5,
    totalAmount: 25.5,
    createdAt: DateTime(2026, 1, 20, 18),
    items: [
      ReceiptItemModel(
        itemId: 'l1',
        description: 'Night Serum',
        unitPrice: 25.5,
        totalPrice: 25.5,
        matchedVanityItemId: serum.vanityItemId,
      ),
    ],
  ));
  await a.wishlist.restoreItem(WishlistItemModel(
    wishlistId: 'wish_${a.userId}',
    userId: a.userId,
    name: 'Sunscreen SPF50',
    brand: 'Brand',
    targetPrice: 18,
    createdAt: DateTime(2026, 3, 1),
  ));
  return a;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    NotificationService.debugLog = [];
  });
  tearDown(() {
    NotificationService.debugLog = null;
    BackupService.debugSaver = null;
    BackupService.debugPicker = null;
  });

  group('Export', () {
    test('includes every supported data type with ids, dates, currency, PAO, ingredients and links', () async {
      final a = await seededAccount();
      final snap = await a.snapshot();
      expect(snap.isComplete, isTrue);
      final json = BackupExportService.buildVerifiedJson(snap, userId: a.userId);
      final m = jsonDecode(json) as Map<String, dynamic>;

      expect(m['format'], 'vanity-tracker-backup');
      expect(m['schema_version'], 3);
      expect(m['source_user_id'], a.userId);
      expect(m['complete'], isTrue);
      expect(m['counts'], {'items': 2, 'receipts': 1, 'wishlist': 1});
      expect(m['excluded'], isNotEmpty);

      final items = {for (final i in m['items'] as List) i['vanity_item_id']: i};
      final serum = items['item_serum_${a.userId}'];
      expect(serum['opened_date'], DateTime(2026, 1, 31).toIso8601String());
      expect(serum['expiry_date'], DateTime(2026, 7, 31).toIso8601String());
      expect(serum['price'], 25.5);
      expect(serum['routine_tags'], ['PM']);
      expect(serum['product']['pao_months'], 6);
      expect(serum['product']['pao_source'], 'user');
      expect(serum['product']['ingredients_source'], 'packaging');
      final cleanser = items['item_cleanser_${a.userId}'];
      expect(cleanser['status'], 'finished');
      expect(cleanser['would_repurchase'], isTrue);
      expect(cleanser['finished_date'], DateTime(2026, 2, 1).toIso8601String());

      final receipt = (m['receipts'] as List).single;
      expect(receipt['currency'], '£');
      expect(receipt['purchase_date'], DateTime(2026, 1, 20).toIso8601String());
      expect(receipt['items'][0]['matched_vanity_item_id'], 'item_serum_${a.userId}');
      expect((m['wishlist'] as List).single['wishlist_id'], 'wish_${a.userId}');

      // No secrets.
      for (final word in ['password', 'token', 'secret', 'apiKey', 'app_password']) {
        expect(json.contains('"$word"'), isFalse, reason: word);
      }
    });

    test('is not affected by shelf search/filters or screens that were never opened', () async {
      final a = await seededAccount();
      a.vanity.setSearchQuery('no-match');
      a.vanity.setStatusFilter('expired');
      expect(a.vanity.activeItems, isEmpty);
      final fresh = Account(a.userId); // nothing loaded in its providers
      final snap = await fresh.snapshot();
      expect(snap.items.length, 2);
      expect(snap.receipts.length, 1);
      expect(snap.wishlist.length, 1);
    });

    test('an account with no records exports a valid empty backup', () async {
      final a = Account(uniqueUser());
      final snap = await a.snapshot();
      final json = BackupExportService.buildVerifiedJson(snap, userId: a.userId);
      final m = jsonDecode(json) as Map<String, dynamic>;
      expect(m['counts'], {'items': 0, 'receipts': 0, 'wishlist': 0});
      final v = BackupService.validateBackup(json, const []);
      expect(v.isValid, isFalse);
      expect(v.errorMessage, contains('contains no products'));
    });

    test('a partial export is labelled partial in the file', () {
      final json = BackupExportService.buildVerifiedJson(
        const BackupSnapshot(items: [], receipts: [], wishlist: [], currencySymbol: '\$', omissions: ['Receipts could not be read']),
        userId: 'u',
      );
      final m = jsonDecode(json);
      expect(m['complete'], isFalse);
      expect(m['omissions'], ['Receipts could not be read']);
    });
  });

  group('File validation', () {
    late String good;
    setUp(() async {
      final a = await seededAccount();
      good = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
    });

    test('truncated, corrupt, foreign and future-version files are rejected', () {
      expect(BackupService.validateBackup(good.substring(0, good.length ~/ 2), const []).errorMessage, contains('Invalid JSON'));

      final m = jsonDecode(good) as Map<String, dynamic>;
      (m['items'] as List).removeLast();
      expect(BackupService.validateBackup(jsonEncode(m), const []).errorMessage, contains('looks truncated'));

      final future = jsonDecode(good) as Map<String, dynamic>..['schema_version'] = 4;
      expect(BackupService.validateBackup(jsonEncode(future), const []).errorMessage, contains('Unsupported backup schema version (4)'));

      final foreign = jsonDecode(good) as Map<String, dynamic>..['format'] = 'something-else';
      expect(BackupService.validateBackup(jsonEncode(foreign), const []).errorMessage, contains('not a Vanity Tracker backup'));

      final damaged = jsonDecode(good) as Map<String, dynamic>..['receipts'] = 'oops';
      expect(BackupService.validateBackup(jsonEncode(damaged), const []).isValid, isFalse);
    });

    test('bad records are listed with type and reason, never silently dropped', () {
      final m = jsonDecode(good) as Map<String, dynamic>;
      (m['receipts'] as List).add({'receipt_id': 'r_bad', 'total_amount': 3});
      (m['wishlist'] as List).add({'wishlist_id': 'w_bad', 'name': ''});
      (m['items'] as List).add({'vanity_item_id': 'i_bad', 'opened_date': 'yesterday', 'product_id': 'p'});
      final counts = m['counts'] as Map<String, dynamic>;
      counts['receipts'] = 2;
      counts['wishlist'] = 2;
      counts['items'] = 3;
      final v = BackupService.validateBackup(jsonEncode(m), const []);
      expect(v.isValid, isTrue);
      expect(v.invalidReasons, hasLength(3));
      expect(v.invalidReasons.join('|'), allOf(contains('Receipt #2: missing or invalid purchase_date'),
          contains('Wishlist item #2: missing name'), contains('Item #3 failed to parse: opened_date')));
    });

    test('file bytes: a byte-order mark is accepted; non-UTF-8 and oversize files are rejected', () {
      final withBom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('{"a":1}')]);
      expect(BackupService.decodeBackupBytes(withBom), '{"a":1}');
      expect(() => BackupService.decodeBackupBytes(Uint8List.fromList([0xC3, 0x28])), throwsFormatException);
      expect(() => BackupService.decodeBackupBytes(Uint8List(BackupService.maxImportBytes + 1)), throwsFormatException);
    });

    test('older v1 and v2 files (missing optional fields) still restore', () async {
      final b = Account(uniqueUser());
      final v1 = jsonEncode({
        'schemaVersion': 1,
        'items': [
          {'vanity_item_id': 'legacy_1', 'user_id': b.userId, 'product': {'name': 'Old Cream'}},
        ],
      });
      final r1 = await b.restore(v1);
      expect(r1.written, 1);
      final restored = b.vanity.allItems.single;
      expect(restored.product!.name, 'Old Cream');
      expect(restored.product!.paoSource, PaoSource.unknown); // missing PAO is not invented

      final v2 = jsonEncode({
        'schema_version': 2,
        'items': [],
        'wishlist': [
          {'wishlist_id': 'w_old', 'user_id': b.userId, 'name': 'Toner', 'created_at': '2026-01-01T00:00:00.000'},
        ],
        'receipts': [],
      });
      expect((await b.restore(v2)).written, 1);
    });
  });

  group('Restore', () {
    test('round trip into an empty account restores everything with relationships', () async {
      final a = await seededAccount();
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);

      final b = Account(uniqueUser());
      final report = await b.restore(json);
      expect(report.isComplete, isTrue);
      expect(report.written, 4);
      expect(report.verified, 4);

      final snap = await b.snapshot();
      expect(snap.items.length, 2);
      final serum = snap.items.firstWhere((i) => i.product!.name == 'Night Serum');
      expect(serum.userId, b.userId);
      expect(serum.vanityItemId, isNot('item_serum_${a.userId}')); // never another account's id
      expect(serum.openedDate, DateTime(2026, 1, 31));
      expect(serum.expiryDate, DateTime(2026, 7, 31));
      expect(serum.product!.paoSource, PaoSource.user);
      expect(serum.routineTags, ['PM']);
      expect(b.vanity.pmRoutineItems.map((i) => i.vanityItemId), contains(serum.vanityItemId));
      final finished = snap.items.firstWhere((i) => i.product!.name == 'Gentle Cleanser');
      expect(finished.status, 'finished');
      expect(finished.wouldRepurchase, isTrue);

      final receipt = snap.receipts.single;
      expect(receipt.currency, '£');
      expect(receipt.totalAmount, 25.5);
      expect(receipt.items.single.matchedVanityItemId, serum.vanityItemId); // link remapped
      expect(snap.wishlist.single.name, 'Sunscreen SPF50');
    });

    test('importing the same file twice creates no duplicates', () async {
      final a = await seededAccount();
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
      final b = Account(uniqueUser());
      await b.restore(json);
      final second = await b.plan(json);
      expect(second.toWrite, 0);
      expect(second.count(RestoreAction.skipIdentical), 4);
      final snap = await b.snapshot();
      expect(snap.totalRecords, 4);
    });

    test('restoring into the same account keeps ids and is a no-op', () async {
      final a = await seededAccount();
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
      final p = await a.plan(json);
      expect(p.crossAccount, isFalse);
      expect(p.toWrite, 0);
      expect(p.entries.every((e) => e.targetId == e.backupId), isTrue);
    });

    test('a newer local change is kept by default; replacing is an explicit choice', () async {
      final a = await seededAccount();
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
      final serum = a.vanity.allItems.firstWhere((i) => i.product!.name == 'Night Serum');
      await a.vanity.updateItem(serum.copyWith(price: 30));

      final keep = await a.plan(json);
      expect(keep.count(RestoreAction.conflictKeep), 1);
      expect(keep.toWrite, 0);

      final report = await a.restore(json, replace: true);
      expect(report.plan.count(RestoreAction.conflictReplace), 1);
      expect(a.vanity.allItems.firstWhere((i) => i.vanityItemId == serum.vanityItemId).price, 25.5);
    });

    test('records that look like existing ones under another id are skipped and links follow them', () async {
      final a = await seededAccount();
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
      final b = Account(uniqueUser());
      // b already has the same serum (e.g. from an old import that minted new ids).
      final mine = await b.vanity.addItem(
        product: product('Night Serum', barcode: '3282770037500'),
        userId: b.userId,
        openedDate: DateTime(2026, 1, 31),
        price: 25.5,
        vanityItemId: 'b_own_serum',
      );
      final report = await b.restore(json);
      expect(report.plan.count(RestoreAction.possibleDuplicate, 'Product'), 1);
      expect((await b.snapshot()).items.where((i) => i.product!.name == 'Night Serum'), hasLength(1));
      expect(b.receipts.receipts.single.items.single.matchedVanityItemId, mine.vanityItemId);
    });

    test('ownership: another account\'s records get account-specific ids and household sharing is cleared', () async {
      final a = Account(uniqueUser());
      await a.vanity.addItem(
        product: product('Shared Serum'),
        userId: a.userId,
        vanityItemId: 'shared_${a.userId}',
        isSharedWithHousehold: true,
        sharedHouseholdId: 'house_1',
      );
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
      final b = Account(uniqueUser());
      final p = await b.plan(json);
      expect(p.crossAccount, isTrue);
      await BackupRestoreService.execute(p, vanity: b.vanity, receipts: b.receipts, wishlist: b.wishlist);
      final restored = (await b.snapshot()).items.single;
      expect(restored.userId, b.userId);
      expect(restored.vanityItemId, startsWith('rst_'));
      expect(restored.isSharedWithHousehold, isFalse);
      expect(restored.sharedHouseholdId, isNull);
      // a's own record is untouched.
      expect((await a.snapshot()).items.single.isSharedWithHousehold, isTrue);
    });

    test('a failed write is reported honestly and the same import retries only what is missing', () async {
      final a = await seededAccount();
      final json = BackupExportService.buildVerifiedJson(await a.snapshot(), userId: a.userId);
      final userB = uniqueUser();
      final b = Account(userB, vanity: FailingVanity({'Gentle Cleanser'}));
      final first = await b.restore(json);
      expect(first.failed, 1);
      expect(first.isComplete, isFalse);
      expect(first.summary, contains('1 FAILED'));
      expect(first.written, 3);

      final retry = Account(userB);
      final again = await retry.restore(json);
      expect(again.plan.toWrite, 1);
      expect(again.written, 1);
      expect((await retry.snapshot()).items.length, 2);
    });

    test('a backup larger than one Firestore batch (520 products) restores completely', () async {
      final a = Account(uniqueUser());
      final items = [
        for (var i = 0; i < 520; i++)
          VanityItemModel(
            vanityItemId: 'bulk_$i',
            productId: 'p$i',
            userId: a.userId,
            product: product('Bulk $i'),
            price: i.toDouble(),
          ),
      ];
      final json = BackupService.exportToJson(items: items, sourceUserId: a.userId);
      final report = await a.restore(json);
      expect(report.written, 520);
      expect(report.verified, 520);
      expect((await a.snapshot()).items.length, 520);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // ─────────────────────────────── screen ───────────────────────────────
  group('Backup screen', () {
    late Account acct;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = AuthProvider();
      await auth.useDemoAccount();
      acct = Account(auth.currentUser!.userId);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<VanityProvider>.value(value: acct.vanity),
          ChangeNotifierProvider.value(value: acct.receipts),
          ChangeNotifierProvider.value(value: acct.wishlist),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: const MaterialApp(home: BackupRestoreScreen()),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('success is reported only after the platform save completed', (tester) async {
      String? savedJson;
      BackupService.debugSaver = (bytes, name) async {
        savedJson = utf8.decode(bytes);
        return BackupSaveOutcome(saved: true, fileName: name, location: 'Downloads', isBrowserDownload: true);
      };
      await pump(tester);
      await tapKey(tester, 'backup-prepare');
      expect(find.byKey(const ValueKey('backup-counts')), findsOneWidget);
      await tapKey(tester, 'backup-save');
      expect(savedJson, isNotNull);
      expect(BackupService.validateBackup(savedJson!, const []).schemaVersion, 3);
      expect(find.textContaining('Download started: vanity_tracker_backup_'), findsWidgets);
    });

    testWidgets('a cancelled save dialog or a failed save is not reported as success', (tester) async {
      BackupService.debugSaver = (bytes, name) async => BackupSaveOutcome(saved: false, cancelled: true, fileName: name);
      await pump(tester);
      await tapKey(tester, 'backup-prepare');
      await tapKey(tester, 'backup-save');
      expect(find.text('Saving was cancelled. No file was saved.'), findsOneWidget);

      BackupService.debugSaver = (bytes, name) async => throw Exception('Storage permission denied');
      await tapKey(tester, 'backup-save');
      expect(find.textContaining('The backup was NOT saved: Storage permission denied'), findsWidgets);
    });

    testWidgets('a cancelled file picker changes nothing; an invalid file is rejected', (tester) async {
      BackupService.debugPicker = () async => null;
      await pump(tester);
      await tester.tap(find.text('Import Backup'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'backup-pick');
      expect(find.text('No file selected.'), findsOneWidget);

      BackupService.debugPicker = () async =>
          const FilePickResultData(fileName: 'broken.json', content: '{"format": "vanity-tracker-ba', fileSizeBytes: 30);
      await tapKey(tester, 'backup-pick');
      expect(find.text('Invalid backup file'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your data was not changed'), findsOneWidget);
    });
  });
}
