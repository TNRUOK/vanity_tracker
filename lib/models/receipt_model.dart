import '../utils/currency.dart';

class ReceiptItemModel {
  final String itemId;
  final String description;
  final int quantity;
  final double unitPrice;
  final double totalPrice;
  final String? matchedVanityItemId;
  final String? matchedProductId;
  final bool isConfirmed;

  const ReceiptItemModel({
    required this.itemId,
    required this.description,
    this.quantity = 1,
    required this.unitPrice,
    required this.totalPrice,
    this.matchedVanityItemId,
    this.matchedProductId,
    this.isConfirmed = true,
  });

  Map<String, dynamic> toMap() {
    return {
      'item_id': itemId,
      'description': description,
      'quantity': quantity,
      'unit_price': unitPrice,
      'total_price': totalPrice,
      'matched_vanity_item_id': matchedVanityItemId,
      'matched_product_id': matchedProductId,
      'is_confirmed': isConfirmed,
    };
  }

  factory ReceiptItemModel.fromMap(Map<String, dynamic> map) {
    return ReceiptItemModel(
      itemId: map['item_id']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 1,
      unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0.0,
      totalPrice: (map['total_price'] as num?)?.toDouble() ?? 0.0,
      matchedVanityItemId: map['matched_vanity_item_id']?.toString(),
      matchedProductId: map['matched_product_id']?.toString(),
      isConfirmed: map['is_confirmed'] as bool? ?? true,
    );
  }

  ReceiptItemModel copyWith({
    String? itemId,
    String? description,
    int? quantity,
    double? unitPrice,
    double? totalPrice,
    String? matchedVanityItemId,
    bool clearMatchedVanityItemId = false,
    String? matchedProductId,
    bool clearMatchedProductId = false,
    bool? isConfirmed,
  }) {
    return ReceiptItemModel(
      itemId: itemId ?? this.itemId,
      description: description ?? this.description,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      totalPrice: totalPrice ?? this.totalPrice,
      matchedVanityItemId: clearMatchedVanityItemId
          ? null
          : (matchedVanityItemId ?? this.matchedVanityItemId),
      matchedProductId: clearMatchedProductId
          ? null
          : (matchedProductId ?? this.matchedProductId),
      isConfirmed: isConfirmed ?? this.isConfirmed,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReceiptItemModel &&
          runtimeType == other.runtimeType &&
          itemId == other.itemId &&
          description == other.description &&
          totalPrice == other.totalPrice;

  @override
  int get hashCode => itemId.hashCode ^ description.hashCode ^ totalPrice.hashCode;
}

class ReceiptModel {
  final String receiptId;
  final String userId;
  final String merchant;
  final DateTime purchaseDate;

  /// Display symbol as entered ("$", "₹"). Older receipts only have this field.
  final String currency;

  /// ISO 4217 code of the amounts (stored as `currency_code`). Null on receipts saved
  /// before codes were recorded; see [effectiveCurrencyCode].
  final String? currencyCode;
  final double subtotal;
  final double taxAmount;
  final double discountAmount;
  final double totalAmount;
  final String? rawOcrText;
  final List<ReceiptItemModel> items;
  final DateTime createdAt;

  const ReceiptModel({
    required this.receiptId,
    required this.userId,
    required this.merchant,
    required this.purchaseDate,
    this.currency = '\$',
    this.currencyCode,
    required this.subtotal,
    this.taxAmount = 0.0,
    this.discountAmount = 0.0,
    required this.totalAmount,
    this.rawOcrText,
    this.items = const [],
    required this.createdAt,
  });

  /// Convenience aliases
  double get total => totalAmount;
  double get tax => taxAmount;
  double get discount => discountAmount;

  /// The currency the amounts are in: the stored code, else a stored symbol that names a
  /// single currency (₹, €, £). Null when it cannot be established ("$", "¥" alone): such
  /// receipts are kept as they are and the user is asked to confirm the currency.
  String? get effectiveCurrencyCode => Currencies.byCode(currencyCode)?.code ?? Currencies.codeFromStored(currency);

  /// Symbol for showing this receipt's amounts.
  String get displaySymbol => effectiveCurrencyCode != null ? Currencies.symbolFor(effectiveCurrencyCode) : currency;

  /// True if any line item in this receipt is associated with an active/finished vanity item
  bool get hasLinkedInventoryItems =>
      items.any((i) => i.matchedVanityItemId != null && i.matchedVanityItemId!.isNotEmpty);

  /// Total sum calculated strictly from confirmed line items
  double get confirmedItemsTotal =>
      items.where((i) => i.isConfirmed).fold(0.0, (sum, i) => sum + i.totalPrice);

  Map<String, dynamic> toMap() {
    return {
      'receipt_id': receiptId,
      'user_id': userId,
      'merchant': merchant,
      'purchase_date': purchaseDate.toIso8601String(),
      'currency': currency,
      if (currencyCode != null) 'currency_code': currencyCode,
      'subtotal': subtotal,
      'tax_amount': taxAmount,
      'discount_amount': discountAmount,
      'total_amount': totalAmount,
      'raw_ocr_text': rawOcrText,
      'items': items.map((i) => i.toMap()).toList(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory ReceiptModel.fromMap(Map<String, dynamic> map, [String? id]) {
    final rawItems = map['items'] as List<dynamic>? ?? [];
    final parsedItems = rawItems
        .map((i) => ReceiptItemModel.fromMap(Map<String, dynamic>.from(i)))
        .toList();

    return ReceiptModel(
      receiptId: id ?? map['receipt_id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      merchant: map['merchant']?.toString() ?? 'Store Purchase',
      purchaseDate: map['purchase_date'] != null
          ? DateTime.tryParse(map['purchase_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      currency: map['currency']?.toString() ?? '\$',
      currencyCode: map['currency_code']?.toString(),
      subtotal: (map['subtotal'] as num?)?.toDouble() ?? 0.0,
      taxAmount: (map['tax_amount'] as num?)?.toDouble() ?? 0.0,
      discountAmount: (map['discount_amount'] as num?)?.toDouble() ?? 0.0,
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0.0,
      rawOcrText: map['raw_ocr_text']?.toString(),
      items: parsedItems,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  ReceiptModel copyWith({
    String? receiptId,
    String? userId,
    String? merchant,
    DateTime? purchaseDate,
    String? currency,
    String? currencyCode,
    double? subtotal,
    double? taxAmount,
    double? discountAmount,
    double? totalAmount,
    String? rawOcrText,
    List<ReceiptItemModel>? items,
    DateTime? createdAt,
  }) {
    return ReceiptModel(
      receiptId: receiptId ?? this.receiptId,
      userId: userId ?? this.userId,
      merchant: merchant ?? this.merchant,
      purchaseDate: purchaseDate ?? this.purchaseDate,
      currency: currency ?? this.currency,
      currencyCode: currencyCode ?? this.currencyCode,
      subtotal: subtotal ?? this.subtotal,
      taxAmount: taxAmount ?? this.taxAmount,
      discountAmount: discountAmount ?? this.discountAmount,
      totalAmount: totalAmount ?? this.totalAmount,
      rawOcrText: rawOcrText ?? this.rawOcrText,
      items: items ?? this.items,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
