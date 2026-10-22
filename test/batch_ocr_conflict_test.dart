import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/services/batch_ocr_service.dart';
import 'package:vanity_tracker/services/ingredient_conflict_service.dart';

void main() {
  group('BatchOcrService - Packaging Text & Date Parsing', () {
    test('extracts batch code and expiry date from packaging text', () {
      const text = '''
      THE ORDINARY
      HYALURONIC ACID 2% + B5
      BATCH: 2K01
      EXP: 12/2026
      MADE IN CANADA
      ''';

      final parsed = BatchOcrService.parsePackagingText(text);

      expect(parsed.suggestedBatchCode, isNotNull);
      expect(parsed.suggestedBatchCode, equals('2K01'));
      expect(parsed.suggestedExpiryDate, isNotNull);
      expect(parsed.suggestedExpiryDate!.date.year, equals(2026));
      expect(parsed.suggestedExpiryDate!.date.month, equals(12));
    });

    test('extracts manufacturing date when present', () {
      const text = '''
      BEAUTY OF JOSEON
      MFG: 2024-03-15
      LOT: BOJ881
      ''';

      final parsed = BatchOcrService.parsePackagingText(text);

      expect(parsed.suggestedBatchCode, equals('BOJ881'));
      expect(parsed.suggestedMfgDate, isNotNull);
      expect(parsed.suggestedMfgDate!.date.year, equals(2024));
      expect(parsed.suggestedMfgDate!.date.month, equals(3));
      expect(parsed.suggestedMfgDate!.date.day, equals(15));
    });

    test('flags ambiguous dates (e.g. 03/04/2027) with alternate date', () {
      const text = '''
      SUNSCREEN SPF 50
      EXP: 03/04/2027
      BATCH: S902
      ''';

      final parsed = BatchOcrService.parsePackagingText(text);

      expect(parsed.suggestedExpiryDate, isNotNull);
      expect(parsed.suggestedExpiryDate!.isAmbiguous, isTrue);
      expect(parsed.suggestedExpiryDate!.alternateDate, isNotNull);

      final date1 = parsed.suggestedExpiryDate!.date;
      final date2 = parsed.suggestedExpiryDate!.alternateDate!;
      final months = [date1.month, date2.month];
      expect(months, contains(3));
      expect(months, contains(4));
    });

    test('unambiguous dates (e.g. 25/08/2026) are not marked ambiguous', () {
      const text = '''
      MOISTURIZER
      EXP: 25/08/2026
      LOT: M9901
      ''';

      final parsed = BatchOcrService.parsePackagingText(text);

      expect(parsed.suggestedExpiryDate, isNotNull);
      expect(parsed.suggestedExpiryDate!.isAmbiguous, isFalse);
      expect(parsed.suggestedExpiryDate!.date.day, equals(25));
      expect(parsed.suggestedExpiryDate!.date.month, equals(8));
      expect(parsed.suggestedExpiryDate!.date.year, equals(2026));
    });

    test('Estée Lauder Group 3-char batch code decoder decodes correctly', () {
      // Estée Lauder batch A31 -> March 2021
      final decodedA31 = BatchOcrService.decodeEsteeLauderBatch('A31');
      expect(decodedA31, isNotNull);
      expect(decodedA31!.month, equals(3));
      expect(decodedA31.year, equals(2021));

      // Clinique batch B92 -> September 2022
      final decodedB92 = BatchOcrService.decodeEsteeLauderBatch('B92');
      expect(decodedB92, isNotNull);
      expect(decodedB92!.month, equals(9));
      expect(decodedB92.year, equals(2022));

      // Brand guard in parsePackagingText: only offered for Estée Lauder Companies brands,
      // and only as a suggestion (community-reported rule, year digit fits two decades):
      // it is never filled in as the manufacturing date.
      const text = 'BATCH: A31';
      final parsedGeneric = BatchOcrService.parsePackagingText(text, brand: 'CeraVe');
      expect(parsedGeneric.suggestedMfgDate, isNull);
      expect(parsedGeneric.brandDecode, isNull);

      final parsedEstee = BatchOcrService.parsePackagingText(text, brand: 'Estee Lauder');
      expect(parsedEstee.suggestedMfgDate, isNull, reason: 'not applied automatically');
      expect(parsedEstee.brandDecode, isNotNull);
      expect(parsedEstee.brandDecode!.month.month, equals(3));
      expect(parsedEstee.brandDecode!.decadeEarlier.year, parsedEstee.brandDecode!.month.year - 10);
      expect(parsedEstee.brandDecode!.note, contains('not confirmed by the manufacturer'));

      // "MAC" must be the brand itself, not a word containing it.
      expect(BatchOcrService.parsePackagingText(text, brand: 'Macadamia Natural Oil').brandDecode, isNull);
      expect(BatchOcrService.parsePackagingText(text, brand: 'MAC').brandDecode, isNotNull);
    });
  });

  group('IngredientConflictService - Safety Rules & Citations', () {
    test('tokenizes and normalizes ingredient lists correctly', () {
      const inci = 'Aqua/Water/Eau, Glycerin, Salicylic Acid (2.0%), Retinol (0.5%), Phenoxyethanol.';
      final tokens = IngredientConflictService.tokenizeIngredients(inci);

      expect(tokens, contains('salicylic acid (2.0%)'));
      expect(tokens.any((t) => t.contains('salicylic acid')), isTrue);
      expect(tokens.any((t) => t.contains('retinol')), isTrue);
    });

    test('detects Retinoid + AHA/BHA conflict between separate products in routine', () {
      final productA = VanityItemModel(
        vanityItemId: 'item_ret',
        productId: 'prod_ret',
        userId: 'user1',
        routineTags: const ['PM'],
        product: const ProductModel(
          productId: 'prod_ret',
          barcode: '001',
          name: 'Retinol 0.5% in Squalane',
          brand: 'The Ordinary',
          categoryId: 'serum',
          paoMonths: 6,
          ingredients: 'Squalane, Caprylic/Capric Triglyceride, Retinol, Solanum Lycopersicum Extract',
        ),
      );

      final productB = VanityItemModel(
        vanityItemId: 'item_aha',
        productId: 'prod_aha',
        userId: 'user1',
        routineTags: const ['PM'],
        product: const ProductModel(
          productId: 'prod_aha',
          barcode: '002',
          name: 'Glycolic Acid 7% Toning Solution',
          brand: 'The Ordinary',
          categoryId: 'toner',
          paoMonths: 12,
          ingredients: 'Aqua, Glycolic Acid, Rosa Damascena Flower Water, Aloe Barbadensis Leaf Water',
        ),
      );

      final analysis = IngredientConflictService.analyzeRoutine(
        routineType: 'PM',
        items: [productA, productB],
      );

      expect(analysis.hasConflicts, isTrue);
      final retinoidAha = analysis.conflicts.firstWhere((c) => c.rule.id == 'retinoid_direct_acid');
      expect(retinoidAha.rule.severity, equals(ConflictSeverity.warning));
      expect(retinoidAha.rule.referenceCitation, isNotEmpty);
      expect(retinoidAha.rule.referenceCitation.contains('AAD'), isTrue);
    });

    test('detects Retinoid + Benzoyl Peroxide conflict between separate products', () {
      final productA = VanityItemModel(
        vanityItemId: 'item_ret',
        productId: 'prod_ret',
        userId: 'user1',
        routineTags: const ['PM'],
        product: const ProductModel(
          productId: 'prod_ret',
          barcode: '003',
          name: 'Tretinoin 0.05% Cream',
          brand: 'Retin-A',
          categoryId: 'treatment',
          paoMonths: 12,
          ingredients: 'Stearic acid, Isopropyl myristate, Polyoxyl 40 stearate, Tretinoin',
        ),
      );

      final productB = VanityItemModel(
        vanityItemId: 'item_bp',
        productId: 'prod_bp',
        userId: 'user1',
        routineTags: const ['PM'],
        product: const ProductModel(
          productId: 'prod_bp',
          barcode: '004',
          name: 'Acne Foaming Cleanser 10% Benzoyl Peroxide',
          brand: 'PanOxyl',
          categoryId: 'cleanser',
          paoMonths: 12,
          ingredients: 'Benzoyl Peroxide, Carbomer, Glycerin, Sodium Cocoyl Isethionate',
        ),
      );

      final analysis = IngredientConflictService.analyzeRoutine(
        routineType: 'PM',
        items: [productA, productB],
      );

      expect(analysis.conflicts.any((c) => c.rule.id == 'retinoid_benzoyl_peroxide'), isTrue);
    });

    // The former "vit_c_direct_acid" rule was removed in the 2026-10-18 rule review: its
    // cited source could not be verified to support it. This test now guards against the
    // unsupported warning coming back.
    test('L-Ascorbic Acid + BHA is no longer flagged (rule removed: source did not support it)', () {
      final productA = VanityItemModel(
        vanityItemId: 'item_vitc',
        productId: 'prod_vitc',
        userId: 'user1',
        routineTags: const ['AM'],
        product: const ProductModel(
          productId: 'prod_vitc',
          barcode: '005',
          name: 'C E Ferulic',
          brand: 'SkinCeuticals',
          categoryId: 'serum',
          paoMonths: 6,
          ingredients: 'Aqua/Water, Ethoxydiglycol, Ascorbic Acid, Propylene Glycol, Glycerin, Tocopherol, Ferulic Acid',
        ),
      );

      final productB = VanityItemModel(
        vanityItemId: 'item_bha',
        productId: 'prod_bha',
        userId: 'user1',
        routineTags: const ['AM'],
        product: const ProductModel(
          productId: 'prod_bha',
          barcode: '006',
          name: '2% BHA Liquid Exfoliant',
          brand: "Paula's Choice",
          categoryId: 'toner',
          paoMonths: 12,
          ingredients: 'Water, Methylpropanediol, Butylene Glycol, Salicylic Acid, Polysorbate 20, Camellia Oleifera Leaf Extract',
        ),
      );

      final analysis = IngredientConflictService.analyzeRoutine(
        routineType: 'AM',
        items: [productA, productB],
      );

      expect(analysis.conflicts.any((c) => c.rule.id == 'vit_c_direct_acid'), isFalse);
      expect(IngredientConflictService.rules.any((r) => r.id == 'vit_c_direct_acid'), isFalse);
      expect(analysis.conflicts, isEmpty);
      expect(analysis.isClean, isTrue);
    });

    test('reports clean routine when actives are compatible and gentle', () {
      final productA = VanityItemModel(
        vanityItemId: 'item_ha',
        productId: 'prod_ha',
        userId: 'user1',
        routineTags: const ['AM'],
        product: const ProductModel(
          productId: 'prod_ha',
          barcode: '007',
          name: 'Hyaluronic Acid 2% + B5',
          brand: 'The Ordinary',
          categoryId: 'serum',
          paoMonths: 12,
          ingredients: 'Aqua, Sodium Hyaluronate, Panthenol, Ahnfeltia Concinna Extract, Glycerin',
        ),
      );

      final productB = VanityItemModel(
        vanityItemId: 'item_niacinamide',
        productId: 'prod_niacinamide',
        userId: 'user1',
        routineTags: const ['AM'],
        product: const ProductModel(
          productId: 'prod_niacinamide',
          barcode: '008',
          name: 'Niacinamide 10% + Zinc 1%',
          brand: 'The Ordinary',
          categoryId: 'serum',
          paoMonths: 12,
          ingredients: 'Aqua, Niacinamide, Zinc PCA, Dimethyl Isosorbide, Tamarindus Indica Seed Gum',
        ),
      );

      final productC = VanityItemModel(
        vanityItemId: 'item_cream',
        productId: 'prod_cream',
        userId: 'user1',
        routineTags: const ['AM'],
        product: const ProductModel(
          productId: 'prod_cream',
          barcode: '009',
          name: 'Moisturizing Cream',
          brand: 'CeraVe',
          categoryId: 'moisturizer',
          paoMonths: 12,
          ingredients: 'Aqua, Glycerin, Cetearyl Alcohol, Caprylic/Capric Triglyceride, Ceramide NP, Ceramide AP, Ceramide EOP',
        ),
      );

      final analysis = IngredientConflictService.analyzeRoutine(
        routineType: 'AM',
        items: [productA, productB, productC],
      );

      expect(analysis.hasConflicts, isFalse);
      expect(analysis.conflicts, isEmpty);
      expect(analysis.missingDataItems, isEmpty);
      expect(analysis.isClean, isTrue);
    });

    test('flags missing ingredient data distinctly without reporting false conflicts', () {
      final productWithInci = VanityItemModel(
        vanityItemId: 'item_1',
        productId: 'prod_1',
        userId: 'user1',
        product: const ProductModel(
          productId: 'prod_1',
          barcode: '010',
          name: 'Retinol Serum',
          brand: 'Brand A',
          categoryId: 'serum',
          paoMonths: 6,
          ingredients: 'Retinol, Glycerin, Water',
        ),
      );

      final productMissingInci = VanityItemModel(
        vanityItemId: 'item_2',
        productId: 'prod_2',
        userId: 'user1',
        product: const ProductModel(
          productId: 'prod_2',
          barcode: '011',
          name: 'Mystery Night Cream',
          brand: 'Brand B',
          categoryId: 'moisturizer',
          paoMonths: 12,
          ingredients: null,
        ),
      );

      final analysis = IngredientConflictService.analyzeRoutine(
        routineType: 'PM',
        items: [productWithInci, productMissingInci],
      );

      expect(analysis.hasConflicts, isFalse);
      expect(analysis.missingDataItems.length, equals(1));
      expect(analysis.missingDataItems.first.vanityItemId, equals('item_2'));
    });
  });

  group('VanityItemModel - Batch Code & Manufacturing Date Serialization', () {
    test('serializes and deserializes batchCode, manufacturingDate and notes accurately', () {
      final mfgDate = DateTime(2024, 6, 15);
      final original = VanityItemModel(
        vanityItemId: 'item_ocr_1',
        productId: 'prod_ocr_1',
        userId: 'user_ocr',
        notes: 'Patch tested on wrist',
        batchCode: 'LOT-9821A',
        manufacturingDate: mfgDate,
        sealedExpiryDate: DateTime(2027, 6, 15),
      );

      final map = original.toMap();
      expect(map['batch_code'], equals('LOT-9821A'));
      expect(map['manufacturing_date'], equals(mfgDate.toIso8601String()));
      expect(map['notes'], equals('Patch tested on wrist'));

      final restored = VanityItemModel.fromMap(map);
      expect(restored.batchCode, equals('LOT-9821A'));
      expect(restored.manufacturingDate, equals(mfgDate));
      expect(restored.notes, equals('Patch tested on wrist'));
      expect(restored.sealedExpiryDate, equals(DateTime(2027, 6, 15)));
    });

    test('copyWith allows modifying and clearing batchCode and manufacturingDate', () {
      final item = VanityItemModel(
        vanityItemId: 'item_1',
        productId: 'prod_1',
        userId: 'user_1',
        batchCode: 'OLD_BATCH',
        manufacturingDate: DateTime(2023, 1, 1),
      );

      // Update
      final updated = item.copyWith(batchCode: 'NEW_BATCH');
      expect(updated.batchCode, equals('NEW_BATCH'));
      expect(updated.manufacturingDate, equals(DateTime(2023, 1, 1)));

      // Clear
      final cleared = updated.copyWith(clearBatchCode: true, clearManufacturingDate: true);
      expect(cleared.batchCode, isNull);
      expect(cleared.manufacturingDate, isNull);
    });

    test('backward compatibility: legacy maps without batch fields deserialize to null', () {
      final legacyMap = {
        'vanity_item_id': 'legacy_1',
        'product_id': 'prod_legacy',
        'user_id': 'user_legacy',
        'opened_date': '2024-01-01T00:00:00.000',
        'status': 'active',
      };

      final item = VanityItemModel.fromMap(legacyMap);
      expect(item.vanityItemId, equals('legacy_1'));
      expect(item.batchCode, isNull);
      expect(item.manufacturingDate, isNull);
    });
  });
}
