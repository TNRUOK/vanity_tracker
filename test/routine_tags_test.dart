import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/guide/pao_guide_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const testProduct = ProductModel(
    productId: 'prod_routine_1',
    barcode: '11223344',
    name: 'Hydrating Essence Toner',
    brand: 'Pyunkang Yul',
    categoryId: 'toner',
    paoMonths: 12,
  );

  group('Routine Tags Model Serialization & Compatibility Tests', () {
    test('Serializes and deserializes routineTags properly', () {
      final item = VanityItemModel(
        vanityItemId: 'r_item_1',
        userId: 'u_1',
        productId: 'prod_routine_1',
        product: testProduct,
        routineTags: const ['AM', 'PM'],
      );

      final map = item.toMap();
      expect(map['routine_tags'], ['AM', 'PM']);

      final restored = VanityItemModel.fromMap(map, item.vanityItemId);
      expect(restored.routineTags, ['AM', 'PM']);
    });

    test('Backward compatibility: defaults to empty list when routine_tags is absent', () {
      final legacyMap = {
        'user_id': 'u_legacy',
        'product_id': 'prod_routine_1',
        'is_opened': true,
        'opened_date': '2025-01-01T00:00:00.000',
        'expiry_date': '2026-01-01T00:00:00.000',
        'price': 19.99,
        // 'routine_tags' intentionally missing as in legacy data
      };

      final legacyItem = VanityItemModel.fromMap(legacyMap, 'legacy_id');
      expect(legacyItem.routineTags, isEmpty);
    });

    test('copyWith updates routineTags independently', () {
      final item = VanityItemModel(
        vanityItemId: 'copy_item',
        userId: 'u_1',
        productId: 'prod_routine_1',
        routineTags: const ['AM'],
      );

      final updated = item.copyWith(routineTags: const ['AM', 'PM', 'Weekly']);
      expect(updated.routineTags, ['AM', 'PM', 'Weekly']);
      expect(item.routineTags, ['AM']); // Immutable original
    });
  });

  group('VanityProvider Routine Filter Tests', () {
    test('Correctly groups active items into amRoutineItems, pmRoutineItems, and weeklyRoutineItems', () async {
      final provider = VanityProvider();
      await provider.loadItems('routine_user');

      // Product 1: AM only
      await provider.addItem(
        product: testProduct.copyWith(productId: 'am_prod', name: 'AM Cleanser'),
        userId: 'routine_user',
        routineTags: const ['AM'],
      );

      // Product 2: PM only
      await provider.addItem(
        product: testProduct.copyWith(productId: 'pm_prod', name: 'PM Retinol Serum'),
        userId: 'routine_user',
        routineTags: const ['PM'],
      );

      // Product 3: Both AM & PM
      await provider.addItem(
        product: testProduct.copyWith(productId: 'ampm_prod', name: 'Barrier Cream'),
        userId: 'routine_user',
        routineTags: const ['AM', 'PM'],
      );

      // Product 4: Weekly treatment
      await provider.addItem(
        product: testProduct.copyWith(productId: 'weekly_prod', name: 'AHA Exfoliating Mask'),
        userId: 'routine_user',
        routineTags: const ['Weekly'],
      );

      // Verify AM list contains Cleanser and Barrier Cream
      expect(provider.amRoutineItems.any((i) => i.product?.name == 'AM Cleanser'), true);
      expect(provider.amRoutineItems.any((i) => i.product?.name == 'Barrier Cream'), true);
      expect(provider.amRoutineItems.any((i) => i.product?.name == 'PM Retinol Serum'), false);

      // Verify PM list contains Retinol and Barrier Cream
      expect(provider.pmRoutineItems.any((i) => i.product?.name == 'PM Retinol Serum'), true);
      expect(provider.pmRoutineItems.any((i) => i.product?.name == 'Barrier Cream'), true);
      expect(provider.pmRoutineItems.any((i) => i.product?.name == 'AM Cleanser'), false);

      // Verify Weekly list contains Exfoliating Mask
      expect(provider.weeklyRoutineItems.any((i) => i.product?.name == 'AHA Exfoliating Mask'), true);
      expect(provider.weeklyRoutineItems.any((i) => i.product?.name == 'AM Cleanser'), false);
    });

    test('Finished or archived items are excluded from routines', () async {
      final provider = VanityProvider();
      await provider.loadItems('routine_empty_user');

      await provider.addItem(
        product: testProduct.copyWith(productId: 'fin_prod', name: 'Finished Eye Cream'),
        userId: 'routine_empty_user',
        routineTags: const ['AM', 'PM'],
      );

      final addedItem = provider.amRoutineItems.firstWhere((i) => i.product?.name == 'Finished Eye Cream');

      // Mark finished
      await provider.markAsFinished(addedItem.vanityItemId, wouldRepurchase: false);

      // Should now be excluded from AM and PM routine lists
      expect(provider.amRoutineItems.any((i) => i.product?.name == 'Finished Eye Cream'), false);
      expect(provider.pmRoutineItems.any((i) => i.product?.name == 'Finished Eye Cream'), false);
    });
  });

  group('PaoGuideScreen Widget Tests', () {
    testWidgets('Renders PAO symbols, timeline guide, and disclaimers', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: PaoGuideScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // App bar & title
      expect(find.text('Cosmetic PAO Guide'), findsOneWidget);

      // PAO badges
      expect(find.text('3M'), findsOneWidget);
      expect(find.text('6M'), findsOneWidget);
      expect(find.text('12M'), findsOneWidget);
      expect(find.text('24M+'), findsOneWidget);

      // Informative sections
      expect(find.text('Why Real Shelf Life Varies'), findsOneWidget);
      expect(find.text('Sealed Batch vs PAO Expiry'), findsOneWidget);
      expect(find.textContaining('Important Disclaimer'), findsOneWidget);
    });
  });
}
