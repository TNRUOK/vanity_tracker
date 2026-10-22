import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:intl/intl.dart';
import '../models/date_precision.dart';

export '../models/date_precision.dart';

enum DateLabelKind { manufacturing, expiry, unlabeled }

/// A date read from packaging text.
class ParsedDateCandidate {
  /// The date (first of the month when [precision] is month).
  final DateTime date;
  final DatePrecision precision;
  final String rawMatch;
  final String formatPattern;

  /// Day and month could be either way round (e.g. 04/05/2027); [alternateDate] is the
  /// other reading. An ambiguous date is never applied without the user's choice.
  final bool isAmbiguous;
  final DateTime? alternateDate;
  final String? ambiguityNote;
  final DateLabelKind kind;

  /// The printed label that introduced the date ("EXP", "MFD", ...), if any.
  final String? label;

  const ParsedDateCandidate({
    required this.date,
    required this.rawMatch,
    required this.formatPattern,
    this.precision = DatePrecision.day,
    this.isAmbiguous = false,
    this.alternateDate,
    this.ambiguityNote,
    this.kind = DateLabelKind.unlabeled,
    this.label,
  });

  String get formattedDisplay => formatPackagingDate(date, precision);

  ParsedDateCandidate withKind(DateLabelKind k, String? l) => ParsedDateCandidate(
        date: date,
        rawMatch: rawMatch,
        formatPattern: formatPattern,
        precision: precision,
        isAmbiguous: isAmbiguous,
        alternateDate: alternateDate,
        ambiguityNote: ambiguityNote,
        kind: k,
        label: l,
      );

  String get _key => '${date.toIso8601String()}|${precision.name}|${alternateDate?.toIso8601String()}';
}

/// A possible batch/lot code.
class BatchCodeCandidate {
  final String code;

  /// The printed label ("LOT", "BATCH NO.", ...); null for an unlabeled guess.
  final String? label;

  const BatchCodeCandidate(this.code, {this.label});

  bool get isLabeled => label != null;

  /// Mixes letters and digits that OCR often confuses (O/0, I/1, B/8, S/5, Z/2): the user
  /// is asked to compare with the pack. The code itself is never changed.
  bool get hasLookalikeCharacters =>
      RegExp(r'[A-Z]').hasMatch(code) && RegExp(r'\d').hasMatch(code) && RegExp(r'[O0I1B8S5Z2]').hasMatch(code);
}

/// A manufacturing month suggested from a batch code by a brand-specific rule. Never
/// applied automatically: the rule is community-reported, not manufacturer-documented,
/// and the year digit fits more than one decade.
class BrandDecodeSuggestion {
  final String rule;
  final DateTime month;
  final DateTime decadeEarlier;
  final String note;
  const BrandDecodeSuggestion({required this.rule, required this.month, required this.decadeEarlier, required this.note});
}

/// Result of packaging-text analysis. Fields are only *suggested* when the text gives a
/// single clear answer; everything else is offered as choices.
class BatchOcrResult {
  final String rawText;

  /// Labeled candidates first, then unlabeled guesses.
  final List<BatchCodeCandidate> batchCandidates;
  final List<ParsedDateCandidate> mfgCandidates;
  final List<ParsedDateCandidate> expiryCandidates;

  /// Dates with no label: shown for the user to assign, never assigned automatically.
  final List<ParsedDateCandidate> unlabeledDates;
  final BrandDecodeSuggestion? brandDecode;

  /// Why text that looked relevant was not used (diagnostics shown to the user).
  final List<String> notes;

  const BatchOcrResult({
    required this.rawText,
    this.batchCandidates = const [],
    this.mfgCandidates = const [],
    this.expiryCandidates = const [],
    this.unlabeledDates = const [],
    this.brandDecode,
    this.notes = const [],
  });

  List<BatchCodeCandidate> get labeledBatchCandidates => batchCandidates.where((c) => c.isLabeled).toList();

  /// The batch code when exactly one distinct labeled code was found, else null.
  String? get suggestedBatchCode {
    final codes = labeledBatchCandidates.map((c) => c.code).toSet();
    return codes.length == 1 ? codes.single : null;
  }

  List<String> get allBatchCodeCandidates => batchCandidates.map((c) => c.code).toSet().toList();

  static ParsedDateCandidate? _single(List<ParsedDateCandidate> list) {
    final keys = list.map((c) => c._key).toSet();
    return keys.length == 1 ? list.first : null;
  }

  /// The manufacturing date when exactly one distinct labeled date was found (it may be
  /// ambiguous: check [ParsedDateCandidate.isAmbiguous]).
  ParsedDateCandidate? get suggestedMfgDate => _single(mfgCandidates);
  ParsedDateCandidate? get suggestedExpiryDate => _single(expiryCandidates);
  String? get brandDecodedNote => brandDecode?.note;

  bool get hasAnyDetection =>
      batchCandidates.isNotEmpty || mfgCandidates.isNotEmpty || expiryCandidates.isNotEmpty || unlabeledDates.isNotEmpty;
}

class _Label {
  final DateLabelKind? dateKind; // null for a batch label
  final String text;
  final int start;
  final int end;
  _Label(this.dateKind, this.text, this.start, this.end);
}

class BatchOcrService {
  /// Extract text from an image file using on-device ML Kit text recognition
  /// (Android/iOS only; the browser uses Tesseract.js, see ocr/receipt_ocr_web.dart).
  static Future<String> recognizeTextFromImage(String imagePath) async {
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await textRecognizer.processImage(inputImage);
      return recognizedText.text;
    } catch (e) {
      debugPrint('On-device OCR error: $e');
      rethrow;
    } finally {
      try {
        await textRecognizer.close();
      } catch (_) {
        // Unsupported platforms have no native recognizer to close.
      }
    }
  }

  // Labels are matched as whole words only ("LOT" in "LOTION" and "EXP" in "EXPERT" are
  // not labels). Longer spellings come first so they win over their prefixes.
  static const _wb = r'(?<![A-Za-z0-9])';
  static const _we = r'(?![A-Za-z])';
  static final _batchLabel = RegExp(
    '$_wb(?:LOT\\s*(?:NO\\.?|NUMBER|#)|BATCH\\s*(?:NO\\.?|NUMBER|CODE|#)|LOT|BATCH|B\\.\\s?NO\\.?|BNO|B/N|BN(?=\\s*[:#])|L(?=\\s*[:.]|\\s+\\S*\\d))$_we',
    caseSensitive: false,
  );
  static final _mfgLabel = RegExp(
    '$_wb(?:MFG\\.?\\s*DATE|MFG|MFD|MANUFACTURING\\s+DATE|MANUFACTURED(?:\\s+ON)?|DATE\\s+OF\\s+MANUFACTURE|MADE\\s+ON|PROD(?:UCTION)?\\.?\\s*DATE|DOM(?=\\s*[:.]?\\s*\\d))$_we',
    caseSensitive: false,
  );
  static final _expLabel = RegExp(
    '$_wb(?:EXP(?:IRY|IRATION)?\\.?\\s*DATE|EXPIRY|EXPIRATION|EXPIRES|EXP|BEST\\s+BEFORE(?:\\s+END)?|BBE|BB(?=\\s*[:.]?\\s*\\d)|USE\\s+BY|USE\\s+BEFORE|VALID\\s+(?:UNTIL|THRU))$_we',
    caseSensitive: false,
  );

  /// Words that are labels or packaging text, never a batch code.
  static const _notCodes = {
    'NO', 'NUMBER', 'CODE', 'LOT', 'BATCH', 'EXP', 'MFG', 'MFD', 'DATE', 'BEST', 'BEFORE', 'MADE', 'USE', 'BY',
    'END', 'BBE', 'DOM', 'IN', 'ON',
  };

  /// Analyses packaging text: batch/lot codes, manufacturing and expiry dates.
  /// Conservative: a field is suggested only from a printed label; everything uncertain
  /// is returned as a candidate for the user to confirm. Nothing is invented.
  static BatchOcrResult parsePackagingText(String text, {String? brand}) {
    final clean = text.replaceAll(RegExp(r'[–—−]'), '-').replaceAll('\r', '');
    if (clean.trim().isEmpty) return const BatchOcrResult(rawText: '');
    final lines = clean.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    final batch = <BatchCodeCandidate>[];
    final mfg = <ParsedDateCandidate>[];
    final exp = <ParsedDateCandidate>[];
    final unlabeled = <ParsedDateCandidate>[];
    final notes = <String>[];
    // Character ranges of each line consumed by a label and its value.
    final used = List.generate(lines.length, (_) => <(int, int)>[]);

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final labels = <_Label>[
        for (final m in _batchLabel.allMatches(line)) _Label(null, m.group(0)!, m.start, m.end),
        for (final m in _mfgLabel.allMatches(line)) _Label(DateLabelKind.manufacturing, m.group(0)!, m.start, m.end),
        for (final m in _expLabel.allMatches(line)) _Label(DateLabelKind.expiry, m.group(0)!, m.start, m.end),
      ]..sort((a, b) => a.start.compareTo(b.start));
      // Drop labels that start inside an earlier label ("BATCH NO" vs "NO").
      final ordered = <_Label>[];
      for (final l in labels) {
        if (ordered.isEmpty || l.start >= ordered.last.end) ordered.add(l);
      }

      for (var k = 0; k < ordered.length; k++) {
        final l = ordered[k];
        final valueEnd = k + 1 < ordered.length ? ordered[k + 1].start : line.length;
        var value = line.substring(l.end, valueEnd).replaceFirst(RegExp(r'^[\s:#.\-]+'), '').trim();
        used[i].add((l.start, valueEnd));
        // A label alone (at the end of its line) takes its value from the next line.
        var fromNext = false;
        if (value.isEmpty && k == ordered.length - 1 && i + 1 < lines.length && !_startsWithLabel(lines[i + 1])) {
          value = lines[i + 1];
          fromNext = true;
        }
        final labelText = l.text.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
        if (l.dateKind == null) {
          final code = _codeFrom(value);
          if (code != null) {
            batch.add(BatchCodeCandidate(code, label: labelText));
            if (fromNext) used[i + 1].add((0, lines[i + 1].length));
          } else if (value.isNotEmpty) {
            notes.add('"$labelText" label found, but "$value" does not look like a batch code.');
          }
        } else {
          final d = parseDate(value, labelled: true);
          if (d != null) {
            (l.dateKind == DateLabelKind.expiry ? exp : mfg).add(d.withKind(l.dateKind!, labelText));
            if (fromNext) used[i + 1].add((0, lines[i + 1].length));
          } else if (value.isNotEmpty) {
            notes.add('"$labelText" label found, but "$value" is not a valid date.');
          }
        }
      }
    }

    // Unlabeled text: dates and code-like tokens are offered as choices only.
    for (var i = 0; i < lines.length; i++) {
      final rest = _unusedText(lines[i], used[i]);
      if (rest.trim().isEmpty) continue;
      final d = parseDate(rest, labelled: false);
      if (d != null) unlabeled.add(d);
      for (final m in RegExp(r'(?<![A-Za-z0-9])[A-Za-z0-9][A-Za-z0-9\-]{2,11}(?![A-Za-z0-9])').allMatches(rest)) {
        final t = m.group(0)!.toUpperCase();
        if (!RegExp(r'[A-Z]').hasMatch(t) || !RegExp(r'\d').hasMatch(t)) continue; // letters AND digits only
        if (_codeFrom(t) == t && !batch.any((c) => c.code == t)) batch.add(BatchCodeCandidate(t));
      }
    }

    BrandDecodeSuggestion? decode;
    if (brand != null && brand.trim().isNotEmpty) {
      for (final c in batch.where((c) => c.isLabeled)) {
        decode = esteeLauderSuggestion(brand, c.code);
        if (decode != null) break;
      }
    }

    // Diagnostics only (no personal data), debug builds only: which stages produced something.
    if (kDebugMode) {
      debugPrint('[packaging-ocr] lines=${lines.length} batch=${batch.length} mfg=${mfg.length} '
          'exp=${exp.length} unlabeledDates=${unlabeled.length} notes=${notes.length}');
    }

    return BatchOcrResult(
      rawText: text,
      batchCandidates: [...batch.where((c) => c.isLabeled), ...batch.where((c) => !c.isLabeled)],
      mfgCandidates: _dedupe(mfg),
      expiryCandidates: _dedupe(exp),
      unlabeledDates: _withoutLabeled(_dedupe(unlabeled), [...mfg, ...exp]),
      brandDecode: decode,
      notes: notes,
    );
  }

  /// Parses several OCR readings of the same image (e.g. original and enhanced) and
  /// merges their candidates; identical values are kept once, differing values are all
  /// offered, so a disagreement between readings is visible instead of silently resolved.
  static BatchOcrResult parsePasses(List<({String label, String text})> passes, {String? brand}) {
    final results = [for (final p in passes) parsePackagingText(p.text, brand: brand)];
    final batch = <BatchCodeCandidate>[];
    for (final c in results.expand((r) => r.batchCandidates)) {
      final existing = batch.indexWhere((b) => b.code == c.code);
      if (existing == -1) {
        batch.add(c);
      } else if (!batch[existing].isLabeled && c.isLabeled) {
        batch[existing] = c;
      }
    }
    return BatchOcrResult(
      rawText: passes.where((p) => p.text.trim().isNotEmpty).map((p) => '[${p.label}]\n${p.text.trim()}').join('\n\n'),
      batchCandidates: [...batch.where((c) => c.isLabeled), ...batch.where((c) => !c.isLabeled)],
      mfgCandidates: _dedupe(results.expand((r) => r.mfgCandidates).toList()),
      expiryCandidates: _dedupe(results.expand((r) => r.expiryCandidates).toList()),
      unlabeledDates: _withoutLabeled(
        _dedupe(results.expand((r) => r.unlabeledDates).toList()),
        results.expand((r) => [...r.mfgCandidates, ...r.expiryCandidates]).toList(),
      ),
      brandDecode: results.map((r) => r.brandDecode).whereType<BrandDecodeSuggestion>().firstOrNull,
      notes: results.expand((r) => r.notes).toSet().toList(),
    );
  }

  static List<ParsedDateCandidate> _dedupe(List<ParsedDateCandidate> list) {
    final seen = <String>{};
    return [for (final c in list) if (seen.add(c._key)) c];
  }

  /// Unlabeled dates that another reading already found with a label are not repeated.
  static List<ParsedDateCandidate> _withoutLabeled(List<ParsedDateCandidate> unlabeled, List<ParsedDateCandidate> labeled) {
    final keys = labeled.map((c) => c._key).toSet();
    return unlabeled.where((c) => !keys.contains(c._key)).toList();
  }

  static bool _startsWithLabel(String line) =>
      [_batchLabel, _mfgLabel, _expLabel].any((r) => r.matchAsPrefix(line.trimLeft()) != null);

  static String _unusedText(String line, List<(int, int)> ranges) {
    final chars = line.split('');
    for (final (a, b) in ranges) {
      for (var i = a; i < b && i < chars.length; i++) {
        chars[i] = ' ';
      }
    }
    return chars.join();
  }

  /// The first token of [value] when it can be a batch/lot code, else null. Rejects label
  /// words, dates, retail barcodes, PAO marks (12M), sizes (50ml), SPF and prices.
  static String? _codeFrom(String value) {
    final m = RegExp(r'^[A-Za-z0-9][A-Za-z0-9\-/.]*').firstMatch(value.trim());
    if (m == null) return null;
    final code = m.group(0)!.replaceFirst(RegExp(r'[\-/.]+$'), '').toUpperCase();
    if (code.length < 2 || code.length > 20) return null;
    if (_notCodes.contains(code)) return null;
    if (RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(code)) return null; // barcode-length numbers
    if (RegExp(r'^\d{1,3}M$').hasMatch(code)) return null; // PAO "12M"
    if (RegExp(r'^\d+(?:[.,]\d+)?(?:ML|M|G|KG|L|OZ|FL|MG)$').hasMatch(code)) return null; // size
    if (RegExp(r'^SPF\d*$').hasMatch(code)) return null;
    if (parseDate(code, labelled: false) != null) return null;
    if (!RegExp(r'\d').hasMatch(code) && code.length < 3) return null;
    return code;
  }

  static const _months = {
    'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6, 'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
  };
  static const _monthRe = r'(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\.?';

  static DateTime? _validDay(int y, int m, int d) {
    if (y < 1990 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime(y, m, d);
    return date.month == m && date.day == d ? date : null; // rejects 31/04, 30/02, ...
  }

  static int _year(String s) => s.length == 2 ? 2000 + int.parse(s) : int.parse(s);

  /// Parses the first date in [input]. Supported (each validated as a real calendar date):
  /// 2027-10-17 / 2027/10/17 / 2027.10.17, 20271017, 17 Oct 2027, Oct 17 2027,
  /// 17/10/2027 (and 17/10/27), Oct 2027, 2027 Oct, 10/2027, 2027-10, and, after a label,
  /// 10/27. Day/month order is only decided when one part is above 12; otherwise the date
  /// is returned as ambiguous with both readings. Month-only dates keep month precision.
  static ParsedDateCandidate? parseDate(String input, {bool labelled = true}) {
    final s = input.toUpperCase();
    const nb = r'(?<!\d)';
    const na = r'(?!\d)';

    var m = RegExp('$nb((?:19|20)\\d\\d)[-/.](\\d{1,2})[-/.](\\d{1,2})$na').firstMatch(s);
    if (m != null) {
      final d = _validDay(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      return d == null ? null : ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'YYYY-MM-DD');
    }
    m = RegExp('$nb(20\\d\\d)(0[1-9]|1[0-2])(0[1-9]|[12]\\d|3[01])$na').firstMatch(s);
    if (m != null) {
      final d = _validDay(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      if (d != null) return ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'YYYYMMDD');
    }
    m = RegExp('$nb(\\d{1,2})[\\s\\-./]*$_monthRe[\\s\\-./,]*((?:19|20)\\d\\d|\\d\\d)$na').firstMatch(s);
    if (m != null) {
      final d = _validDay(_year(m[3]!), _months[m[2]!]!, int.parse(m[1]!));
      return d == null ? null : ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'DD MMM YYYY');
    }
    m = RegExp('$_monthRe[\\s\\-./]*(\\d{1,2}),?[\\s\\-./]+((?:19|20)\\d\\d)$na').firstMatch(s);
    if (m != null) {
      final d = _validDay(int.parse(m[3]!), _months[m[1]!]!, int.parse(m[2]!));
      if (d != null) return ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'MMM DD YYYY');
    }
    m = RegExp('$_monthRe[\\s\\-./,]*((?:19|20)\\d\\d)$na').firstMatch(s) ??
        RegExp('$nb((?:19|20)\\d\\d)[\\s\\-./]*$_monthRe').firstMatch(s);
    if (m != null) {
      final monthFirst = _months.containsKey(m[1]);
      final y = int.parse(monthFirst ? m[2]! : m[1]!);
      final mo = _months[monthFirst ? m[1]! : m[2]!]!;
      final d = _validDay(y, mo, 1);
      if (d != null) {
        return ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'MMM YYYY', precision: DatePrecision.month);
      }
    }
    m = RegExp('$nb(\\d{1,2})([-/.])(\\d{1,2})\\2((?:19|20)\\d\\d|\\d\\d)$na').firstMatch(s);
    if (m != null) {
      final a = int.parse(m[1]!), b = int.parse(m[3]!), y = _year(m[4]!);
      final dayFirst = _validDay(y, b, a); // DD/MM
      final monthFirst = _validDay(y, a, b); // MM/DD
      final twoDigit = m[4]!.length == 2 ? ' (2-digit year read as ${2000 + int.parse(m[4]!)})' : '';
      if (dayFirst != null && monthFirst != null && a != b) {
        return ParsedDateCandidate(
          date: dayFirst,
          alternateDate: monthFirst,
          rawMatch: m[0]!,
          formatPattern: 'DD/MM/YYYY or MM/DD/YYYY',
          isAmbiguous: true,
          ambiguityNote: '"${m[0]}" could be ${DateFormat.yMMMd().format(dayFirst)} (day first) or '
              '${DateFormat.yMMMd().format(monthFirst)} (month first). Choose the one printed on your pack.$twoDigit',
        );
      }
      final d = dayFirst ?? monthFirst;
      if (d != null) {
        return ParsedDateCandidate(
          date: d,
          rawMatch: m[0]!,
          formatPattern: dayFirst != null ? 'DD/MM/YYYY' : 'MM/DD/YYYY',
          ambiguityNote: twoDigit.isEmpty ? null : twoDigit.trim(),
        );
      }
      return null; // e.g. 31/04/2027: not a real date
    }
    m = RegExp('$nb((?:19|20)\\d\\d)[-/.](\\d{1,2})$na(?![-/.]\\d)').firstMatch(s);
    if (m != null) {
      final d = _validDay(int.parse(m[1]!), int.parse(m[2]!), 1);
      if (d != null) {
        return ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'YYYY-MM', precision: DatePrecision.month);
      }
    }
    m = RegExp('$nb(\\d{1,2})[-/.\\s]((?:19|20)\\d\\d)$na').firstMatch(s);
    if (m != null) {
      final d = _validDay(int.parse(m[2]!), int.parse(m[1]!), 1);
      if (d != null) {
        return ParsedDateCandidate(date: d, rawMatch: m[0]!, formatPattern: 'MM/YYYY', precision: DatePrecision.month);
      }
    }
    if (labelled) {
      // "EXP 10/27": only after a date label, where month/2-digit-year is the usual meaning.
      m = RegExp('$nb(0?[1-9]|1[0-2])[/.](\\d\\d)$na').firstMatch(s);
      if (m != null) {
        final d = _validDay(_year(m[2]!), int.parse(m[1]!), 1);
        if (d != null) {
          return ParsedDateCandidate(
            date: d,
            rawMatch: m[0]!,
            formatPattern: 'MM/YY',
            precision: DatePrecision.month,
            ambiguityNote: '2-digit year read as ${d.year}',
          );
        }
      }
    }
    return null;
  }

  /// Brands whose 3-character batch codes follow the Estée Lauder Companies format that is
  /// widely reported by batch-code checker sites (plant letter, month 1-9/A-C, year digit).
  /// It is NOT documented by the manufacturer, so it only produces a suggestion.
  static const _esteeLauderBrands = [
    'estee lauder', 'estée lauder', 'clinique', 'mac', 'm.a.c', 'mac cosmetics', 'origins', 'bobbi brown',
    'la mer', 'aveda', 'smashbox', 'too faced', 'tom ford beauty', 'jo malone',
  ];

  static bool _isEsteeLauderBrand(String brand) {
    final b = ' ${brand.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ')} ';
    return _esteeLauderBrands.any((x) => b == ' $x ' || b.startsWith(' $x ') && x.length > 3);
  }

  /// The most recent month (not in the future) matching an Estée Lauder-style code, or null.
  static DateTime? decodeEsteeLauderBatch(String batchCode, {DateTime? now}) {
    final code = batchCode.trim().toUpperCase();
    final m = RegExp(r'^[A-Z0-9]([1-9ABC])(\d)$').firstMatch(code);
    if (m == null) return null;
    final monthChar = m[1]!;
    final month = switch (monthChar) { 'A' => 10, 'B' => 11, 'C' => 12, _ => int.parse(monthChar) };
    final today = now ?? DateTime.now();
    var year = (today.year ~/ 10) * 10 + int.parse(m[2]!);
    if (DateTime(year, month).isAfter(today)) year -= 10;
    return DateTime(year, month, 1);
  }

  static BrandDecodeSuggestion? esteeLauderSuggestion(String brand, String code, {DateTime? now}) {
    if (!_isEsteeLauderBrand(brand)) return null;
    final month = decodeEsteeLauderBatch(code, now: now);
    if (month == null) return null;
    final earlier = DateTime(month.year - 10, month.month, 1);
    return BrandDecodeSuggestion(
      rule: 'Estée Lauder Companies 3-character batch format (community-reported)',
      month: month,
      decadeEarlier: earlier,
      note: 'Batch $code may mean manufactured in ${DateFormat('MMM yyyy').format(month)} '
          '(or ${DateFormat('MMM yyyy').format(earlier)}): this follows a format reported by batch-code '
          'checker sites, not confirmed by the manufacturer. Use it only if it matches your pack.',
    );
  }
}
