import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../models/product_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../services/product_lookup_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/duplicate_alert_dialog.dart';

class AddProductScreen extends StatefulWidget {
  final String? initialBarcode;

  const AddProductScreen({super.key, this.initialBarcode});

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  // Form Fields
  final _formKey = GlobalKey<FormState>();
  final _barcodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _brandController = TextEditingController();
  final _volumeController = TextEditingController();
  final _priceController = TextEditingController();
  final _notesController = TextEditingController();
  final _ingredientsController = TextEditingController();

  String _selectedCategoryId = 'serum';
  int _paoMonths = 12;
  String? _imageUrl;
  bool _isOpenedToday = true;
  DateTime _openedDate = DateTime.now();
  bool _isLookingUp = false;
  bool _isSaving = false;
  bool _torchOn = false;

  String? _countryOfOrigin;
  String? _packagingType;
  List<String> _skinClaims = [];
  String? _keyActives;
  String? _sourceDatabase;

  // Extended product intelligence
  String? _allergens;
  String? _preservatives;
  String? _fragranceIngredients;
  List<String> _warnings = [];
  List<String> _certifications = [];
  String? _skinType;
  String? _applicationArea;
  String? _texture;
  String? _scent;
  String? _pH;
  String? _inci;
  List<String> _imageGallery = [];
  String? _barcodeScanUrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    if (widget.initialBarcode != null) {
      _barcodeController.text = widget.initialBarcode!;
      _tabController.index = 1;
      _performLookup(widget.initialBarcode!);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scannerController.dispose();
    _barcodeController.dispose();
    _nameController.dispose();
    _brandController.dispose();
    _volumeController.dispose();
    _priceController.dispose();
    _notesController.dispose();
    _ingredientsController.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue != null && barcode.rawValue!.isNotEmpty) {
        final code = barcode.rawValue!;
        _scannerController.stop();
        _barcodeController.text = code;
        _tabController.animateTo(1); // Switch to form tab
        _performLookup(code);
        break;
      }
    }
  }

  Future<void> _performLookup(String barcode) async {
    setState(() => _isLookingUp = true);

    try {
      final result = await ProductLookupService.lookupBarcode(barcode);
      if (result.found && result.product != null) {
        final p = result.product!;
        setState(() {
          _nameController.text = p.name;
          _brandController.text = p.brand;
          _volumeController.text = p.volume ?? '';
          _selectedCategoryId = p.categoryId;
          _paoMonths = p.paoMonths;
          _imageUrl = p.imageUrl;
          _ingredientsController.text = p.ingredients ?? '';
          _countryOfOrigin = p.countryOfOrigin;
          _packagingType = p.packagingType;
          _skinClaims = p.skinClaims;
          _keyActives = p.keyActives;
          _sourceDatabase = p.sourceDatabase ?? result.source;
          // New extended fields
          _allergens = p.allergens;
          _preservatives = p.preservatives;
          _fragranceIngredients = p.fragranceIngredients;
          _warnings = p.warnings;
          _certifications = p.certifications;
          _skinType = p.skinType;
          _applicationArea = p.applicationArea;
          _texture = p.texture;
          _scent = p.scent;
          _pH = p.pH;
          _inci = p.inci;
          _imageGallery = p.imageGallery;
          _barcodeScanUrl = p.barcodeScanUrl;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✨ Found via ${p.sourceDatabase ?? result.source ?? "Database"}: ${p.brand} ${p.name}'),
              backgroundColor: AppTheme.statusGreen,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.errorMessage ?? 'Barcode not found. Fill in details manually.'),
              backgroundColor: AppTheme.statusAmber,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Lookup error: $e');
    } finally {
      if (mounted) setState(() => _isLookingUp = false);
    }
  }

  DateTime get _computedExpiryDate {
    return VanityItemModel.computeExpiryDate(_openedDate, _paoMonths);
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    final vanityProv = context.read<VanityProvider>();
    final auth = context.read<AuthProvider>();
    final userId = auth.currentUser?.userId ?? 'demo_user';

    // Duplicate Check
    final duplicates = vanityProv.checkDuplicates(
      barcode: _barcodeController.text.trim(),
      name: _nameController.text.trim(),
      brand: _brandController.text.trim(),
    );

    if (duplicates.isNotEmpty) {
      final proceed = await DuplicateAlertDialog.show(context, duplicates);
      if (proceed != true) return;
    }

    setState(() => _isSaving = true);

    try {
      final product = ProductModel(
        productId: 'prod_${DateTime.now().millisecondsSinceEpoch}',
        barcode: _barcodeController.text.trim(),
        name: _nameController.text.trim(),
        brand: _brandController.text.trim(),
        categoryId: _selectedCategoryId,
        paoMonths: _paoMonths,
        volume: _volumeController.text.trim().isNotEmpty ? _volumeController.text.trim() : null,
        imageUrl: _imageUrl,
        ingredients: _ingredientsController.text.trim().isNotEmpty ? _ingredientsController.text.trim() : null,
        countryOfOrigin: _countryOfOrigin,
        packagingType: _packagingType,
        skinClaims: _skinClaims,
        keyActives: _keyActives,
        sourceDatabase: _sourceDatabase,
        createdAt: DateTime.now(),
        allergens: _allergens,
        preservatives: _preservatives,
        fragranceIngredients: _fragranceIngredients,
        warnings: _warnings,
        certifications: _certifications,
        skinType: _skinType,
        applicationArea: _applicationArea,
        texture: _texture,
        scent: _scent,
        pH: _pH,
        inci: _inci,
        imageGallery: _imageGallery,
        barcodeScanUrl: _barcodeScanUrl,
      );

      final priceVal = double.tryParse(_priceController.text.trim().replaceAll('\$', ''));

      await vanityProv.addItem(
        product: product,
        userId: userId,
        openedDate: _isOpenedToday ? _openedDate : null,
        price: priceVal,
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 Product added to your Vanity Shelf!'),
            backgroundColor: AppTheme.statusGreen,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving product: $e'), backgroundColor: AppTheme.statusRed),
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
        title: const Text('Add to Vanity'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryRose,
          labelColor: AppTheme.primaryRose,
          unselectedLabelColor: AppTheme.textMuted,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          tabs: const [
            Tab(icon: Icon(Icons.qr_code_scanner_rounded), text: 'Scan Barcode'),
            Tab(icon: Icon(Icons.edit_note_rounded), text: 'Product Details'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildScannerTab(),
          _buildFormTab(categories),
        ],
      ),
    );
  }

  Widget _buildScannerTab() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              MobileScanner(
                controller: _scannerController,
                onDetect: _onBarcodeDetected,
                errorBuilder: (context, error) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.videocam_off_outlined, size: 48, color: AppTheme.textMuted),
                          const SizedBox(height: 12),
                          const Text(
                            'Camera preview not available.\nYou can use manual entry or sample barcodes below.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () => _tabController.animateTo(1),
                            child: const Text('Enter Details Manually'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // Scanner Overlay Guide
              Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppTheme.primaryRose, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primaryRose.withValues(alpha: 0.15),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Align Barcode within Frame',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const Icon(Icons.crop_free, size: 40, color: Colors.white70),
                    const SizedBox(height: 12),
                  ],
                ),
              ),

              // Camera Controls
              Positioned(
                bottom: 24,
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.black.withValues(alpha: 0.65),
                      radius: 24,
                      child: IconButton(
                        icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                        onPressed: () async {
                          await _scannerController.toggleTorch();
                          setState(() => _torchOn = !_torchOn);
                        },
                      ),
                    ),
                    const SizedBox(width: 20),
                    CircleAvatar(
                      backgroundColor: Colors.black.withValues(alpha: 0.65),
                      radius: 24,
                      child: IconButton(
                        icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                        onPressed: () => _scannerController.switchCamera(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Quick Test / Manual Barcode Input Bar
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _barcodeController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: 'Or enter barcode manually...',
                        prefixIcon: const Icon(Icons.qr_code, color: AppTheme.textMuted),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.search, color: AppTheme.primaryRose),
                          onPressed: () {
                            if (_barcodeController.text.trim().isNotEmpty) {
                              _tabController.animateTo(1);
                              _performLookup(_barcodeController.text.trim());
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Sample Demo Barcodes for instant testing
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text('Sample barcodes: ', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                    _buildSampleChip('3337875597180', 'La Roche-Posay'),
                    _buildSampleChip('8809643068098', 'Joseon SPF'),
                    _buildSampleChip('041554420616', 'Sky High Mascara'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSampleChip(String barcode, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 10)),
        onPressed: () {
          _barcodeController.text = barcode;
          _tabController.animateTo(1);
          _performLookup(barcode);
        },
      ),
    );
  }

  Widget _buildFormTab(List<CategoryModel> categories) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Lookup Loading Bar
            if (_isLookingUp)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.statusGreenBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.statusGreen.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.statusGreen)),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Fetching product details from Open Beauty Facts...',
                        style: TextStyle(fontSize: 12, color: AppTheme.statusGreen, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),

            // Barcode field + Lookup button
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Barcode / UPC', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _barcodeController,
                        decoration: const InputDecoration(
                          hintText: 'e.g. 3337875597180',
                          prefixIcon: Icon(Icons.qr_code, color: AppTheme.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 26),
                  child: ElevatedButton(
                    onPressed: _isLookingUp
                        ? null
                        : () {
                            if (_barcodeController.text.trim().isNotEmpty) {
                              _performLookup(_barcodeController.text.trim());
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      backgroundColor: const Color(0xFFF1F5F9),
                      foregroundColor: AppTheme.textDark,
                    ),
                    child: const Text('Lookup'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Product Intelligence Card (When metadata is detected)
            if (_sourceDatabase != null || _countryOfOrigin != null || _keyActives != null || _skinClaims.isNotEmpty) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 18),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFDF4F7), Color(0xFFF9F5FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.primaryRose.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, size: 16, color: AppTheme.primaryRose),
                        const SizedBox(width: 6),
                        const Text(
                          'Product Intelligence Auto-Detected',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primaryRose),
                        ),
                        const Spacer(),
                        if (_sourceDatabase != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _sourceDatabase!,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.textMuted),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Badges (Country, Packaging, Skin Type, Texture, Scent, pH)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (_countryOfOrigin != null)
                          Chip(
                            avatar: const Icon(Icons.public, size: 14, color: AppTheme.textDark),
                            label: Text('Origin: $_countryOfOrigin', style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: Colors.white,
                          ),
                        if (_packagingType != null)
                          Chip(
                            avatar: const Icon(Icons.inventory_2_outlined, size: 14, color: AppTheme.textDark),
                            label: Text(_packagingType!, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: Colors.white,
                          ),
                        if (_skinType != null)
                          Chip(
                            avatar: const Icon(Icons.face_retouching_natural, size: 14, color: AppTheme.textDark),
                            label: Text(_skinType!, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFFF3FEF5),
                          ),
                        if (_texture != null)
                          Chip(
                            avatar: const Icon(Icons.water_drop_outlined, size: 14, color: AppTheme.textDark),
                            label: Text(_texture!, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFFFFF8F0),
                          ),
                        if (_scent != null)
                          Chip(
                            avatar: const Icon(Icons.air, size: 14, color: AppTheme.textDark),
                            label: Text(_scent!, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFFFDF4FF),
                          ),
                        if (_pH != null)
                          Chip(
                            avatar: const Icon(Icons.science, size: 14, color: AppTheme.textDark),
                            label: Text(_pH!, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFFF0F4FF),
                          ),
                        ..._skinClaims.map((claim) => Chip(
                              avatar: const Icon(Icons.check_circle_outline, size: 14, color: AppTheme.statusGreen),
                              label: Text(claim, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              backgroundColor: AppTheme.statusGreenBg,
                            )),
                      ],
                    ),

                    if (_certifications.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: _certifications.map((cert) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3FEF5),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFF4CAF50).withValues(alpha: 0.3)),
                          ),
                          child: Text(cert, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF2E7D32))),
                        )).toList(),
                      ),
                    ],

                    if (_keyActives != null && _keyActives!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.science_outlined, size: 14, color: AppTheme.primaryRose),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Actives: $_keyActives',
                              style: const TextStyle(fontSize: 12, color: AppTheme.textDark, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ],

                    if (_allergens != null && _allergens!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.warning_amber_outlined, size: 14, color: Color(0xFFD97706)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Allergens: $_allergens',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],


            // Brand
            const Text('Brand', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _brandController,
              decoration: const InputDecoration(
                hintText: 'e.g. CeraVe, The Ordinary, Glossier',
                prefixIcon: Icon(Icons.branding_watermark_outlined, color: AppTheme.textMuted),
              ),
              validator: (val) => val == null || val.trim().isEmpty ? 'Brand is required' : null,
            ),
            const SizedBox(height: 16),

            // Product Name
            const Text('Product Name', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                hintText: 'e.g. Hyaluronic Acid 2% + B5',
                prefixIcon: Icon(Icons.spa_outlined, color: AppTheme.textMuted),
              ),
              validator: (val) => val == null || val.trim().isEmpty ? 'Product name is required' : null,
            ),
            const SizedBox(height: 16),

            // Category & PAO Selection
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
                          if (val != null) setState(() => _paoMonths = val);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Volume & Price Row
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
                        decoration: const InputDecoration(
                          hintText: 'e.g. 50 ml / 1.7 oz',
                          prefixIcon: Icon(Icons.scale_outlined, color: AppTheme.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Price (Optional)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _priceController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          hintText: 'e.g. 24.50',
                          prefixIcon: Icon(Icons.attach_money, color: AppTheme.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Opened Today Toggle & Expiry Preview
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
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Opened Today?',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                          ),
                          Text(
                            'Computes expiry date based on PAO',
                            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                      Switch(
                        value: _isOpenedToday,
                        activeThumbColor: AppTheme.primaryRose,
                        onChanged: (val) => setState(() => _isOpenedToday = val),
                      ),
                    ],
                  ),
                  if (_isOpenedToday) ...[
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Opened Date:', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                        TextButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 14, color: AppTheme.primaryRose),
                          label: Text(DateFormat('MMM d, yyyy').format(_openedDate), style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryRose)),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _openedDate,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) setState(() => _openedDate = picked);
                          },
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Calculated Expiry Date:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.statusGreenBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            DateFormat('MMM d, yyyy').format(_computedExpiryDate),
                            style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.statusGreen, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Notes / Usage routine
            const Text('Notes (Optional)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _notesController,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'e.g. Morning routine only, patch tested ok',
              ),
            ),
            const SizedBox(height: 28),

            // Save Button
            ElevatedButton(
              onPressed: _isSaving ? null : _handleSave,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: AppTheme.primaryRose,
              ),
              child: _isSaving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Add to Vanity Shelf', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}
