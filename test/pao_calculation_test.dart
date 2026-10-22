import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/theme/app_theme.dart';

void main() {
  group('PAO Expiry Calculation Tests', () {
    test('Calculates 12 months PAO correctly', () {
      final opened = DateTime(2025, 1, 15);
      final expiry = VanityItemModel.computeExpiryDate(opened, 12);
      expect(expiry.year, 2026);
      expect(expiry.month, 1);
      expect(expiry.day, 15);
    });

    test('Calculates 3 months PAO (Mascara) correctly', () {
      final opened = DateTime(2025, 1, 10);
      final expiry = VanityItemModel.computeExpiryDate(opened, 3);
      expect(expiry.year, 2025);
      expect(expiry.month, 4);
      expect(expiry.day, 10);
    });

    test('Calculates 24 months PAO (Lipstick) correctly', () {
      final opened = DateTime(2024, 6, 1);
      final expiry = VanityItemModel.computeExpiryDate(opened, 24);
      expect(expiry.year, 2026);
      expect(expiry.month, 6);
      expect(expiry.day, 1);
    });

    test('Handles month-end boundaries safely', () {
      final opened = DateTime(2025, 1, 31);
      final expiry = VanityItemModel.computeExpiryDate(opened, 1); // Feb 28
      expect(expiry.month, 2);
      expect(expiry.day, 28);
    });
  });

  group('Urgency Category Color Tests', () {
    test('Item with >30 days remaining is GREEN', () {
      final color = AppTheme.getStatusColor(92);
      expect(color, AppTheme.statusGreen);
    });

    test('Item with 15 days remaining is AMBER (Expiring Soon)', () {
      final color = AppTheme.getStatusColor(15);
      expect(color, AppTheme.statusAmber);
    });

    test('Item with <0 days remaining is RED (Expired)', () {
      final color = AppTheme.getStatusColor(-12);
      expect(color, AppTheme.statusRed);
    });

    test('Unopened item returns unopened color', () {
      final color = AppTheme.getStatusColor(null, isUnopened: true);
      expect(color, AppTheme.statusUnopened);
    });
  });

  group('VanityItemModel Computed Status Tests', () {
    test('Item marked finished has finished status regardless of expiry', () {
      const prod = ProductModel(
        productId: 'p_1',
        barcode: '12345678',
        name: 'Serum',
        brand: 'Brand',
        categoryId: 'serum',
        paoMonths: 12,
      );
      final item = VanityItemModel(
        vanityItemId: 'item_1',
        productId: 'p_1',
        userId: 'user_1',
        openedDate: DateTime(2025, 1, 1),
        expiryDate: DateTime(2026, 1, 1),
        status: 'active',
        finishedDate: DateTime(2025, 6, 1),
        product: prod,
      );
      expect(item.computedStatus, VanityStatus.finished);
    });
  });
}
