class WishlistItemModel {
  final String wishlistId;
  final String userId;
  final String name;
  final String brand;
  final String categoryId;
  final String? barcode;
  final double? targetPrice;
  final String? notes;
  final String? productUrl;
  final DateTime createdAt;

  const WishlistItemModel({
    required this.wishlistId,
    required this.userId,
    required this.name,
    this.brand = '',
    this.categoryId = 'other',
    this.barcode,
    this.targetPrice,
    this.notes,
    this.productUrl,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'wishlist_id': wishlistId,
      'user_id': userId,
      'name': name,
      'brand': brand,
      'category_id': categoryId,
      'barcode': barcode,
      'target_price': targetPrice,
      'notes': notes,
      'product_url': productUrl,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory WishlistItemModel.fromMap(Map<String, dynamic> map, [String? id]) {
    return WishlistItemModel(
      wishlistId: id ?? map['wishlist_id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      brand: map['brand']?.toString() ?? '',
      categoryId: map['category_id']?.toString() ?? 'other',
      barcode: map['barcode']?.toString(),
      targetPrice: (map['target_price'] as num?)?.toDouble(),
      notes: map['notes']?.toString(),
      productUrl: map['product_url']?.toString(),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  WishlistItemModel copyWith({
    String? wishlistId,
    String? userId,
    String? name,
    String? brand,
    String? categoryId,
    String? barcode,
    bool clearBarcode = false,
    double? targetPrice,
    bool clearTargetPrice = false,
    String? notes,
    bool clearNotes = false,
    String? productUrl,
    bool clearProductUrl = false,
    DateTime? createdAt,
  }) {
    return WishlistItemModel(
      wishlistId: wishlistId ?? this.wishlistId,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      categoryId: categoryId ?? this.categoryId,
      barcode: clearBarcode ? null : (barcode ?? this.barcode),
      targetPrice: clearTargetPrice ? null : (targetPrice ?? this.targetPrice),
      notes: clearNotes ? null : (notes ?? this.notes),
      productUrl: clearProductUrl ? null : (productUrl ?? this.productUrl),
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WishlistItemModel &&
          runtimeType == other.runtimeType &&
          wishlistId == other.wishlistId &&
          userId == other.userId &&
          name == other.name &&
          brand == other.brand &&
          barcode == other.barcode;

  @override
  int get hashCode =>
      wishlistId.hashCode ^ userId.hashCode ^ name.hashCode ^ (barcode ?? '').hashCode;
}
