import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../models/receipt_model.dart';
import 'ocr/receipt_ocr_service.dart';

class ParsedReceiptDraft {
  final String receiptId;
  final String merchant;
  final DateTime purchaseDate;
  final bool isDateAmbiguous;
  final DateTime? alternateDate;
  final String currency;
  final double subtotal;
  final double tax;
  final double discount;
  final double total;
  final List<ReceiptItemModel> items;
  final String rawText;
  final List<String> warnings;

  /// False when no date was found on the receipt and today's date was assumed.
  final bool dateDetected;

  /// False when no currency marker was found and the user's default was assumed.
  final bool currencyDetected;

  const ParsedReceiptDraft({
    required this.receiptId,
    required this.merchant,
    required this.purchaseDate,
    this.isDateAmbiguous = false,
    this.alternateDate,
    required this.currency,
    required this.subtotal,
    required this.tax,
    required this.discount,
    required this.total,
    required this.items,
    required this.rawText,
    this.warnings = const [],
    this.dateDetected = true,
    this.currencyDetected = true,
  });

  bool get hasItems => items.isNotEmpty;
  bool get hasTotal => total > 0;
}

class _Amount {
  final int start;
  final int end;
  final double value;
  final bool negative;
  final bool wholeNumber;
  final bool bare; // no currency marker and no decimals

  const _Amount(this.start, this.end, this.value, {this.negative = false, this.wholeNumber = false, this.bare = false});
}

class _DateCandidate {
  final DateTime date;
  final DateTime? alternate;
  const _DateCandidate(this.date, [this.alternate]);
}

class ReceiptParserService {
  static const _uuid = Uuid();

  /// Extract text from image using platform-aware on-device OCR (Google ML Kit on mobile, Tesseract.js on Web)
  static Future<String> extractTextFromImage(String imagePath) async {
    return await ReceiptOcrService.recognize(filePath: imagePath);
  }

  /// Platform-aware text extraction supporting either file path or raw bytes.
  /// Browsers provide only bytes (no path); both are passed through untouched.
  static Future<String> extractText({String? imagePath, Uint8List? imageBytes, String? mimeType}) async {
    return await ReceiptOcrService.recognize(filePath: imagePath, bytes: imageBytes, mimeType: mimeType);
  }

  /// Money amount with exactly two decimals, e.g. 24.00, $24.00, 1,234.56, 24,00, -5.00.
  /// Not preceded/followed by digits or separators, so dates like 12.10.2026 are not amounts.
  static final _amountRegex = RegExp(
    r'(?<![\d.,])(-)?\s*(?:(?:\b[CA])?\$|[€£₹¥])?\s*(\d{1,3}(?:[.,]\d{3})+|\d+)[.,](\d{2})(?![.,]?\d)',
  );

  /// Size/variant printed on its own line under a product: "150ml", "5oml" (OCR for 50ml), "1.7 fl oz".
  static final _sizeLine = RegExp(
    r'^(?:[\d.,]+[oO]?|[oO])\s?(?:ml|l|g|gm|kg|mg|oz|fl\.?\s?oz|pcs?|ct|caps|tabs)\.?$',
    caseSensitive: false,
  );

  static const _monthPattern =
      r'(JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUNE?|JULY?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?)\.?';

  /// Parses an amount found by [_amountRegex]; thousands separators are dropped.
  static double _amountOf(RegExpMatch m) {
    final whole = m.group(2)!.replaceAll(RegExp(r'[.,]'), '');
    return double.parse('$whole.${m.group(3)}');
  }

  /// Whole amounts that carry a currency marker: ₹250, $24, Rs. 1,050, ₹1,00,000.
  static final _currencyIntegerRegex = RegExp(
    r'(?<![\d.,])(-)?\s*(?:(?:\b[CA])?\$|[€£₹¥]|\b(?:Rs|RS|rs)\.?\s?|\bINR\s?)\s*(\d{1,3}(?:,\d{2,3})+|\d+)(?![.,]?\d)',
  );

  /// A bare whole number at the end of a line ("Cleanser 350"). Only trusted on
  /// receipts that print no decimal prices at all, and always flagged for review.
  static final _trailingIntegerRegex = RegExp(r'(?<![\d.,%])\b(\d{1,3}(?:,\d{2,3})+|\d{1,6})\s*$');

  /// Last-token amount whose currency sign OCR turned into a look-alike character
  /// (Tesseract's English model reads "₹" as "%", "X", "R", "z" ...): "Tax — X50".
  /// Always flagged for review.
  static final _glyphAmountRegex = RegExp(r'(?<=^|[\s—–\-:=])[%XxRz](\d{1,3}(?:,\d{2,3})+|\d+)\s*$');

  /// All money amounts in [line], in order. [allowBareInteger] also accepts a trailing
  /// whole number without a currency marker.
  static List<_Amount> _amountsIn(String line, {bool allowBareInteger = false}) {
    final found = <_Amount>[
      for (final m in _amountRegex.allMatches(line)) _Amount(m.start, m.end, _amountOf(m), negative: m.group(1) == '-'),
    ];
    bool overlaps(int s, int e) => found.any((a) => s < a.end && e > a.start);
    for (final m in _currencyIntegerRegex.allMatches(line)) {
      if (overlaps(m.start, m.end)) continue;
      found.add(
        _Amount(
          m.start,
          m.end,
          double.parse(m.group(2)!.replaceAll(',', '')),
          negative: m.group(1) == '-',
          wholeNumber: true,
        ),
      );
    }
    final looksLikeReference = RegExp(
      r'#|\b(?:store|shop|branch|tel|ph|phone|mob|mobile|gstin|bill|order|invoice|no|cashier|counter|till|pin|zip)\b\.?',
      caseSensitive: false,
    ).hasMatch(line);
    if (found.isEmpty && !looksLikeReference) {
      final g = _glyphAmountRegex.firstMatch(line);
      if (g != null) {
        found.add(
          _Amount(g.start, g.end, double.parse(g.group(1)!.replaceAll(',', '')), wholeNumber: true, bare: true),
        );
      }
    }
    if (allowBareInteger && found.isEmpty && !looksLikeReference) {
      final m = _trailingIntegerRegex.firstMatch(line);
      if (m != null && !overlaps(m.start, m.end)) {
        found.add(
          _Amount(m.start, m.end, double.parse(m.group(1)!.replaceAll(',', '')), wholeNumber: true, bare: true),
        );
      }
    }
    found.sort((a, b) => a.start.compareTo(b.start));
    return found;
  }

  static double? _lastAmount(String line) {
    final all = _amountsIn(line, allowBareInteger: true); // totals lines: "Subtotal 1000" is fine
    return all.isEmpty ? null : all.last.value;
  }

  /// Text before the first amount with separators like "—", "-", ":" and currency marks removed.
  static String _descriptionBefore(String line, int end) => line
      .substring(0, end)
      .trim()
      .replaceAll(RegExp(r'[\s\.\-_:—–=|\$€£₹¥]+$'), '')
      .replaceAll(RegExp(r'\b(?:Rs|RS|INR)\.?$'), '')
      .trim();

  static const _months = {
    'JAN': 1,
    'FEB': 2,
    'MAR': 3,
    'APR': 4,
    'MAY': 5,
    'JUN': 6,
    'JUL': 7,
    'AUG': 8,
    'SEP': 9,
    'OCT': 10,
    'NOV': 11,
    'DEC': 12,
  };

  /// Returns a DateTime only if year/month/day form a real calendar date.
  static DateTime? _validDate(int year, int month, int day) {
    if (year < 100) year += 2000;
    if (year < 1990 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) return null;
    final d = DateTime(year, month, day);
    return (d.month == month && d.day == day) ? d : null;
  }

  static _DateCandidate? _findDate(String line, {required bool preferDayFirst}) {
    // ISO: 2026-10-12, 2026/10/12, 2026.10.12
    final iso = RegExp(r'\b(\d{4})[\/\.-](\d{1,2})[\/\.-](\d{1,2})\b').firstMatch(line);
    if (iso != null) {
      final d = _validDate(int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
      if (d != null) return _DateCandidate(d);
    }

    // Textual: 12 Oct 2026, 12-OCT-26, Oct 12, 2026, October 12 2026
    final dayMonth = RegExp(
      '\\b(\\d{1,2})[\\s\\-\\.]*$_monthPattern\\b[\\s\\-,\\.]*(\\d{4}|\\d{2})\\b(?![.,]\\d)',
      caseSensitive: false,
    ).firstMatch(line);
    if (dayMonth != null) {
      final month = _months[dayMonth.group(2)!.substring(0, 3).toUpperCase()];
      if (month != null) {
        final d = _validDate(int.parse(dayMonth.group(3)!), month, int.parse(dayMonth.group(1)!));
        if (d != null) return _DateCandidate(d);
      }
    }
    final monthDay = RegExp(
      '\\b$_monthPattern\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b',
      caseSensitive: false,
    ).firstMatch(line);
    if (monthDay != null) {
      final month = _months[monthDay.group(1)!.substring(0, 3).toUpperCase()];
      if (month != null) {
        final d = _validDate(int.parse(monthDay.group(3)!), month, int.parse(monthDay.group(2)!));
        if (d != null) return _DateCandidate(d);
      }
    }

    // Numeric: 06/07/2026, 6-7-26, 31.12.2026
    final numeric = RegExp(r'\b(\d{1,2})[\/\.-](\d{1,2})[\/\.-](\d{4}|\d{2})\b').firstMatch(line);
    if (numeric != null) {
      final a = int.parse(numeric.group(1)!);
      final b = int.parse(numeric.group(2)!);
      final y = int.parse(numeric.group(3)!);
      final monthFirst = _validDate(y, a, b);
      final dayFirst = _validDate(y, b, a);
      if (monthFirst != null && dayFirst != null && a != b) {
        // Genuinely ambiguous: pick by locale hint, but keep the alternative for the user.
        return preferDayFirst ? _DateCandidate(dayFirst, monthFirst) : _DateCandidate(monthFirst, dayFirst);
      }
      final only = monthFirst ?? dayFirst;
      if (only != null) return _DateCandidate(only);
    }
    return null;
  }

  /// Conservative parsing of receipt text into a structured draft
  static ParsedReceiptDraft parseReceiptText(String rawText, {String defaultCurrency = '\$', String? existingDraftId}) {
    final stableId = existingDraftId ?? 'rec_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';
    if (rawText.trim().isEmpty) {
      return ParsedReceiptDraft(
        receiptId: stableId,
        merchant: 'Unidentified Merchant',
        purchaseDate: DateTime.now(),
        currency: defaultCurrency,
        subtotal: 0.0,
        tax: 0.0,
        discount: 0.0,
        total: 0.0,
        items: const [],
        rawText: '',
        warnings: const ['Receipt text is empty.'],
        dateDetected: false,
        currencyDetected: false,
      );
    }

    final lines = rawText
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim().replaceAll(RegExp(r'\s{2,}'), ' '))
        .where((l) => l.isNotEmpty)
        .toList();

    final warnings = <String>[];

    // 1. Detect Currency (explicit markers only; otherwise the user's default, flagged)
    final currencyMarkers = <String, RegExp>{
      'C\$': RegExp(r'\bC\$|\bCAD\b', caseSensitive: false),
      'A\$': RegExp(r'\bA\$|\bAUD\b', caseSensitive: false),
      '€': RegExp(r'€|\bEUR\b', caseSensitive: false),
      '£': RegExp(r'£|\bGBP\b', caseSensitive: false),
      '₹': RegExp(r'₹|\bINR\b|\bRs\.?\s?\d', caseSensitive: false),
      '¥': RegExp(r'¥|\bJPY\b', caseSensitive: false),
      '\$': RegExp(r'(?<![CA])\$|\bUSD\b', caseSensitive: false),
    };
    final found = currencyMarkers.entries.where((e) => e.value.hasMatch(rawText)).map((e) => e.key).toList();
    final currencyDetected = found.isNotEmpty;
    final detectedCurrency = currencyDetected ? found.first : defaultCurrency;
    if (!currencyDetected) {
      warnings.add('No currency symbol found on the receipt; assumed $defaultCurrency. Please confirm.');
    } else if (found.length > 1) {
      warnings.add(
        'Several currencies appear on the receipt (${found.join(', ')}); using $detectedCurrency. Please confirm.',
      );
    }

    // 2. Detect Merchant Name (first plausible text line near the top)
    String merchant = 'Store Purchase';
    for (int i = 0; i < lines.length && i < 5; i++) {
      final line = lines[i];
      if (RegExp(r'^[\d\s\-\/\.:#]+$').hasMatch(line)) continue;
      if (RegExp(
        r'\b(?:tel|phone|fax|order|receipt|invoice|date|www\.|https?:|\.com)\b',
        caseSensitive: false,
      ).hasMatch(line)) {
        continue;
      }
      if (_amountsIn(line).isNotEmpty) continue;
      if (_sizeLine.hasMatch(line.trim())) continue; // "150ml" is a product size, not a store
      if (_findDate(line, preferDayFirst: false) != null) continue;
      final cleaned = line
          .replaceAll(RegExp(r'^(?:welcome\s+to\s+)', caseSensitive: false), '')
          .replaceAll(RegExp(r'#\s*\d+'), '') // store/receipt number, e.g. "#000207"
          .replaceAll(RegExp(r'[*#=_~]+'), '')
          .trim();
      if (cleaned.length >= 3 && RegExp(r'[A-Za-z]{2,}').hasMatch(cleaned)) {
        merchant = cleaned;
        break;
      }
    }

    // 3. Detect Purchase Date
    // Day-first is the norm outside the US; a plain "$" (or nothing) keeps month-first.
    final preferDayFirst = detectedCurrency != '\$';
    DateTime purchaseDate = DateTime.now();
    bool isDateAmbiguous = false;
    DateTime? alternateDate;
    bool dateDetected = false;
    final dateLineIndexes = <int>{};
    for (int i = 0; i < lines.length; i++) {
      final candidate = _findDate(lines[i], preferDayFirst: preferDayFirst);
      if (candidate != null) {
        purchaseDate = candidate.date;
        alternateDate = candidate.alternate;
        isDateAmbiguous = candidate.alternate != null;
        dateDetected = true;
        dateLineIndexes.add(i);
        break;
      }
    }
    if (!dateDetected) {
      warnings.add('No purchase date found; defaulted to today. Please confirm.');
    } else if (purchaseDate.isAfter(DateTime.now().add(const Duration(days: 1)))) {
      if (alternateDate != null && !alternateDate.isAfter(DateTime.now())) {
        final t = purchaseDate;
        purchaseDate = alternateDate;
        alternateDate = t;
      } else {
        warnings.add('The purchase date appears to be in the future. Please check it.');
      }
    }

    // 4. Financial Totals & Key Amounts
    double? detectedSubtotal;
    double? detectedTax;
    double? detectedDiscount;
    double? detectedTotal;
    double? grandTotal;

    final subtotalLineRegex = RegExp(r'^SUB[\s-]?TOTAL\b', caseSensitive: false);
    final taxLineRegex = RegExp(
      r'^(?:TOTAL\s+)?(?:SALES\s+)?(?:TAX|VAT|GST|HST|PST|CGST|SGST|IGST)\b',
      caseSensitive: false,
    );
    final discountLineRegex = RegExp(
      r'^(?:TOTAL\s+)?(?:MEMBER\s+)?(?:DISCOUNT|SAVINGS|PROMO(?:TION)?|COUPON|OFF)\b|\b\d{1,2}\s?%\s?OFF\b',
      caseSensitive: false,
    );
    final grandTotalRegex = RegExp(r'^GRAND\s+TOTAL\b', caseSensitive: false);
    final totalLineRegex = RegExp(
      r'^(?:TOTAL(?:\s+(?:DUE|SALE|AMOUNT|PAID|PAYABLE))?\b|(?:AMOUNT|BALANCE)\s+DUE\b|NET\s+TOTAL\b|SUMME\b|GESAMT(?:BETRAG)?\b)',
      caseSensitive: false,
    );

    // Payment, card and receipt bookkeeping lines are never products.
    final excludedKeywords = RegExp(
      r'\b(?:TOTAL|SUBTOTAL|TAX|VAT|GST|BALANCE|DUE|CHANGE|CASH|VISA|MASTERCARD|AMEX|DEBIT|CREDIT|CARD|CARDHOLDER|'
      r'AUTH(?:ORI[SZ]ATION)?|APPROV(?:AL|ED)|TRANSACTION|TXN|TERMINAL|REF(?:ERENCE)?\s*(?:NO|#|:)|INVOICE|'
      r'RECEIPT\s*(?:NO|#)|ORDER\s*(?:NO|#)|CASHIER|REGISTER|ITEMS?\s+SOLD|THANK\s+YOU|BARCODE|TICKET|ACCOUNT|MEMBER|'
      r'TENDER|PAYMENT|POINTS|REWARDS?|TIP|SIGNATURE|CUSTOMER\s+COPY|CONTACTLESS)\b',
      caseSensitive: false,
    );
    // "Item Count: 5" - not a product, but tells how many products to expect.
    final itemCountRegex = RegExp(
      r'^(?:ITEMS?|NO\.?\s*OF\s*ITEMS|TOTAL\s+ITEMS?|TOTAL\s+QTY|QTY)\s*(?:COUNT|SOLD)?\s*[:#]?\s*(\d{1,3})\s*$',
      caseSensitive: false,
    );
    // A bare label in front of an amount, e.g. "Price: $373.00" printed under the products.
    final summaryLabelRegex = RegExp(
      r'^(?:TOTAL\s+)?(?:PRICE|AMOUNT(?:\s+PAID)?|AMT|PAID|NET(?:\s+AMOUNT)?|PAYABLE)\s*:?$',
      caseSensitive: false,
    );
    // Column headings such as "Item  Qty  Price" or "Description / Amount".
    final columnHeaderRegex = RegExp(
      r'^(?:(?:ITEMS?|DESCRIPTION|DESC|PRODUCTS?|ARTICLE|QTY|QUANTITY|PRICE|UNIT|RATE|MRP|AMOUNT|AMT|EACH|TOTAL|SKU|CODE|HSN)\b[\s/.:|\-]*)+$',
      caseSensitive: false,
    );
    // Size/variant printed on its own line under a product: "150ml", "5oml" (OCR for 50ml), "1.7 fl oz".
    final sizeLineRegex = _sizeLine;

    final lineItems = <ReceiptItemModel>[];
    int? expectedItemCount;
    double? labelTotal;

    // Receipts that never print decimals ("Cleanser 350") need whole-number prices.
    final wholeNumberReceipt = !lines.any((l) => _amountRegex.hasMatch(l));

    bool isTotalsLine(String l) =>
        subtotalLineRegex.hasMatch(l) ||
        taxLineRegex.hasMatch(l) ||
        discountLineRegex.hasMatch(l) ||
        grandTotalRegex.hasMatch(l) ||
        totalLineRegex.hasMatch(l);
    bool isNoise(String l) =>
        excludedKeywords.hasMatch(l) ||
        itemCountRegex.hasMatch(l) ||
        columnHeaderRegex.hasMatch(l.replaceAll(RegExp(r'\s+'), ' ').trim());
    bool hasWords(String s) => RegExp(r'[A-Za-z]{2,}').hasMatch(s);

    // ---- Pre-pass: column layouts (a block of names, then a block of prices, same count).
    // Paired by order only when the counts match exactly; always flagged for review.
    final pairedPrice = <int, double>{}; // name line index -> price
    final consumedPriceLines = <int>{};
    {
      bool textOnly(int k) {
        final l = lines[k];
        return !dateLineIndexes.contains(k) &&
            !isTotalsLine(l) &&
            !isNoise(l) &&
            !sizeLineRegex.hasMatch(l) &&
            hasWords(l) &&
            _amountsIn(l, allowBareInteger: wholeNumberReceipt).isEmpty;
      }

      bool priceOnly(int k) {
        final l = lines[k];
        if (isTotalsLine(l) || isNoise(l)) return false;
        final a = _amountsIn(l, allowBareInteger: true);
        return a.isNotEmpty && !hasWords(_descriptionBefore(l, a.first.start));
      }

      var k = 0;
      while (k < lines.length) {
        if (!textOnly(k)) {
          k++;
          continue;
        }
        final names = <int>[];
        while (k < lines.length && (textOnly(k) || sizeLineRegex.hasMatch(lines[k]))) {
          if (textOnly(k)) names.add(k);
          k++;
        }
        while (k < lines.length && columnHeaderRegex.hasMatch(lines[k].trim())) {
          k++; // e.g. a "Price" heading between the two blocks
        }
        final prices = <int>[];
        while (k < lines.length && priceOnly(k)) {
          prices.add(k);
          k++;
        }
        if (names.length >= 2 && names.length == prices.length) {
          for (var p = 0; p < names.length; p++) {
            pairedPrice[names[p]] = _amountsIn(lines[prices[p]], allowBareInteger: true).last.value;
            consumedPriceLines.add(prices[p]);
          }
        }
      }
    }

    bool totalsReached = false;
    // A text line without a price, waiting to see if the next line carries its price.
    String? pendingText;
    // Lines without any price; whether they become products is decided after all lines are read.
    final unpriced = <(int, String)>[]; // (insert position in lineItems, text)
    final orphanAmounts = <double>[];

    void addItem(String desc, int qty, double? unit, double lineTotal, {required bool confident}) {
      lineItems.add(
        ReceiptItemModel(
          itemId: 'item_${lineItems.length}_${_uuid.v4().substring(0, 4)}',
          description: desc,
          quantity: qty,
          unitPrice: double.parse((unit ?? (qty > 1 ? lineTotal / qty : lineTotal)).toStringAsFixed(2)),
          totalPrice: double.parse(lineTotal.toStringAsFixed(2)),
          // false = shown to the user as "check this line" (never silently trusted)
          isConfirmed: confident,
        ),
      );
    }

    void flushPending() {
      final text = pendingText;
      pendingText = null;
      if (text != null && !totalsReached) unpriced.add((lineItems.length, text));
    }

    for (int i = 0; i < lines.length; i++) {
      final clean = lines[i];
      if (dateLineIndexes.contains(i) && _amountsIn(clean).isEmpty) continue;
      if (consumedPriceLines.contains(i)) continue;

      if (isTotalsLine(clean)) {
        flushPending();
        totalsReached = true;
      }

      if (subtotalLineRegex.hasMatch(clean)) {
        detectedSubtotal ??= _lastAmount(clean);
        continue;
      }
      if (taxLineRegex.hasMatch(clean)) {
        final v = _lastAmount(clean);
        if (v != null) detectedTax = (detectedTax ?? 0) + v.abs(); // several tax lines add up
        continue;
      }
      if (discountLineRegex.hasMatch(clean)) {
        final v = _lastAmount(clean);
        if (v != null) detectedDiscount = (detectedDiscount ?? 0) + v.abs();
        continue;
      }
      if (grandTotalRegex.hasMatch(clean)) {
        grandTotal ??= _lastAmount(clean);
        continue;
      }
      if (totalLineRegex.hasMatch(clean)) {
        detectedTotal ??= _lastAmount(clean);
        continue;
      }

      final countMatch = itemCountRegex.firstMatch(clean);
      if (countMatch != null) {
        flushPending();
        expectedItemCount = int.parse(countMatch.group(1)!);
        continue;
      }
      if (isNoise(clean)) {
        flushPending();
        continue;
      }

      // Size/variant line belongs to the product above it.
      if (sizeLineRegex.hasMatch(clean)) {
        if (pendingText != null) {
          pendingText = '$pendingText ${clean.trim()}';
        } else if (lineItems.isNotEmpty) {
          final lastItem = lineItems.removeLast();
          lineItems.add(lastItem.copyWith(description: '${lastItem.description} ${clean.trim()}'));
        }
        continue;
      }

      // Column-layout name already paired with a price in the pre-pass.
      if (pairedPrice.containsKey(i)) {
        flushPending();
        addItem(_descriptionBefore(clean, clean.length), 1, null, pairedPrice[i]!, confident: false);
        continue;
      }

      // Item lines, e.g. "CeraVe Cream 19.99", "2x Niacinamide 12.00", "Serum 2 @ 12.00 24.00",
      // "Hydrating Serum — ₹250", and (whole-number receipts only) "Cleanser 350".
      final amounts = _amountsIn(clean, allowBareInteger: wholeNumberReceipt);

      if (amounts.isEmpty) {
        // No price on this line: maybe a wrapped description or a product without a price.
        final text = _descriptionBefore(clean, clean.length);
        final nextIsPriceOnly =
            i + 1 < lines.length &&
            !consumedPriceLines.contains(i + 1) &&
            !isTotalsLine(lines[i + 1]) &&
            !isNoise(lines[i + 1]) &&
            (() {
              final a = _amountsIn(lines[i + 1], allowBareInteger: wholeNumberReceipt);
              return a.isNotEmpty && !hasWords(_descriptionBefore(lines[i + 1], a.first.start));
            })();
        if (pendingText != null && nextIsPriceOnly && hasWords(clean)) {
          // Second line of a name wrapped over two lines, with the price on the line after.
          pendingText = '$pendingText $text';
          continue;
        }
        flushPending();
        if (hasWords(clean) && text.length >= 2 && !totalsReached) pendingText = text;
        continue;
      }

      final last = amounts.last;
      final lineTotal = last.value;
      var desc = _descriptionBefore(clean, amounts.first.start);

      // "Price: $373.00" after the products: a total printed under a plain label.
      if (summaryLabelRegex.hasMatch(desc.trim())) {
        flushPending();
        if (lineItems.isNotEmpty && !last.negative) labelTotal ??= lineTotal;
        totalsReached = lineItems.isNotEmpty || totalsReached;
        continue;
      }

      if (last.negative || lineTotal <= 0 || lineTotal >= 1000000) {
        flushPending();
        continue;
      }

      var confident = !last.bare && lineTotal < 10000;

      if (!hasWords(desc)) {
        if (pendingText != null) {
          // Price-only (or "2 x 12.00 24.00") line right after a text line: one wrapped product.
          desc = '$pendingText ${desc.trim()}'.trim();
          pendingText = null;
          confident = false; // joined from two physical lines
        } else {
          // An amount with nothing to attach it to: reported, never guessed onto a product.
          if (!totalsReached) orphanAmounts.add(lineTotal);
          continue;
        }
      } else {
        flushPending();
      }

      int qty = 1;
      double? unitPrice;

      final atMatch = RegExp(r'^(.*?)\s*(\d{1,3})\s*[@xX]\s*$').firstMatch(desc);
      final leadingQty = RegExp(r'^(\d{1,3})\s*[xX@]\s+(.+)$').firstMatch(desc);
      final trailingQty = RegExp(r'^(.+?)\s+[xX]\s?(\d{1,3})$').firstMatch(desc);
      if (amounts.length >= 2 && atMatch != null) {
        // "Serum 2 @ 12.00 24.00"
        desc = atMatch.group(1)!.trim();
        qty = int.parse(atMatch.group(2)!);
        unitPrice = amounts.first.value;
      } else if (leadingQty != null) {
        qty = int.parse(leadingQty.group(1)!);
        desc = leadingQty.group(2)!.trim();
      } else if (trailingQty != null) {
        desc = trailingQty.group(1)!.trim();
        qty = int.parse(trailingQty.group(2)!);
      }
      if (qty < 1) qty = 1;

      desc = _descriptionBefore(desc, desc.length);

      // Reject if description is too short or is purely numeric
      if (desc.length < 2 || RegExp(r'^[\d\s\.\-]+$').hasMatch(desc)) continue;

      addItem(desc, qty, unitPrice, lineTotal, confident: confident);
    }
    flushPending();

    // ---- Lines without a price. They are only offered as products when the priced
    // products do NOT already account for the receipt, and only between the first and
    // last product (headers/footers are never products).
    final pricedSum = lineItems.fold(0.0, (s, i) => s + i.totalPrice);
    final referenceTotal = grandTotal ?? detectedTotal ?? labelTotal;
    final pricedReconcile =
        (detectedSubtotal != null && (pricedSum - detectedSubtotal).abs() <= 0.02) ||
        (referenceTotal != null &&
            (pricedSum + (detectedTax ?? 0) - (detectedDiscount ?? 0) - referenceTotal).abs() <= 0.02);
    final pricedQty = lineItems.fold(0, (s, i) => s + i.quantity);
    final expected = expectedItemCount;
    final countSatisfied = expected != null && pricedQty >= expected;
    // Only lines after the first priced product (lines above it are headers/addresses).
    final candidates = unpriced.where((u) => u.$1 > 0).toList();
    if (candidates.isNotEmpty && !pricedReconcile && !countSatisfied) {
      // Insert from the back so earlier positions stay valid.
      for (final (pos, text) in candidates.reversed) {
        lineItems.insert(
          pos,
          ReceiptItemModel(
            itemId: 'item_np${pos}_${_uuid.v4().substring(0, 4)}',
            description: text,
            unitPrice: 0,
            totalPrice: 0,
            isConfirmed: false, // price unknown: the review screen asks for it
          ),
        );
      }
      warnings.add(
        '${candidates.length} line${candidates.length == 1 ? '' : 's'} without a price may be '
        '${candidates.length == 1 ? 'a product' : 'products'}. Enter the price, or remove the line if it is not a product.',
      );
    } else if (candidates.isNotEmpty && (pricedReconcile || countSatisfied)) {
      warnings.add(
        '${candidates.length} line${candidates.length == 1 ? '' : 's'} without a price ${candidates.length == 1 ? 'was' : 'were'} '
        'not added, because the priced products already match the receipt'
        '${pricedReconcile ? ' total' : '\'s item count'}. Use "Add Item" if one of them was a product.',
      );
    }
    if (orphanAmounts.isNotEmpty) {
      warnings.add(
        'Amounts without a product name were not assigned to any product: '
        '${orphanAmounts.map((a) => a.toStringAsFixed(2)).join(', ')}.',
      );
    }
    if (pairedPrice.isNotEmpty) {
      warnings.add(
        'Prices printed in a separate column were matched to product names by their order. Please check them.',
      );
    }
    if (expectedItemCount != null) {
      final qtyNow = lineItems.fold(0, (s, i) => s + i.quantity);
      if (qtyNow != expectedItemCount) {
        warnings.add(
          'The receipt says $expectedItemCount item${expectedItemCount == 1 ? '' : 's'}, but $qtyNow '
          '${qtyNow == 1 ? 'was' : 'were'} found. Please check the list.',
        );
      }
    }

    final needsReview = lineItems.where((i) => !i.isConfirmed).length;
    if (needsReview > 0) {
      warnings.add(
        '$needsReview line${needsReview == 1 ? '' : 's'} could not be read confidently '
        '(marked "Check this line"). Please confirm the name and price.',
      );
    }

    final explicitTotal = grandTotal ?? detectedTotal ?? labelTotal;

    // Conservative subtotal & total fallbacks if not explicitly found
    final itemsSum = lineItems.fold(0.0, (sum, i) => sum + i.totalPrice);
    final subtotal = detectedSubtotal ?? itemsSum;
    final tax = detectedTax ?? 0.0;
    final discount = detectedDiscount ?? 0.0;
    final total = explicitTotal ?? (subtotal + tax - discount);

    if (lineItems.isEmpty) {
      warnings.add('No distinct line items could be parsed automatically. You can add items manually.');
    }

    if (explicitTotal == null && itemsSum > 0) {
      warnings.add('Total amount was estimated from parsed line items.');
    }

    // Consistency checks: flag, never silently "fix", so the user decides.
    if (explicitTotal != null && subtotal > 0) {
      final expected = subtotal + tax - discount;
      if ((expected - explicitTotal).abs() > 0.02) {
        warnings.add(
          'Totals do not add up: subtotal ${subtotal.toStringAsFixed(2)} + tax ${tax.toStringAsFixed(2)} '
          '- discount ${discount.toStringAsFixed(2)} = ${expected.toStringAsFixed(2)}, '
          'but the receipt total is ${explicitTotal.toStringAsFixed(2)}.',
        );
      }
    }
    if (detectedSubtotal != null && lineItems.isNotEmpty && (itemsSum - detectedSubtotal).abs() > 0.02) {
      warnings.add(
        'Line items add up to ${itemsSum.toStringAsFixed(2)} but the subtotal is '
        '${detectedSubtotal.toStringAsFixed(2)}; some items may be missing or misread.',
      );
    }
    // A single misread price (e.g. "₹400" OCR'd as "3400") is pointed out, never changed:
    // if dropping the first digit of exactly one line makes the lines match the subtotal
    // (or the total, when nothing else is added or taken off), that line is flagged.
    final reconcileTarget =
        detectedSubtotal ?? (detectedTax == null && detectedDiscount == null ? explicitTotal : null);
    if (reconcileTarget != null && lineItems.isNotEmpty && (itemsSum - reconcileTarget).abs() > 0.02) {
      final suspects = <int, double>{};
      for (var k = 0; k < lineItems.length; k++) {
        final digits = lineItems[k].totalPrice.toStringAsFixed(2).replaceAll('.', '');
        if (digits.length < 4) continue;
        final withoutFirst = int.parse(digits.substring(1)) / 100;
        if ((itemsSum - lineItems[k].totalPrice + withoutFirst - reconcileTarget).abs() <= 0.02) {
          suspects[k] = withoutFirst;
        }
      }
      if (suspects.length == 1) {
        final k = suspects.keys.single;
        lineItems[k] = lineItems[k].copyWith(isConfirmed: false);
        warnings.add(
          '"${lineItems[k].description}" was read as ${lineItems[k].totalPrice.toStringAsFixed(2)}, but '
          '${suspects[k]!.toStringAsFixed(2)} would make the items match the receipt total. A currency sign is '
          'often misread as a digit, so please check this price.',
        );
      }
    }
    if (detectedCurrency == '¥') {
      warnings.add(
        'Currency read as ¥. Receipt OCR often misreads ₹ as ¥, so change the currency if this is a rupee receipt.',
      );
    }
    if (isDateAmbiguous) {
      warnings.add('The date could be read as day/month or month/day. Please confirm it.');
    }

    return ParsedReceiptDraft(
      receiptId: stableId,
      merchant: merchant,
      purchaseDate: purchaseDate,
      isDateAmbiguous: isDateAmbiguous,
      alternateDate: alternateDate,
      currency: detectedCurrency,
      subtotal: double.parse(subtotal.toStringAsFixed(2)),
      tax: double.parse(tax.toStringAsFixed(2)),
      discount: double.parse(discount.toStringAsFixed(2)),
      total: double.parse(total.toStringAsFixed(2)),
      items: lineItems,
      rawText: rawText,
      warnings: warnings,
      dateDetected: dateDetected,
      currencyDetected: currencyDetected,
    );
  }
}
