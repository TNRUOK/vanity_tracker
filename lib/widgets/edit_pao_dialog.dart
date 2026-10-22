import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/product_model.dart';
import '../models/vanity_item_model.dart';
import '../services/packaging_ocr_service.dart';
import '../theme/app_theme.dart';

/// The value chosen in [EditPaoDialog] and where it came from.
class PaoEditResult {
  final int months;

  /// [PaoSource.packaging] when the user picked a value read from a packaging photo,
  /// otherwise [PaoSource.user].
  final PaoSource source;

  const PaoEditResult(this.months, this.source);
}

/// Lets the user correct or confirm one item's PAO. Returns the chosen value, or null
/// when cancelled. Saving does not change the opening or purchase date.
class EditPaoDialog extends StatefulWidget {
  final VanityItemModel item;

  const EditPaoDialog({super.key, required this.item});

  static const presets = [3, 6, 9, 12, 18, 24, 36];

  static Future<PaoEditResult?> show(BuildContext context, VanityItemModel item) {
    return showDialog<PaoEditResult>(context: context, builder: (_) => EditPaoDialog(item: item));
  }

  /// Validation message for a typed custom value, or null when it is valid.
  static String? validate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 'Enter the number of months.';
    final months = RegExp(r'^\d+$').hasMatch(text) ? int.tryParse(text) : null;
    if (months == null) return 'Enter a whole number of months, for example 30.';
    if (months < ProductModel.minPaoMonths || months > ProductModel.maxPaoMonths) {
      return 'PAO must be between ${ProductModel.minPaoMonths} and ${ProductModel.maxPaoMonths} months.';
    }
    return null;
  }

  @override
  State<EditPaoDialog> createState() => _EditPaoDialogState();
}

class _EditPaoDialogState extends State<EditPaoDialog> {
  late final TextEditingController _customController;
  int? _selected;
  String? _customError;

  // Packaging photo reading
  bool _reading = false;
  String? _ocrMessage;
  List<int> _ocrCandidates = const [];
  int? _fromPackaging; // the candidate the user picked, if any

  Future<void> _readFromPackaging() async {
    setState(() {
      _reading = true;
      _ocrMessage = null;
    });
    try {
      final text = await PackagingOcrService.pickAndRead(context: context);
      if (!mounted) return;
      if (text == null) {
        setState(() => _reading = false);
        return; // cancelled
      }
      final candidates = PackagingOcrService.paoCandidates(text);
      setState(() {
        _reading = false;
        _ocrCandidates = candidates;
        _ocrMessage = candidates.isEmpty
            ? 'No PAO like "12M" could be read in that photo. The open-jar symbol itself cannot be '
                'recognized, only printed text. Choose the value yourself below.'
            : 'Read from the photo: tap the value printed in the open-jar symbol to use it. '
                'Text recognition can misread numbers, so check it against the pack.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _ocrMessage = 'Could not read the photo ($e). Choose the value yourself below.';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.item.product?.knownPaoMonths;
    final isPreset = _selected != null && EditPaoDialog.presets.contains(_selected);
    _customController = TextEditingController(text: _selected != null && !isPreset ? '$_selected' : '');
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _onCustomChanged(String raw) {
    setState(() {
      _fromPackaging = null;
      if (raw.trim().isEmpty) {
        _customError = null;
        _selected = null;
        return;
      }
      _customError = EditPaoDialog.validate(raw);
      _selected = _customError == null ? int.parse(raw.trim()) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final product = item.product;
    final current = product?.knownPaoMonths;
    final source = product?.paoSource ?? PaoSource.unknown;
    final opened = item.openedDate;
    final fmt = DateFormat('MMMM d, yyyy');
    final confirmsSame = _selected != null && _selected == current && !source.isVerified;

    return AlertDialog(
      title: const Text('Edit PAO (Period After Opening)'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current != null ? 'Current: $current months. ${source.label}.' : 'Current: ${source.label}.',
              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 6),
            const Text(
              'Check the open-jar symbol on the pack (for example "12M").',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: EditPaoDialog.presets.map((m) {
                return ChoiceChip(
                  key: ValueKey('pao-chip-$m'),
                  label: Text('${m}M'),
                  selected: _selected == m && _customController.text.trim().isEmpty,
                  onSelected: (_) => setState(() {
                    _selected = m;
                    _fromPackaging = null;
                    _customController.clear();
                    _customError = null;
                  }),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('pao-read-photo'),
              onPressed: _reading ? null : _readFromPackaging,
              icon: _reading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.photo_camera_outlined, size: 16),
              label: const Text('Read from packaging photo'),
            ),
            if (_ocrMessage != null) ...[
              const SizedBox(height: 6),
              Text(_ocrMessage!, key: const ValueKey('pao-ocr-message'), style: const TextStyle(fontSize: 11.5)),
            ],
            if (_ocrCandidates.isNotEmpty)
              Wrap(
                spacing: 6,
                children: _ocrCandidates.map((m) {
                  return ActionChip(
                    key: ValueKey('pao-ocr-$m'),
                    avatar: const Icon(Icons.photo_outlined, size: 14),
                    label: Text('${m}M (from photo)'),
                    onPressed: () => setState(() {
                      _selected = m;
                      _fromPackaging = m;
                      _customController.text = EditPaoDialog.presets.contains(m) ? '' : '$m';
                      _customError = null;
                    }),
                  );
                }).toList(),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('pao-custom-field'),
              controller: _customController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Other (months, ${ProductModel.minPaoMonths}–${ProductModel.maxPaoMonths})',
                errorText: _customError,
                isDense: true,
              ),
              onChanged: _onCustomChanged,
            ),
            const SizedBox(height: 14),
            Text(
              opened == null
                  ? 'Not opened yet: the PAO is saved, and the countdown starts when you mark the product as opened.'
                  : (_selected == null
                      ? 'Opened ${fmt.format(opened)}.'
                      : 'Opened ${fmt.format(opened)}. New PAO expiry: '
                          '${fmt.format(VanityItemModel.computeExpiryDate(opened, _selected!))}.'),
              key: const ValueKey('pao-preview'),
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textDark),
            ),
            const SizedBox(height: 4),
            const Text(
              'Changing the PAO does not change the opening or purchase date.',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        if (source != PaoSource.unknown && !source.isVerified)
          TextButton(
            key: const ValueKey('pao-unknown'),
            // Keeps no estimate: the expiry stays unset until a PAO is entered.
            onPressed: () => Navigator.of(context).pop(PaoEditResult(current ?? 12, PaoSource.unknown)),
            child: const Text('Mark as unknown'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          key: const ValueKey('pao-save'),
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(
                    PaoEditResult(
                      _selected!,
                      _fromPackaging == _selected ? PaoSource.packaging : PaoSource.user,
                    ),
                  ),
          child: Text(confirmsSame ? 'Confirm' : 'Save'),
        ),
      ],
    );
  }
}
