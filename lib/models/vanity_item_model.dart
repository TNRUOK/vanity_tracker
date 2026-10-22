import 'date_precision.dart';
import 'product_model.dart';

export 'date_precision.dart';

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
  final DateTime? sealedExpiryDate; // Factory sealed/batch expiration date
  /// Whether [sealedExpiryDate] has a day or only a month ("EXP 10/2027").
  final DatePrecision sealedExpiryPrecision;
  final String status; // 'unopened', 'active', 'expiring', 'expired', 'finished'
  final double? price;

  /// ISO 4217 code of [price] (stored as `price_currency`). Null on items saved before it
  /// was recorded: the amount is kept as is and never assumed to be in any currency.
  final String? priceCurrency;
  final DateTime? finishedDate;
  final bool? wouldRepurchase;
  final ProductModel? product;
  final List<String> routineTags; // e.g. ['AM', 'PM', 'Weekly']
  final String? notes;
  final String? batchCode; // Confirmed product batch/lot code
  final DateTime? manufacturingDate; // Stamped or decoded manufacturing date
  final DatePrecision manufacturingDatePrecision;
  final bool isSharedWithHousehold; // Explicit user opt-in to share with household
  final String? sharedHouseholdId; // Household ID where this item is shared

  const VanityItemModel({
    required this.vanityItemId,
    required this.productId,
    required this.userId,
    this.openedDate,
    this.expiryDate,
    this.sealedExpiryDate,
    this.sealedExpiryPrecision = DatePrecision.day,
    this.manufacturingDatePrecision = DatePrecision.day,
    this.status = 'unopened',
    this.price,
    this.priceCurrency,
    this.finishedDate,
    this.wouldRepurchase,
    this.notes,
    this.product,
    this.routineTags = const [],
    this.batchCode,
    this.manufacturingDate,
    this.isSharedWithHousehold = false,
    this.sharedHouseholdId,
  });

  /// Compute expiry date based on openedDate and paoMonths.
  ///
  /// Date rule: the same day of the month, [paoMonths] calendar months later. When that
  /// month is shorter, the last day of the month is used (Jan 31 + 1 month = Feb 28, or
  /// Feb 29 in a leap year; Feb 29 + 12 months = Feb 28).
  static DateTime computeExpiryDate(DateTime openedDate, int paoMonths) {
    // Exact month addition
    final newYear = openedDate.year + ((openedDate.month + paoMonths - 1) ~/ 12);
    final newMonth = ((openedDate.month + paoMonths - 1) % 12) + 1;
    // Handle days overflow for shorter months
    final lastDayOfNewMonth = DateTime(newYear, newMonth + 1, 0).day;
    final newDay = openedDate.day > lastDayOfNewMonth ? lastDayOfNewMonth : openedDate.day;
    return DateTime(newYear, newMonth, newDay, openedDate.hour, openedDate.minute);
  }

  /// PAO-based expiry, or null when the product is unopened or its PAO is unknown.
  /// This is the single place PAO expiry is derived; never from the purchase date.
  static DateTime? paoExpiryFor(DateTime? openedDate, ProductModel? product) {
    final months = product?.knownPaoMonths;
    if (openedDate == null || months == null) return null;
    return computeExpiryDate(openedDate, months);
  }

  /// Copy with [expiryDate] and [status] derived again from the opening date and PAO.
  /// The opening date, purchase data and sealed expiry are left unchanged.
  VanityItemModel withRecalculatedExpiry() {
    final expiry = paoExpiryFor(openedDate, product);
    final recalculated = copyWith(expiryDate: expiry, clearExpiryDate: expiry == null);
    if (recalculated.status == 'finished' || recalculated.finishedDate != null) return recalculated;
    return recalculated.copyWith(status: recalculated.computedStatusString);
  }

  /// [computedStatus] in the string form stored in `status`.
  String get computedStatusString => switch (computedStatus) {
        VanityStatus.finished => 'finished',
        VanityStatus.expired => 'expired',
        VanityStatus.expiringSoon => 'expiring',
        VanityStatus.active => 'active',
        VanityStatus.unopened => 'unopened',
      };

  /// Effective expiry date: earlier of PAO expiry and factory sealed expiry
  DateTime? get effectiveExpiryDate {
    if (expiryDate != null && sealedExpiryDate != null) {
      return expiryDate!.isBefore(sealedExpiryDate!) ? expiryDate : sealedExpiryDate;
    }
    return expiryDate ?? sealedExpiryDate;
  }

  /// Days remaining until expiry (negative if expired)
  int? get daysUntilExpiry {
    final effective = effectiveExpiryDate;
    if (effective == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiryDay = DateTime(effective.year, effective.month, effective.day);
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

  /// Alias for [daysUsed]
  int get daysInUse => daysUsed;

  /// Cost per day calculation (price / daysUsed)
  double? get costPerDay {
    if (price == null || price! <= 0) return null;
    final days = daysUsed;
    if (days <= 0) return price;
    return price! / days;
  }

  /// Expiry progress from 0.0 (freshly opened) to 1.0 (expired)
  double get expiryProgress {
    final effective = effectiveExpiryDate;
    if (openedDate == null || effective == null) return 0.0;
    final totalDuration = effective.difference(openedDate!).inMilliseconds;
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
    if (openedDate == null) {
      if (sealedExpiryDate != null) {
        final days = daysUntilExpiry ?? 0;
        if (days < 0) return VanityStatus.expired;
        if (days <= 30) return VanityStatus.expiringSoon;
      }
      return VanityStatus.unopened;
    }
    // Opened but no expiry known (PAO unknown, no sealed date): in use, not "expiring".
    if (effectiveExpiryDate == null) return VanityStatus.active;
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
      'sealed_expiry_date': sealedExpiryDate?.toIso8601String(),
      if (sealedExpiryDate != null && sealedExpiryPrecision == DatePrecision.month) 'sealed_expiry_precision': 'month',
      'status': status,
      'price': price,
      if (priceCurrency != null) 'price_currency': priceCurrency,
      'finished_date': finishedDate?.toIso8601String(),
      'would_repurchase': wouldRepurchase,
      'notes': notes,
      'routine_tags': routineTags,
      'batch_code': batchCode,
      'manufacturing_date': manufacturingDate?.toIso8601String(),
      if (manufacturingDate != null && manufacturingDatePrecision == DatePrecision.month)
        'manufacturing_date_precision': 'month',
      'is_shared_with_household': isSharedWithHousehold,
      'shared_household_id': sharedHouseholdId,
      if (product != null) 'product': product!.toMap(),
    };
  }

  factory VanityItemModel.fromMap(Map<String, dynamic> map, [String? id]) {
    final openedStr = map['opened_date'];
    final expiryStr = map['expiry_date'];
    final sealedStr = map['sealed_expiry_date'];
    final finishedStr = map['finished_date'];
    final mfgStr = map['manufacturing_date'];
    final tagsList = (map['routine_tags'] as List?)?.map((e) => e.toString()).toList() ??
        (map['routineTags'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];

    return VanityItemModel(
      vanityItemId: id ?? map['vanity_item_id'] ?? '',
      productId: map['product_id'] ?? '',
      userId: map['user_id'] ?? '',
      openedDate: openedStr != null ? DateTime.tryParse(openedStr) : null,
      expiryDate: expiryStr != null ? DateTime.tryParse(expiryStr) : null,
      sealedExpiryDate: sealedStr != null ? DateTime.tryParse(sealedStr) : null,
      sealedExpiryPrecision: DatePrecision.fromStorage(map['sealed_expiry_precision']),
      manufacturingDatePrecision: DatePrecision.fromStorage(map['manufacturing_date_precision']),
      status: map['status'] ?? 'unopened',
      price: (map['price'] as num?)?.toDouble(),
      priceCurrency: map['price_currency'] as String?,
      finishedDate: finishedStr != null ? DateTime.tryParse(finishedStr) : null,
      wouldRepurchase: map['would_repurchase'] as bool?,
      notes: map['notes'],
      product: map['product'] != null ? ProductModel.fromMap(Map<String, dynamic>.from(map['product'])) : null,
      routineTags: tagsList,
      batchCode: map['batch_code'],
      manufacturingDate: mfgStr != null ? DateTime.tryParse(mfgStr) : null,
      isSharedWithHousehold: map['is_shared_with_household'] as bool? ?? false,
      sharedHouseholdId: map['shared_household_id'] as String?,
    );
  }

  VanityItemModel copyWith({
    String? vanityItemId,
    String? productId,
    String? userId,
    DateTime? openedDate,
    bool clearOpenedDate = false,
    DateTime? expiryDate,
    bool clearExpiryDate = false,
    DateTime? sealedExpiryDate,
    bool clearSealedExpiryDate = false,
    DatePrecision? sealedExpiryPrecision,
    DatePrecision? manufacturingDatePrecision,
    String? status,
    double? price,
    String? priceCurrency,
    DateTime? finishedDate,
    bool clearFinishedDate = false,
    bool? wouldRepurchase,
    bool clearRepurchase = false,
    String? notes,
    ProductModel? product,
    List<String>? routineTags,
    String? batchCode,
    bool clearBatchCode = false,
    DateTime? manufacturingDate,
    bool clearManufacturingDate = false,
    bool? isSharedWithHousehold,
    String? sharedHouseholdId,
    bool clearSharedHouseholdId = false,
  }) {
    return VanityItemModel(
      vanityItemId: vanityItemId ?? this.vanityItemId,
      productId: productId ?? this.productId,
      userId: userId ?? this.userId,
      openedDate: clearOpenedDate ? null : (openedDate ?? this.openedDate),
      expiryDate: clearExpiryDate ? null : (expiryDate ?? this.expiryDate),
      sealedExpiryDate: clearSealedExpiryDate ? null : (sealedExpiryDate ?? this.sealedExpiryDate),
      sealedExpiryPrecision: sealedExpiryPrecision ?? this.sealedExpiryPrecision,
      manufacturingDatePrecision: manufacturingDatePrecision ?? this.manufacturingDatePrecision,
      status: status ?? this.status,
      price: price ?? this.price,
      priceCurrency: priceCurrency ?? this.priceCurrency,
      finishedDate: clearFinishedDate ? null : (finishedDate ?? this.finishedDate),
      wouldRepurchase: clearRepurchase ? null : (wouldRepurchase ?? this.wouldRepurchase),
      notes: notes ?? this.notes,
      product: product ?? this.product,
      routineTags: routineTags ?? this.routineTags,
      batchCode: clearBatchCode ? null : (batchCode ?? this.batchCode),
      manufacturingDate: clearManufacturingDate ? null : (manufacturingDate ?? this.manufacturingDate),
      isSharedWithHousehold: isSharedWithHousehold ?? this.isSharedWithHousehold,
      sharedHouseholdId: clearSharedHouseholdId ? null : (sharedHouseholdId ?? this.sharedHouseholdId),
    );
  }
}
