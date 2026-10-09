import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';

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

  late String _selectedCategoryId;
  late int _paoMonths;
  DateTime? _openedDate;
  DateTime? _expiryDate;
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

    _selectedCategoryId = product?.categoryId ?? 'other';
    _paoMonths = product?.paoMonths ?? 12;
    _openedDate = item.openedDate;
    _expiryDate = item.expiryDate;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _brandController.dispose();
    _volumeController.dispose();
    _priceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _recalculateExpiry() {
    if (_openedDate != null) {
      _expiryDate = VanityItemModel.computeExpiryDate(_openedDate!, _paoMonths);
    }
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final vanityProv = context.read<VanityProvider>();
      final originalProduct = widget.item.product;

      final updatedProduct = originalProduct?.copyWith(
        name: _nameController.text.trim(),
        brand: _brandController.text.trim(),
        volume: _volumeController.text.trim().isNotEmpty ? _volumeController.text.trim() : null,
        categoryId: _selectedCategoryId,
        paoMonths: _paoMonths,
      );

      final priceVal = double.tryParse(_priceController.text.trim().replaceAll('\$', ''));

      // Determine updated status
      String status = widget.item.status;
      if (widget.item.finishedDate == null && widget.item.status != 'finished') {
        if (_openedDate == null) {
          status = 'unopened';
        } else {
          final days = _expiryDate?.difference(DateTime.now()).inDays ?? 0;
          status = days < 0 ? 'expired' : (days <= 30 ? 'expiring' : 'active');
        }
      }

      final updatedItem = widget.item.copyWith(
        product: updatedProduct,
        price: priceVal,
        openedDate: _openedDate,
        expiryDate: _expiryDate,
        status: status,
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating: $e'), backgroundColor: AppTheme.statusRed),
        );
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
                : const Text('Save', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppTheme.primaryRose)),
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
              const Text('Brand', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _brandController,
                decoration: const InputDecoration(hintText: 'e.g. CeraVe, Glossier'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Brand is required' : null,
              ),
              const SizedBox(height: 16),

              // Product Name
              const Text('Product Name', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(hintText: 'e.g. Hyaluronic Acid Serum'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Product name is required' : null,
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
                        const Text('Category', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedCategoryId,
                          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                          items: categories.map((c) {
                            return DropdownMenuItem(
                              value: c.categoryId,
                              child: Text(c.categoryName, style: const TextStyle(fontSize: 14)),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _selectedCategoryId = val;
                                final cat = categories.firstWhere((c) => c.categoryId == val);
                                _paoMonths = cat.defaultPaoMonths;
                                _recalculateExpiry();
                              });
                            }
                          },
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
                        const Text('PAO Months', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<int>(
                          initialValue: _paoMonths,
                          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                          items: [3, 6, 9, 12, 18, 24, 36, 48].map((m) {
                            return DropdownMenuItem(
                              value: m,
                              child: Text('${m}M', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _paoMonths = val;
                                _recalculateExpiry();
                              });
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Volume & Price
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Volume / Size', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
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
                        const Text('Price', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _priceController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(hintText: 'e.g. 24.50', prefixIcon: Icon(Icons.attach_money, color: AppTheme.textMuted)),
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
                        const Text('Opened Date:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
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
                        const Text('Expiry Date:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
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
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Notes
              const Text('Notes', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Usage routine, batch notes, skin reaction...'),
              ),
              const SizedBox(height: 28),

              ElevatedButton(
                onPressed: _isSaving ? null : _handleSave,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: AppTheme.primaryRose,
                ),
                child: _isSaving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Update Product Details', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
