import '../models/product_model.dart';
import '../utils/ingredient_normalizer.dart';

/// A field where the user's confirmed value and the database disagree.
class ProductDataDiscrepancy {
  final String field; // 'pao' or 'ingredients'
  final String currentValue;
  final String fetchedValue;
  final String explanation;

  const ProductDataDiscrepancy({
    required this.field,
    required this.currentValue,
    required this.fetchedValue,
    required this.explanation,
  });
}

class ProductMergeResult {
  final ProductModel merged;

  /// Human-readable list of what would change.
  final List<String> changes;

  /// Confirmed values that were kept although the database differs.
  final List<ProductDataDiscrepancy> discrepancies;

  const ProductMergeResult(this.merged, this.changes, this.discrepancies);

  bool get hasChanges => changes.isNotEmpty;
}

/// Merges freshly looked-up product data into a saved product without losing anything the
/// user confirmed. Source priority (PAO and ingredients):
///   packaging / user  >  product database  >  app catalog / category estimate / unknown.
/// A database value replaces an estimate or an older database value; it never silently
/// replaces a value from the packaging or the user. Those conflicts are returned as
/// [ProductMergeResult.discrepancies], and are only applied when the caller passes
/// [acceptDatabasePao] / [acceptDatabaseIngredients] after the user chose so.
class ProductDataMerge {
  static ProductMergeResult merge({
    required ProductModel current,
    required ProductModel fetched,
    required String sourceName,
    bool acceptDatabasePao = false,
    bool acceptDatabaseIngredients = false,
  }) {
    var merged = current;
    final changes = <String>[];
    final discrepancies = <ProductDataDiscrepancy>[];

    // ---- PAO: only an explicit, product-specific PAO from the record counts.
    final fetchedPao = fetched.paoSource == PaoSource.productDatabase ? fetched.knownPaoMonths : null;
    if (fetchedPao != null) {
      final currentPao = current.knownPaoMonths;
      if (current.paoSource.isVerified) {
        if (currentPao != fetchedPao) {
          if (acceptDatabasePao) {
            merged = merged.copyWith(paoMonths: fetchedPao, paoSource: PaoSource.productDatabase);
            changes.add('PAO changed from your $currentPao months to $fetchedPao months ($sourceName).');
          } else {
            discrepancies.add(ProductDataDiscrepancy(
              field: 'pao',
              currentValue: '$currentPao months',
              fetchedValue: '$fetchedPao months',
              explanation: '$sourceName lists $fetchedPao months; you confirmed $currentPao months. '
                  'Your value is kept unless you choose the database value. Check the open-jar symbol on the pack.',
            ));
          }
        }
      } else if (currentPao != fetchedPao || current.paoSource != PaoSource.productDatabase) {
        merged = merged.copyWith(paoMonths: fetchedPao, paoSource: PaoSource.productDatabase);
        changes.add(currentPao == null
            ? 'PAO set to $fetchedPao months from $sourceName (was unknown).'
            : 'PAO set to $fetchedPao months from $sourceName (was ${current.paoSource == PaoSource.productDatabase ? '' : 'an unverified '}$currentPao months).');
      }
    }

    // ---- Ingredients
    final fetchedList = fetched.ingredientList;
    if (fetchedList != null) {
      final currentList = current.ingredientList;
      final same = currentList != null && _sameIngredients(currentList, fetchedList);
      ProductModel adopt() => merged.copyWith(
            ingredients: fetchedList,
            inci: fetchedList,
            ingredientsSource: fetched.ingredientsSource == IngredientSource.notRecorded
                ? IngredientSource.productDatabase
                : fetched.ingredientsSource,
            ingredientsUpdatedAt: fetched.ingredientsUpdatedAt ?? DateTime.now(),
            ingredientsContext: fetched.ingredientsContext,
          );
      if (currentList == null) {
        merged = adopt();
        changes.add('Ingredient list added from $sourceName (${IngredientNormalizer.parse(fetchedList).length} ingredients).');
      } else if (current.ingredientsSource.isConfirmed) {
        if (!same) {
          if (acceptDatabaseIngredients) {
            merged = adopt();
            changes.add('Your ingredient list was replaced by the $sourceName list.');
          } else {
            discrepancies.add(ProductDataDiscrepancy(
              field: 'ingredients',
              currentValue: '${IngredientNormalizer.parse(currentList).length} ingredients (yours)',
              fetchedValue: '${IngredientNormalizer.parse(fetchedList).length} ingredients ($sourceName)',
              explanation: 'The database list differs from the list you confirmed. Formulas can differ by '
                  'country or version; your list is kept unless you choose the database list.',
            ));
          }
        }
      } else if (!same) {
        merged = adopt();
        changes.add('Ingredient list updated from $sourceName (the previous list was not confirmed).');
      }
    }

    // ---- Descriptive fields: only fill what is empty; never overwrite the user's text.
    String? fill(String current, String fetchedValue, String label) {
      if (current.trim().isEmpty && fetchedValue.trim().isNotEmpty) {
        changes.add('$label filled from $sourceName.');
        return fetchedValue;
      }
      return null;
    }

    merged = merged.copyWith(
      name: fill(current.name, fetched.name, 'Name'),
      brand: fill(current.brand, fetched.brand, 'Brand'),
      volume: fill(current.volume ?? '', fetched.volume ?? '', 'Size'),
      imageUrl: fill(current.imageUrl ?? '', fetched.imageUrl ?? '', 'Image'),
      barcodeScanUrl: (current.barcodeScanUrl ?? '').isEmpty ? fetched.barcodeScanUrl : null,
    );

    return ProductMergeResult(merged, changes, discrepancies);
  }

  static bool _sameIngredients(String a, String b) {
    final ka = IngredientNormalizer.parse(a).map((i) => i.key).toList();
    final kb = IngredientNormalizer.parse(b).map((i) => i.key).toList();
    if (ka.length != kb.length) return false;
    for (var i = 0; i < ka.length; i++) {
      if (ka[i] != kb[i]) return false;
    }
    return true;
  }
}
