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

  static const List<CategoryModel> defaultCategories = [
    CategoryModel(
      categoryId: 'serum',
      categoryName: 'Serum',
      defaultPaoMonths: 12,
      iconName: 'water_drop',
    ),
    CategoryModel(
      categoryId: 'sunscreen',
      categoryName: 'Sunscreen',
      defaultPaoMonths: 12,
      iconName: 'wb_sunny',
    ),
    CategoryModel(
      categoryId: 'mascara',
      categoryName: 'Mascara',
      defaultPaoMonths: 3,
      iconName: 'visibility',
    ),
    CategoryModel(
      categoryId: 'foundation',
      categoryName: 'Foundation',
      defaultPaoMonths: 12,
      iconName: 'brush',
    ),
    CategoryModel(
      categoryId: 'lipstick',
      categoryName: 'Lipstick',
      defaultPaoMonths: 24,
      iconName: 'favorite',
    ),
    CategoryModel(
      categoryId: 'moisturizer',
      categoryName: 'Moisturizer',
      defaultPaoMonths: 12,
      iconName: 'spa',
    ),
    CategoryModel(
      categoryId: 'cleanser',
      categoryName: 'Cleanser',
      defaultPaoMonths: 12,
      iconName: 'soap',
    ),
    CategoryModel(
      categoryId: 'toner',
      categoryName: 'Toner',
      defaultPaoMonths: 12,
      iconName: 'opacity',
    ),
    CategoryModel(
      categoryId: 'eye_cream',
      categoryName: 'Eye Cream',
      defaultPaoMonths: 6,
      iconName: 'remove_red_eye',
    ),
    CategoryModel(
      categoryId: 'fragrance',
      categoryName: 'Perfume / Fragrance',
      defaultPaoMonths: 36,
      iconName: 'local_florist',
    ),
    CategoryModel(
      categoryId: 'other',
      categoryName: 'Other / Misc',
      defaultPaoMonths: 12,
      iconName: 'category',
    ),
  ];
}
