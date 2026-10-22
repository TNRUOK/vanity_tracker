import 'category_model.dart';

export 'category_model.dart' show CategorySource;

/// Where a product's PAO (Period After Opening) value came from.
///
/// Stored as `pao_source`. Records saved before this field existed have no value and are
/// read as [notRecorded]: the stored months are kept, but are not presented as verified.
enum PaoSource {
  packaging('packaging'), // read from the product's own packaging
  user('user'), // entered or confirmed by the user
  productDatabase('product_database'), // explicit PAO from an online product database
  appCatalog('app_catalog'), // the app's built-in curated catalog
  categoryDefault('category_default'), // the category's default, not product-specific
  notRecorded('not_recorded'), // legacy record: a value exists, its origin is unknown
  unknown('unknown'); // no PAO value at all

  final String storageValue;
  const PaoSource(this.storageValue);

  static PaoSource fromStorage(Object? raw) {
    for (final s in values) {
      if (s.storageValue == raw) return s;
    }
    return notRecorded;
  }

  /// Packaging or the user: values the app treats as verified.
  bool get isVerified => this == packaging || this == user;

  String get label => switch (this) {
        packaging => 'Detected from the product packaging',
        user => 'Entered or confirmed by you',
        productDatabase => 'From an online product database (not checked against your packaging)',
        appCatalog => "From the app's built-in catalog (not checked against your packaging)",
        categoryDefault => 'Estimated from the category default (not verified)',
        notRecorded => 'Source not recorded (not verified)',
        unknown => 'Unknown: no PAO has been set',
      };
}

/// Where a product's ingredient list came from. Stored as `ingredients_source`; records
/// saved before this field existed are read as [notRecorded].
enum IngredientSource {
  packaging('packaging'), // read from the product's own label (photo + user review)
  productDatabase('product_database'), // product-specific record, e.g. Open Beauty Facts
  appCatalog('app_catalog'), // the app's built-in sample catalog
  user('user'), // typed or corrected by the user
  notRecorded('not_recorded'); // legacy record: a list exists, its origin is unknown

  final String storageValue;
  const IngredientSource(this.storageValue);

  static IngredientSource fromStorage(Object? raw) {
    for (final s in values) {
      if (s.storageValue == raw) return s;
    }
    return notRecorded;
  }

  /// Confirmed against the exact product (its label) or by the user.
  bool get isConfirmed => this == packaging || this == user;

  String get label => switch (this) {
        packaging => 'From the product label (photo, reviewed by you)',
        productDatabase => 'From an online product database (may differ by country or version)',
        appCatalog => "From the app's sample catalog (not checked against your product)",
        user => 'Entered or corrected by you',
        notRecorded => 'Source not recorded',
      };
}

class ProductModel {
  final String productId;
  final String barcode;
  final String name;
  final String brand;
  final String categoryId;

  /// Provenance of [categoryId] (suggestions are never presented as product facts).
  final CategorySource categorySource;

  /// PAO in months. When [paoSource] is [PaoSource.unknown] this holds a placeholder and
  /// must not be used for expiry; use [knownPaoMonths] for calculations.
  final int paoMonths;
  final PaoSource paoSource;
  final String? imageUrl;
  final String? thumbnailUrl;
  final String? volume;
  final String? ingredients;

  /// Provenance of [ingredients] (meaningless when there is no list).
  final IngredientSource ingredientsSource;

  /// When the ingredient list was retrieved or confirmed.
  final DateTime? ingredientsUpdatedAt;

  /// Version/market context for the list, e.g. "Open Beauty Facts record; sold in: Netherlands".
  final String? ingredientsContext;
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
    this.categorySource = CategorySource.notRecorded,
    required this.paoMonths,
    this.paoSource = PaoSource.notRecorded,
    this.imageUrl,
    this.thumbnailUrl,
    this.volume,
    this.ingredients,
    this.ingredientsSource = IngredientSource.notRecorded,
    this.ingredientsUpdatedAt,
    this.ingredientsContext,
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

  /// Smallest and largest PAO, in months, the app accepts.
  static const int minPaoMonths = 1;
  static const int maxPaoMonths = 120;

  /// PAO usable for expiry calculations, or null when it is unknown.
  int? get knownPaoMonths => paoSource == PaoSource.unknown ? null : paoMonths;

  /// The ingredient list used for checks ([ingredients], else the INCI field), or null.
  String? get ingredientList {
    for (final s in [ingredients, inci]) {
      if (s != null && s.trim().isNotEmpty) return s;
    }
    return null;
  }

  bool get hasIngredients => ingredientList != null;

  Map<String, dynamic> toMap() {
    return {
      'product_id': productId,
      'barcode': barcode,
      'name': name,
      'brand': brand,
      'category_id': categoryId,
      'category_source': categorySource.storageValue,
      'pao_months': paoMonths,
      'pao_source': paoSource.storageValue,
      'image_url': imageUrl,
      'thumbnail_url': thumbnailUrl,
      'volume': volume,
      'ingredients': ingredients,
      'ingredients_source': ingredientsSource.storageValue,
      'ingredients_updated_at': ingredientsUpdatedAt?.toIso8601String(),
      'ingredients_context': ingredientsContext,
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

    // A missing or invalid PAO is read as unknown (12 is only a placeholder for the
    // non-nullable field and is never used for expiry, see knownPaoMonths).
    final storedPao = (map['pao_months'] as num?)?.toInt();
    final hasPao = storedPao != null && storedPao >= minPaoMonths && storedPao <= maxPaoMonths;

    return ProductModel(
      productId: id ?? map['product_id'] ?? '',
      barcode: map['barcode'] ?? '',
      name: map['name'] ?? '',
      brand: map['brand'] ?? '',
      categoryId: map['category_id'] ?? 'other',
      categorySource: CategorySource.fromStorage(map['category_source']),
      paoMonths: hasPao ? storedPao : 12,
      paoSource: hasPao ? PaoSource.fromStorage(map['pao_source']) : PaoSource.unknown,
      imageUrl: map['image_url'],
      thumbnailUrl: map['thumbnail_url'],
      volume: map['volume'],
      ingredients: map['ingredients'],
      ingredientsSource: IngredientSource.fromStorage(map['ingredients_source']),
      ingredientsUpdatedAt: map['ingredients_updated_at'] is String ? DateTime.tryParse(map['ingredients_updated_at']) : null,
      ingredientsContext: map['ingredients_context'] as String?,
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
    CategorySource? categorySource,
    int? paoMonths,
    PaoSource? paoSource,
    String? imageUrl,
    String? thumbnailUrl,
    String? volume,
    String? ingredients,
    IngredientSource? ingredientsSource,
    DateTime? ingredientsUpdatedAt,
    String? ingredientsContext,
    bool clearIngredients = false, // removes the list, its INCI copy and provenance
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
      categorySource: categorySource ?? this.categorySource,
      paoMonths: paoMonths ?? this.paoMonths,
      paoSource: paoSource ?? this.paoSource,
      imageUrl: imageUrl ?? this.imageUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      volume: volume ?? this.volume,
      ingredients: clearIngredients ? null : (ingredients ?? this.ingredients),
      ingredientsSource: clearIngredients
          ? IngredientSource.notRecorded
          : (ingredientsSource ?? this.ingredientsSource),
      ingredientsUpdatedAt: clearIngredients ? null : (ingredientsUpdatedAt ?? this.ingredientsUpdatedAt),
      ingredientsContext: clearIngredients ? null : (ingredientsContext ?? this.ingredientsContext),
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
      inci: clearIngredients ? null : (inci ?? this.inci),
      barcodeScanUrl: barcodeScanUrl ?? this.barcodeScanUrl,
      productCode: productCode ?? this.productCode,
      imageGallery: imageGallery ?? this.imageGallery,
    );
  }
}
