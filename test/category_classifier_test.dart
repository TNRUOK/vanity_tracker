import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/models/category_model.dart';
import 'package:vanity_tracker/services/category_classifier.dart';
import 'package:vanity_tracker/services/product_lookup_service.dart';

String? cat(String text) => CategoryClassifier.fromName(text)?.categoryId;

void main() {
  group('Name classification (receipt lines and typed names)', () {
    test('clear product types are suggested', () {
      expect(cat('Fresh Soy Face Cleanser 150ml'), 'cleanser');
      expect(cat('SPF 50 Facial Sunscreen'), 'sunscreen');
      expect(cat('Hydrating Serum'), 'serum');
      expect(cat('Moisturising Cream'), 'moisturizer');
      expect(cat('Facial Toner'), 'toner');
      expect(cat('Lash Princess Mascara'), 'mascara');
      expect(cat('Fit Me Foundation 120'), 'foundation');
      expect(cat('Radiant Creamy Concealer'), 'concealer');
      expect(cat('Shampoo Repair 400ml'), 'hair_care');
      expect(cat('Cocoa Butter Body Lotion'), 'body_care');
      expect(cat('Eau de Parfum 50ml'), 'fragrance');
      expect(cat('BHA Liquid Exfoliant'), 'exfoliant');
      expect(cat('Retinol Eye Cream'), 'eye_cream');
    });

    test('lipstick with shade information, and other lip products', () {
      expect(cat('MAC Lipstick Ruby Woo'), 'lipstick');
      expect(cat('Matte Lip Colour 05 Nude'), 'lipstick');
      expect(cat('Lip Gloss Clear'), 'lip_gloss');
      expect(cat('Lip Balm SPF 15'), 'lip_care');
    });

    test('specific phrases win over the generic words they contain', () {
      expect(cat('Sun Cream SPF30'), 'sunscreen'); // not moisturizer ("cream")
      expect(cat('Hand Cream'), 'body_care');
      expect(cat('BB Cream Light'), 'foundation');
      expect(cat('Foaming Cream Cleanser'), 'cleanser');
      expect(cat('Foundation SPF 15'), 'foundation'); // SPF alone does not decide
      expect(cat('Hydrating Toner with AHA'), 'toner');
      expect(cat('Face & Body Sunscreen'), 'sunscreen');
      expect(cat('High Gloss Nail Polish'), 'nail_care');
    });

    test('whole words only: no substring matches', () {
      expect(cat('Splash Water 200ml'), isNull); // "lash" inside "splash"
      expect(cat('Glossier You'), isNull); // "gloss" inside a brand name
      expect(cat('Bodyguard Wipes'), isNull); // "body" inside a word
    });

    test('brand and store names do not decide the category', () {
      expect(cat('The Body Shop Vitamin E Serum'), 'serum');
      expect(cat('Bath & Body Works'), isNull);
    });

    test('generic words only give a weak (please check) suggestion', () {
      final s = CategoryClassifier.fromName('Cream 50ml')!;
      expect(s.categoryId, 'moisturizer');
      expect(s.weak, isTrue);
      expect(s.source, CategorySource.nameClassifier);
      expect(CategoryClassifier.fromName('SPF 50')!.weak, isTrue);
      expect(CategoryClassifier.fromName('Essence Lash Princess')!.weak, isTrue); // brand "Essence"
      expect(CategoryClassifier.fromName('Face Cleanser')!.weak, isFalse);
    });

    test('ambiguous or truncated OCR text stays uncategorized', () {
      expect(cat('FRSH SOY CLNS 150'), isNull);
      expect(cat('ITEM 4471'), isNull);
      expect(cat('Daily Defense'), isNull);
      expect(cat(''), isNull);
    });

    test('receipt noise lines are never categorized', () {
      for (final noise in ['CARDHOLDER', 'SUBTOTAL', 'TAX', 'TOTAL', 'VISA ****1234', '150ml', 'CHANGE DUE']) {
        expect(cat(noise), isNull, reason: noise);
      }
    });

    test('an unrecognized product is not defaulted to Serum', () {
      expect(cat('Midnight Recovery Concentrate'), isNull);
    });

    test('every suggested category exists in the canonical list', () {
      for (final text in ['cleanser', 'toner', 'serum', 'face mask', 'peel', 'spot treatment', 'lip oil', 'blush',
          'primer', 'eyeshadow palette', 'eyeliner', 'nail polish', 'body wash', 'perfume', 'mascara']) {
        final id = cat(text);
        expect(id, isNotNull, reason: text);
        expect(CategoryModel.byId(id), isNotNull, reason: '$text -> $id');
      }
    });
  });

  group('Product-database categories (Open Beauty Facts style)', () {
    test('the most specific tag decides and is labelled as database data', () {
      final s = CategoryClassifier.fromDatabaseCategories(['en:skin-care', 'en:face-care', 'en:face-cleansers'])!;
      expect(s.categoryId, 'cleanser');
      expect(s.source, CategorySource.productDatabase);
      expect(s.matchedTerm, 'en:face-cleansers');
    });

    test('generic database categories are not trusted', () {
      expect(CategoryClassifier.fromDatabaseCategories(['en:creams']), isNull);
      expect(CategoryClassifier.fromDatabaseCategories(['en:cosmetics', 'en:beauty']), isNull);
    });

    test('lookup: record categories first, then the name, else none', () {
      expect(
        ProductLookupService.detectCategory({
          'product_name': 'Hydrating Serum', // the name alone would say serum
          'categories_hierarchy': ['en:sun-protection', 'en:sunscreens'],
        })!.categoryId,
        'sunscreen',
      );
      final byName = ProductLookupService.detectCategory({'product_name': 'Gentle Foaming Cleanser'})!;
      expect(byName.categoryId, 'cleanser');
      expect(byName.source, CategorySource.nameClassifier);
      expect(ProductLookupService.detectCategory({'product_name': 'Midnight Recovery'}), isNull);
      expect(ProductLookupService.detectCategory({}), isNull);
    });
  });

  group('Category list', () {
    test('original ids are kept, new ones added, other stays last', () {
      for (final id in ['serum', 'sunscreen', 'mascara', 'foundation', 'lipstick', 'moisturizer', 'cleanser', 'toner',
          'eye_cream', 'fragrance', 'other']) {
        expect(CategoryModel.byId(id), isNotNull, reason: id);
      }
      expect(CategoryModel.defaultCategories.last.categoryId, 'other');
      final ids = CategoryModel.defaultCategories.map((c) => c.categoryId).toList();
      expect(ids.toSet().length, ids.length, reason: 'no duplicate ids');
    });

    test('stored categories are merged with the built-in list without duplicates', () {
      final merged = CategoryModel.mergeWithDefaults([
        const CategoryModel(categoryId: 'serum', categoryName: 'Serum (custom)', defaultPaoMonths: 9),
        const CategoryModel(categoryId: 'other', categoryName: 'Other', defaultPaoMonths: 12),
        const CategoryModel(categoryId: 'tools', categoryName: 'Tools', defaultPaoMonths: 60),
      ]);
      expect(merged.where((c) => c.categoryId == 'serum').single.categoryName, 'Serum (custom)');
      expect(merged.any((c) => c.categoryId == 'cleanser'), isTrue);
      expect(merged.any((c) => c.categoryId == 'tools'), isTrue);
      expect(merged.last.categoryId, 'other');
      expect(merged.map((c) => c.categoryId).toSet().length, merged.length);
    });
  });
}
