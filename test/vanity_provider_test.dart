import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('VanityProvider Flow & Filter Tests', () {
    test('Load items, filter by search query and category', () async {
      final provider = VanityProvider();
      await provider.loadItems('test_user');

      // Add a test product
      const product1 = ProductModel(
        productId: 'p_sunscreen_1',
        barcode: '12345678',
        name: 'Daily Sunscreen UV Defense',
        brand: 'Supergoop',
        categoryId: 'sunscreen',
        paoMonths: 12,
      );

      await provider.addItem(
        product: product1,
        userId: 'test_user',
        openedDate: DateTime.now(),
        price: 38.00,
        notes: 'Great under makeup',
      );

      expect(provider.activeItems.any((i) => i.product?.name == 'Daily Sunscreen UV Defense'), true);

      // Search query filter
      provider.setSearchQuery('Supergoop');
      expect(provider.activeItems.length, 1);

      provider.setSearchQuery('Nonexistent');
      expect(provider.activeItems.length, 0);

      provider.setSearchQuery('');
      // Category filter
      provider.setCategoryFilter('sunscreen');
      expect(provider.activeItems.every((i) => i.product?.categoryId == 'sunscreen'), true);

      provider.setCategoryFilter('all');
    });

    test('Duplicate product detection', () async {
      final provider = VanityProvider();
      await provider.loadItems('test_user');

      const prod = ProductModel(
        productId: 'p_dup_1',
        barcode: '999888777',
        name: 'Vitamin C 20% Serum',
        brand: 'Timeless',
        categoryId: 'serum',
        paoMonths: 6,
      );

      await provider.addItem(
        product: prod,
        userId: 'test_user',
        openedDate: DateTime.now(),
      );

      // Check duplicates by barcode
      final dupsByBarcode = provider.checkDuplicates(barcode: '999888777');
      expect(dupsByBarcode.isNotEmpty, true);

      // Check duplicates by brand & name
      final dupsByName = provider.checkDuplicates(brand: 'Timeless', name: 'Vitamin C');
      expect(dupsByName.isNotEmpty, true);

      // Non-duplicate
      final noDups = provider.checkDuplicates(barcode: '00000000', brand: 'Unknown', name: 'Lip Balm');
      expect(noDups.isEmpty, true);
    });

    test('Mark as opened and mark as finished lifecycle', () async {
      final provider = VanityProvider();
      await provider.loadItems('test_user');

      const prod = ProductModel(
        productId: 'lifecycle_p',
        barcode: '555444333',
        name: 'Soothing Toner',
        brand: 'Klairs',
        categoryId: 'toner',
        paoMonths: 12,
      );

      // Add unopened item
      final created = await provider.addItem(
        product: prod,
        userId: 'test_user',
        price: 22.00,
      );
      expect(created.computedStatus, VanityStatus.unopened);

      // Mark as opened
      await provider.markAsOpened(created.vanityItemId);
      final openedItem = provider.activeItems.firstWhere((i) => i.vanityItemId == created.vanityItemId);
      expect(openedItem.openedDate, isNotNull);
      expect(openedItem.expiryDate, isNotNull);
      expect(openedItem.computedStatus, VanityStatus.active);

      // Mark as finished (Increment 2)
      await provider.markAsFinished(created.vanityItemId, wouldRepurchase: true);
      expect(provider.activeItems.any((i) => i.vanityItemId == created.vanityItemId), false);
      expect(provider.empties.any((i) => i.vanityItemId == created.vanityItemId), true);

      final emptyItem = provider.empties.firstWhere((i) => i.vanityItemId == created.vanityItemId);
      expect(emptyItem.wouldRepurchase, true);
      expect(emptyItem.finishedDate, isNotNull);

      // Restore from Empties back to active shelf
      await provider.restoreFromEmpties(created.vanityItemId);
      expect(provider.empties.any((i) => i.vanityItemId == created.vanityItemId), false);
      expect(provider.activeItems.any((i) => i.vanityItemId == created.vanityItemId), true);
      final restoredItem = provider.activeItems.firstWhere((i) => i.vanityItemId == created.vanityItemId);
      expect(restoredItem.finishedDate, isNull);
      expect(restoredItem.status, 'active');
    });

    test('Currency customization and persistence', () async {
      final provider = VanityProvider();
      await provider.loadItems('test_user');

      // Default is $
      expect(provider.currencySymbol, '\$');

      // Change currency to €
      await provider.setCurrency('€');
      expect(provider.currencySymbol, '€');

      // Change currency to ₹
      await provider.setCurrency('₹');
      expect(provider.currencySymbol, '₹');
    });

    test('Add item with sealed expiry date', () async {
      final provider = VanityProvider();
      await provider.loadItems('test_user');

      const prod = ProductModel(
        productId: 'batch_test_p',
        barcode: '1122334455',
        name: 'Moisturizing Cream',
        brand: 'CeraVe',
        categoryId: 'moisturizer',
        paoMonths: 12,
      );

      final futureSealed = DateTime.now().add(const Duration(days: 200));
      final item = await provider.addItem(
        product: prod,
        userId: 'test_user',
        sealedExpiryDate: futureSealed,
      );

      expect(item.sealedExpiryDate, futureSealed);
      expect(item.computedStatus, VanityStatus.unopened);
      expect(item.effectiveExpiryDate, futureSealed);
    });

    test('clear() empties in-memory items on sign out', () async {
      final provider = VanityProvider();
      await provider.loadItems('test_user');

      const prod = ProductModel(
        productId: 'clear_test_p',
        barcode: '99887766',
        name: 'Lip Oil',
        brand: 'Dior',
        categoryId: 'lipstick',
        paoMonths: 12,
      );
      await provider.addItem(
        product: prod,
        userId: 'test_user',
      );
      expect(provider.activeItems.isNotEmpty, true);

      // Sign out / clear
      provider.clear();
      expect(provider.activeItems.isEmpty, true);
      expect(provider.empties.isEmpty, true);
    });

    test('Demo items are strictly isolated from normal registered users', () async {
      final demoProvider = VanityProvider();
      await demoProvider.loadItems('demo_user');
      // demo_user sees seeded items
      expect(demoProvider.activeItems.every((i) => i.userId == 'demo_user'), true);

      final normalUserProvider = VanityProvider();
      await normalUserProvider.loadItems('real_user_xyz_789');
      // Real user starts clean with 0 demo items
      expect(normalUserProvider.activeItems.isEmpty, true);
      expect(normalUserProvider.empties.isEmpty, true);
    });
  });
}
