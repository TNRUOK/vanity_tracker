import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';

void main() {
  group('Cost-Per-Day and Budget Tests', () {
    test('Calculates cost per day accurately for finished product', () {
      final opened = DateTime(2025, 1, 1);
      final finished = DateTime(2025, 4, 1); // 90 days
      const price = 45.00;

      final item = VanityItemModel(
        vanityItemId: 'item_1',
        productId: 'prod_1',
        userId: 'user_1',
        price: price,
        openedDate: opened,
        finishedDate: finished,
        status: 'finished',
      );

      expect(item.daysInUse, 90);
      expect(item.costPerDay, closeTo(0.50, 0.01)); // $45 / 90 days = $0.50/day
    });

    test('Handles 0 days or same day finished gracefully with min 1 day', () {
      final opened = DateTime(2025, 1, 1);
      final finished = DateTime(2025, 1, 1);
      const price = 25.00;

      final item = VanityItemModel(
        vanityItemId: 'item_2',
        productId: 'prod_2',
        userId: 'user_1',
        price: price,
        openedDate: opened,
        finishedDate: finished,
        status: 'finished',
      );

      expect(item.daysInUse, 1);
      expect(item.costPerDay, 25.00);
    });

    test('Returns null when price is missing or 0', () {
      final opened = DateTime(2025, 1, 1);
      final finished = DateTime(2025, 3, 1);

      final itemNoPrice = VanityItemModel(
        vanityItemId: 'item_3',
        productId: 'prod_3',
        userId: 'user_1',
        price: null,
        openedDate: opened,
        finishedDate: finished,
        status: 'finished',
      );
      expect(itemNoPrice.costPerDay, isNull);

      final itemZeroPrice = VanityItemModel(
        vanityItemId: 'item_4',
        productId: 'prod_4',
        userId: 'user_1',
        price: 0.0,
        openedDate: opened,
        finishedDate: finished,
        status: 'finished',
      );
      expect(itemZeroPrice.costPerDay, isNull);
    });

    test('VanityItemModel costPerDay getter evaluates properly', () {
      const prod = ProductModel(
        productId: 'p_test',
        barcode: '12345678',
        name: 'Dew Drops',
        brand: 'Glow Recipe',
        categoryId: 'serum',
        paoMonths: 12,
      );

      final item = VanityItemModel(
        vanityItemId: 'item_test',
        productId: 'p_test',
        userId: 'user_1',
        price: 35.00,
        openedDate: DateTime.now().subtract(const Duration(days: 70)),
        status: 'active',
        product: prod,
      );

      expect(item.daysInUse, 70);
      expect(item.costPerDay, closeTo(0.50, 0.01));
    });
  });
}
