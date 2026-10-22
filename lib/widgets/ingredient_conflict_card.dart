import 'package:flutter/material.dart';
import '../../models/vanity_item_model.dart';
import '../../services/ingredient_conflict_service.dart';
import 'edit_ingredients_dialog.dart';

class IngredientConflictCard extends StatelessWidget {
  final List<VanityItemModel> items;
  final String routineName;
  final VoidCallback? onIngredientsUpdated;

  const IngredientConflictCard({
    super.key,
    required this.items,
    required this.routineName,
    this.onIngredientsUpdated,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final analysis = IngredientConflictService.analyzeRoutine(
      routineType: routineName,
      items: items,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (analysis.hasConflicts)
          _buildConflictsCard(context, analysis)
        // Only report "no conflicts" for products that were actually checked.
        else if (analysis.assessedItems.length >= 2)
          _buildCleanCard(context, analysis),
        if (analysis.missingDataItems.isNotEmpty || analysis.incompleteDataItems.isNotEmpty)
          _buildMissingDataCard(context, analysis.missingDataItems, analysis.incompleteDataItems),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildCleanCard(BuildContext context, RoutineConflictAnalysis analysis) {
    final complete = analysis.isCompleteCheck;
    return Card(
      color: Colors.green.shade50,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.green.shade200),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.green, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                complete
                    ? 'No combination matched the app\'s ${IngredientConflictService.rules.length} reviewed caution rules. '
                        'This is not a guarantee of compatibility or safety.'
                    : 'No conflict detected among the ingredients that are known. '
                        'This is NOT a complete check: some products below have missing or incomplete ingredient lists.',
                key: const ValueKey('conflict-clean-text'),
                style: const TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConflictsCard(BuildContext context, RoutineConflictAnalysis analysis) {
    return Card(
      color: Colors.amber.shade50,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.amber.shade300),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Potential Ingredient Concerns (${analysis.conflicts.length})',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.amber.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'These are cautions from the cited sources, not prohibitions. Many people use these together; '
              'strength, pH and how often you use each product matter.',
              style: TextStyle(fontSize: 12, color: Colors.brown.shade800),
            ),
            if (!analysis.isCompleteCheck) ...[
              const SizedBox(height: 6),
              Text(
                'Not a complete check: some products have missing or incomplete ingredient lists.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.brown.shade900),
              ),
            ],
            const SizedBox(height: 10),
            ...analysis.conflicts.map((conflict) => _buildConflictDetail(context, conflict)),
            const Divider(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.brown.shade400),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Educational guide based on dermatological literature. Consult a board-certified dermatologist for tailored medical advice.',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Colors.brown.shade600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConflictDetail(BuildContext context, DetectedConflict conflict) {
    final isWarning = conflict.rule.severity == ConflictSeverity.warning;
    final badgeColor = isWarning ? Colors.red.shade700 : Colors.amber.shade900;
    final badgeLabel = isWarning ? 'CAUTION' : 'ADVISORY';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badgeLabel,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${conflict.itemA.product?.name ?? "Product 1"} & ${conflict.itemB.product?.name ?? "Product 2"}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            conflict.rule.description,
            style: const TextStyle(fontSize: 12, height: 1.3),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recommendation: ${conflict.rule.recommendation}',
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
                ),
                if (conflict.involvesRinseOff) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'One of these is a rinse-off product, so skin contact is short.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
                if (conflict.rule.limitations.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Limits: ${conflict.rule.limitations}', style: const TextStyle(fontSize: 11)),
                ],
                if (conflict.rule.referenceCitation.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Source: ${conflict.rule.referenceCitation} (${conflict.rule.referenceUrl})',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Colors.grey.shade700,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMissingDataCard(
    BuildContext context,
    List<VanityItemModel> itemsWithMissing,
    List<VanityItemModel> itemsIncomplete,
  ) {
    final needsData = [...itemsWithMissing, ...itemsIncomplete];
    return Card(
      color: Colors.blueGrey.shade50,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.blueGrey.shade200),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, size: 18, color: Colors.blueGrey.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      if (itemsWithMissing.isNotEmpty) '${itemsWithMissing.length} product(s) not checked: no ingredient list',
                      if (itemsIncomplete.isNotEmpty) '${itemsIncomplete.length} product(s) with an incomplete list',
                    ].join(' · '),
                    key: const ValueKey('conflict-missing-data'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.blueGrey.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'A complete conflict check is not possible until ingredients are added for: '
              '${needsData.map((i) => i.product?.name ?? "Item").join(", ")}. '
              'A missing list does not mean the product contains no actives.',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: needsData.map((item) {
                return ActionChip(
                  avatar: const Icon(Icons.edit, size: 14),
                  label: Text(
                    'Add for ${item.product?.name ?? "Item"}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () async {
                    final updated = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => EditIngredientsDialog(item: item),
                    );
                    if (updated == true && onIngredientsUpdated != null) {
                      onIngredientsUpdated!();
                    }
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
