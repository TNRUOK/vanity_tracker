import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vanity_item_model.dart';
import '../providers/vanity_provider.dart';
import '../screens/routine/routine_screen.dart';
import '../services/database_service.dart';
import '../services/ingredient_conflict_service.dart';
import '../theme/app_theme.dart';

/// Display names of the app's routines, keyed by routine tag.
const routineNames = {
  'AM': 'Morning Routine (AM)',
  'PM': 'Evening Routine (PM)',
  'Weekly': 'Weekly Treatments',
};

/// Bottom sheet for putting an existing inventory item into routines (or taking it out).
/// The item itself is reused: no inventory record is created or copied.
class AddToRoutineSheet extends StatefulWidget {
  final String vanityItemId;

  const AddToRoutineSheet({super.key, required this.vanityItemId});

  /// Returns a summary message after a save, or null when closed without changes.
  static Future<String?> show(BuildContext context, String vanityItemId) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AddToRoutineSheet(vanityItemId: vanityItemId),
    );
  }

  @override
  State<AddToRoutineSheet> createState() => _AddToRoutineSheetState();
}

class _AddToRoutineSheetState extends State<AddToRoutineSheet> {
  Set<String>? _selected;
  bool _saving = false;
  String? _error;

  VanityItemModel? _item(VanityProvider prov) =>
      prov.allItems.where((i) => i.vanityItemId == widget.vanityItemId).firstOrNull;

  Future<void> _save(VanityProvider prov, VanityItemModel item) async {
    if (_saving) return; // a second tap while saving does nothing
    setState(() {
      _saving = true;
      _error = null;
    });
    final selected = _selected!;
    final before = item.routineTags.toSet();
    final added = VanityProvider.routineTagOrder.where((t) => selected.contains(t) && !before.contains(t));
    final removed = VanityProvider.routineTagOrder.where((t) => !selected.contains(t) && before.contains(t));
    final name = item.product?.name.isNotEmpty == true ? item.product!.name : 'Product';
    final parts = <String>[
      if (added.isNotEmpty) '$name added to ${added.map((t) => routineNames[t]).join(' and ')}.',
      if (removed.isNotEmpty) 'Removed from ${removed.map((t) => routineNames[t]).join(' and ')}.',
    ];
    try {
      final changed = await prov.setRoutineMembership(item.vanityItemId, selected);
      if (!mounted) return;
      Navigator.of(context).pop(changed ? parts.join(' ') : null);
    } on VanitySyncException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop('${parts.join(' ')} ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not update routines: ${e.toString().replaceAll('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<VanityProvider>();
    final item = _item(prov);
    if (item == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('This product is no longer on your shelf.'),
      );
    }
    final selected = _selected ??= item.routineTags.where(VanityProvider.routineTagOrder.contains).toSet();
    final unchanged = selected.length == item.routineTags.where(VanityProvider.routineTagOrder.contains).toSet().length &&
        selected.every(item.routineTags.contains);
    final name = item.product?.name.isNotEmpty == true ? item.product!.name : 'This product';

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Add to Routine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.textDark)),
              const SizedBox(height: 4),
              Text(name, style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
              const SizedBox(height: 8),
              const Text(
                'Choose one or more routines. Steps are listed in each routine\'s existing order. '
                'The product stays the same shelf item: nothing is copied.',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
              ),
              const SizedBox(height: 8),
              for (final tag in VanityProvider.routineTagOrder) _routineOption(prov, item, tag, selected),
              ..._conflictNotes(prov, item, selected),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: AppTheme.statusRed, fontSize: 12.5)),
                ),
              const SizedBox(height: 12),
              ElevatedButton(
                key: const ValueKey('routine-save'),
                onPressed: _saving || unchanged ? null : () => _save(prov, item),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryRose,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(unchanged ? 'No changes' : 'Save Routines'),
              ),
              TextButton.icon(
                key: const ValueKey('open-routines'),
                icon: const Icon(Icons.wb_sunny_outlined, size: 16),
                label: const Text('Open Routines'),
                onPressed: () {
                  final navigator = Navigator.of(context);
                  navigator.pop();
                  navigator.push(MaterialPageRoute(builder: (_) => const RoutineScreen()));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _routineOption(VanityProvider prov, VanityItemModel item, String tag, Set<String> selected) {
    final members = prov.routineItems(tag);
    final isMember = item.routineTags.contains(tag);
    final count = members.length;
    return Material(
      color: Colors.transparent,
      child: CheckboxListTile(
        key: ValueKey('routine-option-$tag'),
        contentPadding: EdgeInsets.zero,
        value: selected.contains(tag),
        activeColor: AppTheme.primaryRose,
        title: Text(routineNames[tag]!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(
          isMember
              ? 'Already in this routine (step ${members.indexWhere((i) => i.vanityItemId == item.vanityItemId) + 1} of $count). Untick to remove.'
              : (count == 0 ? 'No products yet' : '$count product${count == 1 ? '' : 's'}'),
          style: const TextStyle(fontSize: 12),
        ),
        onChanged: _saving
            ? null
            : (v) => setState(() {
                  if (v == true) {
                    selected.add(tag);
                  } else {
                    selected.remove(tag);
                  }
                }),
      ),
    );
  }

  /// What the existing conflict checker says about this product in each selected routine.
  /// Never claims the products are safe together: absence of a warning is reported as
  /// "none found by the checker", and unchecked products are listed.
  List<Widget> _conflictNotes(VanityProvider prov, VanityItemModel item, Set<String> selected) {
    final notes = <Widget>[];
    for (final tag in VanityProvider.routineTagOrder.where(selected.contains)) {
      final others = prov.routineItems(tag).where((i) => i.vanityItemId != item.vanityItemId).toList();
      if (others.isEmpty) continue;
      final analysis = IngredientConflictService.analyzeRoutine(routineType: tag, items: [...others, item]);
      final mine = analysis.conflicts
          .where((c) => c.itemA.vanityItemId == item.vanityItemId || c.itemB.vanityItemId == item.vanityItemId)
          .toList();
      final itemUnchecked = analysis.missingDataItems.any((i) => i.vanityItemId == item.vanityItemId);
      final othersUnchecked = analysis.missingDataItems.where((i) => i.vanityItemId != item.vanityItemId).length;

      final lines = <String>[
        for (final c in mine)
          '⚠ With ${(c.itemA.vanityItemId == item.vanityItemId ? c.itemB : c.itemA).product?.name ?? 'another product'}: '
              '${c.rule.description} (${c.rule.recommendation})',
        if (itemUnchecked) 'This product has no ingredients listed, so it could not be checked against this routine.',
        if (othersUnchecked > 0)
          '$othersUnchecked other product${othersUnchecked == 1 ? '' : 's'} in this routine '
              '${othersUnchecked == 1 ? 'has' : 'have'} no ingredients listed and could not be checked.',
        if (analysis.incompleteDataItems.isNotEmpty)
          '${analysis.incompleteDataItems.length} product${analysis.incompleteDataItems.length == 1 ? ' has' : 's have'} '
              'an incomplete ingredient list, so the check is partial.',
        if (mine.isEmpty && !itemUnchecked)
          'No known conflicts found by the app\'s checker for the products it could check. '
              'This is not a guarantee of compatibility.',
      ];
      notes.add(
        Container(
          key: ValueKey('routine-conflicts-$tag'),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: mine.isNotEmpty ? Colors.amber.shade50 : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: mine.isNotEmpty ? Colors.amber.shade300 : const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(routineNames[tag]!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(l, style: const TextStyle(fontSize: 11.5, height: 1.3)),
                ),
            ],
          ),
        ),
      );
    }
    return notes;
  }
}
