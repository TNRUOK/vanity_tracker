import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/models/category_model.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';

void main() {
  group('PAO Expiry Calculation Tests', () {
    test('Calculates 12 months PAO correctly', () {
      final openedDate = DateTime(2026, 1, 15);
      final expiryDate = VanityItemModel.computeExpiryDate(openedDate, 12);
      expect(expiryDate.year, 2027);
      expect(expiryDate.month, 1);
      expect(expiryDate.day, 15);
    });

    test('Calculates 3 months PAO (Mascara) correctly', () {
      final openedDate = DateTime(2026, 1, 15);
      final expiryDate = VanityItemModel.computeExpiryDate(openedDate, 3);
      expect(expiryDate.year, 2026);
      expect(expiryDate.month, 4);
      expect(expiryDate.day, 15);
    });

    test('Calculates 24 months PAO (Lipstick) correctly', () {
      final openedDate = DateTime(2026, 3, 10);
      final expiryDate = VanityItemModel.computeExpiryDate(openedDate, 24);
      expect(expiryDate.year, 2028);
      expect(expiryDate.month, 3);
      expect(expiryDate.day, 10);
    });
  });

  group('Vanity Status & Color Coding Logic', () {
    final now = DateTime.now();

    test('Status is active (Green) when > 30 days remaining', () {
      final item = VanityItemModel(
        vanityItemId: 'test_1',
        productId: 'prod_1',
        userId: 'user_1',
        openedDate: now,
        expiryDate: now.add(const Duration(days: 90)),
        status: 'active',
      );
      expect(item.computedStatus, VanityStatus.active);
      expect(item.daysUntilExpiry! > 30, true);
    });

    test('Status is expiringSoon (Amber) when 0-30 days remaining', () {
      final item = VanityItemModel(
        vanityItemId: 'test_2',
        productId: 'prod_2',
        userId: 'user_1',
        openedDate: now.subtract(const Duration(days: 340)),
        expiryDate: now.add(const Duration(days: 15)),
        status: 'expiring_soon',
      );
      expect(item.computedStatus, VanityStatus.expiringSoon);
      expect(item.daysUntilExpiry! <= 30 && item.daysUntilExpiry! >= 0, true);
    });

    test('Status is expired (Red) when days remaining < 0', () {
      final item = VanityItemModel(
        vanityItemId: 'test_3',
        productId: 'prod_3',
        userId: 'user_1',
        openedDate: now.subtract(const Duration(days: 120)),
        expiryDate: now.subtract(const Duration(days: 10)),
        status: 'expired',
      );
      expect(item.computedStatus, VanityStatus.expired);
      expect(item.daysUntilExpiry! < 0, true);
    });

    test('Status is unopened when openedDate is null', () {
      const item = VanityItemModel(
        vanityItemId: 'test_4',
        productId: 'prod_4',
        userId: 'user_1',
        status: 'unopened',
      );
      expect(item.computedStatus, VanityStatus.unopened);
      expect(item.daysUntilExpiry, isNull);
    });

    test('Status is finished when marked finished with finishedDate', () {
      final item = VanityItemModel(
        vanityItemId: 'test_5',
        productId: 'prod_5',
        userId: 'user_1',
        openedDate: now.subtract(const Duration(days: 60)),
        expiryDate: now.add(const Duration(days: 300)),
        finishedDate: now,
        status: 'finished',
        wouldRepurchase: true,
      );
      expect(item.computedStatus, VanityStatus.finished);
    });
  });

  group('Increment 2 Budget & Cost-per-Day Calculation', () {
    final now = DateTime.now();

    test('Computes cost per day accurately (price / days_used)', () {
      final item = VanityItemModel(
        vanityItemId: 'budget_1',
        productId: 'prod_1',
        userId: 'user_1',
        openedDate: now.subtract(const Duration(days: 50)),
        expiryDate: now.add(const Duration(days: 300)),
        finishedDate: now,
        price: 25.00,
        status: 'finished',
        wouldRepurchase: true,
      );

      expect(item.daysUsed, 50);
      expect(item.costPerDay, closeTo(0.50, 0.01)); // $25.00 / 50 days = $0.50/day
    });

    test('Handles 1 day minimum for immediate finished product', () {
      final item = VanityItemModel(
        vanityItemId: 'budget_2',
        productId: 'prod_2',
        userId: 'user_1',
        openedDate: now,
        finishedDate: now,
        price: 15.00,
        status: 'finished',
      );

      expect(item.daysUsed, 1);
      expect(item.costPerDay, closeTo(15.00, 0.01));
    });
  });

  group('Product and Category Model Mapping', () {
    test('Default categories have correct PAO values', () {
      final serum = CategoryModel.defaultCategories.firstWhere((c) => c.categoryId == 'serum');
      final mascara = CategoryModel.defaultCategories.firstWhere((c) => c.categoryId == 'mascara');
      final lipstick = CategoryModel.defaultCategories.firstWhere((c) => c.categoryId == 'lipstick');

      expect(serum.defaultPaoMonths, 12);
      expect(mascara.defaultPaoMonths, 3);
      expect(lipstick.defaultPaoMonths, 24);
    });

    test('ProductModel toMap and fromMap serialization', () {
      const prod = ProductModel(
        productId: 'p123',
        barcode: '123456789012',
        name: 'Niacinamide 10% + Zinc 1%',
        brand: 'The Ordinary',
        categoryId: 'serum',
        paoMonths: 12,
        volume: '30 ml',
        ingredients: 'Aqua, Niacinamide, Zinc PCA...',
      );

      final map = prod.toMap();
      final reconstructed = ProductModel.fromMap(map);

      expect(reconstructed.productId, prod.productId);
      expect(reconstructed.barcode, prod.barcode);
      expect(reconstructed.name, prod.name);
      expect(reconstructed.brand, prod.brand);
      expect(reconstructed.categoryId, prod.categoryId);
      expect(reconstructed.paoMonths, prod.paoMonths);
      expect(reconstructed.volume, prod.volume);
      expect(reconstructed.ingredients, prod.ingredients);
    });
  });
}
