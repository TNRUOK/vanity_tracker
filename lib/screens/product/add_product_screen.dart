import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../models/category_model.dart';
import '../../services/category_classifier.dart';
import '../../widgets/product_search_dialog.dart';
import '../../models/product_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../services/database_service.dart';
import '../../services/product_lookup_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/barcode_utils.dart';
import '../../widgets/batch_scan_confirm_dialog.dart';
import '../../widgets/duplicate_alert_dialog.dart';
import '../guide/pao_guide_screen.dart';

class AddProductScreen extends StatefulWidget {
  final String? initialBarcode;

  const AddProductScreen({super.key, this.initialBarcode});

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
    // Retail product barcodes only: ignores QR codes/other symbols and speeds up detection.
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE],
  );
  final BarcodeScanGate _scanGate = BarcodeScanGate();

  /// Increments per lookup so a slow, older lookup can't overwrite a newer one.
  int _lookupToken = 0;

  /// Barcode whose online data currently fills the form (null if typed by the user).
  String? _autoFilledBarcode;

  /// The values the last lookup put into each text field. A field whose text differs is
  /// the user's own edit and is never overwritten or cleared by a lookup.
  final Map<TextEditingController, String> _autoFilledText = {};

  /// Outcome of the last lookup, shown with its next steps (null = no lookup yet).
  ProductLookupResult? _lastLookup;

  /// Field names a lookup left alone because the user had typed them.
  List<String> _keptUserFields = const [];

  /// Shown on the scanner when a read was skipped because its check digit failed.
  String? _scanHint;

  // Form Fields
  final _formKey = GlobalKey<FormState>();
  final _barcodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _brandController = TextEditingController();
  final _volumeController = TextEditingController();
  final _priceController = TextEditingController();
  final _notesController = TextEditingController();
  final _ingredientsController = TextEditingController();
  final _batchCodeController = TextEditingController();

  // Uncategorized until the name, a lookup or the user identifies the category.
  String _selectedCategoryId = 'other';
  CategorySource _categorySource = CategorySource.unknown;
  int _paoMonths = 12; // placeholder while the PAO is unknown (never used for expiry)
  PaoSource _paoSource = PaoSource.unknown;
  ProductModel? _lookedUpProduct; // the record the form was filled from, for provenance
  bool _saveInFlight = false;

  /// One id per form (one physical item being added): retries reuse it.
  final String _pendingItemId = 'item_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 8)}';
  String? _imageUrl;
  bool _isOpenedToday = true;
  DateTime _openedDate = DateTime.now();
  DateTime? _sealedExpiryDate;
  DateTime? _manufacturingDate;
  // Month-only dates ("EXP 10/2027") keep that precision when saved.
  DatePrecision _sealedExpiryPrecision = DatePrecision.day;
  DatePrecision _manufacturingDatePrecision = DatePrecision.day;
  final List<String> _selectedRoutineTags = [];
  bool _isSharedWithHousehold = false;
  bool _isLookingUp = false;
  bool _isSaving = false;

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
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        if (_tabController.index == 0) {
          _scanGate.reset(); // back on the scanner: allow the next scan
          _safeStartScanner();
        } else {
          _safeStopScanner();
        }
      }
    });
    if (widget.initialBarcode != null) {
      _barcodeController.text = widget.initialBarcode!;
      _tabController.index = 1;
      _performLookup(widget.initialBarcode!);
    }
    // Refresh the inline duplicate hint as identity fields change.
    for (final c in [_barcodeController, _nameController, _brandController, _volumeController]) {
      c.addListener(_onIdentityChanged);
    }
  }

  void _onIdentityChanged() {
    if (mounted) setState(() {});
  }

  /// Matches for the product currently in the form (same rules as the save-time check).
  List<DuplicateMatch> _currentMatches(VanityProvider vanity, HouseholdProvider household) {
    if (_nameController.text.trim().isEmpty && _barcodeController.text.trim().isEmpty) return const [];
    return vanity.checkHouseholdDuplicates(
      barcode: _barcodeController.text.trim(),
      name: _nameController.text.trim(),
      brand: _brandController.text.trim(),
      volume: _volumeController.text.trim(),
      sharedHouseholdItems: household.sharedItems,
      memberEmails: household.memberEmails,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _scannerController.dispose();
    _barcodeController.dispose();
    _nameController.dispose();
    _brandController.dispose();
    _volumeController.dispose();
    _priceController.dispose();
    _notesController.dispose();
    _ingredientsController.dispose();
    _batchCodeController.dispose();
    super.dispose();
  }

  /// The MobileScanner widget also starts/stops the camera as the scanner tab is
  /// shown/hidden, so overlapping calls are expected; they must never surface as
  /// uncaught errors.
  Future<void> _safeStartScanner() async {
    final state = _scannerController.value;
    if (state.isRunning || state.isStarting) return;
    try {
      await _scannerController.start();
    } catch (e) {
      debugPrint('Scanner start skipped: $e');
    }
  }

  Future<void> _safeStopScanner() async {
    try {
      await _scannerController.stop();
    } catch (e) {
      debugPrint('Scanner stop skipped: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same policy as mobile_scanner's built-in handling: never re-prompt for a denied permission.
    if (!_scannerController.value.hasCameraPermission) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _safeStopScanner();
    } else if (state == AppLifecycleState.resumed && _tabController.index == 0) {
      _safeStartScanner();
    }
  }

  static RetailFormat? _retailFormat(BarcodeFormat f) => switch (f) {
        BarcodeFormat.ean13 => RetailFormat.ean13,
        BarcodeFormat.ean8 => RetailFormat.ean8,
        BarcodeFormat.upcA => RetailFormat.upcA,
        BarcodeFormat.upcE => RetailFormat.upcE,
        _ => null,
      };

  void _onBarcodeDetected(BarcodeCapture capture) {
    // Only the first valid retail barcode is handled; repeated frames are ignored until
    // the user comes back to the scanner tab. A read whose check digit fails is skipped
    // (the decoder misread a bar) and scanning continues.
    final check = _scanGate.acceptReads(
      capture.barcodes.map((b) => (value: b.rawValue, format: _retailFormat(b.format))),
    );
    if (check == null) {
      final rejected = _scanGate.lastRejected;
      if (rejected != null && mounted) {
        setState(() => _scanHint = 'Read ${rejected.raw} but its check digit failed: hold steady, avoid glare, try again.');
      }
      if (kDebugMode) debugPrint('[scan] no usable read in frame (rejected: ${rejected?.formatLabel})');
      return;
    }
    if (kDebugMode) debugPrint('[scan] accepted ${check.formatLabel} read');
    _scanHint = null;
    _safeStopScanner();
    _barcodeController.text = check.lookupDigits!;
    _tabController.animateTo(1); // Switch to form tab
    _performLookup(check.lookupDigits!);
  }

  /// Clears fields that a previous lookup filled in, so data from product A is never
  /// saved under the barcode of product B.
  void _clearAutoFilledProduct() {
    // Only text the previous lookup put there is removed; the user's own typing stays.
    for (final e in _autoFilledText.entries) {
      if (e.key.text == e.value) e.key.clear();
    }
    _autoFilledText.clear();
    _imageUrl = null;
    _countryOfOrigin = null;
    _packagingType = null;
    _skinClaims = [];
    _keyActives = null;
    _sourceDatabase = null;
    _allergens = null;
    _preservatives = null;
    _fragranceIngredients = null;
    _warnings = [];
    _certifications = [];
    _skinType = null;
    _applicationArea = null;
    _texture = null;
    _scent = null;
    _pH = null;
    _inci = null;
    _imageGallery = [];
    _barcodeScanUrl = null;
    _autoFilledBarcode = null;
    _lookedUpProduct = null;
    // The previous product's PAO must not carry over: back to the category estimate.
    _paoMonths = (CategoryModel.byId(_selectedCategoryId) ?? CategoryModel.defaultCategories.last).defaultPaoMonths;
    _paoSource = _categorySource == CategorySource.unknown ? PaoSource.unknown : PaoSource.categoryDefault;
    // Neither may its category, unless the user chose it: re-suggest from what is left.
    if (_categorySource != CategorySource.user) {
      _categorySource = CategorySource.unknown;
      _paoSource = PaoSource.unknown;
      _suggestCategoryFromName();
    }
  }

  /// Suggests the category from the typed brand and name, unless the user chose it or a
  /// product database supplied it. A PAO that is only a category estimate (or unknown)
  /// follows the suggestion; any other PAO is product-specific and is never replaced.
  void _suggestCategoryFromName() {
    if (_categorySource == CategorySource.user || _categorySource == CategorySource.productDatabase) return;
    final s = CategoryClassifier.fromName('${_brandController.text} ${_nameController.text}');
    _selectedCategoryId = s?.categoryId ?? 'other';
    _categorySource = s?.source ?? CategorySource.unknown;
    if (_paoSource == PaoSource.categoryDefault || _paoSource == PaoSource.unknown) {
      final cat = s != null ? CategoryModel.byId(s.categoryId) : null;
      _paoMonths = cat?.defaultPaoMonths ?? 12;
      _paoSource = cat != null ? PaoSource.categoryDefault : PaoSource.unknown;
    }
  }

  void _showLookupMessage(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color, duration: const Duration(seconds: 4)));
  }

  /// Puts a looked-up value into [c] unless the user typed their own text there.
  /// Returns false when the field was left alone.
  bool _fillFromLookup(TextEditingController c, String? value) {
    final current = c.text;
    final userOwned = current.trim().isNotEmpty && current != _autoFilledText[c];
    if (userOwned) return false;
    c.text = value ?? '';
    _autoFilledText[c] = c.text;
    return true;
  }

  Future<void> _performLookup(String barcode, {bool allowInvalidCheckDigit = false}) async {
    final token = ++_lookupToken;
    setState(() {
      _isLookingUp = true;
      _lastLookup = null;
    });

    try {
      final result = await ProductLookupService.lookupBarcode(barcode, allowInvalidCheckDigit: allowInvalidCheckDigit);
      if (!mounted || token != _lookupToken) return; // a newer lookup superseded this one

      final lookedUp = result.barcode ?? barcode.trim();
      if (_autoFilledBarcode != null && _autoFilledBarcode != lookedUp) {
        setState(_clearAutoFilledProduct);
      }

      if (result.found && result.product != null) {
        final p = result.product!;
        setState(() {
          _autoFilledBarcode = lookedUp;
          _lookedUpProduct = p;
          if (result.barcode != null) _barcodeController.text = result.barcode!;
          final kept = <String>[
            if (!_fillFromLookup(_nameController, p.name)) 'Product name',
            if (!_fillFromLookup(_brandController, p.brand)) 'Brand',
            if (!_fillFromLookup(_volumeController, p.volume)) 'Volume / Size',
            if (!_fillFromLookup(_ingredientsController, p.ingredients)) 'Ingredients',
          ];
          // A category or PAO the user chose (or read from the pack) is never replaced.
          if (_categorySource != CategorySource.user) {
            _selectedCategoryId = p.categoryId;
            _categorySource = p.categorySource;
          } else {
            kept.add('Category');
          }
          if (!_paoSource.isVerified) {
            _paoMonths = p.paoMonths;
            _paoSource = p.paoSource;
          } else {
            kept.add('PAO');
          }
          _keptUserFields = kept;
          _imageUrl = p.imageUrl;
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

      } else {
        setState(() => _keptUserFields = const []);
      }
      setState(() => _lastLookup = result);
    } catch (e) {
      debugPrint('Lookup error: $e');
      if (token == _lookupToken) {
        _showLookupMessage('Product lookup failed ($e). You can enter the details manually.', AppTheme.statusRed);
      }
    } finally {
      if (mounted && token == _lookupToken) setState(() => _isLookingUp = false);
    }
  }

  DateTime get _computedExpiryDate {
    return VanityItemModel.computeExpiryDate(_openedDate, _paoMonths);
  }

  Future<void> _handleSave() async {
    // A second tap while the first save (or its duplicate warning) is in progress is ignored,
    // so one tap sequence can never create two items.
    if (_saveInFlight) return;
    if (!_formKey.currentState!.validate()) return;
    _saveInFlight = true;
    try {
      await _saveAfterChecks();
    } finally {
      _saveInFlight = false;
    }
  }

  Future<void> _saveAfterChecks() async {
    final vanityProv = context.read<VanityProvider>();
    final householdProv = context.read<HouseholdProvider>();
    final auth = context.read<AuthProvider>();
    final userId = auth.currentUser?.userId ?? 'demo_user';

    // Duplicate Check (Personal + Shared Household)
    final duplicates = vanityProv.checkHouseholdDuplicates(
      barcode: _barcodeController.text.trim(),
      name: _nameController.text.trim(),
      brand: _brandController.text.trim(),
      volume: _volumeController.text.trim(),
      sharedHouseholdItems: householdProv.sharedItems,
      memberEmails: householdProv.memberEmails,
    );

    // Destination: the form's share switch, unless a duplicate warning asks the user to
    // choose explicitly (personal / shared / don't add). Nothing is created before that.
    var shouldShare = _isSharedWithHousehold && householdProv.hasHousehold;
    if (duplicates.isNotEmpty) {
      final decision = await DuplicateAlertDialog.showDecision(
        context,
        duplicates,
        canShare: householdProv.hasHousehold,
      );
      if (decision == DuplicateDecision.cancel || !mounted) return;
      shouldShare = decision == DuplicateDecision.addShared;
    }

    setState(() => _isSaving = true);

    try {
      final ingredientsText = _ingredientsController.text.trim();
      final lookedUpList = _lookedUpProduct?.ingredients;
      final product = ProductModel(
        productId: 'prod_${DateTime.now().millisecondsSinceEpoch}',
        barcode: _barcodeController.text.trim(),
        name: _nameController.text.trim(),
        brand: _brandController.text.trim(),
        categoryId: _selectedCategoryId,
        categorySource: _categorySource,
        paoMonths: _paoMonths,
        paoSource: _paoSource,
        volume: _volumeController.text.trim().isNotEmpty ? _volumeController.text.trim() : null,
        imageUrl: _imageUrl,
        ingredients: ingredientsText.isNotEmpty ? ingredientsText : null,
        // A looked-up list keeps its provenance only if the user did not change it.
        ingredientsSource: ingredientsText.isEmpty
            ? IngredientSource.notRecorded
            : (lookedUpList != null && ingredientsText == lookedUpList.trim()
                  ? _lookedUpProduct!.ingredientsSource
                  : IngredientSource.user),
        ingredientsUpdatedAt: ingredientsText.isEmpty ? null : DateTime.now(),
        ingredientsContext: ingredientsText.isNotEmpty && lookedUpList != null && ingredientsText == lookedUpList.trim()
            ? _lookedUpProduct!.ingredientsContext
            : null,
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

      final priceVal = double.tryParse(_priceController.text.trim().replaceAll(RegExp(r'[^\d.]'), ''));

      await vanityProv.addItem(
        // Same id for every retry of this form, so a slow or repeated save rewrites one
        // record instead of creating a second physical item.
        vanityItemId: _pendingItemId,
        product: product,
        userId: userId,
        openedDate: _isOpenedToday ? _openedDate : null,
        sealedExpiryDate: _sealedExpiryDate,
        sealedExpiryPrecision: _sealedExpiryPrecision,
        batchCode: _batchCodeController.text.trim().isNotEmpty ? _batchCodeController.text.trim() : null,
        manufacturingDate: _manufacturingDate,
        manufacturingDatePrecision: _manufacturingDatePrecision,
        price: priceVal,
        // The price field shows the budget currency, so that is the price's currency.
        priceCurrency: vanityProv.budgetCurrencyCode,
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        routineTags: _selectedRoutineTags,
        isSharedWithHousehold: shouldShare,
        sharedHouseholdId: shouldShare ? householdProv.currentHousehold?.householdId : null,
        throwOnSyncFailure: true,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              shouldShare
                  ? '🎉 Added to your shelf and shared with your household.'
                  : '🎉 Added to your shelf (private).',
            ),
            backgroundColor: AppTheme.statusGreen,
          ),
        );
        Navigator.of(context).pop();
      }
    } on VanitySyncException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added on this device. ${e.message}'), backgroundColor: AppTheme.statusAmber),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving product: $e'), backgroundColor: AppTheme.statusRed));
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
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
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
      body: TabBarView(controller: _tabController, children: [_buildScannerTab(), _buildFormTab(categories)]),
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
                errorBuilder: (context, error) => _buildScannerError(error),
              ),

              // Overlay guide and camera controls only make sense while the camera works.
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: _scannerController,
                builder: (context, state, _) {
                  if (state.error != null) return const SizedBox.shrink();
                  return _buildScannerOverlay(state);
                },
              ),
              Positioned(
                top: 12,
                left: 16,
                right: 16,
                child: ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _scannerController,
                  builder: (context, state, _) => state.error != null
                      ? const SizedBox.shrink()
                      : Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _scanHint ??
                                'Fill the frame with the barcode, 10–20 cm away. Hold it flat and steady, tilt '
                                    'slightly to avoid glare, and use the flash in low light.',
                            key: const ValueKey('scan-hint'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _scanHint != null ? const Color(0xFFFDE68A) : Colors.white, fontSize: 11.5),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),

        // Quick Test / Manual Barcode Input Bar
        _buildManualBarcodeBar(),
      ],
    );
  }

  /// Camera failure view with a cause-specific message and a manual-entry fallback.
  Widget _buildScannerError(MobileScannerException error) {
    final (String title, String detail, bool canRetry) = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => (
        'Camera access was denied',
        kIsWeb
            ? 'Allow camera access for this site (camera icon in the address bar), then tap Try again.'
            : 'Allow camera access in Settings → Apps → Vanity Tracker → Permissions, then tap Try again.',
        true,
      ),
      MobileScannerErrorCode.unsupported => (
        'No camera available',
        'This device or browser has no usable camera for scanning.',
        false,
      ),
      _ => (
        'Camera could not start',
        error.errorDetails?.message ?? 'Another app or browser tab may be using the camera.',
        true,
      ),
    };
    return Container(
      color: const Color(0xFFFDFBF9),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off_outlined, size: 48, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textDark, fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '$detail\nYou can also type the barcode below or enter the details manually.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (canRetry)
                OutlinedButton.icon(
                  onPressed: _safeStartScanner,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Try again'),
                ),
              ElevatedButton(onPressed: () => _tabController.animateTo(1), child: const Text('Enter Details Manually')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScannerOverlay(MobileScannerState state) {
    final torchOn = state.torchState == TorchState.on;
    final hasTorch = state.isRunning && state.torchState != TorchState.unavailable;
    final canSwitch = state.isRunning && (state.availableCameras ?? 2) > 1;
    return Stack(
      alignment: Alignment.center,
      children: [
        // Scanner Overlay Guide
        Container(
          width: 260,
          height: 260,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.primaryRose, width: 2.5),
            boxShadow: [
              BoxShadow(color: AppTheme.primaryRose.withValues(alpha: 0.15), blurRadius: 20, spreadRadius: 2),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(height: 8),
              const Icon(Icons.crop_free, size: 40, color: Colors.white70),
              const SizedBox(height: 12),
            ],
          ),
        ),


        // Camera Controls (torch reflects the camera's real state; hidden when unsupported)
        Positioned(
          bottom: 24,
          child: Row(
            children: [
              if (hasTorch)
                CircleAvatar(
                  backgroundColor: Colors.black.withValues(alpha: 0.65),
                  radius: 24,
                  child: IconButton(
                    tooltip: torchOn ? 'Turn flash off' : 'Turn flash on',
                    icon: Icon(torchOn ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                    onPressed: () => _scannerController.toggleTorch().catchError(
                      (Object e) => debugPrint('Torch toggle failed: $e'),
                    ),
                  ),
                ),
              if (hasTorch && canSwitch) const SizedBox(width: 20),
              if (canSwitch)
                CircleAvatar(
                  backgroundColor: Colors.black.withValues(alpha: 0.65),
                  radius: 24,
                  child: IconButton(
                    tooltip: 'Switch camera',
                    icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                    onPressed: () => _scannerController.switchCamera().catchError(
                      (Object e) => debugPrint('Camera switch failed: $e'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildManualBarcodeBar() {
    return Container(
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
                // Verified against Open Beauty Facts on 2026-10-19 (labels are what the
                // database lists for these codes).
                _buildSampleChip('3337875597180', 'CeraVe Hydrating Cleanser'),
                _buildSampleChip('041554420616', 'Maybelline mascara (UPC-A)'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The outcome of the last lookup with the next steps that fit it. A valid barcode that
  /// no database lists is never called invalid.
  Widget _buildLookupStatus(ProductLookupResult r) {
    final p = r.product;
    final via = r.source ?? p?.sourceDatabase ?? 'database';
    final (Color fg, Color bg, IconData icon, String text) = switch (r.status) {
      LookupStatus.found => (
          r.errorMessage != null || r.hasMissingDetails ? AppTheme.statusAmber : AppTheme.statusGreen,
          r.errorMessage != null || r.hasMissingDetails ? AppTheme.statusAmberBg : AppTheme.statusGreenBg,
          Icons.check_circle_outline_rounded,
          r.errorMessage ??
              (r.hasMissingDetails
                  ? 'Found a record via $via, but its name or brand is missing. Please fill them in.'
                  : r.fromCache
                      ? 'Found (saved lookup from ${r.cachedAt!.toIso8601String().split('T').first}) via $via: ${p!.brand} ${p.name}'
                      : 'Found via $via: ${p!.brand} ${p.name}. Check the details below; you can edit them.'),
        ),
      LookupStatus.invalidCheckDigit || LookupStatus.invalidFormat => (
          AppTheme.statusRed,
          const Color(0xFFFEE2E2),
          Icons.error_outline_rounded,
          r.errorMessage ?? 'Not a valid barcode.',
        ),
      LookupStatus.notFound => (AppTheme.statusAmber, AppTheme.statusAmberBg, Icons.search_off_rounded, r.errorMessage ?? 'Not found.'),
      LookupStatus.offline || LookupStatus.timeout || LookupStatus.unavailable => (
          AppTheme.statusAmber,
          AppTheme.statusAmberBg,
          Icons.cloud_off_rounded,
          r.errorMessage ?? 'The databases could not be checked.',
        ),
    };
    Widget action(String key, String label, IconData icon, VoidCallback onTap) => TextButton.icon(
          key: ValueKey('lookup-action-$key'),
          onPressed: _isLookingUp ? null : onTap,
          icon: Icon(icon, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12)),
        );
    final rescan = action('rescan', 'Rescan', Icons.qr_code_scanner_rounded, () => _tabController.animateTo(0));
    final manual = action('manual', 'Enter details manually', Icons.edit_rounded, () => setState(() => _lastLookup = null));
    final search = action('search', 'Search by name', Icons.manage_search_rounded, _searchByName);
    final retry = action('retry', 'Try again', Icons.refresh_rounded, () => _performLookup(_barcodeController.text.trim()));
    final actions = switch (r.status) {
      LookupStatus.found => <Widget>[],
      LookupStatus.invalidCheckDigit => [
          rescan,
          action('anyway', 'Search this number anyway', Icons.travel_explore_rounded,
              () => _performLookup(_barcodeController.text.trim(), allowInvalidCheckDigit: true)),
          manual,
        ],
      LookupStatus.invalidFormat => [rescan, manual],
      LookupStatus.notFound => [search, rescan, manual],
      LookupStatus.offline => [retry, manual],
      LookupStatus.timeout || LookupStatus.unavailable => [retry, search, manual],
    };
    return Container(
      key: const ValueKey('lookup-status'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  key: const ValueKey('lookup-status-text'),
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textDark, fontWeight: FontWeight.w600, height: 1.35),
                ),
              ),
            ],
          ),
          if (r.found && _keptUserFields.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Kept what you entered for: ${_keptUserFields.join(', ')}.',
                key: const ValueKey('lookup-kept-fields'),
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
              ),
            ),
          if (r.found && r.attribution != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(r.attribution!, style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            ),
          if (actions.isNotEmpty) Wrap(spacing: 4, children: actions),
        ],
      ),
    );
  }

  /// Name/brand search on Open Beauty Facts; the chosen product is then looked up by its
  /// barcode so the full record (and its identity check) is used.
  Future<void> _searchByName() async {
    final initial = [_brandController.text.trim(), _nameController.text.trim()].where((s) => s.isNotEmpty).join(' ');
    final picked = await ProductSearchDialog.show(context, initialQuery: initial);
    if (picked == null || !mounted) return;
    _barcodeController.text = picked.barcode;
    await _performLookup(picked.barcode);
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
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.statusGreen),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Checking the product databases (Open Beauty Facts first)...',
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
                      const Text(
                        'Barcode / UPC',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                      ),
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
            if (_lastLookup != null) _buildLookupStatus(_lastLookup!),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('search-by-name'),
                onPressed: _isLookingUp ? null : _searchByName,
                icon: const Icon(Icons.manage_search_rounded, size: 18),
                label: const Text('No barcode? Search Open Beauty Facts by name'),
              ),
            ),
            const SizedBox(height: 8),

            // Product Intelligence Card (When metadata is detected)
            if (_sourceDatabase != null ||
                _countryOfOrigin != null ||
                _keyActives != null ||
                _skinClaims.isNotEmpty) ...[
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
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                            child: Text(
                              _sourceDatabase!,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textMuted,
                              ),
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
                        ..._skinClaims.map(
                          (claim) => Chip(
                            avatar: const Icon(Icons.check_circle_outline, size: 14, color: AppTheme.statusGreen),
                            label: Text(claim, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            backgroundColor: AppTheme.statusGreenBg,
                          ),
                        ),
                      ],
                    ),

                    if (_certifications.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: _certifications
                            .map(
                              (cert) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3FEF5),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: const Color(0xFF4CAF50).withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  cert,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF2E7D32),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
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
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textDark,
                                fontWeight: FontWeight.w600,
                              ),
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
            const Text(
              'Brand',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _brandController,
              decoration: const InputDecoration(
                hintText: 'e.g. CeraVe, The Ordinary, Glossier',
                prefixIcon: Icon(Icons.branding_watermark_outlined, color: AppTheme.textMuted),
              ),
              validator: (val) => val == null || val.trim().isEmpty ? 'Brand is required' : null,
              onChanged: (_) => setState(_suggestCategoryFromName),
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
              decoration: const InputDecoration(
                hintText: 'e.g. Hyaluronic Acid 2% + B5',
                prefixIcon: Icon(Icons.spa_outlined, color: AppTheme.textMuted),
              ),
              validator: (val) => val == null || val.trim().isEmpty ? 'Product name is required' : null,
              onChanged: (_) => setState(_suggestCategoryFromName),
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
                      const Text(
                        'Category',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        // Keyed by value so a suggestion or lookup is shown, not just saved.
                        key: ValueKey('add-category-$_selectedCategoryId'),
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
                          if (!categories.any((c) => c.categoryId == _selectedCategoryId))
                            DropdownMenuItem(value: _selectedCategoryId, child: Text(_selectedCategoryId)),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _selectedCategoryId = val;
                              _categorySource = CategorySource.user;
                              final cat = categories.where((c) => c.categoryId == val).firstOrNull;
                              // Only an estimate or an unknown PAO follows the category.
                              if (cat != null &&
                                  (_paoSource == PaoSource.categoryDefault || _paoSource == PaoSource.unknown)) {
                                _paoMonths = cat.defaultPaoMonths;
                                _paoSource = PaoSource.categoryDefault;
                              }
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _categorySource == CategorySource.unknown
                            ? 'Uncategorized: choose a category'
                            : _categorySource.label,
                        key: const ValueKey('add-category-source'),
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'PAO Months',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                          ),
                          InkWell(
                            onTap: () =>
                                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaoGuideScreen())),
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                              child: Text(
                                'Guide 📖',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.primaryRose,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<int>(
                        // Keyed by value so a lookup or category change is shown, not just saved.
                        key: ValueKey('add-pao-$_paoMonths'),
                        initialValue: _paoMonths,
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
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
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _paoSource.isVerified
                            ? 'Set by you'
                            : (_paoSource == PaoSource.productDatabase
                                  ? 'From the product database: check your pack'
                                  : (_paoSource == PaoSource.unknown
                                        ? 'Unknown: set it from the open-jar symbol on the pack'
                                        : 'Estimate: check the open-jar symbol on the pack')),
                        key: const ValueKey('add-pao-source'),
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
            const SizedBox(height: 16),

            // Volume & Price Row
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
                      const Text(
                        'Price (Optional)',
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
                              context.watch<VanityProvider>().currencySymbol,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textMuted,
                                fontSize: 16,
                              ),
                            ),
                          ),
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
                          label: Text(
                            DateFormat('MMM d, yyyy').format(_openedDate),
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryRose),
                          ),
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
                        const Text(
                          'Calculated Expiry Date:',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.statusGreenBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            DateFormat('MMM d, yyyy').format(_computedExpiryDate),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.statusGreen,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 24),
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
                            'Manufacturing Date',
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
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sealed / Batch Expiry',
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

            // Notes / Usage routine
            const Text(
              'Notes (Optional)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _notesController,
              maxLines: 2,
              decoration: const InputDecoration(hintText: 'e.g. Morning routine only, patch tested ok'),
            ),
            // Inline duplicate hint (the save-time warning still asks for a decision)
            Builder(
              builder: (ctx) {
                final matches = _currentMatches(ctx.watch<VanityProvider>(), ctx.watch<HouseholdProvider>());
                if (matches.isEmpty) return const SizedBox.shrink();
                final m = matches.first;
                return Container(
                  key: const ValueKey('add-duplicate-banner'),
                  margin: const EdgeInsets.only(top: 12, bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.statusAmberBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.copy_rounded, color: AppTheme.statusAmber, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${m.strengthLabel}: ${[m.item.product?.brand, m.item.product?.name].where((s) => s != null && s.isNotEmpty).join(' ')}'
                          ' - ${m.whoseLabel}${matches.length > 1 ? ' (+${matches.length - 1} more)' : ''}. '
                          'You will be asked before anything is added.',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: () => DuplicateAlertDialog.viewExisting(ctx, m),
                        child: const Text('View', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                );
              },
            ),
            // Household sharing switch (when in a household)
            Builder(
              builder: (ctx) {
                final householdProv = ctx.watch<HouseholdProvider>();
                if (!householdProv.hasHousehold) return const SizedBox.shrink();
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
                    // Own Material so the tile's ink is not hidden by the decorated box.
                    child: Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile(
                        value: _isSharedWithHousehold,
                        activeThumbColor: const Color(0xFF7E22CE),
                        key: const ValueKey('add-share-switch'),
                        title: const Text(
                          'Share with Household 👥',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        subtitle: Text(
                          _isSharedWithHousehold
                              ? 'Visible to members of "$hhName" to prevent duplicates'
                              : 'Private by default (only you can see this item)',
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

            // Save Button
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
                  : const Text('Add to Vanity Shelf', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ],
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
