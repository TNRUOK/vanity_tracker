import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../models/product_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/household_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/barcode_utils.dart';
import '../../utils/currency.dart';
import '../../widgets/batch_scan_confirm_dialog.dart';
import '../../widgets/duplicate_alert_dialog.dart';

class EditProductScreen extends StatefulWidget {
  final VanityItemModel item;

  const EditProductScreen({super.key, required this.item});

  @override
  State<EditProductScreen> createState() => _EditProductScreenState();
}

class _EditProductScreenState extends State<EditProductScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _brandController;
  late TextEditingController _volumeController;
  late TextEditingController _priceController;
  late TextEditingController _notesController;
  late TextEditingController _batchCodeController;
  late TextEditingController _barcodeController;

  late String _selectedCategoryId;
  late CategorySource _categorySource;

  /// Explains a PAO that was kept when the category changed (null = nothing to explain).
  String? _paoCategoryNote;

  /// ISO code of the price; null = not recorded (older items), shown as such.
  String? _priceCurrency;
  late int _paoMonths;
  late PaoSource _paoSource;
  DateTime? _openedDate;
  DateTime? _expiryDate;
  DateTime? _sealedExpiryDate;
  DateTime? _manufacturingDate;
  // Month-only dates ("EXP 10/2027") keep that precision when saved.
  DatePrecision _sealedExpiryPrecision = DatePrecision.day;
  DatePrecision _manufacturingDatePrecision = DatePrecision.day;
  late List<String> _selectedRoutineTags;
  late bool _isSharedWithHousehold;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    final product = item.product;

    _nameController = TextEditingController(text: product?.name ?? '');
    _brandController = TextEditingController(text: product?.brand ?? '');
    _volumeController = TextEditingController(text: product?.volume ?? '');
    _priceController = TextEditingController(text: item.price != null ? item.price!.toStringAsFixed(2) : '');
    _notesController = TextEditingController(text: item.notes ?? '');
    _batchCodeController = TextEditingController(text: item.batchCode ?? '');
    _barcodeController = TextEditingController(text: product?.barcode ?? '');

    _selectedCategoryId = product?.categoryId ?? 'other';
    _categorySource = product?.categorySource ?? CategorySource.notRecorded;
    _priceCurrency = Currencies.byCode(item.priceCurrency)?.code;
    _paoMonths = product?.paoMonths ?? 12;
    _paoSource = product?.paoSource ?? PaoSource.unknown;
    _openedDate = item.openedDate;
    _expiryDate = item.expiryDate;
    _sealedExpiryDate = item.sealedExpiryDate;
    _sealedExpiryPrecision = item.sealedExpiryPrecision;
    _manufacturingDatePrecision = item.manufacturingDatePrecision;
    _manufacturingDate = item.manufacturingDate;
    _selectedRoutineTags = List<String>.from(item.routineTags);
    _isSharedWithHousehold = item.isSharedWithHousehold;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _brandController.dispose();
    _volumeController.dispose();
    _priceController.dispose();
    _notesController.dispose();
    _batchCodeController.dispose();
    _barcodeController.dispose();
    super.dispose();
  }

  /// A category change replaces the PAO only when the PAO itself was the old category's
  /// estimate. A PAO from the packaging, the user or a product database is product-
  /// specific and is kept; an unknown PAO stays unknown (the estimate is only mentioned).
  void _changeCategory(String id, List<CategoryModel> categories) {
    _selectedCategoryId = id;
    _categorySource = CategorySource.user;
    final cat = categories.where((c) => c.categoryId == id).firstOrNull;
    _paoCategoryNote = null;
    if (cat == null) return;
    if (_paoSource == PaoSource.categoryDefault) {
      _paoMonths = cat.defaultPaoMonths;
      _recalculateExpiry();
    } else {
      final kept = _paoSource == PaoSource.unknown ? 'PAO stays unknown' : 'Your PAO (${_paoMonths}M) is kept';
      _paoCategoryNote = '$kept: the ${cat.categoryName} estimate (${cat.defaultPaoMonths}M) is only a typical value. '
          'Change PAO yourself if your product differs.';
    }
  }

  /// The barcode to save: digits of a valid retail barcode (a UPC-E is stored in its
  /// UPC-A form, which is what the databases use), or null when the field is empty.
  String? get _barcodeDigits {
    final t = _barcodeController.text.trim();
    return t.isEmpty ? null : BarcodeUtils.check(t).lookupDigits;
  }

  /// Empty is allowed (e.g. products added from a receipt). A typed barcode must be a real
  /// retail barcode whose check digit matches; no digit is ever corrected automatically.
  String? _validateBarcode(String? value) {
    final t = value?.trim() ?? '';
    if (t.isEmpty) return null;
    final c = BarcodeUtils.check(t);
    if (!c.isRetailBarcode) return 'Not a product barcode (EAN/UPC: 8, 12, 13 or 14 digits).';
    if (!c.checkDigitValid) return 'The check digit does not match: compare each digit with the pack.';
    return null;
  }

  void _recalculateExpiry() {
    if (_openedDate != null && _paoSource != PaoSource.unknown) {
      _expiryDate = VanityItemModel.computeExpiryDate(_openedDate!, _paoMonths);
    }
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    final vanityProv = context.read<VanityProvider>();
    final householdProv = context.read<HouseholdProvider>();

    // Duplicate Check excluding current item
    final duplicates = vanityProv.checkHouseholdDuplicates(
      barcode: _barcodeDigits,
      name: _nameController.text.trim(),
      brand: _brandController.text.trim(),
      volume: _volumeController.text.trim(),
      excludeItemId: widget.item.vanityItemId,
      sharedHouseholdItems: householdProv.sharedItems,
      memberEmails: householdProv.memberEmails,
    );

    if (duplicates.isNotEmpty) {
      final proceed = await DuplicateAlertDialog.showMatches(context, duplicates);
      if (proceed != true) return;
    }

    setState(() => _isSaving = true);

    try {
      final originalProduct = widget.item.product;

      final updatedProduct = originalProduct?.copyWith(
        name: _nameController.text.trim(),
        brand: _brandController.text.trim(),
        volume: _volumeController.text.trim().isNotEmpty ? _volumeController.text.trim() : null,
        barcode: _barcodeDigits ?? '',
        categoryId: _selectedCategoryId,
        categorySource: _categorySource,
        paoMonths: _paoMonths,
        paoSource: _paoSource,
      );

      final priceVal = parseAmountInput(_priceController.text);

      // Determine updated status
      String status = widget.item.status;
      final effective = _expiryDate != null && _sealedExpiryDate != null
          ? (_expiryDate!.isBefore(_sealedExpiryDate!) ? _expiryDate : _sealedExpiryDate)
          : (_expiryDate ?? _sealedExpiryDate);

      if (widget.item.finishedDate == null && widget.item.status != 'finished') {
        if (_openedDate == null && _sealedExpiryDate == null) {
          status = 'unopened';
        } else if (effective == null) {
          status = 'active'; // opened, but no expiry can be calculated (PAO unknown)
        } else {
          final days = effective.difference(DateTime.now()).inDays;
          status = days < 0 ? 'expired' : (days <= 30 ? 'expiring' : 'active');
        }
      }

      final hasHousehold = householdProv.hasHousehold;
      final shouldShare = _isSharedWithHousehold && (hasHousehold || widget.item.isSharedWithHousehold);

      final updatedItem = widget.item.copyWith(
        product: updatedProduct,
        price: priceVal,
        priceCurrency: priceVal != null ? _priceCurrency : null,
        openedDate: _openedDate,
        expiryDate: _expiryDate,
        sealedExpiryDate: _sealedExpiryDate,
        clearSealedExpiryDate: _sealedExpiryDate == null,
        sealedExpiryPrecision: _sealedExpiryPrecision,
        manufacturingDatePrecision: _manufacturingDatePrecision,
        batchCode: _batchCodeController.text.trim().isNotEmpty ? _batchCodeController.text.trim() : null,
        clearBatchCode: _batchCodeController.text.trim().isEmpty,
        manufacturingDate: _manufacturingDate,
        clearManufacturingDate: _manufacturingDate == null,
        status: status,
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        routineTags: _selectedRoutineTags,
        isSharedWithHousehold: shouldShare,
        sharedHouseholdId: shouldShare
            ? (widget.item.sharedHouseholdId ?? householdProv.currentHousehold?.householdId)
            : null,
        clearSharedHouseholdId: !shouldShare,
      );

      await vanityProv.updateItem(updatedItem);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✨ Product details updated successfully!'),
            backgroundColor: AppTheme.statusGreen,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error updating: $e'), backgroundColor: AppTheme.statusRed));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<VanityProvider>().categories;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Edit Product'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _handleSave,
            child: _isSaving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text(
                    'Save',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppTheme.primaryRose),
                  ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Brand
              const Text(
                'Brand',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _brandController,
                decoration: const InputDecoration(hintText: 'e.g. CeraVe, Glossier'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Brand is required' : null,
              ),
              const SizedBox(height: 16),

              // Product Name
              const Text(
                'Product Name',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(hintText: 'e.g. Hyaluronic Acid Serum'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Product name is required' : null,
              ),
              const SizedBox(height: 16),

              // Barcode (optional): lets a product added from a receipt be looked up later.
              const Text(
                'Barcode (optional)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
              ),
              const SizedBox(height: 6),
              TextFormField(
                key: const ValueKey('edit-barcode'),
                controller: _barcodeController,
                keyboardType: TextInputType.number,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(
                  hintText: 'Digits under the barcode on the pack',
                  helperText: 'Save, then use "Look up again" on the product page to fetch its details.',
                  prefixIcon: Icon(Icons.qr_code, color: AppTheme.textMuted),
                ),
                validator: _validateBarcode,
              ),
              const SizedBox(height: 16),

              // Category & PAO
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Category',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          key: const Key('edit-category'),
                          initialValue: _selectedCategoryId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: [
                            for (final c in categories)
                              DropdownMenuItem(
                                value: c.categoryId,
                                child: Text(c.categoryName, style: const TextStyle(fontSize: 14)),
                              ),
                            // A stored id the app no longer lists stays selectable as is.
                            if (!categories.any((c) => c.categoryId == _selectedCategoryId))
                              DropdownMenuItem(value: _selectedCategoryId, child: Text(_selectedCategoryId)),
                          ],
                          onChanged: (val) {
                            if (val != null) setState(() => _changeCategory(val, categories));
                          },
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _categorySource == CategorySource.unknown
                              ? 'Not categorized yet: choose a category'
                              : _categorySource.label,
                          key: const Key('edit-category-source'),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: _categorySource.isConfirmed ? AppTheme.textMuted : AppTheme.statusAmber,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PAO Months',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<int>(
                          // Keyed by value so a category change is shown, not just saved.
                          key: ValueKey('edit-pao-$_paoMonths'),
                          initialValue: _paoMonths,
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          // Includes the current value so a custom PAO (e.g. 30) can be shown.
                          items: ({3, 6, 9, 12, 18, 24, 36, 48, _paoMonths}.toList()..sort()).map((m) {
                            return DropdownMenuItem(
                              value: m,
                              child: Text('${m}M', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _paoMonths = val;
                                _paoSource = PaoSource.user;
                                _recalculateExpiry();
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _paoSource.isVerified
                              ? 'Set by you'
                              : (_paoSource == PaoSource.productDatabase
                                    ? 'From product database'
                                    : (_paoSource == PaoSource.categoryDefault ? 'Category estimate' : 'Not verified')),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: _paoSource.isVerified ? AppTheme.textMuted : AppTheme.statusAmber,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_paoCategoryNote != null) ...[
                const SizedBox(height: 6),
                Text(
                  _paoCategoryNote!,
                  key: const Key('edit-pao-kept-note'),
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
                ),
              ],
              const SizedBox(height: 16),

              // Volume & Price
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Volume / Size',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _volumeController,
                          decoration: const InputDecoration(hintText: 'e.g. 50 ml'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Price',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _priceController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            hintText: 'e.g. 24.50',
                            prefixIcon: Center(
                              widthFactor: 1.0,
                              child: Text(
                                Currencies.symbolFor(_priceCurrency),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textMuted,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        // The price's own currency (Budget Stats convert from it).
                        DropdownButtonFormField<String?>(
                          key: const Key('edit-price-currency'),
                          initialValue: _priceCurrency,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Price currency',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Not recorded', style: TextStyle(fontSize: 13, color: AppTheme.statusAmber)),
                            ),
                            for (final c in Currencies.supported)
                              DropdownMenuItem<String?>(
                                value: c.code,
                                child: Text('${c.symbol} ${c.code}', style: const TextStyle(fontSize: 13)),
                              ),
                          ],
                          onChanged: (v) => setState(() => _priceCurrency = v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Opened & Expiry Date Section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Opened Date:',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 14, color: AppTheme.primaryRose),
                          label: Text(
                            _openedDate != null ? DateFormat('MMM d, yyyy').format(_openedDate!) : 'Set Opened Date',
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryRose),
                          ),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _openedDate ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setState(() {
                                _openedDate = picked;
                                _recalculateExpiry();
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'PAO Expiry Date:',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.event_busy, size: 14, color: AppTheme.statusAmber),
                          label: Text(
                            _expiryDate != null ? DateFormat('MMM d, yyyy').format(_expiryDate!) : 'Calculated on open',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textDark),
                          ),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _expiryDate ?? DateTime.now().add(const Duration(days: 365)),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2035),
                            );
                            if (picked != null) {
                              setState(() => _expiryDate = picked);
                            }
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    // Batch Code & Packaging OCR
                    OutlinedButton.icon(
                      icon: const Icon(Icons.document_scanner_outlined, size: 18, color: Color(0xFF6B46C1)),
                      label: const Text(
                        'Scan Packaging / Batch Code OCR 📷',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF6B46C1)),
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFFFAF5FF),
                        side: const BorderSide(color: Color(0xFFD6BCFA)),
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () async {
                        final result = await BatchScanConfirmDialog.show(
                          context,
                          brand: _brandController.text.trim(),
                          initialBatchCode: _batchCodeController.text.trim(),
                          initialMfgDate: _manufacturingDate,
                          initialMfgPrecision: _manufacturingDatePrecision,
                          initialSealedExpiryDate: _sealedExpiryDate,
                          initialSealedExpiryPrecision: _sealedExpiryPrecision,
                        );
                        if (result != null) {
                          setState(() {
                            // The dialog started from these values and the user confirmed them, so a
                              // field cleared there is cleared here too.
                              _batchCodeController.text = result.batchCode ?? '';
                              _manufacturingDate = result.manufacturingDate;
                              _manufacturingDatePrecision = result.manufacturingDatePrecision;
                              _sealedExpiryDate = result.sealedExpiryDate;
                              _sealedExpiryPrecision = result.sealedExpiryPrecision;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _batchCodeController,
                      decoration: const InputDecoration(
                        labelText: 'Batch Code (Optional)',
                        hintText: 'e.g. A31, 23049, LOT4821',
                        prefixIcon: Icon(Icons.tag, size: 18, color: AppTheme.textMuted),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Manufacturing Date:',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                            ),
                            Text(
                              'Printed on the pack (optional)',
                              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                        _manufacturingDate != null
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(
                                      Icons.precision_manufacturing_outlined,
                                      size: 14,
                                      color: AppTheme.primaryRose,
                                    ),
                                    label: Text(
                                      formatPackagingDate(_manufacturingDate!, _manufacturingDatePrecision),
                                      style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryRose),
                                    ),
                                    onPressed: () async {
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate: _manufacturingDate!,
                                        firstDate: DateTime(1990),
                                        lastDate: DateTime(2100),
                                      );
                                      if (picked != null) {
                                      setState(() {
                                        _manufacturingDate = picked;
                                        _manufacturingDatePrecision = DatePrecision.day;
                                      });
                                    }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18, color: AppTheme.textMuted),
                                    tooltip: 'Clear manufacturing date',
                                    onPressed: () => setState(() => _manufacturingDate = null),
                                  ),
                                ],
                              )
                            : OutlinedButton.icon(
                                icon: const Icon(Icons.calendar_month, size: 14),
                                label: const Text('Set Date', style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: DateTime.now(),
                                    firstDate: DateTime(1990),
                                    lastDate: DateTime(2100),
                                  );
                                  if (picked != null) {
                                      setState(() {
                                        _manufacturingDate = picked;
                                        _manufacturingDatePrecision = DatePrecision.day;
                                      });
                                    }
                                },
                              ),
                      ],
                    ),
                    const Divider(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Sealed / Batch Expiry:',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                            ),
                            Text(
                              'Printed on packaging (optional)',
                              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                        _sealedExpiryDate != null
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.event, size: 14, color: AppTheme.primaryRose),
                                    label: Text(
                                      formatPackagingDate(_sealedExpiryDate!, _sealedExpiryPrecision),
                                      style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryRose),
                                    ),
                                    onPressed: () async {
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate: _sealedExpiryDate ?? DateTime.now().add(const Duration(days: 365)),
                                        firstDate: DateTime(1990),
                                        lastDate: DateTime(2100),
                                      );
                                      if (picked != null) {
                                      setState(() {
                                        _sealedExpiryDate = picked;
                                        _sealedExpiryPrecision = DatePrecision.day;
                                      });
                                    }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18, color: AppTheme.textMuted),
                                    tooltip: 'Clear sealed expiry date',
                                    onPressed: () => setState(() => _sealedExpiryDate = null),
                                  ),
                                ],
                              )
                            : OutlinedButton.icon(
                                icon: const Icon(Icons.calendar_month, size: 14),
                                label: const Text('Set Date', style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: DateTime.now().add(const Duration(days: 365)),
                                    firstDate: DateTime(1990),
                                    lastDate: DateTime(2100),
                                  );
                                  if (picked != null) {
                                      setState(() {
                                        _sealedExpiryDate = picked;
                                        _sealedExpiryPrecision = DatePrecision.day;
                                      });
                                    }
                                },
                              ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Routine Tags
              const Text(
                'Routine Tags (Optional)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  _buildRoutineChip('AM', '☀️ Morning (AM)'),
                  _buildRoutineChip('PM', '🌙 Evening (PM)'),
                  _buildRoutineChip('Weekly', '📅 Weekly'),
                ],
              ),
              const SizedBox(height: 16),

              // Notes
              const Text(
                'Notes',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Usage routine, batch notes, skin reaction...'),
              ),
              const SizedBox(height: 20),
              // Household sharing switch (if member of a household or already shared)
              Builder(
                builder: (ctx) {
                  final householdProv = ctx.watch<HouseholdProvider>();
                  if (!householdProv.hasHousehold && !widget.item.isSharedWithHousehold) {
                    return const SizedBox.shrink();
                  }
                  final hhName = householdProv.currentHousehold?.name ?? 'Household';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isSharedWithHousehold ? const Color(0xFFFAF5FF) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _isSharedWithHousehold ? const Color(0xFFD8B4FE) : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          value: _isSharedWithHousehold,
                          activeThumbColor: const Color(0xFF7E22CE),
                          title: const Text(
                            'Share with Household 👥',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          ),
                          subtitle: Text(
                            _isSharedWithHousehold
                                ? 'Visible to members of "$hhName" to prevent duplicates'
                                : 'Private to your vanity only',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onChanged: (val) {
                            setState(() => _isSharedWithHousehold = val);
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),

              ElevatedButton(
                onPressed: _isSaving ? null : _handleSave,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: AppTheme.primaryRose,
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Text('Update Product Details', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoutineChip(String tag, String label) {
    final isSelected = _selectedRoutineTags.contains(tag);
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: AppTheme.primaryRose.withValues(alpha: 0.15),
      checkmarkColor: AppTheme.primaryRose,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        color: isSelected ? AppTheme.primaryRose : AppTheme.textDark,
      ),
      onSelected: (selected) {
        setState(() {
          if (selected) {
            _selectedRoutineTags.add(tag);
          } else {
            _selectedRoutineTags.remove(tag);
          }
        });
      },
    );
  }
}
