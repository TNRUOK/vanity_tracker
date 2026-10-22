class CategoryModel {
  final String categoryId;
  final String categoryName;
  final int defaultPaoMonths;
  final String iconName;

  const CategoryModel({
    required this.categoryId,
    required this.categoryName,
    required this.defaultPaoMonths,
    this.iconName = 'sparkles',
  });

  String get name => categoryName;
  static List<CategoryModel> get categories => defaultCategories;

  Map<String, dynamic> toMap() {
    return {
      'category_id': categoryId,
      'category_name': categoryName,
      'default_pao_months': defaultPaoMonths,
      'icon_name': iconName,
    };
  }

  factory CategoryModel.fromMap(Map<String, dynamic> map, [String? id]) {
    return CategoryModel(
      categoryId: id ?? map['category_id'] ?? '',
      categoryName: map['category_name'] ?? 'Other',
      defaultPaoMonths: (map['default_pao_months'] as num?)?.toInt() ?? 12,
      iconName: map['icon_name'] ?? 'sparkles',
    );
  }

  /// The app's canonical categories. Ids are stable (stored on every product); the first
  /// eleven are the original ones and keep their ids. `other` must stay last (fallback).
  /// [defaultPaoMonths] is only a category-level estimate, shown as unverified.
  static const List<CategoryModel> defaultCategories = [
    // Skincare
    CategoryModel(categoryId: 'cleanser', categoryName: 'Cleanser', defaultPaoMonths: 12, iconName: 'soap'),
    CategoryModel(categoryId: 'toner', categoryName: 'Toner', defaultPaoMonths: 12, iconName: 'opacity'),
    CategoryModel(categoryId: 'serum', categoryName: 'Serum', defaultPaoMonths: 12, iconName: 'water_drop'),
    CategoryModel(categoryId: 'moisturizer', categoryName: 'Moisturizer', defaultPaoMonths: 12, iconName: 'spa'),
    CategoryModel(categoryId: 'sunscreen', categoryName: 'Sunscreen', defaultPaoMonths: 12, iconName: 'wb_sunny'),
    CategoryModel(categoryId: 'eye_cream', categoryName: 'Eye Care', defaultPaoMonths: 6, iconName: 'remove_red_eye'),
    CategoryModel(categoryId: 'face_mask', categoryName: 'Face Mask', defaultPaoMonths: 12, iconName: 'face'),
    CategoryModel(categoryId: 'exfoliant', categoryName: 'Exfoliant', defaultPaoMonths: 12, iconName: 'grain'),
    CategoryModel(categoryId: 'treatment', categoryName: 'Treatment', defaultPaoMonths: 12, iconName: 'healing'),
    CategoryModel(categoryId: 'lip_care', categoryName: 'Lip Care', defaultPaoMonths: 12, iconName: 'favorite_border'),
    // Makeup
    CategoryModel(categoryId: 'lipstick', categoryName: 'Lipstick', defaultPaoMonths: 24, iconName: 'favorite'),
    CategoryModel(categoryId: 'lip_gloss', categoryName: 'Lip Gloss', defaultPaoMonths: 12, iconName: 'auto_awesome'),
    CategoryModel(categoryId: 'foundation', categoryName: 'Foundation', defaultPaoMonths: 12, iconName: 'brush'),
    CategoryModel(categoryId: 'concealer', categoryName: 'Concealer', defaultPaoMonths: 12, iconName: 'brush'),
    CategoryModel(categoryId: 'primer', categoryName: 'Primer', defaultPaoMonths: 12, iconName: 'layers'),
    CategoryModel(categoryId: 'blush', categoryName: 'Blush', defaultPaoMonths: 24, iconName: 'palette'),
    CategoryModel(categoryId: 'eyeshadow', categoryName: 'Eyeshadow', defaultPaoMonths: 24, iconName: 'palette'),
    CategoryModel(categoryId: 'eyeliner', categoryName: 'Eyeliner', defaultPaoMonths: 6, iconName: 'edit'),
    CategoryModel(categoryId: 'mascara', categoryName: 'Mascara', defaultPaoMonths: 3, iconName: 'visibility'),
    CategoryModel(categoryId: 'nail_care', categoryName: 'Nail Care', defaultPaoMonths: 12, iconName: 'back_hand'),
    // Other beauty
    CategoryModel(categoryId: 'hair_care', categoryName: 'Hair Care', defaultPaoMonths: 12, iconName: 'content_cut'),
    CategoryModel(categoryId: 'body_care', categoryName: 'Body Care', defaultPaoMonths: 12, iconName: 'bathtub'),
    CategoryModel(categoryId: 'fragrance', categoryName: 'Perfume / Fragrance', defaultPaoMonths: 36, iconName: 'local_florist'),
    CategoryModel(categoryId: 'other', categoryName: 'Other / Misc', defaultPaoMonths: 12, iconName: 'category'),
  ];

  static CategoryModel? byId(String? id) {
    for (final c in defaultCategories) {
      if (c.categoryId == id) return c;
    }
    return null;
  }

  static CategoryModel findById(String? id) => byId(id) ?? defaultCategories.last;

  /// Categories stored in the database merged with the built-in list: stored records win
  /// for ids they define (their names/PAO are kept), built-in ids they lack are added, and
  /// `other` stays last. Nothing is written back.
  static List<CategoryModel> mergeWithDefaults(List<CategoryModel> stored) {
    final byIdMap = {for (final c in stored) c.categoryId: c};
    final merged = <CategoryModel>[
      for (final d in defaultCategories)
        if (d.categoryId != 'other') byIdMap.remove(d.categoryId) ?? d,
      ...byIdMap.values.where((c) => c.categoryId != 'other'),
    ];
    merged.add(byIdMap['other'] ?? stored.where((c) => c.categoryId == 'other').firstOrNull ?? defaultCategories.last);
    return merged;
  }
}

/// Where a product's category came from. Stored as `category_source`; records saved before
/// this field existed are read as [notRecorded].
enum CategorySource {
  user('user'), // chosen or confirmed by the user
  productDatabase('product_database'), // mapped from the product record's own categories
  nameClassifier('name_classifier'), // suggested from words in the product name
  unknown('unknown'), // nothing identified the category ("Uncategorized")
  notRecorded('not_recorded'); // legacy record

  final String storageValue;
  const CategorySource(this.storageValue);

  static CategorySource fromStorage(Object? raw) {
    for (final s in values) {
      if (s.storageValue == raw) return s;
    }
    return notRecorded;
  }

  bool get isConfirmed => this == user;

  String get label => switch (this) {
        user => 'Chosen by you',
        productDatabase => "From the product database's categories (suggestion)",
        nameClassifier => 'Suggested from the product name',
        unknown => 'Not categorized yet',
        notRecorded => 'Source not recorded',
      };
}
