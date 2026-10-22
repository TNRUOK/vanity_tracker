/// Parses and normalizes cosmetic ingredient (INCI) lists.
///
/// Normalization only removes differences that do not change which ingredient is meant:
/// case, spacing, list punctuation, percentages, footnote marks and a short list of
/// well-known INCI synonyms (Aqua = Water = Eau, Parfum = Fragrance, ...). Names that
/// merely look alike are never merged (e.g. "ascorbic acid" and "sodium ascorbyl
/// phosphate" stay distinct).
class NormalizedIngredient {
  /// The text as written on the list (cleaned of bullets and footnote marks).
  final String display;

  /// Lower-case identity used for duplicate detection and rule matching.
  final String key;

  const NormalizedIngredient(this.display, this.key);

  @override
  String toString() => display;
}

class IngredientNormalizer {
  /// Well-understood INCI synonyms -> one identity. Kept deliberately small.
  static const Map<String, String> synonyms = {
    'aqua': 'water',
    'eau': 'water',
    'aqua/water': 'water',
    'water/aqua': 'water',
    'aqua/water/eau': 'water',
    'water/aqua/eau': 'water',
    'aqua (water)': 'water',
    'water (aqua)': 'water',
    'parfum': 'fragrance',
    'parfum/fragrance': 'fragrance',
    'fragrance/parfum': 'fragrance',
    'parfum (fragrance)': 'fragrance',
    'l-ascorbic acid': 'ascorbic acid',
    'retinaldehyde': 'retinal',
    'gluconolactone (pha)': 'gluconolactone',
  };

  static final _leadingLabel = RegExp(
    r'^\s*(ingredients?|ingr[ée]dients?|inci|composition|zutaten|ingredientes)\s*[:.]\s*',
    caseSensitive: false,
  );
  static final _mayContain = RegExp(r'\[?\s*\+/-\s*|\bmay contain\b', caseSensitive: false);
  static final _percent = RegExp(r'\s*\(?\d+(?:[.,]\d+)?\s*%\)?');

  /// Splits a list into ingredients. Commas, semicolons, bullets and line breaks
  /// separate entries; "/" does not (it is part of names like "Caprylic/Capric Triglyceride").
  /// Commas inside parentheses (e.g. "Tocopherol (Vitamin E, natural)") are kept.
  static List<String> split(String? raw) {
    if (raw == null) return const [];
    var text = raw.replaceFirst(_leadingLabel, '');
    final parts = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    for (final ch in text.split('')) {
      if (ch == '(' || ch == '[') depth++;
      if ((ch == ')' || ch == ']') && depth > 0) depth--;
      if (depth == 0 && (ch == ',' || ch == ';' || ch == '•' || ch == '\n' || ch == '\r' || ch == '·')) {
        parts.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    parts.add(buf.toString());
    return parts
        .map((s) => s.replaceAll(RegExp(r'^[\s•\-\*·]+'), '').replaceAll(RegExp(r'[\s.*†]+$'), '').trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Identity for one ingredient name.
  static String keyOf(String name) {
    var s = name.toLowerCase().replaceAll(_mayContain, '').replaceAll(_percent, '');
    s = s.replaceAll(RegExp(r'[*†]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'\s*/\s*'), '/');
    final direct = synonyms[s];
    if (direct != null) return direct;
    // "Aqua (Water)"-style: a synonym in parentheses names the same ingredient.
    final paren = RegExp(r'^(.*?)\s*\((.*)\)$').firstMatch(s);
    if (paren != null) {
      final outer = paren.group(1)!.trim();
      final inner = paren.group(2)!.trim();
      final o = synonyms[outer] ?? outer;
      final i = synonyms[inner] ?? inner;
      if (o == i) return o;
      // Botanical names like "Oryza Sativa (Rice) Extract" keep their outer INCI name.
      return synonyms[outer] ?? outer;
    }
    return s;
  }

  /// Parsed, de-duplicated list (first occurrence kept).
  static List<NormalizedIngredient> parse(String? raw) {
    final seen = <String>{};
    final out = <NormalizedIngredient>[];
    for (final part in split(raw)) {
      final key = keyOf(part);
      if (key.length < 2 || !seen.add(key)) continue;
      out.add(NormalizedIngredient(part, key));
    }
    return out;
  }

  /// Number of entries that were repeats of an earlier ingredient.
  static int duplicateCount(String? raw) {
    final all = split(raw).map(keyOf).where((k) => k.length >= 2).toList();
    return all.length - all.toSet().length;
  }

  /// The list with repeated ingredients removed, in original order and wording.
  static String dedupe(String raw) => parse(raw).map((i) => i.display).join(', ');

  /// True when the list looks cut off ("...", "…", "etc."), as some database
  /// records and catalog entries are. Such a list cannot support a complete check.
  static bool looksIncomplete(String? raw) {
    if (raw == null) return false;
    final t = raw.trim().toLowerCase();
    return t.endsWith('...') || t.endsWith('…') || t.endsWith('etc') || t.endsWith('etc.');
  }

  /// Extracts the ingredient section from OCR text of a product label, or null when no
  /// ingredient heading is found. Everything after the heading up to a blank line or a
  /// typical next section ("Directions", "Warnings", ...) is returned for user review.
  static String? extractFromLabelText(String ocrText) {
    final m = RegExp(
      r'(ingredients?|ingr[ée]dients?|inci)\s*[:.]?\s*([\s\S]+)',
      caseSensitive: false,
    ).firstMatch(ocrText);
    if (m == null) return null;
    var body = m.group(2)!;
    final stop = RegExp(
      r'\n\s*\n|\b(directions|how to use|warnings?|caution|precautions?|made in|distributed by|mode d.emploi)\b',
      caseSensitive: false,
    ).firstMatch(body);
    if (stop != null) body = body.substring(0, stop.start);
    body = body.replaceAll(RegExp(r'-\s*\n\s*'), '').replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    return body.isEmpty ? null : body;
  }
}
