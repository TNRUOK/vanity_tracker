import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../../models/receipt_model.dart';
import '../../providers/vanity_provider.dart';
import '../../services/image_capture_service.dart';
import '../../services/ocr/receipt_ocr_service.dart';
import '../../services/product_lookup_service.dart';
import '../../services/receipt_parser_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/barcode_utils.dart';
import 'receipt_history_screen.dart';
import 'receipt_review_screen.dart';

/// An image chosen by the user. On web there is no filesystem [path]; [bytes] are
/// always kept so OCR can run on every platform.
class PickedReceiptImage {
  final Uint8List bytes;
  final String? path;
  final String? name;
  final String mimeType;

  const PickedReceiptImage({required this.bytes, this.path, this.name, this.mimeType = 'image/jpeg'});
}

typedef ReceiptImagePicker = Future<PickedReceiptImage?> Function();
typedef ReceiptTextRecognizer = Future<String> Function({String? imagePath, Uint8List? imageBytes, String? mimeType});

/// Default picker: file_picker on every platform, reading bytes so web works without a path.
Future<PickedReceiptImage?> pickReceiptImageWithFilePicker() async {
  final files = await FilePicker.pickFiles(dialogTitle: 'Select Receipt Image', type: FileType.image);
  if (files.isEmpty) return null; // user cancelled

  final picked = files.first;
  final bytes = await picked.readAsBytes();
  return PickedReceiptImage(
    bytes: bytes,
    path: kIsWeb ? null : picked.path,
    name: picked.name,
    mimeType: ReceiptOcrService.mimeTypeForExtension(picked.extension),
  );
}

/// Represents an item scanned via barcode to be compiled into the receipt draft.
class ScannedReceiptBarcodeItem {
  final String barcode;
  final String name;
  final String brand;
  final String categoryId;
  final double price;
  final int quantity;

  const ScannedReceiptBarcodeItem({
    required this.barcode,
    required this.name,
    this.brand = '',
    this.categoryId = 'other',
    this.price = 0.0,
    this.quantity = 1,
  });

  String get displayName => brand.isNotEmpty ? '$brand - $name' : name;
}

class ReceiptScannerScreen extends StatefulWidget {
  /// Injectable for tests; defaults to [pickReceiptImageWithFilePicker].
  final ReceiptImagePicker? pickImage;

  /// Injectable for tests; defaults to [ReceiptParserService.extractText].
  final ReceiptTextRecognizer? recognizeText;

  const ReceiptScannerScreen({super.key, this.pickImage, this.recognizeText});

  @override
  State<ReceiptScannerScreen> createState() => _ReceiptScannerScreenState();
}

class _ReceiptScannerScreenState extends State<ReceiptScannerScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;

  // OCR Image Scanning State
  bool _isProcessing = false;
  String? _statusMessage;
  String? _errorMessage;
  PickedReceiptImage? _lastImage;
  final TextEditingController _manualTextController = TextEditingController();
  bool _showManualInput = false;

  // Barcode Scanner State
  late final MobileScannerController _scannerController;
  final BarcodeScanGate _scanGate = BarcodeScanGate();
  final List<ScannedReceiptBarcodeItem> _scannedBarcodeItems = [];
  final TextEditingController _manualBarcodeController = TextEditingController();
  final TextEditingController _merchantController = TextEditingController();
  bool _isLookingUpBarcode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.qrCode,
        BarcodeFormat.code128,
      ],
    );

    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        if (_tabController.index == 1) {
          _scanGate.reset();
          _safeStartScanner();
        } else {
          _safeStopScanner();
        }
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_scannerController.value.hasCameraPermission) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _safeStopScanner();
    } else if (state == AppLifecycleState.resumed && _tabController.index == 1) {
      _safeStartScanner();
    }
  }

  Future<void> _safeStartScanner() async {
    try {
      if (!_scannerController.value.isRunning) {
        await _scannerController.start();
      }
    } catch (e) {
      debugPrint('Scanner start error: $e');
    }
  }

  Future<void> _safeStopScanner() async {
    try {
      if (_scannerController.value.isRunning) {
        await _scannerController.stop();
      }
    } catch (e) {
      debugPrint('Scanner stop error: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _scannerController.dispose();
    _manualTextController.dispose();
    _manualBarcodeController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  // --- OCR Image Methods ---

  Future<void> _captureReceiptWithCamera() async {
    PickedReceiptImage? image;
    try {
      image = await ImageCaptureService.captureWithCamera();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not capture photo: ${_clean(e)}';
        _showManualInput = true;
      });
      return;
    }
    if (image == null) return; // user cancelled

    if (image.bytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'The captured image is empty or could not be read.';
        _showManualInput = true;
      });
      return;
    }

    _lastImage = image;
    await _runOcr(image);
  }

  Future<void> _pickReceiptImage() async {
    PickedReceiptImage? image;
    try {
      image = await (widget.pickImage ?? ImageCaptureService.pickFromGallery)();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not open the selected file: ${_clean(e)}';
        _showManualInput = true;
      });
      return;
    }
    if (image == null) return;

    if (image.bytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'The selected image file is empty or could not be read.';
        _showManualInput = true;
      });
      return;
    }

    _lastImage = image;
    await _runOcr(image);
  }

  Future<void> _runOcr(PickedReceiptImage image) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
      _statusMessage = kIsWeb
          ? 'Reading receipt in your browser (first scan loads the OCR engine, ~10 MB)...'
          : 'Reading receipt using on-device OCR...';
    });

    try {
      final recognize = widget.recognizeText ?? ReceiptParserService.extractText;
      final rawText = await recognize(imagePath: image.path, imageBytes: image.bytes, mimeType: image.mimeType);

      if (!mounted) return;

      if (rawText.trim().isEmpty) {
        setState(() {
          _isProcessing = false;
          _statusMessage = null;
          _errorMessage =
              'No text was recognized in this image. Try a sharper, well-lit photo, '
              'or type the receipt details below.';
          _showManualInput = true;
        });
        return;
      }

      _parseAndNavigate(rawText);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _statusMessage = null;
        _errorMessage = 'Could not scan the image: ${_clean(e)}';
        _showManualInput = true;
      });
    }
  }

  static String _clean(Object e) => e.toString().replaceAll('Exception: ', '');

  void _parseAndNavigate(String text) {
    setState(() {
      _isProcessing = false;
      _statusMessage = null;
      _errorMessage = null;
    });

    final defaultCurrency = context.read<VanityProvider>().currencySymbol;
    final draft = ReceiptParserService.parseReceiptText(text, defaultCurrency: defaultCurrency);

    Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ReceiptReviewScreen(initialDraft: draft))).then((
      saved,
    ) {
      if (saved == true && mounted) Navigator.of(context).pop();
    });
  }

  // --- Barcode Scanning Methods ---

  static RetailFormat? _retailFormat(BarcodeFormat f) => switch (f) {
        BarcodeFormat.ean13 => RetailFormat.ean13,
        BarcodeFormat.ean8 => RetailFormat.ean8,
        BarcodeFormat.upcA => RetailFormat.upcA,
        BarcodeFormat.upcE => RetailFormat.upcE,
        _ => null,
      };

  void _onBarcodeDetected(BarcodeCapture capture) async {
    final check = _scanGate.acceptReads(
      capture.barcodes.map((b) => (value: b.rawValue, format: _retailFormat(b.format))),
    );
    if (check == null) return;
    await _addBarcodeItem(check.lookupDigits ?? check.raw);
  }

  Future<void> _addBarcodeItem(String rawBarcode) async {
    final normalized = BarcodeUtils.normalize(rawBarcode) ?? rawBarcode.trim();
    if (normalized.isEmpty) return;

    setState(() => _isLookingUpBarcode = true);
    try {
      final lookup = await ProductLookupService.lookupBarcode(normalized);
      final product = lookup.product;
      final name = product?.name ?? 'Product ($normalized)';
      final brand = product?.brand ?? '';
      final category = product?.categoryId ?? 'other';

      final newItem = ScannedReceiptBarcodeItem(
        barcode: normalized,
        name: name,
        brand: brand,
        categoryId: category,
      );

      if (mounted) {
        setState(() {
          _scannedBarcodeItems.add(newItem);
          _isLookingUpBarcode = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Added to receipt: ${newItem.displayName}'),
            duration: const Duration(seconds: 2),
            backgroundColor: AppTheme.statusGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scannedBarcodeItems.add(ScannedReceiptBarcodeItem(
            barcode: normalized,
            name: 'Item ($normalized)',
          ));
          _isLookingUpBarcode = false;
        });
      }
    } finally {
      Future.delayed(const Duration(milliseconds: 1500), () {
        _scanGate.reset();
      });
    }
  }

  void _handleManualBarcodeSubmit() {
    final text = _manualBarcodeController.text.trim();
    if (text.isEmpty) return;
    _manualBarcodeController.clear();
    _addBarcodeItem(text);
  }

  void _proceedWithScannedBarcodeItems() {
    if (_scannedBarcodeItems.isEmpty) return;
    final defaultCurrency = context.read<VanityProvider>().currencySymbol;
    final merchant = _merchantController.text.trim().isNotEmpty ? _merchantController.text.trim() : 'Store Purchase';
    final items = _scannedBarcodeItems.asMap().entries.map((entry) {
      final idx = entry.key;
      final item = entry.value;
      return ReceiptItemModel(
        itemId: 'item_${DateTime.now().millisecondsSinceEpoch}_$idx',
        description: item.displayName,
        quantity: item.quantity,
        unitPrice: item.price,
        totalPrice: item.price * item.quantity,
      );
    }).toList();

    final total = items.fold<double>(0.0, (sum, i) => sum + i.totalPrice);
    final draft = ParsedReceiptDraft(
      receiptId: 'receipt_${DateTime.now().millisecondsSinceEpoch}',
      merchant: merchant,
      purchaseDate: DateTime.now(),
      currency: defaultCurrency,
      subtotal: total,
      tax: 0.0,
      discount: 0.0,
      total: total,
      items: items,
      rawText: 'Scanned barcodes: ${_scannedBarcodeItems.map((i) => '${i.displayName} (${i.barcode})').join(', ')}',
    );

    Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => ReceiptReviewScreen(initialDraft: draft)))
        .then((saved) {
      if (saved == true && mounted) Navigator.of(context).pop();
    });
  }

  // --- Build UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Scan Receipt'),
        actions: [
          TextButton.icon(
            key: const Key('open-receipt-history'),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReceiptHistoryScreen())),
            icon: const Icon(Icons.history_rounded, size: 18),
            label: const Text('Receipt History'),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryRose,
          labelColor: AppTheme.primaryRose,
          unselectedLabelColor: AppTheme.textMuted,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          tabs: const [
            Tab(
              icon: Icon(Icons.receipt_long_rounded),
              text: 'Receipt Image (OCR)',
            ),
            Tab(
              icon: Icon(Icons.qr_code_scanner_rounded),
              text: 'Barcode Scanner',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildImageScannerTab(),
          _buildBarcodeScannerTab(),
        ],
      ),
    );
  }

  Widget _buildImageScannerTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Informational header card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFF1ECE8)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryRose.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.receipt_long_rounded, size: 40, color: AppTheme.primaryRose),
                ),
                const SizedBox(height: 14),
                const Text(
                  'On-Device Receipt Scanning',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scan or upload a paper receipt or e-receipt screenshot. Your image is processed on this device (or in your browser) without cloud uploads.\n\nYou will be able to review, edit line items, and match purchases to your vanity items before saving.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          if (_isProcessing) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                children: [
                  if (_lastImage != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _lastImage!.bytes,
                        height: 120,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const CircularProgressIndicator(color: AppTheme.primaryRose),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage ?? 'Processing...',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ] else ...[
            if (_errorMessage != null) ...[
              Container(
                key: const Key('receipt-scan-error'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.statusAmberBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: AppTheme.statusAmber, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_errorMessage!, style: const TextStyle(fontSize: 13, color: AppTheme.textDark)),
                        ),
                      ],
                    ),
                    if (_lastImage != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => _runOcr(_lastImage!),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Retry scan'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('receipt-camera-button'),
                    onPressed: _captureReceiptWithCamera,
                    icon: const Icon(Icons.camera_alt_rounded),
                    label: Text(_lastImage == null ? 'Take Photo' : 'Retake Photo'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: AppTheme.primaryRose,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('receipt-gallery-button'),
                    onPressed: _pickReceiptImage,
                    icon: const Icon(Icons.photo_library_rounded),
                    label: Text(_lastImage == null ? 'Select Receipt Image' : 'Select Another Image'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _showManualInput = !_showManualInput;
                });
              },
              icon: Icon(_showManualInput ? Icons.keyboard_hide : Icons.edit_note_rounded),
              label: Text(_showManualInput ? 'Hide Manual Input' : 'Paste Receipt Text Manually'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ],

          if (_showManualInput && !_isProcessing) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Paste Receipt Text',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('receipt-manual-text'),
                    controller: _manualTextController,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      hintText:
                          'SEPHORA\n2026-10-12\nHyaluronic Acid Serum \$24.00\nSubtotal \$24.00\nTax \$1.92\nTotal \$25.92',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      final text = _manualTextController.text.trim();
                      if (text.isEmpty) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('Please enter or paste receipt text')));
                        return;
                      }
                      _parseAndNavigate(text);
                    },
                    child: const Text('Parse Text'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBarcodeScannerTab() {
    return Column(
      children: [
        // Store name field
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.white,
          child: Row(
            children: [
              const Icon(Icons.storefront_rounded, size: 20, color: AppTheme.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _merchantController,
                  decoration: const InputDecoration(
                    hintText: 'Store name (e.g. Sephora, Ulta, Nykaa)',
                    hintStyle: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF1ECE8)),

        // Camera Scanner Area
        Expanded(
          flex: 3,
          child: Stack(
            alignment: Alignment.center,
            children: [
              MobileScanner(
                controller: _scannerController,
                onDetect: _onBarcodeDetected,
                errorBuilder: (context, error) => _buildScannerError(error),
              ),
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: _scannerController,
                builder: (context, state, _) {
                  if (state.error != null) return const SizedBox.shrink();
                  return _buildScannerOverlay(state);
                },
              ),
              if (_isLookingUpBarcode)
                Positioned(
                  top: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                        SizedBox(width: 8),
                        Text('Looking up product barcode...', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Manual Barcode Input Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              top: BorderSide(color: Colors.grey.shade200),
              bottom: BorderSide(color: Colors.grey.shade200),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('receipt-barcode-input'),
                  controller: _manualBarcodeController,
                  decoration: const InputDecoration(
                    hintText: 'Enter barcode (e.g. 3337875597180)',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (val) => _handleManualBarcodeSubmit(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                key: const Key('add-barcode-item-button'),
                onPressed: _handleManualBarcodeSubmit,
                child: const Text('Add Item'),
              ),
            ],
          ),
        ),

        // Scanned Items List & Review Action Bar
        Expanded(
          flex: 2,
          child: Container(
            color: const Color(0xFFFDFBF9),
            child: _scannedBarcodeItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.inventory_2_outlined, size: 36, color: AppTheme.textMuted),
                        SizedBox(height: 8),
                        Text(
                          'Point camera at product barcodes to add to receipt',
                          style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Scanned Items (${_scannedBarcodeItems.length})',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                            ),
                            TextButton(
                              onPressed: () => setState(() => _scannedBarcodeItems.clear()),
                              child: const Text('Clear all', style: TextStyle(color: AppTheme.statusRed, fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          itemCount: _scannedBarcodeItems.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 6),
                          itemBuilder: (context, index) {
                            final item = _scannedBarcodeItems[index];
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFF1ECE8)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.qr_code_2_rounded, size: 20, color: AppTheme.primaryRose),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.displayName,
                                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          'Barcode: ${item.barcode} · ${item.categoryId}',
                                          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppTheme.statusRed),
                                    tooltip: 'Remove',
                                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                    onPressed: () {
                                      setState(() => _scannedBarcodeItems.removeAt(index));
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: ElevatedButton.icon(
                          key: const Key('proceed-to-receipt-review-button'),
                          onPressed: _proceedWithScannedBarcodeItems,
                          icon: const Icon(Icons.check_circle_outline_rounded),
                          label: Text('Review Receipt (${_scannedBarcodeItems.length} items)'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildScannerError(MobileScannerException error) {
    final message = error.errorCode == MobileScannerErrorCode.permissionDenied
        ? 'Camera permission denied'
        : (error.errorDetails?.message ?? 'Camera not available');
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off_rounded, size: 48, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textDark),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'You can enter or paste product barcodes using the manual input bar below.',
            style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
            textAlign: TextAlign.center,
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
        Container(
          width: 240,
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.primaryRose, width: 2.5),
            boxShadow: [
              BoxShadow(color: AppTheme.primaryRose.withValues(alpha: 0.15), blurRadius: 16, spreadRadius: 2),
            ],
          ),
          child: const Center(
            child: Icon(Icons.crop_free, size: 40, color: Colors.white70),
          ),
        ),
        Positioned(
          bottom: 16,
          child: Row(
            children: [
              if (hasTorch)
                CircleAvatar(
                  backgroundColor: Colors.black.withValues(alpha: 0.65),
                  radius: 22,
                  child: IconButton(
                    tooltip: torchOn ? 'Turn flash off' : 'Turn flash on',
                    icon: Icon(torchOn ? Icons.flash_on : Icons.flash_off, color: Colors.white, size: 20),
                    onPressed: () => _scannerController.toggleTorch().catchError(
                      (Object e) => debugPrint('Torch toggle failed: $e'),
                    ),
                  ),
                ),
              if (hasTorch && canSwitch) const SizedBox(width: 16),
              if (canSwitch)
                CircleAvatar(
                  backgroundColor: Colors.black.withValues(alpha: 0.65),
                  radius: 22,
                  child: IconButton(
                    tooltip: 'Switch camera',
                    icon: const Icon(Icons.flip_camera_ios, color: Colors.white, size: 20),
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
}
