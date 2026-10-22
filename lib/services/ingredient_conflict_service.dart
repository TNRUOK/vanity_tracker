import '../models/vanity_item_model.dart';
import '../utils/ingredient_normalizer.dart';

enum ConflictSeverity {
  warning, // "Caution": plausible extra irritation, or a caution printed on a drug label
  info, // "Advisory": weaker or lab-only evidence, or a timing suggestion
}

/// One reviewed, source-backed caution. Rules are educational: they flag combinations a
/// cited source cautions about; they do not declare products incompatible or unsafe, and
/// the absence of a match does not mean a routine is safe.
class IngredientConflictRule {
  final String id;
  final String title;
  final ConflictSeverity severity;

  /// Normalized ingredient names (see [IngredientNormalizer.keyOf]); matched exactly.
  final List<String> primaryGroup;
  final List<String> secondaryGroup;

  /// Plain-language explanation of the possible issue.
  final String description;
  final String recommendation;
  final String referenceCitation;
  final String referenceUrl;

  /// Short verbatim excerpt from the source that supports the rule.
  final String sourceQuote;

  /// What the rule does not know (concentration, pH, rinse-off, skin type, ...).
  final String limitations;

  /// When the rule and its source were last reviewed for this project.
  final String reviewedOn;

  const IngredientConflictRule({
    required this.id,
    required this.title,
    required this.severity,
    required this.primaryGroup,
    required this.secondaryGroup,
    required this.description,
    required this.recommendation,
    required this.referenceCitation,
    required this.referenceUrl,
    this.sourceQuote = '',
    this.limitations = '',
    this.reviewedOn = '',
  });
}

class DetectedConflict {
  final IngredientConflictRule rule;
  final VanityItemModel itemA;
  final VanityItemModel itemB;
  final String matchedIngredientA;
  final String matchedIngredientB;

  /// One of the two products is washed off (e.g. a cleanser), so skin contact is short.
  final bool involvesRinseOff;

  const DetectedConflict({
    required this.rule,
    required this.itemA,
    required this.itemB,
    required this.matchedIngredientA,
    required this.matchedIngredientB,
    this.involvesRinseOff = false,
  });

  /// Unique signature to prevent duplicate warnings
  String get deduplicationKey {
    final ids = [itemA.vanityItemId, itemB.vanityItemId]..sort();
    return '${rule.id}_${ids[0]}_${ids[1]}';
  }
}

class RoutineConflictAnalysis {
  final String routineType; // 'AM', 'PM', 'Weekly', 'Custom'
  final List<DetectedConflict> conflicts;

  /// Products whose ingredient lists were checked.
  final List<VanityItemModel> assessedItems;

  /// Products with no ingredient list: they were NOT checked.
  final List<VanityItemModel> missingDataItems;

  /// Checked products whose list looks cut off ("..."), so the check is partial.
  final List<VanityItemModel> incompleteDataItems;

  const RoutineConflictAnalysis({
    required this.routineType,
    required this.conflicts,
    required this.assessedItems,
    required this.missingDataItems,
    this.incompleteDataItems = const [],
  });

  bool get hasConflicts => conflicts.isNotEmpty;
  bool get hasMissingData => missingDataItems.isNotEmpty;

  /// True only when every product had a complete-looking ingredient list. Even then the
  /// result means "no match against the app's rules", not "verified compatible".
  bool get isCompleteCheck => missingDataItems.isEmpty && incompleteDataItems.isEmpty && assessedItems.isNotEmpty;

  /// No rule matched and every product could be checked.
  bool get isClean => isCompleteCheck && conflicts.isEmpty;
}

class IngredientConflictService {
  static const _retinoids = [
    'retinol',
    'retinal',
    'tretinoin',
    'adapalene',
    'tazarotene',
    'trifarotene',
    'hydroxypinacolone retinoate',
  ];

  /// Exfoliating acids, by INCI name. Citric/malic/tartaric acid are deliberately left out:
  /// in most products they are small-dose pH adjusters, and matching them would flag
  /// almost every routine.
  static const _exfoliatingAcids = ['glycolic acid', 'lactic acid', 'mandelic acid', 'salicylic acid'];

  static const _aadExfoliation =
      'https://www.aad.org/public/everyday-care/skin-care-secrets/routine/safely-exfoliate-at-home';

  /// Reviewed rule catalog (v2, 2026-10-18). Sources were read for this review; rules
  /// whose cited sources did not support them were removed (see project report).
  static final List<IngredientConflictRule> rules = [
    const IngredientConflictRule(
      id: 'retinoid_direct_acid',
      title: 'Retinoid + exfoliating acid (AHA/BHA)',
      severity: ConflictSeverity.warning,
      primaryGroup: _retinoids,
      secondaryGroup: _exfoliatingAcids,
      description:
          'Retinoids can make skin more sensitive and prone to peeling; exfoliating at the same time may increase dryness or irritation for some people.',
      recommendation:
          'Consider using them at different times (e.g. AM and PM) or on different days, and follow each product\'s directions. Stop and seek advice if irritation develops.',
      referenceCitation: 'American Academy of Dermatology (AAD), "How to safely exfoliate at home"',
      referenceUrl: _aadExfoliation,
      sourceQuote:
          'Some medications and even over-the-counter products may cause your skin to be more sensitive or peel, '
          'such as prescription retinoid creams or products containing retinol or benzoyl peroxide. '
          'Exfoliating while using these products may worsen dry skin or even cause acne breakouts.',
      limitations:
          'Ingredient lists do not show strength or pH; many people tolerate this combination, and rinse-off products have short contact.',
      reviewedOn: '2026-10-18',
    ),
    const IngredientConflictRule(
      id: 'tretinoin_keratolytic',
      title: 'Tretinoin + salicylic acid, sulfur or resorcinol',
      severity: ConflictSeverity.warning,
      primaryGroup: ['tretinoin'],
      secondaryGroup: ['salicylic acid', 'sulfur', 'resorcinol'],
      description: 'The tretinoin drug label asks for particular caution when it is used with these ingredients.',
      recommendation: 'Follow your prescriber\'s or pharmacist\'s advice before combining them.',
      referenceCitation: 'Tretinoin cream prescribing information (DailyMed, U.S. National Library of Medicine)',
      referenceUrl: 'https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query=tretinoin+cream',
      sourceQuote:
          'Particular caution should be exercised in using preparations containing sulfur, resorcinol, or salicylic acid with tretinoin.',
      limitations: 'Applies to tretinoin (a prescription medicine) only, not to cosmetic retinol.',
      reviewedOn: '2026-10-18',
    ),
    const IngredientConflictRule(
      id: 'retinoid_benzoyl_peroxide',
      title: 'Tretinoin + benzoyl peroxide (applied together)',
      severity: ConflictSeverity.info,
      primaryGroup: ['tretinoin'],
      secondaryGroup: ['benzoyl peroxide'],
      description:
          'In a laboratory study, tretinoin mixed with benzoyl peroxide broke down quickly under light; adapalene stayed stable.',
      recommendation:
          'If you use both, ask your prescriber about timing (e.g. not applied at the same time). Combined acne treatments are common under medical supervision.',
      referenceCitation:
          'Martin B. et al., Br J Dermatol 1998;139 Suppl 52:8-11 (Chemical stability of adapalene and tretinoin when combined with benzoyl peroxide)',
      referenceUrl: 'https://doi.org/10.1046/j.1365-2133.1998.1390s2008.x',
      sourceQuote:
          'The combination of benzoyl peroxide and light results in more than 50% degradation of tretinoin in about 2 h and 95% in 24 h.',
      limitations:
          'Lab (in vitro) mixing study, not a study of skin; does not apply to adapalene, and some tretinoin formulations differ.',
      reviewedOn: '2026-10-18',
    ),
    const IngredientConflictRule(
      id: 'stacked_exfoliants',
      title: 'More than one exfoliating-acid product',
      severity: ConflictSeverity.info,
      primaryGroup: _exfoliatingAcids,
      secondaryGroup: _exfoliatingAcids,
      description: 'Using several exfoliating products in one routine raises the chance of over-exfoliating.',
      recommendation: 'Watch for redness or irritation; one exfoliating product per routine is often enough.',
      referenceCitation: 'American Academy of Dermatology (AAD), "How to safely exfoliate at home"',
      referenceUrl: _aadExfoliation,
      sourceQuote: 'Be careful not to over-exfoliate, as this could lead to skin that is red and irritated.',
      limitations: 'Strength and how often each product is used are unknown; rinse-off cleansers have short contact.',
      reviewedOn: '2026-10-18',
    ),
  ];

  /// Lower-case ingredient entries (kept for compatibility; matching uses normalized keys).
  static List<String> tokenizeIngredients(String? rawIngredients) {
    return IngredientNormalizer.split(rawIngredients)
        .map((s) => s.toLowerCase())
        .where((s) => s.length > 2)
        .toList();
  }

  static bool _isRinseOff(VanityItemModel item) {
    final p = item.product;
    if (p == null) return false;
    final name = p.name.toLowerCase();
    return p.categoryId == 'cleanser' || RegExp(r'\b(cleanser|face wash|wash|shampoo)\b').hasMatch(name);
  }

  /// Analyze a group of vanity items belonging to a routine (AM, PM, Weekly)
  static RoutineConflictAnalysis analyzeRoutine({
    required String routineType,
    required List<VanityItemModel> items,
  }) {
    final assessedItems = <VanityItemModel>[];
    final missingDataItems = <VanityItemModel>[];
    final incompleteDataItems = <VanityItemModel>[];
    final keysById = <String, Set<String>>{};
    final detectedMap = <String, DetectedConflict>{};

    for (final item in items) {
      final list = item.product?.ingredientList;
      final parsed = IngredientNormalizer.parse(list);
      if (parsed.isEmpty) {
        // No list: this product was not checked, and that is reported, never treated as
        // "contains nothing relevant".
        missingDataItems.add(item);
        continue;
      }
      assessedItems.add(item);
      keysById[item.vanityItemId] = parsed.map((i) => i.key).toSet();
      if (IngredientNormalizer.looksIncomplete(list)) incompleteDataItems.add(item);
    }

    // Evaluate pair combinations across assessed items (different products only).
    for (int i = 0; i < assessedItems.length; i++) {
      for (int j = i + 1; j < assessedItems.length; j++) {
        final itemA = assessedItems[i];
        final itemB = assessedItems[j];
        final keysA = keysById[itemA.vanityItemId]!;
        final keysB = keysById[itemB.vanityItemId]!;
        final rinseOff = _isRinseOff(itemA) || _isRinseOff(itemB);

        for (final rule in rules) {
          final matchA1 = _findMatchingIngredient(keysA, rule.primaryGroup);
          final matchB1 = _findMatchingIngredient(keysB, rule.secondaryGroup);
          if (matchA1 != null && matchB1 != null) {
            final conflict = DetectedConflict(
              rule: rule,
              itemA: itemA,
              itemB: itemB,
              matchedIngredientA: matchA1,
              matchedIngredientB: matchB1,
              involvesRinseOff: rinseOff,
            );
            detectedMap[conflict.deduplicationKey] = conflict;
            continue;
          }

          // Check inverted pair: B in primary and A in secondary
          final matchB2 = _findMatchingIngredient(keysB, rule.primaryGroup);
          final matchA2 = _findMatchingIngredient(keysA, rule.secondaryGroup);
          if (matchB2 != null && matchA2 != null) {
            final conflict = DetectedConflict(
              rule: rule,
              itemA: itemB,
              itemB: itemA,
              matchedIngredientA: matchB2,
              matchedIngredientB: matchA2,
              involvesRinseOff: rinseOff,
            );
            detectedMap[conflict.deduplicationKey] = conflict;
          }
        }
      }
    }

    return RoutineConflictAnalysis(
      routineType: routineType,
      conflicts: detectedMap.values.toList(),
      assessedItems: assessedItems,
      missingDataItems: missingDataItems,
      incompleteDataItems: incompleteDataItems,
    );
  }

  /// Exact match on normalized ingredient names. Substring matching is deliberately not
  /// used: it made a bare "acid" match "glycolic acid" and similar false alarms.
  static String? _findMatchingIngredient(Set<String> keys, List<String> targets) {
    for (final target in targets) {
      if (keys.contains(target)) return target;
    }
    return null;
  }
}
