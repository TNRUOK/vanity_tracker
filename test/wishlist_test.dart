import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/models/wishlist_item_model.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/providers/wishlist_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WishlistItemModel Tests', () {
    test('Model serialization roundtrip preserves all fields', () {
      final item = WishlistItemModel(
        wishlistId: 'wish_1',
        userId: 'user_123',
        name: 'Watermelon Glow Niacinamide Dew Drops',
        brand: 'Glow Recipe',
        categoryId: 'serum',
        targetPrice: 35.0,
        notes: 'Repurchase when current serum empties',
        barcode: '850001316185',
        createdAt: DateTime(2026, 3, 10, 14, 0),
      );

      final map = item.toMap();
      final restored = WishlistItemModel.fromMap(map);

      expect(restored.wishlistId, equals(item.wishlistId));
      expect(restored.userId, equals(item.userId));
      expect(restored.name, equals(item.name));
      expect(restored.brand, equals(item.brand));
      expect(restored.categoryId, equals(item.categoryId));
      expect(restored.targetPrice, equals(35.0));
      expect(restored.notes, equals('Repurchase when current serum empties'));
      expect(restored.barcode, equals('850001316185'));
      expect(restored.createdAt.year, equals(2026));
    });
  });

  group('WishlistProvider Operations & Duplicate Detection Tests', () {
    test('Add, update, and delete wishlist items', () async {
      final prov = WishlistProvider();
      await prov.loadWishlist('user_123');

      final toAdd = WishlistItemModel(
        wishlistId: 'wish_test_1',
        userId: 'user_123',
        name: 'Barrier Restoration Cream',
        brand: 'Dieux',
        categoryId: 'moisturizer',
        targetPrice: 42.0,
        notes: 'Ceramide rich',
        createdAt: DateTime.now(),
      );

      final created = await prov.addItem(toAdd);

      expect(prov.items.length, equals(1));
      expect(prov.items.first.name, equals('Barrier Restoration Cream'));
      expect(prov.items.first.targetPrice, equals(42.0));

      // Update item
      await prov.updateItem(created.copyWith(targetPrice: 38.0));
      expect(prov.items.first.targetPrice, equals(38.0));

      // Delete item
      await prov.deleteItem(created.wishlistId, 'user_123');
      expect(prov.items.isEmpty, isTrue);
    });

    test('Filter by category and search query', () async {
      final prov = WishlistProvider();
      prov.loadWishlistFromList([
        WishlistItemModel(
          wishlistId: 'w1',
          userId: 'u1',
          name: 'Niacinamide 10%',
          brand: 'The Ordinary',
          categoryId: 'serum',
          createdAt: DateTime.now(),
        ),
        WishlistItemModel(
          wishlistId: 'w2',
          userId: 'u1',
          name: 'Anthelios UVmune 400',
          brand: 'La Roche-Posay',
          categoryId: 'sunscreen',
          createdAt: DateTime.now(),
        ),
      ]);

      expect(prov.items.length, equals(2));

      // Filter by sunscreen
      prov.setCategoryFilter('sunscreen');
      expect(prov.items.length, equals(1));
      expect(prov.items.first.name, contains('Anthelios'));

      // Clear filter and search
      prov.setCategoryFilter(null);
      prov.setSearchQuery('ordinary');
      expect(prov.items.length, equals(1));
      expect(prov.items.first.brand, equals('The Ordinary'));
    });

    test('Detects already-owned items on personal shelf and in household', () {
      final wishlistProv = WishlistProvider();
      final vanityProv = VanityProvider();

      const ownedProduct = ProductModel(
        productId: 'prod_owned',
        barcode: '1234567890',
        name: 'Advanced Snail 96 Mucin',
        brand: 'COSRX',
        categoryId: 'serum',
        paoMonths: 12,
      );

      final ownedItem = VanityItemModel(
        vanityItemId: 'shelf_1',
        productId: 'prod_owned',
        userId: 'u1',
        product: ownedProduct,
        status: 'active',
      );

      vanityProv.loadItemsFromList([ownedItem]);

      final wishItemBarcodeMatch = WishlistItemModel(
        wishlistId: 'w_bar',
        userId: 'u1',
        name: 'Snail Essence',
        brand: 'COSRX',
        categoryId: 'serum',
        barcode: '1234567890',
        createdAt: DateTime.now(),
      );

      // Check barcode match
      final match1 = wishlistProv.checkOwnership(
        wishItemBarcodeMatch,
        vanityProv,
      );
      expect(match1, isNotNull);
      expect(match1!.matchType, equals(DuplicateMatchType.exactBarcode));

      final wishItemNameMatch = WishlistItemModel(
        wishlistId: 'w_name',
        userId: 'u1',
        name: '  advanced snail 96  mucin!  ',
        brand: 'COSRX',
        categoryId: 'serum',
        createdAt: DateTime.now(),
      );

      // Check brand/name fuzzy duplicate match
      final match2 = wishlistProv.checkOwnership(
        wishItemNameMatch,
        vanityProv,
      );
      expect(match2, isNotNull);
      expect(match2!.isPersonal, isTrue);
    });

    test('Move to Vanity Shelf converts wishlist item and removes from wishlist', () async {
      final wishlistProv = WishlistProvider();
      final vanityProv = VanityProvider();

      final wishItem = WishlistItemModel(
        wishlistId: 'w_bought',
        userId: 'u1',
        name: 'Lip Sleeping Mask',
        brand: 'Laneige',
        categoryId: 'lipstick',
        targetPrice: 24.0,
        createdAt: DateTime.now(),
      );

      wishlistProv.loadWishlistFromList([wishItem]);
      expect(wishlistProv.items.length, equals(1));

      // User purchased the item, move to vanity shelf
      final createdProduct = ProductModel(
        productId: 'prod_laneige',
        barcode: wishItem.barcode ?? '',
        name: wishItem.name,
        brand: wishItem.brand,
        categoryId: wishItem.categoryId,
        paoMonths: 12,
      );

      await vanityProv.addItem(
        product: createdProduct,
        userId: 'u1',
        price: wishItem.targetPrice,
        notes: 'Purchased from wishlist',
      );

      await wishlistProv.deleteItem(wishItem.wishlistId, 'u1');

      expect(wishlistProv.items.isEmpty, isTrue);
      expect(vanityProv.activeItems.any((i) => i.product?.name == 'Lip Sleeping Mask'), isTrue);
      expect(vanityProv.activeItems.first.price, equals(24.0));
    });
  });
}
