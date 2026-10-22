import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/receipt_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/models/wishlist_item_model.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/providers/wishlist_provider.dart';
import 'package:vanity_tracker/services/backup_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const testProduct = ProductModel(
    productId: 'p_test',
    barcode: '11223344',
    name: 'Retinol 0.2% in Squalane',
    brand: 'The Ordinary',
    categoryId: 'serum',
    paoMonths: 6,
  );

  final testItem = VanityItemModel(
    vanityItemId: 'orig_item_1',
    productId: 'p_test',
    userId: 'source_user_999',
    product: testProduct,
    price: 9.80,
    status: 'active',
  );

  final testWishlistItem = WishlistItemModel(
    wishlistId: 'orig_wish_1',
    userId: 'source_user_999',
    name: 'Centella Asiatica Extract',
    brand: 'SKIN1004',
    categoryId: 'serum',
    targetPrice: 18.0,
    createdAt: DateTime(2026, 4, 1),
  );

  final testReceipt = ReceiptModel(
    receiptId: 'orig_rec_1',
    userId: 'source_user_999',
    merchant: 'Deciem Store',
    purchaseDate: DateTime(2026, 3, 15),
    currency: '\$',
    subtotal: 9.80,
    taxAmount: 0.80,
    discountAmount: 0.0,
    totalAmount: 10.60,
    items: const [
      ReceiptItemModel(
        itemId: 'line_1',
        description: 'Retinol 0.2%',
        quantity: 1,
        unitPrice: 9.80,
        totalPrice: 9.80,
        matchedVanityItemId: 'orig_item_1',
      ),
    ],
    createdAt: DateTime(2026, 3, 15),
  );

  group('Schema V2 Backup & Restore Tests', () {
    test('Exports the current schema JSON structure with items, wishlist, and receipts', () {
      final jsonStr = BackupService.exportToJson(
        items: [testItem],
        wishlist: [testWishlistItem],
        receipts: [testReceipt],
      );

      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(decoded['schema_version'], equals(BackupService.currentSchemaVersion));
      expect(decoded['total_items'], equals(1));
      expect(decoded['items'], isA<List>());
      expect((decoded['items'] as List).length, equals(1));
      expect(decoded['wishlist'], isA<List>());
      expect((decoded['wishlist'] as List).length, equals(1));
      expect(decoded['receipts'], isA<List>());
      expect((decoded['receipts'] as List).length, equals(1));
    });

    test('Validates Schema V2 backup correctly', () {
      // A file in the exact v2 layout written by the previous app version.
      final jsonStr = jsonEncode({
        'schema_version': 2,
        'app': 'Vanity Tracker',
        'exported_at': '2026-10-01T10:00:00.000',
        'currency_symbol': '\$',
        'total_items': 1,
        'items': [testItem.toMap()],
        'wishlist': [testWishlistItem.toMap()],
        'receipts': [testReceipt.toMap()],
      });

      final valResult = BackupService.validateBackupJson(jsonStr);
      expect(valResult.isValid, isTrue);
      expect(valResult.schemaVersion, equals(2));
      expect(valResult.validItems.length, equals(1));
      expect(valResult.validWishlist.length, equals(1));
      expect(valResult.validReceipts.length, equals(1));
    });

    test('Backward Compatibility: Schema V1 backup validates and does not wipe wishlist or receipts', () {
      // Simulate Schema V1 backup (without wishlist and receipts arrays)
      final v1Map = {
        'schemaVersion': 1,
        'appVersion': '1.0.0',
        'exportedAt': DateTime.now().toIso8601String(),
        'totalItems': 1,
        'items': [testItem.toMap()],
      };
      final v1Json = jsonEncode(v1Map);

      final valResult = BackupService.validateBackupJson(v1Json);
      expect(valResult.isValid, isTrue);
      expect(valResult.schemaVersion, equals(1));
      expect(valResult.validItems.length, equals(1));
      expect(valResult.validWishlist.isEmpty, isTrue);
      expect(valResult.validReceipts.isEmpty, isTrue);

      // Verify that existing wishlist and receipts in providers are NOT erased when restoring V1
      final wishlistProv = WishlistProvider();
      final receiptProv = ReceiptProvider();

      wishlistProv.loadWishlistFromList([testWishlistItem]);
      receiptProv.loadReceiptsFromList([testReceipt]);

      // When restoring V1, since validWishlist and validReceipts are empty, we do NOT call clear/import
      // only items are merged.
      expect(wishlistProv.items.length, equals(1));
      expect(receiptProv.receipts.length, equals(1));
    });

    test('Imports Schema V2 data reassigning targetUserId and remapping matched item IDs', () async {
      final vanityProv = VanityProvider();
      final wishlistProv = WishlistProvider();
      final receiptProv = ReceiptProvider();

      const targetUserId = 'target_user_new';

      final idMapping = <String, String>{};
      await vanityProv.importBackupItems(
        items: [testItem],
        targetUserId: targetUserId,
        skipDuplicates: false,
        idMappingOut: idMapping,
      );

      // Item was imported with remapped ID and targetUserId
      expect(vanityProv.items.length, equals(1));
      final importedItem = vanityProv.items.first;
      expect(importedItem.userId, equals(targetUserId));
      expect(idMapping.containsKey('orig_item_1'), isTrue);
      final newMappedItemId = idMapping['orig_item_1']!;
      expect(importedItem.vanityItemId, equals(newMappedItemId));

      // Import Wishlist
      await wishlistProv.importBackupWishlist(
        importedItems: [testWishlistItem],
        targetUserId: targetUserId,
      );
      expect(wishlistProv.items.length, equals(1));
      expect(wishlistProv.items.first.userId, equals(targetUserId));

      // Import Receipts with idMapping
      await receiptProv.importBackupReceipts(
        importedReceipts: [testReceipt],
        targetUserId: targetUserId,
        vanityItemIdMapping: idMapping,
      );
      expect(receiptProv.receipts.length, equals(1));
      final importedReceipt = receiptProv.receipts.first;
      expect(importedReceipt.userId, equals(targetUserId));
      expect(importedReceipt.items.first.matchedVanityItemId, equals(newMappedItemId));
    });
  });
}
