/// Retail barcode symbologies the app handles.
enum RetailFormat { ean8, upcE, upcA, ean13, gtin14 }

/// Outcome of checking one barcode value (camera read or typed).
class BarcodeCheck {
  /// The value as received (camera raw value or typed text), never altered.
  final String raw;

  /// Digits to look up: the value itself, or the UPC-A expansion of a UPC-E code.
  /// Null when [raw] is not a retail product barcode at all.
  final String? lookupDigits;
  final RetailFormat? format;
  final bool checkDigitValid;

  const BarcodeCheck({required this.raw, this.lookupDigits, this.format, this.checkDigitValid = false});

  bool get isRetailBarcode => lookupDigits != null;
  bool get isUsable => isRetailBarcode && checkDigitValid;

  String get formatLabel => switch (format) {
        RetailFormat.ean8 => 'EAN-8',
        RetailFormat.upcE => 'UPC-E',
        RetailFormat.upcA => 'UPC-A',
        RetailFormat.ean13 => 'EAN-13',
        RetailFormat.gtin14 => 'GTIN-14',
        null => 'unknown',
      };
}

/// Lets exactly one camera detection through until [reset] is called.
///
/// Cameras report the same barcode many times per second (and a frame can contain
/// several codes); without this gate each report would start another lookup and
/// another tab switch. Reads whose check digit fails are NOT accepted (the decoder
/// probably misread a bar); scanning simply continues, and [lastRejected] records it.
class BarcodeScanGate {
  bool _busy = false;

  bool get isBusy => _busy;

  /// The most recent read that was skipped because its check digit failed.
  BarcodeCheck? lastRejected;

  /// Returns the first usable retail barcode among [reads] (value + format reported by
  /// the decoder; the format may be null) and closes the gate, or null.
  BarcodeCheck? acceptReads(Iterable<({String? value, RetailFormat? format})> reads) {
    if (_busy) return null;
    for (final r in reads) {
      if (r.value == null) continue;
      final check = BarcodeUtils.check(r.value!, format: r.format);
      if (!check.isRetailBarcode) continue;
      if (!check.checkDigitValid) {
        lastRejected = check;
        continue;
      }
      _busy = true;
      return check;
    }
    return null;
  }

  /// Convenience for values without a reported format. Returns the digits to look up.
  String? accept(Iterable<String?> rawValues) =>
      acceptReads(rawValues.map((v) => (value: v, format: null)))?.lookupDigits;

  /// Re-opens the gate (e.g. when the user returns to the scanner to scan again).
  void reset() => _busy = false;
}

/// Helpers for retail product barcodes (EAN-8, UPC-E, UPC-A, EAN-13, GTIN-14).
class BarcodeUtils {
  BarcodeUtils._();

  static const retailLengths = {8, 12, 13, 14};

  /// Returns the barcode as digits only (spaces/dashes removed), or null when the value
  /// is not a retail product barcode (e.g. a QR code URL, letters, wrong length).
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || !RegExp(r'^[\d\s-]+$').hasMatch(trimmed)) return null;
    final digits = trimmed.replaceAll(RegExp(r'[\s-]'), '');
    return retailLengths.contains(digits.length) ? digits : null;
  }

  /// GS1 mod-10 check digit validation (same rule for EAN-8/UPC-A/EAN-13/GTIN-14).
  /// A UPC-E code must be expanded first ([expandUpcE]); see [check].
  static bool hasValidCheckDigit(String digits) {
    if (!RegExp(r'^\d+$').hasMatch(digits) || digits.length < 8) return false;
    final body = digits.substring(0, digits.length - 1).split('').map(int.parse).toList().reversed.toList();
    var sum = 0;
    for (var i = 0; i < body.length; i++) {
      sum += body[i] * (i.isEven ? 3 : 1);
    }
    return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
  }

  /// Expands an 8-digit UPC-E code (number system 0 or 1 + 6 data digits + check digit)
  /// into its 12-digit UPC-A form (GS1 zero-suppression rules). Returns null when [upce]
  /// is not a UPC-E code. The check digit is carried over unchanged, never recomputed.
  static String? expandUpcE(String upce) {
    if (!RegExp(r'^[01]\d{7}$').hasMatch(upce)) return null;
    final ns = upce[0];
    final d = upce.substring(1, 7);
    final check = upce[7];
    final String body;
    switch (d[5]) {
      case '0':
      case '1':
      case '2':
        body = '${d.substring(0, 2)}${d[5]}0000${d.substring(2, 5)}';
      case '3':
        body = '${d.substring(0, 3)}00000${d.substring(3, 5)}';
      case '4':
        body = '${d.substring(0, 4)}00000${d[4]}';
      default:
        body = '${d.substring(0, 5)}0000${d[5]}';
    }
    return '$ns$body$check';
  }

  /// Identifies the format of [raw] and validates its check digit with that format's
  /// rule. [format] is what a camera decoder reported (null for typed input). An 8-digit
  /// value without a reported format is EAN-8 when its check digit fits EAN-8, otherwise
  /// UPC-E when it fits that. Digits are never changed or guessed.
  static BarcodeCheck check(String raw, {RetailFormat? format}) {
    final digits = normalize(raw);
    if (digits == null) return BarcodeCheck(raw: raw);
    if (digits.length == 8) {
      final upcA = expandUpcE(digits);
      if (format == RetailFormat.upcE || (format == null && !hasValidCheckDigit(digits) && upcA != null && hasValidCheckDigit(upcA))) {
        return BarcodeCheck(
          raw: raw,
          lookupDigits: upcA ?? digits,
          format: RetailFormat.upcE,
          checkDigitValid: upcA != null && hasValidCheckDigit(upcA),
        );
      }
      return BarcodeCheck(raw: raw, lookupDigits: digits, format: RetailFormat.ean8, checkDigitValid: hasValidCheckDigit(digits));
    }
    final f = switch (digits.length) { 12 => RetailFormat.upcA, 13 => RetailFormat.ean13, _ => RetailFormat.gtin14 };
    return BarcodeCheck(raw: raw, lookupDigits: digits, format: f, checkDigitValid: hasValidCheckDigit(digits));
  }

  /// Equivalent spellings of the same product code, most specific first:
  /// a UPC-A (12 digits) is the same product as the EAN-13 with a leading 0.
  static List<String> equivalents(String digits) {
    final out = <String>[digits];
    if (digits.length == 12) out.add('0$digits');
    if (digits.length == 13 && digits.startsWith('0')) out.add(digits.substring(1));
    return out;
  }

  /// True when [a] and [b] identify the same product (leading zeros of the GTIN
  /// padding are not significant: 041554420616 = 0041554420616).
  static bool sameProduct(String a, String b) {
    String key(String s) => s.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+'), '');
    final ka = key(a), kb = key(b);
    return ka.isNotEmpty && ka == kb;
  }
}
