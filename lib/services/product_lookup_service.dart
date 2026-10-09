import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/category_model.dart';
import '../models/product_model.dart';

class ProductLookupResult {
  final bool found;
  final ProductModel? product;
  final String? rawResponse;
  final String? errorMessage;
  final String? source;

  ProductLookupResult({
    required this.found,
    this.product,
    this.rawResponse,
    this.errorMessage,
    this.source,
  });
}

class ProductLookupService {
  static const String _beautyFactsV2Url = 'https://world.openbeautyfacts.org/api/v2/product';
  static const String _beautyFactsV0Url = 'https://world.openbeautyfacts.org/api/v0/product';
  static const String _foodFactsV2Url = 'https://world.openfoodfacts.org/api/v2/product';
  static const String _productsFactsV2Url = 'https://world.openproductsfacts.org/api/v2/product';
  static const String _upcItemDbUrl = 'https://api.upcitemdb.com/prod/trial/lookup';

  /// Lookup a product by barcode across multiple databases + offline beauty intelligence catalog
  static Future<ProductLookupResult> lookupBarcode(String barcode) async {
    final cleanBarcode = barcode.trim().replaceAll(RegExp(r'\s+'), '');
    if (cleanBarcode.isEmpty) {
      return ProductLookupResult(found: false, errorMessage: 'Empty barcode provided');
    }

    // 0. Check our local curated high-accuracy catalog first for instant response
    final offlineMatch = _lookupLocalCatalog(cleanBarcode);
    if (offlineMatch != null) {
      return ProductLookupResult(
        found: true,
        product: offlineMatch,
        source: 'Curated Beauty Intelligence Database',
      );
    }

    // 1. Try Open Beauty Facts v2
    try {
      final v2Url = Uri.parse('$_beautyFactsV2Url/$cleanBarcode.json');
      final res = await http.get(v2Url, headers: {
        'User-Agent': 'VanityTracker - FlutterApp - Version 1.0 (contact: info@vanitytracker.app)',
      }).timeout(const Duration(seconds: 7));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 1 && data['product'] != null) {
          final product = _parseApiProduct(cleanBarcode, data['product'], 'Open Beauty Facts');
          return ProductLookupResult(found: true, product: product, source: 'Open Beauty Facts', rawResponse: res.body);
        }
      }
    } catch (e) {
      debugPrint('Open Beauty Facts v2 error: $e');
    }

    // 2. Try Open Beauty Facts v0
    try {
      final v0Url = Uri.parse('$_beautyFactsV0Url/$cleanBarcode.json');
      final res = await http.get(v0Url, headers: {
        'User-Agent': 'VanityTracker - FlutterApp - Version 1.0',
      }).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 1 && data['product'] != null) {
          final product = _parseApiProduct(cleanBarcode, data['product'], 'Open Beauty Facts v0');
          return ProductLookupResult(found: true, product: product, source: 'Open Beauty Facts', rawResponse: res.body);
        }
      }
    } catch (e) {
      debugPrint('Open Beauty Facts v0 error: $e');
    }

    // 3. Try Open Food Facts (for cosmetic & personal care crossover products)
    try {
      final offUrl = Uri.parse('$_foodFactsV2Url/$cleanBarcode.json');
      final res = await http.get(offUrl, headers: {
        'User-Agent': 'VanityTracker - FlutterApp - Version 1.0',
      }).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 1 && data['product'] != null) {
          final product = _parseApiProduct(cleanBarcode, data['product'], 'Open Food Facts');
          return ProductLookupResult(found: true, product: product, source: 'Open Food Facts', rawResponse: res.body);
        }
      }
    } catch (e) {
      debugPrint('Open Food Facts lookup error: $e');
    }

    // 4. Try Open Products Facts
    try {
      final opfUrl = Uri.parse('$_productsFactsV2Url/$cleanBarcode.json');
      final res = await http.get(opfUrl, headers: {
        'User-Agent': 'VanityTracker - FlutterApp - Version 1.0',
      }).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 1 && data['product'] != null) {
          final product = _parseApiProduct(cleanBarcode, data['product'], 'Open Products Facts');
          return ProductLookupResult(found: true, product: product, source: 'Open Products Facts', rawResponse: res.body);
        }
      }
    } catch (e) {
      debugPrint('Open Products Facts lookup error: $e');
    }

    // 5. Try UPCitemdb Public Lookup
    try {
      final upcUrl = Uri.parse('$_upcItemDbUrl?upc=$cleanBarcode');
      final res = await http.get(upcUrl).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['items'] != null && (data['items'] as List).isNotEmpty) {
          final item = data['items'][0];
          final product = _parseUpcDbProduct(cleanBarcode, item);
          return ProductLookupResult(found: true, product: product, source: 'UPC Database', rawResponse: res.body);
        }
      }
    } catch (e) {
      debugPrint('UPCitemdb lookup error: $e');
    }

    // 6. Barcode Country & Brand Prefix Inference (Heuristic fallback)
    final inferred = _inferFromBarcodePrefix(cleanBarcode);
    if (inferred != null) {
      return ProductLookupResult(
        found: true,
        product: inferred,
        source: 'Smart Barcode Prefix Heuristic',
      );
    }

    return ProductLookupResult(
      found: false,
      errorMessage: 'Product barcode not found online. You can enter details manually.',
    );
  }

  /// Parses Open Beauty/Food Facts comprehensive JSON
  static ProductModel _parseApiProduct(String barcode, Map<String, dynamic> p, String sourceDb) {
    // 1. Name
    final name = (p['product_name'] as String?)?.trim() ??
        (p['product_name_en'] as String?)?.trim() ??
        (p['generic_name'] as String?)?.trim() ??
        (p['product_name_fr'] as String?)?.trim() ??
        'Cosmetic Product';

    // 2. Brand
    final brand = (p['brands'] as String?)?.trim() ??
        (p['brand_owner'] as String?)?.trim() ??
        (p['brands_tags'] != null && (p['brands_tags'] as List).isNotEmpty
            ? (p['brands_tags'] as List).first.toString().replaceAll('en:', '').replaceAll('-', ' ')
            : 'Unknown Brand');

    // 3. Images
    final imageUrl = p['image_front_url'] as String? ??
        p['image_url'] as String? ??
        p['image_front_small_url'] as String? ??
        (p['selected_images']?['front']?['display']?['en'] as String?);

    final thumbnailUrl = p['image_front_small_url'] as String? ??
        p['image_small_url'] as String? ??
        (p['selected_images']?['front']?['thumb']?['en'] as String?);

    // Collect image gallery from selected_images
    final imageGallery = <String>[];
    final selectedImages = p['selected_images'] as Map<String, dynamic>?;
    if (selectedImages != null) {
      for (final side in ['front', 'ingredients', 'nutrition', 'packaging']) {
        final sideData = selectedImages[side] as Map<String, dynamic>?;
        final displayData = sideData?['display'] as Map<String, dynamic>?;
        if (displayData != null) {
          final url = displayData['en'] as String? ?? displayData.values.firstOrNull?.toString();
          if (url != null && url.isNotEmpty && !imageGallery.contains(url)) {
            imageGallery.add(url);
          }
        }
      }
    }

    // 4. Volume / Quantity
    final volume = (p['quantity'] as String?)?.trim() ??
        (p['product_quantity'] != null ? '${p['product_quantity']} ${p['product_quantity_unit'] ?? ''}'.trim() : null);

    // 5. Ingredients & INCI
    final ingredients = (p['ingredients_text'] as String?)?.trim() ??
        (p['ingredients_text_en'] as String?)?.trim() ??
        (p['ingredients_text_with_allergens'] as String?)?.trim();
    final inci = (p['ingredients_text_en'] as String?)?.trim() ??
        (p['ingredients'] as List<dynamic>?)?.map((i) => i['text']?.toString() ?? '').where((s) => s.isNotEmpty).join(', ');

    // 6. Category & PAO
    final detectedCategory = _detectCategory(p);
    final paoMonths = _extractPao(p, defaultPao: detectedCategory.defaultPaoMonths);

    // 7. Country of Origin
    final country = _extractCountry(p, barcode);

    // 8. Packaging type
    final packaging = _extractPackaging(p);

    // 9. Skin Claims & Key Actives
    final claims = _extractClaims(p, name, ingredients);
    final keyActives = _extractKeyActives(ingredients, name);

    // 10. Allergens
    final allergens = _extractAllergens(p, ingredients);

    // 11. Preservatives detected from ingredients
    final preservatives = _extractPreservatives(ingredients);

    // 12. Fragrance ingredients
    final fragranceIngredients = _extractFragranceIngredients(ingredients);

    // 13. Warnings
    final warnings = _extractWarnings(p);

    // 14. Certifications
    final certifications = _extractCertifications(p);

    // 15. Skin type
    final skinType = _extractSkinType(p, name, ingredients);

    // 16. Application area
    final applicationArea = _extractApplicationArea(p, name, detectedCategory.categoryId);

    // 17. Texture
    final texture = _extractTexture(p, name, detectedCategory.categoryId);

    // 18. Scent / Fragrance profile
    final scent = _extractScent(p, name, ingredients);

    // 19. pH level
    final pH = _extractPH(p);

    // 20. Product code / SKU
    final productCode = p['code'] as String? ?? p['_id'] as String?;

    // 21. Product page URL
    final barcodeScanUrl = p['url'] as String? ??
        'https://world.openbeautyfacts.org/product/$barcode';

    return ProductModel(
      productId: 'prod_${DateTime.now().millisecondsSinceEpoch}_$barcode',
      barcode: barcode,
      name: name,
      brand: brand,
      categoryId: detectedCategory.categoryId,
      paoMonths: paoMonths,
      imageUrl: imageUrl,
      thumbnailUrl: thumbnailUrl,
      volume: volume,
      ingredients: ingredients,
      countryOfOrigin: country,
      packagingType: packaging,
      skinClaims: claims,
      keyActives: keyActives,
      sourceDatabase: sourceDb,
      createdAt: DateTime.now(),
      allergens: allergens,
      preservatives: preservatives,
      fragranceIngredients: fragranceIngredients,
      warnings: warnings,
      certifications: certifications,
      skinType: skinType,
      applicationArea: applicationArea,
      texture: texture,
      scent: scent,
      pH: pH,
      inci: inci,
      barcodeScanUrl: barcodeScanUrl,
      productCode: productCode,
      imageGallery: imageGallery,
    );
  }


  /// Parses UPC Item DB API
  static ProductModel _parseUpcDbProduct(String barcode, Map<String, dynamic> item) {
    final title = (item['title'] as String?)?.trim() ?? 'Cosmetic Product';
    final brand = (item['brand'] as String?)?.trim() ?? 'Unknown Brand';
    final category = (item['category'] as String?) ?? '';
    final images = item['images'] as List?;
    final imageUrl = images != null && images.isNotEmpty ? images[0] as String? : null;

    final detectedCat = _detectCategoryFromText('$title $category');
    final claims = _extractClaimsFromText(title);
    final keyActives = _extractKeyActives(item['description'] as String?, title);

    return ProductModel(
      productId: 'prod_${DateTime.now().millisecondsSinceEpoch}_$barcode',
      barcode: barcode,
      name: title,
      brand: brand,
      categoryId: detectedCat.categoryId,
      paoMonths: detectedCat.defaultPaoMonths,
      imageUrl: imageUrl,
      volume: item['size'] as String?,
      countryOfOrigin: _getCountryFromBarcodePrefix(barcode),
      skinClaims: claims,
      keyActives: keyActives,
      sourceDatabase: 'UPC Database',
      createdAt: DateTime.now(),
    );
  }

  // ===================== INTELLIGENT METADATA EXTRACTORS =====================

  static CategoryModel _detectCategory(Map<String, dynamic> p) {
    final categoriesStr = [
      p['categories'] ?? '',
      p['categories_tags'] != null ? (p['categories_tags'] as List).join(' ') : '',
      p['categories_hierarchy'] != null ? (p['categories_hierarchy'] as List).join(' ') : '',
      p['product_name'] ?? '',
      p['generic_name'] ?? '',
    ].join(' ').toLowerCase();

    return _detectCategoryFromText(categoriesStr);
  }

  static CategoryModel _detectCategoryFromText(String text) {
    final lower = text.toLowerCase();

    if (lower.contains('serum') || lower.contains('ampoule') || lower.contains('essence') || lower.contains('booster') || lower.contains('concentrate')) {
      return _findCategory('serum');
    }
    if (lower.contains('sunscreen') || lower.contains('spf') || lower.contains('sun protection') || lower.contains('solaire') || lower.contains('sun cream') || lower.contains('sun milk')) {
      return _findCategory('sunscreen');
    }
    if (lower.contains('mascara') || lower.contains('lash') || lower.contains('eyelash')) {
      return _findCategory('mascara');
    }
    if (lower.contains('foundation') || lower.contains('bb cream') || lower.contains('cc cream') || lower.contains('concealer') || lower.contains('cushion') || lower.contains('skin tint')) {
      return _findCategory('foundation');
    }
    if (lower.contains('lipstick') || lower.contains('lip gloss') || lower.contains('lip balm') || lower.contains('lip tint') || lower.contains('lip oil') || lower.contains('lip mask')) {
      return _findCategory('lipstick');
    }
    if (lower.contains('eye cream') || lower.contains('eye contour') || lower.contains('eye gel') || lower.contains('contour des yeux')) {
      return _findCategory('eye_cream');
    }
    if (lower.contains('moisturizer') || lower.contains('moisturiser') || lower.contains('cream') || lower.contains('lotion') || lower.contains('hydratant') || lower.contains('emulsion') || lower.contains('balm')) {
      return _findCategory('moisturizer');
    }
    if (lower.contains('cleanser') || lower.contains('face wash') || lower.contains('micellar') || lower.contains('nettoyant') || lower.contains('cleansing foam') || lower.contains('cleansing oil')) {
      return _findCategory('cleanser');
    }
    if (lower.contains('toner') || lower.contains('astringent') || lower.contains('skin refiner') || lower.contains('facial mist') || lower.contains('clarifying lotion')) {
      return _findCategory('toner');
    }
    if (lower.contains('perfume') || lower.contains('fragrance') || lower.contains('eau de parfum') || lower.contains('eau de toilette') || lower.contains('cologne')) {
      return _findCategory('fragrance');
    }

    return _findCategory('other');
  }

  static CategoryModel _findCategory(String id) {
    return CategoryModel.defaultCategories.firstWhere(
      (c) => c.categoryId == id,
      orElse: () => CategoryModel.defaultCategories.last,
    );
  }

  static int _extractPao(Map<String, dynamic> p, {required int defaultPao}) {
    final rawPao = p['period_after_opening'] as String? ??
        p['pao'] as String? ??
        p['period_after_opening_en'] as String?;

    if (rawPao != null) {
      final match = RegExp(r'(\d+)\s*m', caseSensitive: false).firstMatch(rawPao);
      if (match != null) {
        final parsed = int.tryParse(match.group(1)!);
        if (parsed != null && parsed > 0 && parsed <= 60) {
          return parsed;
        }
      }
    }
    return defaultPao;
  }

  static String? _extractCountry(Map<String, dynamic> p, String barcode) {
    final origin = p['origins'] as String? ??
        p['countries'] as String? ??
        p['manufacturing_places'] as String?;

    if (origin != null && origin.isNotEmpty) {
      return origin.split(',').first.trim().replaceAll('en:', '');
    }
    return _getCountryFromBarcodePrefix(barcode);
  }

  static String? _getCountryFromBarcodePrefix(String barcode) {
    if (barcode.length < 3) return null;
    final prefix2 = barcode.substring(0, 2);
    final prefix3 = barcode.substring(0, 3);
    final n2 = int.tryParse(prefix2) ?? -1;
    final n3 = int.tryParse(prefix3) ?? -1;

    if (n2 >= 0 && n2 <= 13) return 'United States / Canada';
    if (n2 >= 30 && n2 <= 37) return 'France';
    if (n2 >= 40 && n2 <= 44) return 'Germany';
    if (n3 == 450 || n3 == 490 || (n3 >= 450 && n3 <= 459) || (n3 >= 490 && n3 <= 499)) return 'Japan';
    if (n2 == 50) return 'United Kingdom';
    if (n2 >= 80 && n2 <= 83) return 'Italy';
    if (n2 == 84) return 'Spain';
    if (n3 == 880) return 'South Korea';
    if (n3 == 890) return 'India';
    if (n3 >= 690 && n3 <= 699) return 'China';
    if (n2 == 93) return 'Australia';
    if (n2 == 76) return 'Switzerland';
    return null;
  }

  static String? _extractPackaging(Map<String, dynamic> p) {
    final packStr = [
      p['packaging'] ?? '',
      p['packaging_text'] ?? '',
      p['packaging_tags'] != null ? (p['packaging_tags'] as List).join(' ') : '',
    ].join(' ').toLowerCase();

    if (packStr.contains('dropper') || packStr.contains('pipette')) return 'Dropper Pipette';
    if (packStr.contains('pump') || packStr.contains('dispenser')) return 'Pump Bottle';
    if (packStr.contains('tube') || packStr.contains('squeeze')) return 'Squeeze Tube';
    if (packStr.contains('jar') || packStr.contains('pot') || packStr.contains('tub')) return 'Jar / Tub';
    if (packStr.contains('spray') || packStr.contains('mist') || packStr.contains('aerosol')) return 'Spray Mist';
    if (packStr.contains('stick') || packStr.contains('roll-on')) return 'Stick Applicator';
    if (packStr.contains('bottle') || packStr.contains('flacon')) return 'Bottle';
    return null;
  }

  static List<String> _extractClaims(Map<String, dynamic> p, String name, String? ingredients) {
    final claims = <String>{};
    final combined = [
      name,
      p['labels'] ?? '',
      p['labels_tags'] != null ? (p['labels_tags'] as List).join(' ') : '',
      ingredients ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('fragrance-free') || combined.contains('sans parfum') || combined.contains('unscented')) {
      claims.add('Fragrance-Free');
    }
    if (combined.contains('non-comedogenic') || combined.contains('non comedogene')) {
      claims.add('Non-Comedogenic');
    }
    if (combined.contains('paraben-free') || combined.contains('sans paraben')) {
      claims.add('Paraben-Free');
    }
    if (combined.contains('cruelty-free') || combined.contains('vegan') || combined.contains('leaping bunny')) {
      claims.add('Cruelty-Free / Vegan');
    }
    if (combined.contains('spf') || combined.contains('pa++++') || combined.contains('broad spectrum')) {
      claims.add('SPF Protection');
    }
    if (combined.contains('dermatologist tested') || combined.contains('dermatologically tested')) {
      claims.add('Dermatologist Tested');
    }
    if (combined.contains('hypoallergenic') || combined.contains('sensitive skin')) {
      claims.add('For Sensitive Skin');
    }
    if (combined.contains('alcohol-free') || combined.contains('sans alcool')) {
      claims.add('Alcohol-Free');
    }
    if (combined.contains('hydrating') || combined.contains('moisturizing')) {
      claims.add('Deep Hydration');
    }

    return claims.toList();
  }

  static List<String> _extractClaimsFromText(String text) {
    final claims = <String>[];
    final lower = text.toLowerCase();
    if (lower.contains('spf')) claims.add('SPF Protection');
    if (lower.contains('hydrating') || lower.contains('hyaluronic')) claims.add('Hydrating');
    if (lower.contains('soothing') || lower.contains('calming') || lower.contains('cica')) claims.add('Soothing');
    if (lower.contains('brightening') || lower.contains('vitamin c')) claims.add('Brightening');
    if (lower.contains('anti-aging') || lower.contains('retinol')) claims.add('Anti-Aging');
    return claims;
  }

  static String? _extractKeyActives(String? ingredients, String name) {
    if (ingredients == null && name.isEmpty) return null;
    final text = '${name.toLowerCase()} ${ingredients?.toLowerCase() ?? ''}';
    final actives = <String>[];

    if (text.contains('hyaluronic acid') || text.contains('sodium hyaluronate')) actives.add('Hyaluronic Acid');
    if (text.contains('niacinamide')) actives.add('Niacinamide (Vitamin B3)');
    if (text.contains('ceramide') || text.contains('ceramides')) actives.add('Ceramides NP/AP/EOP');
    if (text.contains('centella asiatica') || text.contains('madecassoside') || text.contains('cica')) actives.add('Centella Asiatica (Cica)');
    if (text.contains('salicylic acid') || text.contains('bha')) actives.add('Salicylic Acid (BHA)');
    if (text.contains('glycolic acid') || text.contains('lactic acid') || text.contains('aha')) actives.add('AHA (Glycolic / Lactic Acid)');
    if (text.contains('ascorbic acid') || text.contains('vitamin c')) actives.add('Vitamin C');
    if (text.contains('retinol') || text.contains('retinal') || text.contains('bakuchiol')) actives.add('Retinol / Retinal');
    if (text.contains('snail secretion') || text.contains('snail mucin')) actives.add('Snail Secretion Filtrate');
    if (text.contains('panthenol') || text.contains('vitamin b5')) actives.add('Panthenol (Pro-Vitamin B5)');
    if (text.contains('zinc pca') || text.contains('zinc oxide')) actives.add('Zinc');
    if (text.contains('propolis') || text.contains('honey')) actives.add('Propolis Extract');
    if (text.contains('peptide') || text.contains('peptides')) actives.add('Peptides Complex');
    if (text.contains('squalane')) actives.add('Plant-derived Squalane');
    if (text.contains('tea tree') || text.contains('melaleuca')) actives.add('Tea Tree');

    return actives.isNotEmpty ? actives.join(' • ') : null;
  }

  static String? _extractAllergens(Map<String, dynamic> p, String? ingredients) {
    final raw = (p['allergens'] as String?)?.trim() ??
        (p['allergens_from_ingredients'] as String?)?.trim();

    if (raw != null && raw.isNotEmpty) {
      return raw.replaceAll('en:', '').replaceAll(',', ', ').trim();
    }

    // Infer from ingredients if labeled in INCI
    if (ingredients != null) {
      final lower = ingredients.toLowerCase();
      final found = <String>[];
      if (lower.contains('parfum') || lower.contains('fragrance')) found.add('Fragrance (Parfum)');
      if (lower.contains('limonene')) found.add('Limonene');
      if (lower.contains('linalool')) found.add('Linalool');
      if (lower.contains('citronellol')) found.add('Citronellol');
      if (lower.contains('geraniol')) found.add('Geraniol');
      if (lower.contains('benzyl alcohol')) found.add('Benzyl Alcohol');
      if (lower.contains('eugenol')) found.add('Eugenol');
      if (lower.contains('cinnamal')) found.add('Cinnamal');
      if (lower.contains('coumarin')) found.add('Coumarin');
      if (lower.contains('isoeugenol')) found.add('Isoeugenol');
      if (found.isNotEmpty) return found.join(', ');
    }
    return null;
  }

  static String? _extractPreservatives(String? ingredients) {
    if (ingredients == null) return null;
    final lower = ingredients.toLowerCase();
    final found = <String>[];

    if (lower.contains('phenoxyethanol')) found.add('Phenoxyethanol');
    if (lower.contains('ethylhexylglycerin')) found.add('Ethylhexylglycerin');
    if (lower.contains('caprylyl glycol')) found.add('Caprylyl Glycol');
    if (lower.contains('sodium benzoate')) found.add('Sodium Benzoate');
    if (lower.contains('potassium sorbate')) found.add('Potassium Sorbate');
    if (lower.contains('methylparaben') || lower.contains('propylparaben') ||
        lower.contains('butylparaben') || lower.contains('ethylparaben')) {
      found.add('Parabens');
    }
    if (lower.contains('benzalkonium chloride')) found.add('Benzalkonium Chloride');
    if (lower.contains('chlorphenesin')) found.add('Chlorphenesin');
    if (lower.contains('dehydroacetic acid')) found.add('Dehydroacetic Acid');
    if (lower.contains('1,2-hexanediol') || lower.contains('1,2 hexanediol')) found.add('1,2-Hexanediol');

    return found.isNotEmpty ? found.join(', ') : null;
  }

  static String? _extractFragranceIngredients(String? ingredients) {
    if (ingredients == null) return null;
    final lower = ingredients.toLowerCase();
    final found = <String>[];

    if (lower.contains('parfum') || lower.contains('fragrance')) found.add('Parfum/Fragrance');
    if (lower.contains('limonene')) found.add('Limonene');
    if (lower.contains('linalool')) found.add('Linalool');
    if (lower.contains('citronellol')) found.add('Citronellol');
    if (lower.contains('geraniol')) found.add('Geraniol');
    if (lower.contains('citral')) found.add('Citral');
    if (lower.contains('eugenol')) found.add('Eugenol');
    if (lower.contains('cinnamal')) found.add('Cinnamal');
    if (lower.contains('benzyl salicylate')) found.add('Benzyl Salicylate');
    if (lower.contains('alpha-isomethyl ionone')) found.add('Alpha-Isomethyl Ionone');

    return found.isNotEmpty ? found.join(', ') : null;
  }

  static List<String> _extractWarnings(Map<String, dynamic> p) {
    final warnings = <String>[];
    final combined = [
      p['warning'] ?? '',
      p['conservation_conditions'] ?? '',
      p['labels'] ?? '',
      p['labels_tags'] != null ? (p['labels_tags'] as List).join(' ') : '',
    ].join(' ').toLowerCase();

    if (combined.contains('avoid eye')) warnings.add('Avoid contact with eyes');
    if (combined.contains('keep out of reach')) warnings.add('Keep out of reach of children');
    if (combined.contains('flammable') || combined.contains('inflammable')) warnings.add('Flammable');
    if (combined.contains('do not swallow') || combined.contains('not for ingestion')) warnings.add('Not for ingestion');
    if (combined.contains('patch test') || combined.contains('sensitivity test')) warnings.add('Patch test recommended');
    if (combined.contains('discontinue use')) warnings.add('Discontinue if irritation occurs');
    if (combined.contains('not suitable for children')) warnings.add('Not suitable for children');
    if (combined.contains('consult a doctor') || combined.contains('consult physician')) warnings.add('Consult a physician before use');
    if (combined.contains('pregnancy') || combined.contains('pregnant')) warnings.add('Consult doctor if pregnant or nursing');

    return warnings;
  }

  static List<String> _extractCertifications(Map<String, dynamic> p) {
    final certs = <String>[];
    final labelsStr = [
      p['labels'] ?? '',
      p['labels_tags'] != null ? (p['labels_tags'] as List).join(' ') : '',
    ].join(' ').toLowerCase();

    if (labelsStr.contains('ecocert') || labelsStr.contains('ecocert')) certs.add('Ecocert Certified');
    if (labelsStr.contains('cosmos organic') || labelsStr.contains('cosmos-organic')) certs.add('COSMOS Organic');
    if (labelsStr.contains('cosmos natural')) certs.add('COSMOS Natural');
    if (labelsStr.contains('natrue')) certs.add('NATRUE Certified');
    if (labelsStr.contains('usda organic') || labelsStr.contains('usda-organic')) certs.add('USDA Organic');
    if (labelsStr.contains('leaping bunny')) certs.add('Leaping Bunny (Cruelty-Free)');
    if (labelsStr.contains('peta') || labelsStr.contains('certified vegan')) certs.add('PETA Certified');
    if (labelsStr.contains('fragrance free') || labelsStr.contains('fragrance-free')) certs.add('Fragrance-Free');
    if (labelsStr.contains('dermatologist tested')) certs.add('Dermatologist Tested');
    if (labelsStr.contains('allergy tested') || labelsStr.contains('hypoallergenic')) certs.add('Hypoallergenic');
    if (labelsStr.contains('non-comedogenic') || labelsStr.contains('non comedogenic')) certs.add('Non-Comedogenic');
    if (labelsStr.contains('ophthalmologist')) certs.add('Ophthalmologist Tested');
    if (labelsStr.contains('iso ') && (labelsStr.contains('22716') || labelsStr.contains('9001'))) certs.add('ISO Certified');

    return certs;
  }

  static String? _extractSkinType(Map<String, dynamic> p, String name, String? ingredients) {
    final combined = [
      name,
      p['product_name'] ?? '',
      p['generic_name'] ?? '',
      p['labels'] ?? '',
      ingredients ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('oily skin') || combined.contains('oil-free') || combined.contains('for oily')) return 'Oily Skin';
    if (combined.contains('dry skin') || combined.contains('for dry') || combined.contains('very dry')) return 'Dry Skin';
    if (combined.contains('combination skin') || combined.contains('for combination')) return 'Combination Skin';
    if (combined.contains('sensitive skin') || combined.contains('for sensitive') || combined.contains('hypoallergenic')) return 'Sensitive Skin';
    if (combined.contains('normal skin') || combined.contains('all skin types') || combined.contains('tous types')) return 'All Skin Types';
    if (combined.contains('mature skin') || combined.contains('anti-aging') || combined.contains('anti-age')) return 'Mature Skin';
    if (combined.contains('acne') || combined.contains('blemish') || combined.contains('acne-prone')) return 'Acne-Prone Skin';
    return null;
  }

  static String? _extractApplicationArea(Map<String, dynamic> p, String name, String categoryId) {
    final combined = [
      name,
      p['generic_name'] ?? '',
      p['categories'] ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('eye') || categoryId == 'eye_cream' || categoryId == 'mascara') return 'Eye Area';
    if (combined.contains('lip') || categoryId == 'lipstick') return 'Lips';
    if (combined.contains('body') || combined.contains('hands') || combined.contains('foot')) return 'Body';
    if (combined.contains('hair') || combined.contains('scalp')) return 'Hair & Scalp';
    if (combined.contains('neck') || combined.contains('décolleté') || combined.contains('decollete')) return 'Face, Neck & Décolleté';
    return 'Face'; // Default for most cosmetics
  }

  static String? _extractTexture(Map<String, dynamic> p, String name, String categoryId) {
    final combined = [
      name,
      p['generic_name'] ?? '',
      p['categories'] ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('gel') || combined.contains('jelly')) return 'Gel';
    if (combined.contains('foam') || combined.contains('mousse')) return 'Foam / Mousse';
    if (combined.contains('oil') && !combined.contains('oil-free')) return 'Oil / Dry Oil';
    if (combined.contains('milk') || combined.contains('emulsion')) return 'Fluid / Emulsion';
    if (combined.contains('balm') || combined.contains('baume')) return 'Balm / Ointment';
    if (combined.contains('mist') || combined.contains('spray') || combined.contains('toner')) return 'Watery Mist / Toner';
    if (combined.contains('serum') || combined.contains('ampoule') || combined.contains('essence')) return 'Lightweight Serum';
    if (combined.contains('cream') || combined.contains('crème') || categoryId == 'moisturizer') return 'Cream';
    if (combined.contains('lotion')) return 'Lotion';
    if (combined.contains('powder') || combined.contains('poudre')) return 'Powder';
    if (combined.contains('stick') || combined.contains('baton')) return 'Solid Stick';
    return null;
  }

  static String? _extractScent(Map<String, dynamic> p, String name, String? ingredients) {
    final combined = [
      name,
      p['product_name'] ?? '',
      p['generic_name'] ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('unscented') || combined.contains('fragrance-free') || combined.contains('sans parfum')) return 'Fragrance-Free / Unscented';
    if (combined.contains('rose') || combined.contains('floral')) return 'Floral (Rose)';
    if (combined.contains('citrus') || combined.contains('orange') || combined.contains('bergamot')) return 'Citrus';
    if (combined.contains('lavender') || combined.contains('lavande')) return 'Floral (Lavender)';
    if (combined.contains('vanilla')) return 'Warm / Vanilla';
    if (combined.contains('mint') || combined.contains('menthol')) return 'Fresh / Minty';
    if (combined.contains('cedar') || combined.contains('woody') || combined.contains('sandalwood')) return 'Woody / Earthy';
    if (combined.contains('musk')) return 'Musky';
    if (combined.contains('berry') || combined.contains('fruit')) return 'Fruity / Berry';
    if (combined.contains('fresh') || combined.contains('aqua')) return 'Fresh / Aquatic';

    // Check if fragrance free from ingredients
    if (ingredients != null && !ingredients.toLowerCase().contains('parfum') &&
        !ingredients.toLowerCase().contains('fragrance')) {
      return 'Fragrance-Free';
    }
    return null;
  }

  static String? _extractPH(Map<String, dynamic> p) {
    final phRaw = p['ph'] as String? ?? p['pH'] as String?;
    if (phRaw != null && phRaw.isNotEmpty) return 'pH $phRaw';

    // Infer likely pH range from category/name
    final name = (p['product_name'] ?? p['generic_name'] ?? '').toString().toLowerCase();
    if (name.contains('aha') || name.contains('bha') || name.contains('peeling') || name.contains('exfoliant')) {
      return '~pH 3.5–4.0 (Acid Exfoliant)';
    }
    if (name.contains('toner') || name.contains('astringent')) return '~pH 5.0–6.0';
    if (name.contains('cleanser') || name.contains('face wash')) return '~pH 5.5–6.5';
    if (name.contains('vitamin c') || name.contains('ascorbic acid')) return '~pH 2.5–3.5 (Vitamin C)';
    return null;
  }

  // ===================== CURATED BEAUTY INTELLIGENCE LOCAL CATALOG =====================


  static ProductModel? _lookupLocalCatalog(String barcode) {
    final catalog = _curatedBeautyCatalog;
    return catalog[barcode];
  }

  static ProductModel? _inferFromBarcodePrefix(String barcode) {
    final country = _getCountryFromBarcodePrefix(barcode);
    if (country == null) return null;

    return ProductModel(
      productId: 'inferred_${DateTime.now().millisecondsSinceEpoch}',
      barcode: barcode,
      name: 'Cosmetic Product ($country)',
      brand: 'Product of $country',
      categoryId: 'other',
      paoMonths: 12,
      countryOfOrigin: country,
      sourceDatabase: 'Barcode Region Intelligence',
      createdAt: DateTime.now(),
    );
  }

  static final Map<String, ProductModel> _curatedBeautyCatalog = {
    // La Roche-Posay
    '3337875597180': const ProductModel(
      productId: 'curated_lrp_hyalu',
      barcode: '3337875597180',
      name: 'Hyalu B5 Pure Hyaluronic Acid Serum',
      brand: 'La Roche-Posay',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'France',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Deep Hydration', 'Dermatologist Tested', 'For Sensitive Skin'],
      keyActives: 'Hyaluronic Acid • Panthenol (Pro-Vitamin B5) • Madecassoside',
      ingredients: 'Aqua / Water, Glycerin, Alcohol Denat., Propylene Glycol, Panthenol, Pentylene Glycol, Dimethicone, PEG-6 Caprylic/Capric Glycerides, PPG-6-Decyltetradeceth-30, Glyceryl Isostearate, Madecassoside, Sodium Hyaluronate, Ammonium Polyacryloyldimethyl Taurate, Disodium EDTA, Hydrolyzed Hyaluronic Acid, Caprylyl Glycol, Citric Acid, Xanthan Gum, Butylene Glycol, Tocopherol, Phenoxyethanol, Parfum / Fragrance.',
    ),
    '3337875545778': const ProductModel(
      productId: 'curated_lrp_anthelios',
      barcode: '3337875545778',
      name: 'Anthelios UVMune 400 Invisible Fluid SPF50+',
      brand: 'La Roche-Posay',
      categoryId: 'sunscreen',
      paoMonths: 12,
      volume: '50 ml',
      countryOfOrigin: 'France',
      packagingType: 'Bottle',
      skinClaims: ['SPF Protection', 'Fragrance-Free', 'Non-Comedogenic'],
      keyActives: 'Mexoryl 400 • Netlock Technology • Vitamin E',
      ingredients: 'Aqua / Water, Alcohol Denat., Triethyl Citrate, Diisopropyl Sebacate, Silica, Ethylhexyl Salicylate, Bis-Ethylhexyloxyphenol Methoxyphenyl Triazine, Ethylhexyl Triazone, Butyl Methoxydibenzoylmethane, Glycerin, Propanediol, C12-22 Alkyl Acrylate/Hydroxyethylacrylate Copolymer, Methoxypropylamino Cyclohexenylidene Ethoxyethylcyanoacetate, Perlite, Drometrizole Trisiloxane, Caprylic/Capric Triglyceride, Tocopherol...',
    ),
    '3337872412995': const ProductModel(
      productId: 'curated_lrp_cicaplast',
      barcode: '3337872412995',
      name: 'Cicaplast Baume B5+ Ultra-Repairing Soothing Balm',
      brand: 'La Roche-Posay',
      categoryId: 'moisturizer',
      paoMonths: 6,
      volume: '100 ml',
      countryOfOrigin: 'France',
      packagingType: 'Squeeze Tube',
      skinClaims: ['Fragrance-Free', 'For Sensitive Skin', 'Deep Hydration'],
      keyActives: 'Panthenol (Pro-Vitamin B5) • Madecassoside • Zinc',
    ),

    // Beauty of Joseon
    '8809643068098': const ProductModel(
      productId: 'curated_boj_relief_sun',
      barcode: '8809643068098',
      name: 'Relief Sun : Rice + Probiotics (SPF50+ PA++++)',
      brand: 'Beauty of Joseon',
      categoryId: 'sunscreen',
      paoMonths: 12,
      volume: '50 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Squeeze Tube',
      skinClaims: ['SPF Protection', 'Fragrance-Free', 'Cruelty-Free / Vegan', 'Deep Hydration'],
      keyActives: 'Oryza Sativa (Rice) Extract (30%) • Grain Probiotics Complex • Niacinamide (Vitamin B3)',
      ingredients: 'Water, Oryza Sativa (Rice) Extract (30%), Dibutyl Adipate, Propanediol, Diethylamino Hydroxybenzoyl Hexyl Benzoate, Polymethylsilsesquioxane, Ethylhexyl Triazone, Niacinamide, Methylene Bis-benzotriazolyl Tetramethylbutylphenol, Coco-caprylate/Caprate, Caprylyl Methicone, Diethylhexyl Butamido Triazone, Glycerin, Butylene Glycol, Oryza Sativa (Rice) Germ Extract, Camellia Sinensis Leaf Extract, Lactobacillus/Rice Ferment, Aspergillus Ferment, Saccharomyces/Rice Ferment Filtrate, Panax Ginseng Root Extract...',
    ),
    '8809643068104': const ProductModel(
      productId: 'curated_boj_glow_serum',
      barcode: '8809643068104',
      name: 'Glow Serum : Propolis + Niacinamide',
      brand: 'Beauty of Joseon',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Deep Hydration', 'Cruelty-Free / Vegan', 'Fragrance-Free'],
      keyActives: 'Propolis Extract (60%) • Niacinamide (Vitamin B3) (2%) • BHA',
    ),

    // CeraVe
    '3337872412483': const ProductModel(
      productId: 'curated_cerave_moisturizing_cream',
      barcode: '3337872412483',
      name: 'Moisturizing Cream with Essential Ceramides',
      brand: 'CeraVe',
      categoryId: 'moisturizer',
      paoMonths: 12,
      volume: '454 g',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Jar / Tub',
      skinClaims: ['Fragrance-Free', 'Non-Comedogenic', 'Deep Hydration', 'Dermatologist Tested'],
      keyActives: 'Ceramides NP/AP/EOP • Hyaluronic Acid • MVE Technology',
      ingredients: 'Aqua / Water / Eau, Glycerin, Cetearyl Alcohol, Caprylic/Capric Triglyceride, Cetyl Alcohol, Ceteareth-20, Petrolatum, Potassium Phosphate, Ceramide NP, Ceramide AP, Ceramide EOP, Carbomer, Dimethicone, Behentrimonium Methosulfate, Sodium Lauroyl Lactylate, Sodium Hyaluronate, Cholesterol, Phenoxyethanol, Disodium EDTA, Dipotassium Phosphate, Tocopherol, Phytosphingosine, Xanthan Gum, Ethylhexylglycerin.',
    ),
    '3337875597388': const ProductModel(
      productId: 'curated_cerave_hydrating_cleanser',
      barcode: '3337875597388',
      name: 'Hydrating Facial Cleanser for Normal to Dry Skin',
      brand: 'CeraVe',
      categoryId: 'cleanser',
      paoMonths: 12,
      volume: '236 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Pump Bottle',
      skinClaims: ['Fragrance-Free', 'Non-Comedogenic', 'Dermatologist Tested'],
      keyActives: 'Ceramides NP/AP/EOP • Hyaluronic Acid',
    ),

    // The Ordinary
    '769915190601': const ProductModel(
      productId: 'curated_the_ordinary_niacinamide',
      barcode: '769915190601',
      name: 'Niacinamide 10% + Zinc 1% High-Strength Vitamin and Mineral Formula',
      brand: 'The Ordinary',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Alcohol-Free', 'Cruelty-Free / Vegan', 'Fragrance-Free'],
      keyActives: 'Niacinamide (Vitamin B3) • Zinc',
      ingredients: 'Aqua (Water), Niacinamide, Pentylene Glycol, Zinc PCA, Dimethyl Isosorbide, Tamarindus Indica Seed Gum, Xanthan Gum, Isoceteth-20, Ethoxydiglycol, Phenoxyethanol, Chlorphenesin.',
    ),
    '769915190588': const ProductModel(
      productId: 'curated_the_ordinary_ha',
      barcode: '769915190588',
      name: 'Hyaluronic Acid 2% + B5 Hydration Support Formula',
      brand: 'The Ordinary',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Deep Hydration', 'Cruelty-Free / Vegan', 'Fragrance-Free'],
      keyActives: 'Hyaluronic Acid • Panthenol (Pro-Vitamin B5)',
    ),
    '769915190595': const ProductModel(
      productId: 'curated_the_ordinary_aha_bha',
      barcode: '769915190595',
      name: 'AHA 30% + BHA 2% Peeling Solution (10-Minute Exfoliating Facial)',
      brand: 'The Ordinary',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Cruelty-Free / Vegan', 'Alcohol-Free'],
      keyActives: 'AHA (Glycolic / Lactic Acid) • Salicylic Acid (BHA) • Hyaluronic Acid',
    ),

    // COSRX
    '8809416470009': const ProductModel(
      productId: 'curated_cosrx_snail_essence',
      barcode: '8809416470009',
      name: 'Advanced Snail 96 Mucin Power Essence',
      brand: 'COSRX',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '100 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Pump Bottle',
      skinClaims: ['Fragrance-Free', 'Cruelty-Free / Vegan', 'Deep Hydration', 'For Sensitive Skin'],
      keyActives: 'Snail Secretion Filtrate (96%) • Sodium Hyaluronate • Panthenol (Pro-Vitamin B5) • Allantoin',
      ingredients: 'Snail Secretion Filtrate, Betaine, Butylene Glycol, 1,2-Hexanediol, Sodium Polyacrylate, Phenoxyethanol, Sodium Hyaluronate, Allantoin, Ethyl Hexanediol, Carbomer, Panthenol, Arginine.',
    ),
    '8809416470030': const ProductModel(
      productId: 'curated_cosrx_low_ph',
      barcode: '8809416470030',
      name: 'Low pH Good Morning Gel Cleanser',
      brand: 'COSRX',
      categoryId: 'cleanser',
      paoMonths: 12,
      volume: '150 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Squeeze Tube',
      skinClaims: ['For Sensitive Skin', 'Cruelty-Free / Vegan'],
      keyActives: 'Tea Tree • Betaine Salicylate (BHA)',
    ),

    // Paula's Choice
    '0655439020108': const ProductModel(
      productId: 'curated_paulas_choice_bha',
      barcode: '0655439020108',
      name: 'Skin Perfecting 2% BHA Liquid Exfoliant',
      brand: "Paula's Choice",
      categoryId: 'toner',
      paoMonths: 12,
      volume: '118 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Bottle',
      skinClaims: ['Fragrance-Free', 'Cruelty-Free / Vegan', 'Non-Comedogenic'],
      keyActives: 'Salicylic Acid (BHA) (2%) • Green Tea Extract • Methylpropanediol',
    ),

    // Maybelline
    '041554420616': const ProductModel(
      productId: 'curated_maybelline_sky_high',
      barcode: '041554420616',
      name: 'Lash Sensational Sky High Washable Mascara (Very Black)',
      brand: 'Maybelline New York',
      categoryId: 'mascara',
      paoMonths: 3,
      volume: '7.2 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Stick Applicator',
      skinClaims: ['Ophthalmologist Tested', 'For Sensitive Eyes'],
      keyActives: 'Bamboo Extract • Fiber Extensions',
    ),
    '041554422504': const ProductModel(
      productId: 'curated_maybelline_instant_age_rewind',
      barcode: '041554422504',
      name: 'Instant Age Rewind Multi-Use Concealer',
      brand: 'Maybelline New York',
      categoryId: 'foundation',
      paoMonths: 6,
      volume: '6.0 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Stick Applicator',
      keyActives: 'Haloxyl • Goji Berry Extract',
    ),

    // Laneige
    '8809643053674': const ProductModel(
      productId: 'curated_laneige_lip_sleeping_mask',
      barcode: '8809643053674',
      name: 'Lip Sleeping Mask Intense Hydration with Vitamin C (Berry)',
      brand: 'Laneige',
      categoryId: 'lipstick',
      paoMonths: 12,
      volume: '20 g',
      countryOfOrigin: 'South Korea',
      packagingType: 'Jar / Tub',
      skinClaims: ['Deep Hydration', 'Dermatologist Tested'],
      keyActives: 'Berry Fruit Complex • Vitamin C • Coconut Oil • Shea Butter',
    ),

    // Bioderma
    '3401575645851': const ProductModel(
      productId: 'curated_bioderma_sensibio',
      barcode: '3401575645851',
      name: 'Sensibio H2O Soothing Micellar Water',
      brand: 'Bioderma',
      categoryId: 'cleanser',
      paoMonths: 12,
      volume: '500 ml',
      countryOfOrigin: 'France',
      packagingType: 'Bottle',
      skinClaims: ['Fragrance-Free', 'Alcohol-Free', 'For Sensitive Skin', 'Dermatologist Tested'],
      keyActives: 'Micellar Technology • Cucumis Sativus (Cucumber) Fruit Extract',
    ),

    // Minimalist
    '8906128100010': const ProductModel(
      productId: 'curated_minimalist_salicylic',
      barcode: '8906128100010',
      name: 'Salicylic Acid 2% Face Serum for Acne & Blackheads',
      brand: 'Minimalist',
      categoryId: 'serum',
      paoMonths: 6,
      volume: '30 ml',
      countryOfOrigin: 'India',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Fragrance-Free', 'Non-Comedogenic', 'Cruelty-Free / Vegan'],
      keyActives: 'Salicylic Acid (BHA) (2%) • Oligopeptide-10 • EGCG',
    ),
    '8906128100140': const ProductModel(
      productId: 'curated_minimalist_sunscreen',
      barcode: '8906128100140',
      name: 'Sunscreen SPF 50 PA++++ with Niacinamide & Multi-Vitamins',
      brand: 'Minimalist',
      categoryId: 'sunscreen',
      paoMonths: 12,
      volume: '50 g',
      countryOfOrigin: 'India',
      packagingType: 'Squeeze Tube',
      skinClaims: ['SPF Protection', 'Fragrance-Free', 'Non-Comedogenic'],
      keyActives: 'Niacinamide (Vitamin B3) • Vitamin C • Vitamin E',
    ),

    // Anua
    '8809640733852': const ProductModel(
      productId: 'curated_anua_77_toner',
      barcode: '8809640733852',
      name: 'Heartleaf 77% Soothing Toner',
      brand: 'Anua',
      categoryId: 'toner',
      paoMonths: 12,
      volume: '250 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Bottle',
      skinClaims: ['Cruelty-Free / Vegan', 'Fragrance-Free', 'For Sensitive Skin', 'Deep Hydration'],
      keyActives: 'Houttuynia Cordata (Heartleaf) Extract (77%) • Panthenol (Pro-Vitamin B5) • Centella Asiatica (Cica)',
    ),
  };
}
