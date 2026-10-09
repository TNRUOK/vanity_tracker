class ProductModel {
  final String productId;
  final String barcode;
  final String name;
  final String brand;
  final String categoryId;
  final int paoMonths;
  final String? imageUrl;
  final String? thumbnailUrl;
  final String? volume;
  final String? ingredients;
  final String? countryOfOrigin;
  final String? packagingType;
  final List<String> skinClaims;
  final String? keyActives;
  final String? sourceDatabase;
  final DateTime? createdAt;

  // Extended product intelligence fields
  final String? allergens;            // Known allergens listed
  final String? preservatives;        // Preservative ingredients detected
  final String? fragranceIngredients; // Fragrance-related components
  final List<String> warnings;        // Safety or usage warnings
  final List<String> certifications;  // Organic, vegan, etc.
  final String? skinType;             // Suitable skin type (e.g., oily, dry)
  final String? applicationArea;      // Where to apply (face, body, eye area)
  final String? texture;              // Gel, cream, oil, foam, etc.
  final String? scent;                // Fragrance profile
  final String? pH;                   // Product pH level if available
  final String? cosmeticGrade;        // Grade/quality tier
  final String? inci;                 // International Nomenclature of Cosmetic Ingredients list
  final String? barcodeScanUrl;       // Product page URL from source
  final String? productCode;          // Manufacturer product code
  final List<String> imageGallery;    // Multiple product images

  const ProductModel({
    required this.productId,
    required this.barcode,
    required this.name,
    required this.brand,
    required this.categoryId,
    required this.paoMonths,
    this.imageUrl,
    this.thumbnailUrl,
    this.volume,
    this.ingredients,
    this.countryOfOrigin,
    this.packagingType,
    this.skinClaims = const [],
    this.keyActives,
    this.sourceDatabase,
    this.createdAt,
    this.allergens,
    this.preservatives,
    this.fragranceIngredients,
    this.warnings = const [],
    this.certifications = const [],
    this.skinType,
    this.applicationArea,
    this.texture,
    this.scent,
    this.pH,
    this.cosmeticGrade,
    this.inci,
    this.barcodeScanUrl,
    this.productCode,
    this.imageGallery = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'product_id': productId,
      'barcode': barcode,
      'name': name,
      'brand': brand,
      'category_id': categoryId,
      'pao_months': paoMonths,
      'image_url': imageUrl,
      'thumbnail_url': thumbnailUrl,
      'volume': volume,
      'ingredients': ingredients,
      'country_of_origin': countryOfOrigin,
      'packaging_type': packagingType,
      'skin_claims': skinClaims,
      'key_actives': keyActives,
      'source_database': sourceDatabase,
      'created_at': createdAt?.toIso8601String(),
      'allergens': allergens,
      'preservatives': preservatives,
      'fragrance_ingredients': fragranceIngredients,
      'warnings': warnings,
      'certifications': certifications,
      'skin_type': skinType,
      'application_area': applicationArea,
      'texture': texture,
      'scent': scent,
      'ph': pH,
      'cosmetic_grade': cosmeticGrade,
      'inci': inci,
      'barcode_scan_url': barcodeScanUrl,
      'product_code': productCode,
      'image_gallery': imageGallery,
    };
  }

  factory ProductModel.fromMap(Map<String, dynamic> map, [String? id]) {
    List<String> parseStringList(dynamic raw) {
      if (raw is List) return raw.map((e) => e.toString()).toList();
      return [];
    }

    return ProductModel(
      productId: id ?? map['product_id'] ?? '',
      barcode: map['barcode'] ?? '',
      name: map['name'] ?? '',
      brand: map['brand'] ?? '',
      categoryId: map['category_id'] ?? 'other',
      paoMonths: (map['pao_months'] as num?)?.toInt() ?? 12,
      imageUrl: map['image_url'],
      thumbnailUrl: map['thumbnail_url'],
      volume: map['volume'],
      ingredients: map['ingredients'],
      countryOfOrigin: map['country_of_origin'],
      packagingType: map['packaging_type'],
      skinClaims: parseStringList(map['skin_claims']),
      keyActives: map['key_actives'],
      sourceDatabase: map['source_database'],
      createdAt: map['created_at'] != null ? DateTime.tryParse(map['created_at']) : null,
      allergens: map['allergens'],
      preservatives: map['preservatives'],
      fragranceIngredients: map['fragrance_ingredients'],
      warnings: parseStringList(map['warnings']),
      certifications: parseStringList(map['certifications']),
      skinType: map['skin_type'],
      applicationArea: map['application_area'],
      texture: map['texture'],
      scent: map['scent'],
      pH: map['ph'],
      cosmeticGrade: map['cosmetic_grade'],
      inci: map['inci'],
      barcodeScanUrl: map['barcode_scan_url'],
      productCode: map['product_code'],
      imageGallery: parseStringList(map['image_gallery']),
    );

  }

  ProductModel copyWith({
    String? productId,
    String? barcode,
    String? name,
    String? brand,
    String? categoryId,
    int? paoMonths,
    String? imageUrl,
    String? thumbnailUrl,
    String? volume,
    String? ingredients,
    String? countryOfOrigin,
    String? packagingType,
    List<String>? skinClaims,
    String? keyActives,
    String? sourceDatabase,
    DateTime? createdAt,
    String? allergens,
    String? preservatives,
    String? fragranceIngredients,
    List<String>? warnings,
    List<String>? certifications,
    String? skinType,
    String? applicationArea,
    String? texture,
    String? scent,
    String? pH,
    String? cosmeticGrade,
    String? inci,
    String? barcodeScanUrl,
    String? productCode,
    List<String>? imageGallery,
  }) {
    return ProductModel(
      productId: productId ?? this.productId,
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      categoryId: categoryId ?? this.categoryId,
      paoMonths: paoMonths ?? this.paoMonths,
      imageUrl: imageUrl ?? this.imageUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      volume: volume ?? this.volume,
      ingredients: ingredients ?? this.ingredients,
      countryOfOrigin: countryOfOrigin ?? this.countryOfOrigin,
      packagingType: packagingType ?? this.packagingType,
      skinClaims: skinClaims ?? this.skinClaims,
      keyActives: keyActives ?? this.keyActives,
      sourceDatabase: sourceDatabase ?? this.sourceDatabase,
      createdAt: createdAt ?? this.createdAt,
      allergens: allergens ?? this.allergens,
      preservatives: preservatives ?? this.preservatives,
      fragranceIngredients: fragranceIngredients ?? this.fragranceIngredients,
      warnings: warnings ?? this.warnings,
      certifications: certifications ?? this.certifications,
      skinType: skinType ?? this.skinType,
      applicationArea: applicationArea ?? this.applicationArea,
      texture: texture ?? this.texture,
      scent: scent ?? this.scent,
      pH: pH ?? this.pH,
      cosmeticGrade: cosmeticGrade ?? this.cosmeticGrade,
      inci: inci ?? this.inci,
      barcodeScanUrl: barcodeScanUrl ?? this.barcodeScanUrl,
      productCode: productCode ?? this.productCode,
      imageGallery: imageGallery ?? this.imageGallery,
    );
  }
}
