import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/models/category_model.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/services/notification_service.dart';

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

  group('Sealed Batch Expiry & Effective Expiry Logic', () {
    final now = DateTime.now();

    test('effectiveExpiryDate picks earlier of sealed expiry and PAO expiry', () {
      final paoExpiry = now.add(const Duration(days: 365));
      final sealedExpiry = now.add(const Duration(days: 180));

      final item = VanityItemModel(
        vanityItemId: 'sealed_1',
        productId: 'prod_1',
        userId: 'user_1',
        openedDate: now,
        expiryDate: paoExpiry,
        sealedExpiryDate: sealedExpiry,
        status: 'active',
      );

      // Sealed expiry is sooner, so it should be the effective date
      expect(item.effectiveExpiryDate, sealedExpiry);
      expect(item.daysUntilExpiry, closeTo(180, 2));
    });

    test('effectiveExpiryDate picks PAO expiry when PAO is earlier than sealed expiry', () {
      final paoExpiry = now.add(const Duration(days: 90));
      final sealedExpiry = now.add(const Duration(days: 365));

      final item = VanityItemModel(
        vanityItemId: 'sealed_2',
        productId: 'prod_2',
        userId: 'user_1',
        openedDate: now,
        expiryDate: paoExpiry,
        sealedExpiryDate: sealedExpiry,
        status: 'active',
      );

      // PAO expiry is sooner, so it should be the effective date
      expect(item.effectiveExpiryDate, paoExpiry);
      expect(item.daysUntilExpiry, closeTo(90, 2));
    });

    test('Unopened item with sealed expiry date computes daysUntilExpiry', () {
      final sealedExpiry = now.add(const Duration(days: 60));

      final item = VanityItemModel(
        vanityItemId: 'sealed_3',
        productId: 'prod_3',
        userId: 'user_1',
        sealedExpiryDate: sealedExpiry,
        status: 'unopened',
      );

      expect(item.openedDate, isNull);
      expect(item.expiryDate, isNull);
      expect(item.effectiveExpiryDate, sealedExpiry);
      expect(item.daysUntilExpiry, closeTo(60, 2));
      // Status remains unopened
      expect(item.computedStatus, VanityStatus.unopened);
    });

    test('VanityItemModel toMap and fromMap preserves sealedExpiryDate', () {
      final sealed = DateTime(2027, 8, 20);
      final item = VanityItemModel(
        vanityItemId: 'sealed_ser_1',
        productId: 'prod_10',
        userId: 'user_1',
        sealedExpiryDate: sealed,
        status: 'unopened',
      );

      final map = item.toMap();
      expect(map['sealed_expiry_date'], isNotNull);

      final restored = VanityItemModel.fromMap(map);
      expect(restored.sealedExpiryDate?.year, 2027);
      expect(restored.sealedExpiryDate?.month, 8);
      expect(restored.sealedExpiryDate?.day, 20);
    });

    test('effectiveExpiryDate returns null when both expiry dates are null', () {
      const item = VanityItemModel(
        vanityItemId: 'sealed_null_1',
        productId: 'prod_null',
        userId: 'user_1',
      );
      expect(item.effectiveExpiryDate, isNull);
      expect(item.daysUntilExpiry, isNull);
    });

    test('effectiveExpiryDate returns exact date when PAO and sealed expiry are identical', () {
      final targetDate = now.add(const Duration(days: 120));
      final item = VanityItemModel(
        vanityItemId: 'sealed_identical_1',
        productId: 'prod_identical',
        userId: 'user_1',
        openedDate: now,
        expiryDate: targetDate,
        sealedExpiryDate: targetDate,
        status: 'active',
      );
      expect(item.effectiveExpiryDate, targetDate);
    });

    test('Backward compatibility: legacy record without sealed_expiry_date deserializes safely', () {
      final legacyMap = {
        'vanity_item_id': 'legacy_101',
        'product_id': 'prod_legacy',
        'user_id': 'user_legacy',
        'opened_date': '2026-01-01T00:00:00.000',
        'expiry_date': '2027-01-01T00:00:00.000',
        'status': 'active',
        // Note: 'sealed_expiry_date' is intentionally absent
      };

      final item = VanityItemModel.fromMap(legacyMap);
      expect(item.vanityItemId, 'legacy_101');
      expect(item.sealedExpiryDate, isNull);
      expect(item.expiryDate, DateTime(2027, 1, 1));
      expect(item.effectiveExpiryDate, DateTime(2027, 1, 1));
      expect(item.price, isNull);
      expect(item.notes, isNull);
      expect(item.finishedDate, isNull);
      expect(item.wouldRepurchase, isNull);
    });
  });

  group('NotificationService Resilience', () {
    test('Initializes cleanly without throwing LateInitializationError or PlatformException', () async {
      final service = NotificationService();
      await expectLater(service.initialize(), completes);
    });

    test('scheduleExpiryNotifications completes gracefully even in headless environment', () async {
      final service = NotificationService();
      await service.initialize();
      final now = DateTime.now();
      final item = VanityItemModel(
        vanityItemId: 'notify_test_1',
        productId: 'prod_notify_1',
        userId: 'user_1',
        openedDate: now,
        expiryDate: now.add(const Duration(days: 45)),
        status: 'active',
      );
      await expectLater(
        service.scheduleExpiryNotifications(item),
        completes,
      );
    });

    test('scheduleExpiryNotifications handles unopened items with sealed expiry', () async {
      final service = NotificationService();
      await service.initialize();
      final now = DateTime.now();
      final item = VanityItemModel(
        vanityItemId: 'notify_unopened_1',
        productId: 'prod_unopened_1',
        userId: 'user_1',
        sealedExpiryDate: now.add(const Duration(days: 60)),
        status: 'unopened',
      );
      await expectLater(
        service.scheduleExpiryNotifications(item),
        completes,
      );
    });

    test('scheduleExpiryNotifications safely skips finished items', () async {
      final service = NotificationService();
      await service.initialize();
      final now = DateTime.now();
      final item = VanityItemModel(
        vanityItemId: 'notify_finished_1',
        productId: 'prod_fin_1',
        userId: 'user_1',
        openedDate: now.subtract(const Duration(days: 100)),
        expiryDate: now.add(const Duration(days: 200)),
        finishedDate: now,
        status: 'finished',
      );
      await expectLater(
        service.scheduleExpiryNotifications(item),
        completes,
      );
    });

    test('cancelItemNotifications executes without error', () async {
      final service = NotificationService();
      await service.initialize();
      await expectLater(
        service.cancelItemNotifications('notify_test_1'),
        completes,
      );
    });
  });
}
