import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/product_model.dart';
import '../models/vanity_item_model.dart';
import '../providers/vanity_provider.dart';
import '../services/database_service.dart';
import '../services/packaging_ocr_service.dart';
import '../theme/app_theme.dart';
import '../utils/ingredient_normalizer.dart';

/// Add, scan, review, correct or clear one product's ingredient list.
///
/// Provenance is kept: a list read from a label photo (and reviewed here) is saved as
/// "from the product label"; a typed or edited list as "entered by you"; an unchanged
/// database list stays a database list unless the user ticks that they checked it
/// against their product's label.
class EditIngredientsDialog extends StatefulWidget {
  final VanityItemModel item;

  const EditIngredientsDialog({super.key, required this.item});

  static Future<bool?> show(BuildContext context, VanityItemModel item) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => EditIngredientsDialog(item: item),
    );
  }

  @override
  State<EditIngredientsDialog> createState() => _EditIngredientsDialogState();
}

class _EditIngredientsDialogState extends State<EditIngredientsDialog> {
  late TextEditingController _controller;
  late final String _initialText;
  bool _isSaving = false;
  bool _reading = false;
  String? _ocrNote;
  String? _ocrText; // what the label photo produced (before user edits)
  bool _confirmedAgainstLabel = false;

  @override
  void initState() {
    super.initState();
    _initialText = widget.item.product?.ingredientList ?? '';
    _controller = TextEditingController(text: _initialText);
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _scanLabel() async {
    setState(() {
      _reading = true;
      _ocrNote = null;
    });
    try {
      final text = await PackagingOcrService.pickAndRead();
      if (!mounted) return;
      if (text == null) {
        setState(() => _reading = false);
        return;
      }
      final section = IngredientNormalizer.extractFromLabelText(text);
      setState(() {
        _reading = false;
        if (text.trim().isEmpty) {
          _ocrNote = 'No text could be read from that photo. Try a sharper, well-lit photo of the list, or type it.';
          return;
        }
        _ocrText = section ?? text.trim();
        _controller.text = _ocrText!;
        _ocrNote = section != null
            ? 'Read from the photo. Text recognition can misread names: compare with the label and correct it before saving.'
            : 'No "Ingredients" heading was found, so all recognized text was inserted. Delete anything that is not '
                'an ingredient and correct misread names before saving.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _ocrNote = 'Could not read the photo ($e). You can type the list instead.';
      });
    }
  }

  Future<void> _handleSave() async {
    final text = _controller.text.trim();
    final unchanged = text == _initialText.trim();
    final current = widget.item.product?.ingredientsSource ?? IngredientSource.notRecorded;

    if (unchanged && !_confirmedAgainstLabel) {
      Navigator.of(context).pop(false); // nothing to save
      return;
    }
    if (text.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove the ingredient list?'),
          content: const Text('The routine checker will then report this product as "not checked".'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Remove')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    // A label photo reviewed in this dialog counts as packaging; a typed, edited or
    // label-checked list as the user's.
    final source = _ocrText != null ? IngredientSource.packaging : IngredientSource.user;

    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final removed = await context.read<VanityProvider>().updateIngredients(
            widget.item.vanityItemId,
            text,
            source: source,
            context: source == IngredientSource.packaging
                ? 'Read from a label photo and reviewed in the app'
                : (unchanged ? 'Checked against the label by you (was: ${current.label})' : null),
          );
      navigator.pop(true);
      messenger.showSnackBar(SnackBar(
        content: Text(text.isEmpty
            ? 'Ingredient list removed.'
            : 'Ingredients saved${removed > 0 ? ' ($removed repeated entr${removed == 1 ? 'y' : 'ies'} removed)' : ''}.'),
      ));
    } on VanitySyncException catch (e) {
      navigator.pop(true);
      messenger.showSnackBar(SnackBar(content: Text('Ingredients saved. ${e.message}')));
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to update ingredients: $e'), backgroundColor: AppTheme.statusRed),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.item.product;
    final productName = product?.name ?? 'Product';
    final hadList = _initialText.trim().isNotEmpty;
    final source = product?.ingredientsSource ?? IngredientSource.notRecorded;
    final parsed = IngredientNormalizer.parse(_controller.text);
    final dupes = IngredientNormalizer.duplicateCount(_controller.text);
    final unchanged = _controller.text.trim() == _initialText.trim();

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.science_outlined, color: AppTheme.primaryRose, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Ingredients: $productName',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hadList)
              Text(
                'Current list: ${source.label}${product?.ingredientsContext != null ? ' (${product!.ingredientsContext})' : ''}.',
                key: const ValueKey('ingredients-current-source'),
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
              ),
            const SizedBox(height: 6),
            const Text(
              'Use the list printed on YOUR product (formulas can differ by country and version). '
              'Separate ingredients with commas.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('ingredients-scan'),
              onPressed: _reading || _isSaving ? null : _scanLabel,
              icon: _reading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.document_scanner_outlined, size: 16),
              label: const Text('Scan the ingredient label (photo)'),
            ),
            if (_ocrNote != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.amber.shade50, borderRadius: BorderRadius.circular(8)),
                child: Text(_ocrNote!, key: const ValueKey('ingredients-ocr-note'), style: const TextStyle(fontSize: 11.5)),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('ingredients-field'),
              controller: _controller,
              maxLines: 7,
              style: const TextStyle(fontSize: 12, height: 1.4),
              decoration: const InputDecoration(
                hintText: 'e.g. Water, Glycerin, Niacinamide, Retinol, Sodium Hyaluronate...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              parsed.isEmpty
                  ? 'No ingredients entered.'
                  : '${parsed.length} ingredient${parsed.length == 1 ? '' : 's'} recognized'
                      '${dupes > 0 ? ' · $dupes repeated entr${dupes == 1 ? 'y' : 'ies'} will be removed' : ''}'
                      '${IngredientNormalizer.looksIncomplete(_controller.text) ? ' · list looks cut off ("...")' : ''}',
              key: const ValueKey('ingredients-summary'),
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
            ),
            if (hadList && unchanged && !source.isConfirmed)
              CheckboxListTile(
                key: const ValueKey('ingredients-confirm'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _confirmedAgainstLabel,
                onChanged: (v) => setState(() => _confirmedAgainstLabel = v ?? false),
                title: const Text('I checked this list against my product\'s label', style: TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const ValueKey('ingredients-save'),
          onPressed: _isSaving ? null : _handleSave,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
          child: _isSaving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save Ingredients', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
