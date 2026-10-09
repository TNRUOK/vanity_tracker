import 'product_model.dart';

enum VanityStatus {
  unopened,
  active,
  expiringSoon,
  expired,
  finished,
}

class VanityItemModel {
  final String vanityItemId;
  final String productId;
  final String userId;
  final DateTime? openedDate;
  final DateTime? expiryDate;
  final String status; // 'unopened', 'active', 'expiring', 'expired', 'finished'
  final double? price;
  final DateTime? finishedDate;
  final bool? wouldRepurchase;
  final String? notes;
  final ProductModel? product;

  const VanityItemModel({
    required this.vanityItemId,
    required this.productId,
    required this.userId,
    this.openedDate,
    this.expiryDate,
    this.status = 'unopened',
    this.price,
    this.finishedDate,
    this.wouldRepurchase,
    this.notes,
    this.product,
  });

  /// Compute expiry date based on openedDate and paoMonths
  static DateTime computeExpiryDate(DateTime openedDate, int paoMonths) {
    // Exact month addition
    final newYear = openedDate.year + ((openedDate.month + paoMonths - 1) ~/ 12);
    final newMonth = ((openedDate.month + paoMonths - 1) % 12) + 1;
    // Handle days overflow for shorter months
    final lastDayOfNewMonth = DateTime(newYear, newMonth + 1, 0).day;
    final newDay = openedDate.day > lastDayOfNewMonth ? lastDayOfNewMonth : openedDate.day;
    return DateTime(newYear, newMonth, newDay, openedDate.hour, openedDate.minute);
  }

  /// Days remaining until expiry (negative if expired)
  int? get daysUntilExpiry {
    if (expiryDate == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiryDay = DateTime(expiryDate!.year, expiryDate!.month, expiryDate!.day);
    return expiryDay.difference(today).inDays;
  }

  /// Days the product has been used
  int get daysUsed {
    if (openedDate == null) return 0;
    final startDate = DateTime(openedDate!.year, openedDate!.month, openedDate!.day);
    final endDate = finishedDate != null
        ? DateTime(finishedDate!.year, finishedDate!.month, finishedDate!.day)
        : DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final diff = endDate.difference(startDate).inDays;
    return diff <= 0 ? 1 : diff; // Minimum 1 day
  }

  /// Cost per day calculation (price / daysUsed)
  double? get costPerDay {
    if (price == null || price! <= 0) return null;
    final days = daysUsed;
    if (days <= 0) return price;
    return price! / days;
  }

  /// Expiry progress from 0.0 (freshly opened) to 1.0 (expired)
  double get expiryProgress {
    if (openedDate == null || expiryDate == null) return 0.0;
    final totalDuration = expiryDate!.difference(openedDate!).inMilliseconds;
    if (totalDuration <= 0) return 1.0;
    final elapsed = DateTime.now().difference(openedDate!).inMilliseconds;
    if (elapsed <= 0) return 0.0;
    if (elapsed >= totalDuration) return 1.0;
    return elapsed / totalDuration;
  }

  /// Evaluated status based on dates
  VanityStatus get computedStatus {
    if (finishedDate != null || status == 'finished') {
      return VanityStatus.finished;
    }
    if (openedDate == null || expiryDate == null) {
      return VanityStatus.unopened;
    }
    final days = daysUntilExpiry ?? 0;
    if (days < 0) {
      return VanityStatus.expired;
    } else if (days <= 30) {
      return VanityStatus.expiringSoon;
    } else {
      return VanityStatus.active;
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'vanity_item_id': vanityItemId,
      'product_id': productId,
      'user_id': userId,
      'opened_date': openedDate?.toIso8601String(),
      'expiry_date': expiryDate?.toIso8601String(),
      'status': status,
      'price': price,
      'finished_date': finishedDate?.toIso8601String(),
      'would_repurchase': wouldRepurchase,
      'notes': notes,
      if (product != null) 'product': product!.toMap(),
    };
  }

  factory VanityItemModel.fromMap(Map<String, dynamic> map, [String? id]) {
    final openedStr = map['opened_date'];
    final expiryStr = map['expiry_date'];
    final finishedStr = map['finished_date'];

    return VanityItemModel(
      vanityItemId: id ?? map['vanity_item_id'] ?? '',
      productId: map['product_id'] ?? '',
      userId: map['user_id'] ?? '',
      openedDate: openedStr != null ? DateTime.tryParse(openedStr) : null,
      expiryDate: expiryStr != null ? DateTime.tryParse(expiryStr) : null,
      status: map['status'] ?? 'unopened',
      price: (map['price'] as num?)?.toDouble(),
      finishedDate: finishedStr != null ? DateTime.tryParse(finishedStr) : null,
      wouldRepurchase: map['would_repurchase'] as bool?,
      notes: map['notes'],
      product: map['product'] != null ? ProductModel.fromMap(Map<String, dynamic>.from(map['product'])) : null,
    );
  }

  VanityItemModel copyWith({
    String? vanityItemId,
    String? productId,
    String? userId,
    DateTime? openedDate,
    DateTime? expiryDate,
    String? status,
    double? price,
    DateTime? finishedDate,
    bool? wouldRepurchase,
    String? notes,
    ProductModel? product,
  }) {
    return VanityItemModel(
      vanityItemId: vanityItemId ?? this.vanityItemId,
      productId: productId ?? this.productId,
      userId: userId ?? this.userId,
      openedDate: openedDate ?? this.openedDate,
      expiryDate: expiryDate ?? this.expiryDate,
      status: status ?? this.status,
      price: price ?? this.price,
      finishedDate: finishedDate ?? this.finishedDate,
      wouldRepurchase: wouldRepurchase ?? this.wouldRepurchase,
      notes: notes ?? this.notes,
      product: product ?? this.product,
    );
  }
}
