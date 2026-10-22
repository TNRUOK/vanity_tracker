import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/batch_ocr_service.dart';
import '../services/packaging_ocr_service.dart';
import '../theme/app_theme.dart';

class BatchConfirmationResult {
  final String? batchCode;
  final DateTime? manufacturingDate;
  final DatePrecision manufacturingDatePrecision;
  final DateTime? sealedExpiryDate;
  final DatePrecision sealedExpiryPrecision;

  const BatchConfirmationResult({
    this.batchCode,
    this.manufacturingDate,
    this.manufacturingDatePrecision = DatePrecision.day,
    this.sealedExpiryDate,
    this.sealedExpiryPrecision = DatePrecision.day,
  });
}

/// A date field value with how much of it is known.
class _DateValue {
  final DateTime date;
  final DatePrecision precision;
  const _DateValue(this.date, this.precision);
  String get text => formatPackagingDate(date, precision);
  @override
  bool operator ==(Object other) => other is _DateValue && other.date == date && other.precision == precision;
  @override
  int get hashCode => Object.hash(date, precision);
}

/// Review screen for batch/lot code, manufacturing date and printed sealed expiry, from a
/// packaging photo or typed text. OCR results are only candidates: a field is filled
/// automatically only from a printed label with one clear value, and never when the date
/// is ambiguous or the user already entered something. Nothing is saved until
/// Confirm & Apply; Cancel changes nothing.
class BatchScanConfirmDialog extends StatefulWidget {
  final String? brand;
  final String? initialBatchCode;
  final DateTime? initialMfgDate;
  final DatePrecision initialMfgPrecision;
  final DateTime? initialSealedExpiryDate;
  final DatePrecision initialSealedExpiryPrecision;

  const BatchScanConfirmDialog({
    super.key,
    this.brand,
    this.initialBatchCode,
    this.initialMfgDate,
    this.initialMfgPrecision = DatePrecision.day,
    this.initialSealedExpiryDate,
    this.initialSealedExpiryPrecision = DatePrecision.day,
  });

  static Future<BatchConfirmationResult?> show(
    BuildContext context, {
    String? brand,
    String? initialBatchCode,
    DateTime? initialMfgDate,
    DatePrecision initialMfgPrecision = DatePrecision.day,
    DateTime? initialSealedExpiryDate,
    DatePrecision initialSealedExpiryPrecision = DatePrecision.day,
  }) {
    return showDialog<BatchConfirmationResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BatchScanConfirmDialog(
        brand: brand,
        initialBatchCode: initialBatchCode,
        initialMfgDate: initialMfgDate,
        initialMfgPrecision: initialMfgPrecision,
        initialSealedExpiryDate: initialSealedExpiryDate,
        initialSealedExpiryPrecision: initialSealedExpiryPrecision,
      ),
    );
  }

  @override
  State<BatchScanConfirmDialog> createState() => _BatchScanConfirmDialogState();
}

class _BatchScanConfirmDialogState extends State<BatchScanConfirmDialog> {
  late final TextEditingController _batchCodeController;
  _DateValue? _mfg;
  _DateValue? _exp;

  // The user changed the field themselves: OCR never overwrites it afterwards.
  bool _batchUserEdited = false;
  bool _mfgUserSet = false;
  bool _expUserSet = false;
  String? _batchAutoValue; // last value OCR put in the batch field

  bool _isProcessing = false;
  String? _status; // what happened in the last run, shown above the fields
  bool _statusIsError = false;
  BatchOcrResult? _result;
  PackagingOcrRun? _run;
  bool _showRawText = false;

  // The selected image and how the user adjusted it.
  PickedReceiptImage? _image;
  Size? _imageSize;
  int _quarterTurns = 0;
  final TransformationController _zoom = TransformationController();
  Size _viewport = const Size(300, 180);

  @override
  void initState() {
    super.initState();
    _batchCodeController = TextEditingController(text: widget.initialBatchCode ?? '');
    _batchCodeController.addListener(() {
      if (_batchCodeController.text != (_batchAutoValue ?? widget.initialBatchCode ?? '')) _batchUserEdited = true;
    });
    if (widget.initialMfgDate != null) _mfg = _DateValue(widget.initialMfgDate!, widget.initialMfgPrecision);
    if (widget.initialSealedExpiryDate != null) {
      _exp = _DateValue(widget.initialSealedExpiryDate!, widget.initialSealedExpiryPrecision);
    }
    // Existing values count as the user's: a scan suggests, it does not replace them.
    _batchUserEdited = (widget.initialBatchCode ?? '').isNotEmpty;
    _mfgUserSet = _mfg != null;
    _expUserSet = _exp != null;
  }

  @override
  void dispose() {
    _batchCodeController.dispose();
    _zoom.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    PickedReceiptImage? picked;
    try {
      picked = await PackagingOcrService.pickImage(context: context);
    } catch (e) {
      _setStatus('Could not open the selected file ($e). You can type the text instead.', error: true);
      return;
    }
    if (picked == null || !mounted) return; // cancelled: nothing changes
    if (picked.bytes.isEmpty && (picked.path == null || picked.path!.isEmpty)) {
      _setStatus('The selected file has no readable image data on this device.', error: true);
      return;
    }
    setState(() {
      _image = picked;
      _imageSize = null;
      _quarterTurns = 0;
      _zoom.value = Matrix4.identity();
    });
    _readImageSize(picked); // only needed for "Scan zoomed area"; OCR does not wait for it
    await _runOcr();
  }

  Future<void> _readImageSize(PickedReceiptImage image) async {
    try {
      final codec = await ui.instantiateImageCodec(image.bytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      if (mounted && identical(_image, image)) setState(() => _imageSize = size);
    } catch (_) {
      // No preview size: "Scan zoomed area" then scans the whole image.
    }
  }

  /// The part of the (rotated) image visible in the zoomed preview, normalized 0..1, or
  /// null when the whole image is visible.
  ui.Rect? _visibleCrop() {
    final size = _imageSize;
    if (size == null) return null;
    final rotated = _quarterTurns.isOdd ? Size(size.height, size.width) : size;
    final fit = applyBoxFit(BoxFit.contain, rotated, _viewport).destination;
    final imageRect = Alignment.center.inscribe(fit, Offset.zero & _viewport);
    final inverse = Matrix4.inverted(_zoom.value);
    final tl = MatrixUtils.transformPoint(inverse, Offset.zero);
    final br = MatrixUtils.transformPoint(inverse, Offset(_viewport.width, _viewport.height));
    final visible = Rect.fromPoints(tl, br).intersect(imageRect);
    if (visible.isEmpty) return null;
    final n = Rect.fromLTRB(
      (visible.left - imageRect.left) / imageRect.width,
      (visible.top - imageRect.top) / imageRect.height,
      (visible.right - imageRect.left) / imageRect.width,
      (visible.bottom - imageRect.top) / imageRect.height,
    );
    return n.width > 0.98 && n.height > 0.98 ? null : n;
  }

  Future<void> _runOcr({bool visibleAreaOnly = false}) async {
    final image = _image;
    if (image == null || _isProcessing) return;
    setState(() {
      _isProcessing = true;
      _status = null;
    });
    try {
      final run = await PackagingOcrService.readPackaging(
        image,
        quarterTurns: _quarterTurns,
        crop: visibleAreaOnly ? _visibleCrop() : null,
      );
      if (!mounted) return;
      _run = run;
      if (run.allFailed) {
        _setStatus('OCR could not read this image: ${run.firstError}. Try another photo, or type the text.', error: true);
        return;
      }
      if (!run.anyText) {
        _setStatus(
          'No text was found in this image. Zoom in on the code and tap "Scan zoomed area", rotate it if it is '
          'sideways, use brighter light without glare, or type the text.',
          error: true,
        );
        setState(() => _result = const BatchOcrResult(rawText: ''));
        return;
      }
      _apply(BatchOcrService.parsePasses([for (final p in run.passes) (label: p.label, text: p.text)], brand: widget.brand));
      final failed = run.passes.where((p) => !p.ok).toList();
      if (failed.isNotEmpty && mounted) {
        setState(() => _status = '${_status ?? ''} (The ${failed.map((p) => p.label).join(', ')} reading failed: '
            '${failed.first.error}. Results come from the other reading.)');
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _setStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  /// Fills a field only with a single, labeled, unambiguous value, and only when the user
  /// has not entered their own value; everything else stays a visible choice.
  void _apply(BatchOcrResult r) {
    final filled = <String>[];
    final code = r.suggestedBatchCode;
    if (code != null && !_batchUserEdited) {
      _batchAutoValue = code;
      _batchCodeController.text = code;
      filled.add('batch code');
    }
    final m = r.suggestedMfgDate;
    if (m != null && !m.isAmbiguous && !_mfgUserSet) {
      _mfg = _DateValue(m.date, m.precision);
      filled.add('manufacturing date');
    }
    final e = r.suggestedExpiryDate;
    if (e != null && !e.isAmbiguous && !_expUserSet) {
      _exp = _DateValue(e.date, e.precision);
      filled.add('printed expiry');
    }
    final hasChoices = r.batchCandidates.isNotEmpty || r.mfgCandidates.isNotEmpty || r.expiryCandidates.isNotEmpty ||
        r.unlabeledDates.isNotEmpty || r.brandDecode != null;
    setState(() {
      _result = r;
      _status = filled.isNotEmpty
          ? 'Filled from printed labels: ${filled.join(', ')}. Check each value against the pack.'
          : hasChoices
              ? 'Text was read, but nothing could be filled with confidence. Choose from the suggestions below, or type the values.'
              : 'Text was read, but no batch code or date was found in it. Check the text below or type the values.';
      _statusIsError = filled.isEmpty && !hasChoices;
    });
  }

  Future<void> _promptManualTextEntry() async {
    final entered = await showDialog<String>(context: context, builder: (_) => const _ManualTextDialog());
    if (entered != null && entered.isNotEmpty && mounted) {
      _run = PackagingOcrRun([OcrPass('typed', entered)]);
      _apply(BatchOcrService.parsePackagingText(entered, brand: widget.brand));
    }
  }

  Future<void> _pickDate({required bool isMfg}) async {
    final current = isMfg ? _mfg : _exp;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current?.date ?? (isMfg ? now : DateTime(now.year + 1, now.month, now.day)),
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _set(isMfg, _DateValue(picked, DatePrecision.day)));
  }

  void _set(bool isMfg, _DateValue? v) {
    if (isMfg) {
      _mfg = v;
      _mfgUserSet = true;
    } else {
      _exp = v;
      _expUserSet = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.document_scanner_rounded, color: AppTheme.primaryRose, size: 24),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Batch Code & Date OCR',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.textDark),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Photograph the batch/lot code and dates up close, in good light without glare. Everything read '
                'from the image is a suggestion: check each field against the pack before applying.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted, height: 1.3),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      key: const ValueKey('batch-scan-image'),
                      onPressed: _isProcessing ? null : _pickImage,
                      icon: _isProcessing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.photo_library_outlined, size: 16),
                      label: Text(_image == null ? 'Scan Image' : 'New image',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryRose,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('batch-input-text'),
                      onPressed: _isProcessing ? null : _promptManualTextEntry,
                      icon: const Icon(Icons.edit_note_rounded, size: 16, color: AppTheme.primaryRose),
                      label: const Text('Input Text',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primaryRose)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.primaryRose),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
              if (_image != null) _buildPreview(),
              if (_isProcessing)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('Reading the image (two passes: as captured, then enhanced)…',
                      key: ValueKey('batch-ocr-progress'), style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                ),
              if (_status != null)
                Container(
                  key: const ValueKey('batch-ocr-status'),
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _statusIsError ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_status!, style: const TextStyle(fontSize: 12, height: 1.3)),
                ),
              if (r != null && r.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    r.notes.map((n) => '• $n').join('\n'),
                    key: const ValueKey('batch-ocr-notes'),
                    style: const TextStyle(fontSize: 11, color: Color(0xFFB45309)),
                  ),
                ),
              if (_run != null && _run!.anyText) _buildRawText(),
              const Divider(height: 24),
              _buildBatchField(r),
              const SizedBox(height: 14),
              _buildDateField(r, isMfg: true),
              const SizedBox(height: 14),
              _buildDateField(r, isMfg: false),
              if (r != null && r.unlabeledDates.isNotEmpty) _buildUnlabeledDates(r),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('batch-cancel'), onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
        ElevatedButton(
          key: const ValueKey('batch-confirm'),
          onPressed: () {
            final batch = _batchCodeController.text.trim();
            Navigator.of(context).pop(
              BatchConfirmationResult(
                batchCode: batch.isNotEmpty ? batch : null,
                manufacturingDate: _mfg?.date,
                manufacturingDatePrecision: _mfg?.precision ?? DatePrecision.day,
                sealedExpiryDate: _exp?.date,
                sealedExpiryPrecision: _exp?.precision ?? DatePrecision.day,
              ),
            );
          },
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
          child: const Text('Confirm & Apply', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(builder: (context, c) {
            _viewport = Size(c.maxWidth, 180);
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 180,
                color: const Color(0xFF0F172A),
                child: InteractiveViewer(
                  key: const ValueKey('batch-preview'),
                  transformationController: _zoom,
                  minScale: 1,
                  maxScale: 8,
                  child: RotatedBox(
                    quarterTurns: _quarterTurns,
                    child: Image.memory(
                      _image!.bytes,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Text('Preview not available', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 4),
          const Text('Pinch or scroll to zoom into the batch code and dates.',
              style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted)),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('batch-rotate'),
                onPressed: _isProcessing
                    ? null
                    : () => setState(() {
                          _quarterTurns = (_quarterTurns + 1) % 4;
                          _zoom.value = Matrix4.identity();
                        }),
                icon: const Icon(Icons.rotate_right_rounded, size: 16),
                label: const Text('Rotate', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                key: const ValueKey('batch-scan-visible'),
                onPressed: _isProcessing ? null : () => _runOcr(visibleAreaOnly: true),
                icon: const Icon(Icons.crop_rounded, size: 16),
                label: const Text('Scan zoomed area', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                key: const ValueKey('batch-rerun'),
                onPressed: _isProcessing ? null : () => _runOcr(),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Run OCR again', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRawText() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('batch-toggle-raw'),
          onTap: () => setState(() => _showRawText = !_showRawText),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(_showRawText ? Icons.expand_less : Icons.expand_more, size: 18, color: AppTheme.textMuted),
                const SizedBox(width: 4),
                Text(_showRawText ? 'Hide recognized text' : 'Show recognized text',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
        if (_showRawText)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            width: double.infinity,
            decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(8)),
            child: SelectableText(
              [
                for (final p in _run!.passes)
                  '[${p.label}${p.steps.isNotEmpty ? ': ${p.steps.join(', ')}' : ''}]\n'
                      '${p.ok ? (p.text.trim().isEmpty ? '(no text)' : p.text.trim()) : 'failed: ${p.error}'}',
              ].join('\n\n'),
              key: const ValueKey('batch-raw-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF334155)),
            ),
          ),
      ],
    );
  }

  Widget _chip(String key, String label, bool selected, VoidCallback onTap, {bool uncertain = false}) {
    return ChoiceChip(
      key: ValueKey(key),
      label: Text(label, style: TextStyle(fontSize: 11, fontStyle: uncertain ? FontStyle.italic : FontStyle.normal)),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }

  Widget _buildBatchField(BatchOcrResult? r) {
    final candidates = r?.batchCandidates ?? const <BatchCodeCandidate>[];
    final current = _batchCodeController.text.trim().toUpperCase();
    final selected = candidates.where((c) => c.code == current).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Batch / Lot Code', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
        const SizedBox(height: 4),
        TextField(
          key: const ValueKey('batch-code-field'),
          controller: _batchCodeController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'e.g. 4021A or B23',
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            suffixIcon: _batchCodeController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () => setState(() {
                      _batchCodeController.clear();
                      _batchUserEdited = true;
                    }),
                  )
                : null,
          ),
        ),
        if (r != null && candidates.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('No batch code found in the text. Type it if you can read it on the pack.',
                key: ValueKey('batch-none-found'), style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ),
        if (candidates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final c in candidates)
                  _chip(
                    'batch-candidate-${c.code}',
                    c.isLabeled ? '${c.code} (after ${c.label})' : '${c.code}? (no label)',
                    current == c.code,
                    () => setState(() {
                      _batchCodeController.text = c.code;
                      _batchUserEdited = true;
                    }),
                    uncertain: !c.isLabeled,
                  ),
              ],
            ),
          ),
        if (selected != null && selected.hasLookalikeCharacters)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Compare with the pack: OCR can confuse O/0, I/1, B/8, S/5 and Z/2.',
                key: ValueKey('batch-lookalike-note'), style: TextStyle(fontSize: 10.5, color: Color(0xFFB45309))),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'Most brands do not publish how their batch codes encode dates, so the app does not derive a '
            'manufacturing date from the code. Enter it below if it is printed.',
            style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _buildDateField(BatchOcrResult? r, {required bool isMfg}) {
    final value = isMfg ? _mfg : _exp;
    final candidates = r == null ? const <ParsedDateCandidate>[] : (isMfg ? r.mfgCandidates : r.expiryCandidates);
    final prefix = isMfg ? 'mfg' : 'exp';
    final options = <_DateValue, String>{};
    final notes = <String>[];
    for (final c in candidates) {
      options[_DateValue(c.date, c.precision)] = '${c.formattedDisplay}${c.label != null ? ' (${c.label})' : ''}';
      if (c.isAmbiguous && c.alternateDate != null) {
        options[_DateValue(c.alternateDate!, c.precision)] = '${formatPackagingDate(c.alternateDate!, c.precision)} (other reading)';
        if (c.ambiguityNote != null) notes.add(c.ambiguityNote!);
      } else if (c.ambiguityNote != null) {
        notes.add(c.ambiguityNote!);
      }
    }
    final decode = isMfg ? r?.brandDecode : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(isMfg ? 'Manufacturing Date' : 'Printed Sealed Expiry',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
            if (value != null)
              InkWell(
                key: ValueKey('$prefix-clear'),
                onTap: () => setState(() => _set(isMfg, null)),
                child: const Text('Clear', style: TextStyle(fontSize: 11, color: AppTheme.statusRed)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: () => _pickDate(isMfg: isMfg),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: Row(
              children: [
                Icon(isMfg ? Icons.calendar_today_outlined : Icons.event_available_outlined, size: 16, color: AppTheme.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value?.text ?? 'Not recorded',
                    key: ValueKey('$prefix-value'),
                    style: TextStyle(
                      fontSize: 13,
                      color: value != null ? AppTheme.textDark : AppTheme.textMuted,
                      fontWeight: value != null ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in options.entries)
                  _chip('$prefix-choice-${DateFormat('yyyy-MM-dd').format(e.key.date)}', e.value, value == e.key,
                      () => setState(() => _set(isMfg, e.key))),
              ],
            ),
          ),
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(n, key: ValueKey('$prefix-note'), style: const TextStyle(fontSize: 10.5, color: Color(0xFFB45309))),
          ),
        if (decode != null)
          Container(
            key: const ValueKey('brand-decode'),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(8)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(decode.note, style: const TextStyle(fontSize: 10.5, color: Color(0xFF92400E))),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final d in [decode.month, decode.decadeEarlier])
                      TextButton(
                        key: ValueKey('brand-decode-${d.year}'),
                        onPressed: () => setState(() => _set(true, _DateValue(d, DatePrecision.month))),
                        child: Text('Use ${DateFormat('MMM yyyy').format(d)}', style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildUnlabeledDates(BatchOcrResult r) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        key: const ValueKey('unlabeled-dates'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dates without a label (the app cannot tell what they mean):',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.textDark),
          ),
          for (final (i, d) in r.unlabeledDates.indexed)
            Row(
              children: [
                Expanded(child: Text('${d.formattedDisplay}${d.isAmbiguous ? ' (day/month unclear)' : ''}',
                    style: const TextStyle(fontSize: 12))),
                if (!d.isAmbiguous) ...[
                  TextButton(
                    key: ValueKey('unlabeled-$i-mfg'),
                    onPressed: () => setState(() => _set(true, _DateValue(d.date, d.precision))),
                    child: const Text('Manufactured', style: TextStyle(fontSize: 11)),
                  ),
                  TextButton(
                    key: ValueKey('unlabeled-$i-exp'),
                    onPressed: () => setState(() => _set(false, _DateValue(d.date, d.precision))),
                    child: const Text('Expiry', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// Typed packaging text (owns its controller, so it is disposed only when the dialog is gone).
class _ManualTextDialog extends StatefulWidget {
  const _ManualTextDialog();
  @override
  State<_ManualTextDialog> createState() => _ManualTextDialogState();
}

class _ManualTextDialogState extends State<_ManualTextDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter Packaging Text', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: TextField(
        key: const ValueKey('batch-manual-text'),
        controller: _text,
        maxLines: 4,
        decoration: const InputDecoration(hintText: 'e.g. LOT 4021A\nMFG: 2024-03-15\nEXP: 03/2027'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
        ElevatedButton(
          key: const ValueKey('batch-manual-analyze'),
          onPressed: () => Navigator.of(context).pop(_text.text.trim()),
          child: const Text('Analyze Text'),
        ),
      ],
    );
  }
}