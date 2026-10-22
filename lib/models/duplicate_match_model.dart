import 'vanity_item_model.dart';

enum DuplicateSource { personal, householdShared }

enum DuplicateMatchType {
  exactBarcode, // same barcode (UPC-A / EAN-13 spellings treated as equal)
  normalizedBrandAndName, // same brand and name; sizes equal or not recorded
  sameNameDifferentSize, // same brand and name but a different recorded size
  sameNameBrandMissing, // same name; the brand is missing on one side
}

class DuplicateMatch {
  final VanityItemModel item;
  final DuplicateSource source;
  final DuplicateMatchType matchType;

  /// Owner's e-mail, only for household items and only when the household record
  /// (which members can already see) lists it.
  final String? ownerEmail;

  const DuplicateMatch({
    required this.item,
    required this.source,
    required this.matchType,
    this.ownerEmail,
  });

  bool get isPersonal => source == DuplicateSource.personal;
  bool get isHousehold => source == DuplicateSource.householdShared;

  /// Barcode matches and brand+name+size matches are treated as the same product;
  /// the others are only possibly the same (different size, missing brand).
  bool get isLikelySame =>
      matchType == DuplicateMatchType.exactBarcode || matchType == DuplicateMatchType.normalizedBrandAndName;

  /// "Strong match" (barcode, or same brand+name+size) or "Possible match".
  String get strengthLabel => isLikelySame ? 'Strong match' : 'Possible match';

  /// Whose item it is, in words the user can act on.
  String get whoseLabel {
    if (isPersonal) {
      return item.isSharedWithHousehold ? 'Yours (shared with your household)' : 'Yours (private)';
    }
    return ownerEmail != null && ownerEmail!.isNotEmpty ? 'Shared by $ownerEmail' : 'Shared by a household member';
  }

  /// Size/variant text of the existing item, when recorded.
  String? get sizeLabel => item.product?.volume?.trim().isNotEmpty == true ? item.product!.volume : null;

  String get matchDescription {
    switch (matchType) {
      case DuplicateMatchType.exactBarcode:
        return 'Exact barcode match';
      case DuplicateMatchType.normalizedBrandAndName:
        return 'Brand & product name match';
      case DuplicateMatchType.sameNameDifferentSize:
        return 'Same name, different size: possibly a different product';
      case DuplicateMatchType.sameNameBrandMissing:
        return 'Same name (brand not recorded on both): possibly the same product';
    }
  }
}
