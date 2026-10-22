import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/services/backup_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const sampleProduct1 = ProductModel(
    productId: 'p_serum_1',
    barcode: '8809643068098',
    name: 'Glow Deep Serum',
    brand: 'Beauty of Joseon',
    categoryId: 'serum',
    paoMonths: 12,
  );

  const sampleProduct2 = ProductModel(
    productId: 'p_moisturizer_1',
    barcode: '3337875597180',
    name: 'Toleriane Ultra Fluide',
    brand: 'La Roche-Posay',
    categoryId: 'moisturizer',
    paoMonths: 6,
  );

  final sampleItem1 = VanityItemModel(
    vanityItemId: 'item_test_1',
    userId: 'source_user_abc',
    productId: 'p_serum_1',
    product: sampleProduct1,
    openedDate: DateTime(2025, 1, 15),
    expiryDate: DateTime(2026, 1, 15),
    price: 17.50,
    routineTags: const ['AM', 'PM'],
    notes: 'Hydrating rice serum',
  );

  final sampleItem2 = VanityItemModel(
    vanityItemId: 'item_test_2',
    userId: 'source_user_abc',
    productId: 'p_moisturizer_1',
    product: sampleProduct2,
    openedDate: DateTime(2025, 2, 1),
    expiryDate: DateTime(2025, 8, 1),
    price: 24.00,
    routineTags: const ['PM'],
    notes: 'Gentle night moisturiser',
  );

  group('BackupService Export Tests', () {
    test('Exports inventory to JSON with current schema version and metadata', () {
      final jsonString = BackupService.exportToJson(
        items: [sampleItem1, sampleItem2],
        currencySymbol: 'USD',
      );
      final data = jsonDecode(jsonString) as Map<String, dynamic>;

      expect(data['app'], 'Vanity Tracker');
      expect(data['schema_version'], BackupService.currentSchemaVersion);
      expect(data['currency_symbol'], 'USD');
      expect(data['exported_at'], isNotNull);
      expect(data['total_items'], 2);

      final items = data['items'] as List<dynamic>;
      expect(items.length, 2);

      final first = items[0] as Map<String, dynamic>;
      expect(first['vanity_item_id'], 'item_test_1');
      expect(first['price'], 17.50);
      expect(first['routine_tags'], ['AM', 'PM']);
      expect(first['product'], isNotNull);
      expect(first['product']['name'], 'Glow Deep Serum');
      expect(first['product']['brand'], 'Beauty of Joseon');
    });
  });

  group('BackupService Validation Tests', () {
    test('Rejects malformed JSON syntax', () {
      final result = BackupService.validateBackup('this is not json { [', []);
      expect(result.isValid, false);
      expect(result.errorMessage, contains('Invalid JSON format'));
      expect(result.validItems, isEmpty);
    });

    test('Rejects non-map JSON root', () {
      final result = BackupService.validateBackup('["item1", "item2"]', []);
      expect(result.isValid, false);
      expect(result.errorMessage, contains('JSON root must be an object'));
    });

    test('Rejects unsupported schema version > currentSchemaVersion', () {
      final unsupportedVersion = BackupService.currentSchemaVersion + 1;
      final invalidVersionJson = jsonEncode({
        'schema_version': unsupportedVersion,
        'app': 'Vanity Tracker',
        'items': [],
      });
      final result = BackupService.validateBackup(invalidVersionJson, []);
      expect(result.isValid, false);
      expect(result.errorMessage, contains('Unsupported backup schema version ($unsupportedVersion)'));
    });

    test('Identifies invalid items missing essential fields', () {
      final malformedItemsJson = jsonEncode({
        'schema_version': 1,
        'app': 'Vanity Tracker',
        'items': [
          {
            // Missing product
            'vanity_item_id': 'bad_item_1',
            'user_id': 'u1',
          },
          {
            // Missing vanity_item_id
            'product': {
              'product_id': 'p1',
              'name': 'Test',
              'brand': 'TestBrand',
            },
          },
          // Valid item
          sampleItem1.toMap(),
        ],
      });

      final result = BackupService.validateBackup(malformedItemsJson, []);
      expect(result.isValid, true);
      expect(result.validItems.length, 1);
      expect(result.invalidReasons.length, 2);
      expect(result.invalidReasons.any((reason) => reason.contains('missing product details')), true);
      expect(result.invalidReasons.any((reason) => reason.contains('missing vanity_item_id')), true);
    });

    test('Detects duplicate items against existing inventory by barcode and name', () {
      final existingItems = [sampleItem1];

      // Item matching by barcode
      final incomingSameBarcode = VanityItemModel(
        vanityItemId: 'incoming_1',
        userId: 'other_user',
        productId: 'new_pid_1',
        product: const ProductModel(
          productId: 'new_pid_1',
          barcode: '8809643068098', // Same barcode as sampleItem1
          name: 'Different Name But Same Barcode',
          brand: 'Joseon',
          categoryId: 'serum',
          paoMonths: 12,
        ),
      );

      // Item matching by brand + name
      final incomingSameBrandName = VanityItemModel(
        vanityItemId: 'incoming_2',
        userId: 'other_user',
        productId: 'new_pid_2',
        product: const ProductModel(
          productId: 'new_pid_2',
          barcode: '',
          name: 'glow deep serum', // Same name lowercase
          brand: 'beauty of joseon', // Same brand lowercase
          categoryId: 'serum',
          paoMonths: 12,
        ),
      );

      // Distinct item
      final distinctItem = sampleItem2;

      final backupJson = BackupService.exportToJson(
        items: [
          incomingSameBarcode,
          incomingSameBrandName,
          distinctItem,
        ],
        currencySymbol: 'USD',
      );

      final result = BackupService.validateBackup(backupJson, existingItems);
      expect(result.isValid, true);
      expect(result.validItems.length, 3);
      expect(result.duplicateItems.length, 2);
      expect(result.duplicateItems.any((d) => d.vanityItemId == incomingSameBarcode.vanityItemId), true);
      expect(result.duplicateItems.any((d) => d.vanityItemId == incomingSameBrandName.vanityItemId), true);
      expect(result.duplicateItems.any((d) => d.vanityItemId == distinctItem.vanityItemId), false);
    });
  });

  group('VanityProvider Import Execution Tests', () {
    test('Import safely assigns active userId and generates fresh item IDs', () async {
      final provider = VanityProvider();
      await provider.loadItems('active_user_123');

      final itemsToImport = [sampleItem1, sampleItem2];

      final importedCount = await provider.importBackupItems(
        items: itemsToImport,
        targetUserId: 'active_user_123',
        skipDuplicates: false,
      );

      expect(importedCount, 2);

      // Verify items in provider
      final userItems = provider.activeItems.where((i) => i.userId == 'active_user_123').toList();
      expect(userItems.length >= 2, true);

      // Ensure fresh unique IDs were generated and user ownership was enforced
      for (final item in userItems) {
        expect(item.userId, 'active_user_123');
        expect(item.vanityItemId, isNot('item_test_1'));
        expect(item.vanityItemId, isNot('item_test_2'));
      }
    });

    test('Import with skipDuplicates avoids re-adding existing items', () async {
      final provider = VanityProvider();
      await provider.loadItems('user_dup_test');

      // Add sampleItem1 to user inventory
      await provider.addItem(
        product: sampleProduct1,
        userId: 'user_dup_test',
        openedDate: DateTime.now(),
        price: 15.0,
      );

      final initialCount = provider.activeItems.length;

      // Import batch containing duplicate sampleItem1 and new sampleItem2
      final importedCount = await provider.importBackupItems(
        items: [sampleItem1, sampleItem2],
        targetUserId: 'user_dup_test',
        skipDuplicates: true,
      );

      // Only sampleItem2 should have been imported
      expect(importedCount, 1);
      expect(provider.activeItems.length, initialCount + 1);
    });
  });

  group('Backup File Export & Import Direct Tests', () {
    test('generateBackupFileName uses vanity_tracker_backup_YYYY-MM-DD.json', () {
      final fixedDate = DateTime(2026, 10, 15, 14, 30, 0);
      final fileName = BackupService.generateBackupFileName(fixedDate);
      expect(fileName, 'vanity_tracker_backup_2026-10-15.json');
      expect(fileName.endsWith('.json'), true);
    });

    test('Full file workflow: export to file, read from file, validate, and safe import', () async {
      final tempDir = await Directory.systemTemp.createTemp('vanity_test_backup_');
      final backupFile = File('${tempDir.path}${Platform.pathSeparator}inventory_backup.json');

      try {
        final jsonString = BackupService.exportToJson(
          items: [sampleItem1, sampleItem2],
          currencySymbol: 'USD',
        );

        // 1. Write backup directly to disk
        await BackupService.writeBackupToFileDirect(backupFile, jsonString);
        expect(await backupFile.exists(), true);
        expect(await backupFile.length(), greaterThan(0));

        // 2. Read backup directly from disk
        final fileContent = await BackupService.readBackupFromFileDirect(backupFile);
        expect(fileContent, jsonString);

        // 3. Validate content read from disk
        final validationResult = BackupService.validateBackup(fileContent, []);
        expect(validationResult.isValid, true);
        expect(validationResult.validItems.length, 2);
        expect(validationResult.schemaVersion, BackupService.currentSchemaVersion);

        // 4. Import items to target user
        final provider = VanityProvider();
        await provider.loadItems('file_test_user');

        final imported = await provider.importBackupItems(
          items: validationResult.validItems,
          targetUserId: 'file_test_user',
          skipDuplicates: false,
        );

        expect(imported, 2);
        final userItems = provider.activeItems.where((i) => i.userId == 'file_test_user').toList();
        expect(userItems.length >= 2, true);

        // 5. Existing items are not deleted or overwritten
        final countBeforeSecondImport = provider.activeItems.length;
        final secondImport = await provider.importBackupItems(
          items: validationResult.validItems,
          targetUserId: 'file_test_user',
          skipDuplicates: true, // Safe merge skips existing duplicates
        );
        expect(secondImport, 0);
        expect(provider.activeItems.length, countBeforeSecondImport);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('Handles corrupt or truncated files gracefully', () async {
      final tempDir = await Directory.systemTemp.createTemp('vanity_corrupt_backup_');
      final badFile = File('${tempDir.path}${Platform.pathSeparator}bad_backup.json');

      try {
        await badFile.writeAsString('{"schema_version": 1, "items": [ truncated...');
        final content = await BackupService.readBackupFromFileDirect(badFile);

        final result = BackupService.validateBackup(content, []);
        expect(result.isValid, false);
        expect(result.errorMessage, contains('Invalid JSON format'));
        expect(result.validItems, isEmpty);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
