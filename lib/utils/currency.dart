/// ISO 4217 currencies the app records amounts in. Money is identified by its code; the
/// symbol is only for display (several currencies share "$" or "¥").
class CurrencyInfo {
  final String code;
  final String symbol;
  final String name;

  /// ISO 4217 minor-unit digits (2 for USD/INR/..., 0 for JPY).
  final int minorDigits;

  const CurrencyInfo(this.code, this.symbol, this.name, this.minorDigits);

  int get minorFactor => _pow10(minorDigits);

  /// [amount] (as stored, a decimal number) in integer minor units, rounded half away
  /// from zero. All sums are done on these integers.
  int toMinor(double amount) => roundHalfAwayFromZero(amount * minorFactor);

  double fromMinor(int minor) => minor / minorFactor;

  /// "₹1,234.50" style text for an amount in minor units.
  String format(int minor) {
    final negative = minor < 0;
    final abs = minor.abs();
    final whole = abs ~/ minorFactor;
    final frac = abs % minorFactor;
    final grouped = whole.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final text = minorDigits == 0 ? grouped : '$grouped.${frac.toString().padLeft(minorDigits, '0')}';
    return '${negative ? '-' : ''}$symbol$text';
  }

  String formatAmount(double amount) => format(toMinor(amount));

  String get label => '$name ($code, $symbol)';
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

int roundHalfAwayFromZero(double v) => v < 0 ? -((-v) + 0.5).floor() : (v + 0.5).floor();

class Currencies {
  static const usd = CurrencyInfo('USD', '\$', 'US Dollar', 2);
  static const eur = CurrencyInfo('EUR', '€', 'Euro', 2);
  static const gbp = CurrencyInfo('GBP', '£', 'British Pound', 2);
  static const inr = CurrencyInfo('INR', '₹', 'Indian Rupee', 2);
  static const cad = CurrencyInfo('CAD', 'C\$', 'Canadian Dollar', 2);
  static const aud = CurrencyInfo('AUD', 'A\$', 'Australian Dollar', 2);
  static const jpy = CurrencyInfo('JPY', '¥', 'Japanese Yen', 0);

  /// The currencies offered in the app (all are published by the ECB, see
  /// ExchangeRateService). Order is the order shown in pickers.
  static const supported = [inr, usd, eur, gbp, cad, aud, jpy];

  static CurrencyInfo? byCode(String? code) {
    if (code == null) return null;
    final c = code.trim().toUpperCase();
    for (final info in supported) {
      if (info.code == c) return info;
    }
    return null;
  }

  /// Symbols that identify exactly one of the supported currencies. "$" (USD, CAD, AUD,
  /// MXN, ...) and "¥" (JPY or CNY; OCR also misreads ₹ as ¥) are deliberately absent.
  static const _unambiguousSymbols = {'₹': 'INR', '€': 'EUR', '£': 'GBP', 'C\$': 'CAD', 'A\$': 'AUD'};

  /// The code recorded by a stored currency value: an ISO code, or a symbol that names a
  /// single currency. Null when the value is ambiguous ("$", "¥") or unknown.
  static String? codeFromStored(String? stored) {
    if (stored == null) return null;
    final s = stored.trim();
    final byIso = byCode(s);
    if (byIso != null) return byIso.code;
    return _unambiguousSymbols[s];
  }

  /// The code the receipt form labelled a symbol with before codes were stored
  /// ("$ (USD)", "¥ (JPY)"). Only offered to the user as a suggestion to confirm.
  static String? suggestedCodeForLegacySymbol(String? stored) {
    final exact = codeFromStored(stored);
    if (exact != null) return exact;
    return switch (stored?.trim()) { '\$' => 'USD', '¥' => 'JPY', _ => null };
  }

  /// Display symbol for a code, or the code itself when it is not a supported currency.
  static String symbolFor(String? code) => byCode(code)?.symbol ?? (code ?? '');
}

/// Parses a user-entered money amount, accepting "24.00", "24,00" and "1,234.56".
double? parseAmountInput(String input) {
  var s = input.trim().replaceAll(RegExp(r'[\s\$€£₹¥]'), '');
  if (s.isEmpty) return null;
  if (s.contains(',') && !s.contains('.')) {
    s = s.replaceAll(',', '.');
  } else {
    s = s.replaceAll(',', '');
  }
  return double.tryParse(s);
}
/// [amount] in the currency [code] ("₹24.50"), or the bare number when the currency is not
/// recorded (no symbol is invented for it).
String formatInCurrency(String? code, double amount) =>
    Currencies.byCode(code)?.formatAmount(amount) ?? amount.toStringAsFixed(2);