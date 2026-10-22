import '../models/category_model.dart';

/// A category suggested for a product, with where it came from. Suggestions are shown to
/// the user for confirmation; they are never product facts.
class CategorySuggestion {
  final String categoryId;
  final CategorySource source;

  /// The words that produced the suggestion, e.g. "face cleanser" or "en:sunscreens".
  final String matchedTerm;

  /// True for generic words that only hint at a category ("cream", "mask", "SPF" alone).
  final bool weak;

  const CategorySuggestion(this.categoryId, this.source, this.matchedTerm, {this.weak = false});

  String get categoryName => CategoryModel.byId(categoryId)?.categoryName ?? categoryId;

  String get explanation => switch (source) {
        CategorySource.productDatabase => 'Suggested from the product database category "$matchedTerm"',
        _ => weak
            ? 'Possible match from the word "$matchedTerm": please check'
            : 'Suggested from "$matchedTerm" in the name',
      };
}

class _Rule {
  final String categoryId;
  final List<String> phrases;
  final bool weak;
  const _Rule(this.categoryId, this.phrases, {this.weak = false});
}

/// Deterministic category suggestions from product text (receipt lines, product names and
/// product-database category tags).
///
/// * Whole words only ("lash" does not match "splash"; "gloss" does not match "Glossier").
/// * Rules are ordered from specific to generic and the first match wins, so "eye cream"
///   is Eye Care, "body lotion" is Body Care and "sun cream" is Sunscreen before the
///   generic "cream" (Moisturizer) is considered. "SPF" alone only decides when no product
///   type is named ("Foundation SPF 15" stays Foundation).
/// * No match returns null: the line stays uncategorized for the user to choose.
class CategoryClassifier {
  static const _rules = <_Rule>[
    _Rule('fragrance', ['eau de parfum', 'eau de toilette', 'eau de cologne', 'perfume', 'parfum', 'cologne', 'edp', 'edt', 'body mist', 'fragrance mist']),
    _Rule('eye_cream', ['eye cream', 'eye gel', 'eye serum', 'eye contour', 'under eye', 'eye balm', 'eye care', 'eye patch']),
    _Rule('nail_care', ['nail polish', 'nail lacquer', 'nail varnish', 'nail paint', 'nail', 'cuticle']),
    _Rule('lip_care', ['lip balm', 'lip mask', 'lip oil', 'lip scrub', 'lip care', 'lip treatment', 'lip butter', 'lip sleeping mask', 'chapstick']),
    _Rule('lip_gloss', ['lip gloss', 'lipgloss', 'gloss']),
    _Rule('lipstick', ['lipstick', 'lip stick', 'lip colour', 'lip color', 'lip tint', 'lip crayon', 'lip liner', 'lip lacquer', 'liquid lip', 'matte lip']),
    _Rule('eyeliner', ['eyeliner', 'eye liner', 'kohl', 'kajal']),
    _Rule('eyeshadow', ['eyeshadow', 'eye shadow', 'shadow palette']),
    _Rule('mascara', ['mascara']),
    _Rule('sunscreen', ['sunscreen', 'sun screen', 'sunblock', 'sun block', 'sun cream', 'sun lotion', 'sun protection', 'sun fluid', 'sun stick', 'sun milk', 'sun care']),
    _Rule('hair_care', ['shampoo', 'conditioner', 'hair', 'scalp']),
    _Rule('body_care', ['body lotion', 'body wash', 'body butter', 'body oil', 'body scrub', 'body cream', 'shower gel', 'hand cream', 'hand wash', 'foot cream', 'deodorant', 'antiperspirant', 'body']),
    _Rule('cleanser', ['cleanser', 'face wash', 'facial wash', 'facewash', 'cleansing', 'micellar', 'makeup remover', 'make up remover', 'foaming wash']),
    _Rule('toner', ['toner', 'toning', 'face mist', 'facial mist', 'tonique']),
    _Rule('face_mask', ['face mask', 'facial mask', 'sheet mask', 'clay mask', 'sleeping mask', 'peel off mask']),
    _Rule('exfoliant', ['exfoliant', 'exfoliator', 'peeling', 'peel', 'scrub']),
    _Rule('concealer', ['concealer']),
    _Rule('primer', ['primer']),
    _Rule('foundation', ['foundation', 'bb cream', 'cc cream', 'skin tint', 'cushion foundation']),
    _Rule('blush', ['blush', 'blusher']),
    _Rule('serum', ['serum', 'ampoule']),
    _Rule('treatment', ['spot treatment', 'acne treatment', 'blemish', 'pimple patch', 'acne patch', 'treatment']),
    _Rule('moisturizer', ['moisturizer', 'moisturiser', 'moisturizing cream', 'moisturising cream', 'face cream', 'facial cream', 'day cream', 'night cream', 'gel cream', 'water cream', 'hydrator']),
    _Rule('moisturizer', ['cream', 'lotion', 'emulsion', 'creme'], weak: true),
    _Rule('face_mask', ['mask', 'masque'], weak: true),
    _Rule('sunscreen', ['spf', 'uv protection'], weak: true),
    _Rule('exfoliant', ['exfoliating', 'aha', 'bha'], weak: true),
    // "Essence" is also a makeup brand.
    _Rule('serum', ['essence', 'booster'], weak: true),
  ];

  /// Brand/store names that contain category words and must not decide a category.
  static const _ignoredPhrases = ['the body shop', 'body shop', 'bath and body works', 'bath body works'];

  /// Words of [text]: lowercase, "&" read as "and", letters and digits split apart
  /// ("SPF50" -> "spf 50"), everything else a separator.
  static List<String> tokens(String text) {
    var t = text.toLowerCase().replaceAll('&', ' and ');
    t = t.replaceAllMapped(RegExp(r'([a-z])(\d)'), (m) => '${m[1]} ${m[2]}');
    t = t.replaceAllMapped(RegExp(r'(\d)([a-z])'), (m) => '${m[1]} ${m[2]}');
    t = t.replaceAll(RegExp(r'[^a-z0-9éèêà]+'), ' ').trim();
    if (t.isEmpty) return const [];
    var joined = ' $t ';
    for (final p in _ignoredPhrases) {
      joined = joined.replaceAll(' $p ', ' ');
    }
    return joined.trim().isEmpty ? const [] : joined.trim().split(' ');
  }

  static bool _wordMatches(String token, String word, {required bool allowPlural}) =>
      token == word || (allowPlural && (token == '${word}s' || token == '${word}es'));

  static bool _containsPhrase(List<String> toks, String phrase) {
    final words = phrase.split(' ');
    for (var i = 0; i + words.length <= toks.length; i++) {
      var ok = true;
      for (var j = 0; j < words.length && ok; j++) {
        ok = _wordMatches(toks[i + j], words[j], allowPlural: j == words.length - 1);
      }
      if (ok) return true;
    }
    return false;
  }

  /// Suggestion from a product name or receipt line, or null when nothing identifies one.
  static CategorySuggestion? fromName(String text) => _classify(text, CategorySource.nameClassifier);

  static CategorySuggestion? _classify(String text, CategorySource source, {String? term}) {
    final toks = tokens(text);
    if (toks.isEmpty) return null;
    for (final rule in _rules) {
      for (final phrase in rule.phrases) {
        if (_containsPhrase(toks, phrase)) {
          return CategorySuggestion(rule.categoryId, source, term ?? phrase, weak: rule.weak);
        }
      }
    }
    return null;
  }

  /// Suggestion from a product database's own category data, e.g. Open Beauty Facts
  /// `categories_hierarchy` / `categories_tags` ("en:face-cleansers"). Tags are tried from
  /// the most specific (last) to the most general; generic-word matches are not used here,
  /// because a database category like "en:creams" says little about the product type.
  static CategorySuggestion? fromDatabaseCategories(Iterable<String> tags) {
    final list = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    for (final tag in list.reversed) {
      final text = tag.contains(':') ? tag.substring(tag.indexOf(':') + 1) : tag;
      final s = _classify(text.replaceAll('-', ' '), CategorySource.productDatabase, term: tag);
      if (s != null && !s.weak) return s;
    }
    return null;
  }
}
