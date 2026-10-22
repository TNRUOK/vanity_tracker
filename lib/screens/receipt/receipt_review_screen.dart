import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../models/receipt_model.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/receipt_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../services/category_classifier.dart';
import '../../services/receipt_inventory_service.dart';
import '../../services/receipt_parser_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/currency.dart';
import '../../widgets/duplicate_alert_dialog.dart';
import '../../widgets/receipt_duplicate_dialog.dart';

export '../../services/receipt_inventory_service.dart' show LineItemAction, LineOutcome;
export '../../utils/currency.dart' show parseAmountInput;



class LineItemDraft {
  /// Stable for the draft (parser item id), so inventory ids derived from it are idempotent.
  final String id;
  final TextEditingController nameController;
  final TextEditingController quantityController;
  final TextEditingController priceController;
  final TextEditingController brandController = TextEditingController();
  LineItemAction action;
  String? matchedVanityItemId;
  bool updateShelfPrice;

  /// Category for a new shelf item; null = uncategorized (the user is asked to choose).
  String? categoryId;

  /// The automatic suggestion for the current name (null = nothing recognised).
  CategorySuggestion? suggestion;

  /// The user picked the category themselves; later name edits no longer change it.
  bool categoryChosenByUser = false;

  /// The parser was unsure about this line (e.g. no price found, joined from two lines).
  bool needsReview;

  /// Destination for a new item: shared with the household (owned by the user) or private.
  bool shareWithHousehold = false;

  /// The user saw this line's duplicate warning and chose to add a separate item anyway.
  bool duplicateAcknowledged = false;

  /// Result of the last save attempt for this line (null = not attempted yet).
  LineOutcome? lastOutcome;
  String? lastError;

  LineItemDraft({
    required this.id,
    required String name,
    required int quantity,
    required double? price,
    this.action = LineItemAction.ignore,
    this.matchedVanityItemId,
    this.updateShelfPrice = false,
    this.needsReview = false,
  }) : nameController = TextEditingController(text: name),
       quantityController = TextEditingController(text: quantity.toString()),
       priceController = TextEditingController(text: price != null && price > 0 ? price.toStringAsFixed(2) : '') {
    refreshSuggestion();
  }

  /// Re-suggests the category from the current name (and brand) unless the user chose one.
  void refreshSuggestion() {
    if (categoryChosenByUser) return;
    suggestion = CategoryClassifier.fromName('${brandController.text} ${nameController.text}');
    categoryId = suggestion?.categoryId;
  }

  void chooseCategory(String? id) {
    categoryId = id;
    categoryChosenByUser = true;
  }

  CategorySource get categorySource =>
      categoryChosenByUser ? CategorySource.user : (suggestion?.source ?? CategorySource.unknown);

  void dispose() {
    nameController.dispose();
    quantityController.dispose();
    priceController.dispose();
    brandController.dispose();
  }

  int get quantity => int.tryParse(quantityController.text.trim()) ?? 1;
  double get unitPrice => parseAmountInput(priceController.text) ?? 0.0;
  double get lineTotal => quantity * unitPrice;

  /// Already in the inventory from an earlier attempt (must not be written again).
  bool get isAddedToInventory => lastOutcome == LineOutcome.added || lastOutcome == LineOutcome.addedNotSynced;

  String? get nameError => nameController.text.trim().isEmpty ? 'Enter a product name' : null;

  String? get quantityError {
    final q = int.tryParse(quantityController.text.trim());
    return q == null || q < 1 ? 'Whole number ≥ 1' : null;
  }

  String? get priceError {
    final text = priceController.text.trim();
    if (text.isEmpty) return 'Enter the price (0 if free), or remove the line if it is not a product';
    final p = parseAmountInput(text);
    if (p == null) return 'Not a valid amount';
    if (p < 0) return 'Cannot be negative';
    return null;
  }

  String? get matchError =>
      action == LineItemAction.matchExisting && matchedVanityItemId == null ? 'Choose the shelf item' : null;

  bool get isValid => nameError == null && quantityError == null && priceError == null && matchError == null;
}

class ReceiptReviewScreen extends StatefulWidget {
  final ParsedReceiptDraft initialDraft;

  const ReceiptReviewScreen({super.key, required this.initialDraft});

  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {

  late TextEditingController _merchantController;
  late TextEditingController _subtotalController;
  late TextEditingController _taxController;
  late TextEditingController _discountController;
  late TextEditingController _totalController;

  late DateTime _selectedDate;
  bool _isDateAmbiguous = false;
  DateTime? _alternateDate;
  /// ISO 4217 code of the receipt's amounts.
  late String _selectedCurrency;

  /// Shown when the receipt's symbol could stand for several currencies.
  String? _currencyNote;

  String get _sym => Currencies.symbolFor(_selectedCurrency);
  late List<LineItemDraft> _lineItems;
  bool _isSaving = false;

  /// Set synchronously on the first tap so a double tap cannot start a second save.
  bool _submitInFlight = false;

  /// Show per-field errors only after the user tried to save.
  bool _showValidation = false;

  /// Result of the last save attempt when it was incomplete (stays on screen for retry).
  ReceiptSaveReport? _lastReport;
  int _addedLineCounter = 0;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDraft;
    _merchantController = TextEditingController(text: d.merchant);
    _selectedDate = d.purchaseDate;
    _isDateAmbiguous = d.isDateAmbiguous;
    _alternateDate = d.alternateDate;
    _selectedCurrency = _initialCurrencyCode(d);

    _subtotalController = TextEditingController(text: d.subtotal > 0 ? d.subtotal.toStringAsFixed(2) : '');
    _taxController = TextEditingController(text: d.tax > 0 ? d.tax.toStringAsFixed(2) : '');
    _discountController = TextEditingController(text: d.discount > 0 ? d.discount.toStringAsFixed(2) : '');
    _totalController = TextEditingController(text: d.total > 0 ? d.total.toStringAsFixed(2) : '');

    // One draft per parsed line, keyed by the parser's per-draft item id (stable, unique).
    _lineItems = d.items.asMap().entries.map((entry) {
      final item = entry.value;
      return LineItemDraft(
        id: item.itemId.isNotEmpty ? item.itemId : 'line_${entry.key}',
        name: item.description,
        quantity: item.quantity,
        price: item.isConfirmed || item.unitPrice > 0 ? item.unitPrice : null,
        action: LineItemAction.ignore,
        needsReview: !item.isConfirmed,
      );
    }).toList();

    // Matches are no longer auto-applied (the old substring rule linked lines to shelf items
    // by brand alone). Each line shows its matches from the shared matcher and the user
    // decides: link the purchase, add a separate item (personal/shared), or receipt only.
  }

  /// The receipt's currency code. A symbol that names one currency (₹ € £) is used as is;
  /// "$"/"¥" alone could be several currencies, so the budget currency is preselected when
  /// it uses that symbol (else USD/JPY) and the user is asked to check it.
  String _initialCurrencyCode(ParsedReceiptDraft d) {
    final exact = Currencies.codeFromStored(d.currency);
    if (exact != null) return exact;
    final budget = context.read<VanityProvider>().budgetCurrency;
    final code = budget.symbol.endsWith(d.currency) ? budget.code : (Currencies.suggestedCodeForLegacySymbol(d.currency) ?? budget.code);
    if (d.currencyDetected) {
      _currencyNote = 'The receipt shows "${d.currency}", which can mean more than one currency. '
          'Preselected $code: check the Currency field.';
    }
    return code;
  }

  /// Matches for one line, using the same matcher as manual adds and barcode scans:
  /// the user's own items plus items household members explicitly shared.
  List<DuplicateMatch> _matchesFor(LineItemDraft line) {
    final name = line.nameController.text.trim();
    if (name.isEmpty || line.isAddedToInventory) return const [];
    final household = context.read<HouseholdProvider?>();
    return context.read<VanityProvider>().checkHouseholdDuplicates(
          name: name,
          brand: line.brandController.text.trim(),
          // Items created earlier from this same receipt are not duplicates of it.
          excludeItemIds: {
            for (final l in _lineItems) ReceiptInventoryService.inventoryIdFor(widget.initialDraft.receiptId, l.id),
          },
          sharedHouseholdItems: household?.sharedItems ?? const [],
          memberEmails: household?.memberEmails ?? const {},
        );
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _subtotalController.dispose();
    _taxController.dispose();
    _discountController.dispose();
    _totalController.dispose();
    for (var item in _lineItems) {
      item.dispose();
    }
    super.dispose();
  }

  double get _currentSubtotal => parseAmountInput(_subtotalController.text) ?? 0.0;
  double get _currentTax => parseAmountInput(_taxController.text) ?? 0.0;
  double get _currentDiscount => parseAmountInput(_discountController.text) ?? 0.0;
  double get _currentTotal => parseAmountInput(_totalController.text) ?? 0.0;

  /// Warnings not already covered by the dedicated date/total banners.
  List<String> get _parserWarnings => widget.initialDraft.warnings
      .where((w) => !w.startsWith('The date could be read') && !w.startsWith('Totals do not add up'))
      .toList();

  double get _computedExpectedTotal => (_currentSubtotal + _currentTax - _currentDiscount);

  bool get _hasTotalMismatch {
    if (_currentTotal <= 0 || _currentSubtotal <= 0) return false;
    return (_computedExpectedTotal - _currentTotal).abs() > 0.05;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate.isAfter(now) ? now : _selectedDate,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _isDateAmbiguous = false;
      });
    }
  }

  void _addLineItem() {
    setState(() {
      _lineItems.add(
        LineItemDraft(
          id: 'line_added_${_addedLineCounter++}_${DateTime.now().millisecondsSinceEpoch}',
          name: '',
          quantity: 1,
          price: null,
          action: LineItemAction.createNew,
        ),
      );
    });
  }

  void _removeLineItem(int index) {
    if (_lineItems[index].isAddedToInventory) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This item is already in your Vanity Inventory, so it stays on the receipt.')),
      );
      return;
    }
    setState(() {
      _lineItems[index].dispose();
      _lineItems.removeAt(index);
    });
  }

  Future<void> _confirmAndSave() async {
    // Synchronous guard: a second tap while the first is still running does nothing.
    if (_submitInFlight) return;
    _submitInFlight = true;
    try {
      await _confirmAndSaveOnce();
    } finally {
      _submitInFlight = false;
      if (mounted && _isSaving) setState(() => _isSaving = false);
    }
  }

  void _showSnack(String message, Color color) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color, duration: const Duration(seconds: 5)));
  }

  Future<void> _confirmAndSaveOnce() async {
    final merchant = _merchantController.text.trim();
    if (merchant.isEmpty) {
      _showSnack('Please enter a merchant name', AppTheme.statusRed);
      return;
    }

    final total = _currentTotal;
    if (total <= 0) {
      _showSnack('Please enter a valid receipt total', AppTheme.statusRed);
      return;
    }

    final invalid = _lineItems.where((l) => !l.isValid).length;
    if (invalid > 0) {
      setState(() => _showValidation = true);
      _showSnack(
        '$invalid item${invalid == 1 ? ' needs' : 's need'} attention (highlighted below). Fix or remove ${invalid == 1 ? 'it' : 'them'} before saving.',
        AppTheme.statusRed,
      );
      return;
    }

    final receiptProv = context.read<ReceiptProvider>();
    final vanityProv = context.read<VanityProvider>();
    final auth = context.read<AuthProvider>();

    if (auth.currentUser == null) {
      _showSnack('You must be logged in to save receipts', AppTheme.statusRed);
      return;
    }

    // Duplicate detection safeguard (a retry of THIS receipt is not a duplicate)
    final potentialDup = receiptProv.findPotentialDuplicate(
      merchant: merchant,
      purchaseDate: _selectedDate,
      total: total,
      excludeReceiptId: widget.initialDraft.receiptId,
    );

    if (potentialDup != null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Possible Duplicate Receipt'),
          content: Text(
            'A receipt from "$merchant" on ${DateFormat('yyyy-MM-dd').format(potentialDup.purchaseDate)} '
            'with total $_sym${potentialDup.total.toStringAsFixed(2)} was already saved.\n\n'
            'Do you still want to save this receipt?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Save Anyway')),
          ],
        ),
      );

      if (proceed != true || !mounted) return;
    }

    // Duplicate-product check for lines that would become new shelf items.
    final household = context.read<HouseholdProvider?>(); // absent in some embeddings/tests
    // Lines already confirmed inline ("I bought another unit") are not asked again; any
    // unresolved possible duplicate is asked about before anything is written.
    final dupes = ReceiptDuplicateCheck.find(
      receiptId: widget.initialDraft.receiptId,
      lines: [
        for (final l in _lineItems)
          if (l.action == LineItemAction.createNew && !l.isAddedToInventory && !l.duplicateAcknowledged)
            (lineId: l.id, description: l.nameController.text.trim(), brand: l.brandController.text.trim()),
      ],
      allLineIds: _lineItems.map((l) => l.id),
      vanity: vanityProv,
      sharedHouseholdItems: household?.sharedItems ?? const [],
      memberEmails: household?.memberEmails ?? const {},
    );
    if (dupes.isNotEmpty) {
      final choice = await ReceiptDuplicateCheck.show(context, dupes);
      if (choice == ReceiptDuplicateChoice.cancel || !mounted) return;
      final ids = dupes.map((d) => d.lineId).toSet();
      setState(() {
        for (final l in _lineItems.where((l) => ids.contains(l.id))) {
          if (choice == ReceiptDuplicateChoice.keepOnReceipt) {
            l.action = LineItemAction.ignore;
          } else {
            l.duplicateAcknowledged = true;
          }
        }
      });
    }

    setState(() => _isSaving = true);

    final requests = [
      for (final line in _lineItems)
        ReceiptLineRequest(
          lineId: line.id,
          description: line.nameController.text.trim(),
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          action: line.action,
          matchedVanityItemId: line.matchedVanityItemId,
          updateShelfPrice: line.updateShelfPrice,
          brand: line.brandController.text,
          categoryId: line.categoryId,
          categorySource: line.categorySource,
          shareWithHousehold: line.shareWithHousehold,
        ),
    ];

    final report = await ReceiptInventoryService.saveReceiptAndInventory(
      receiptHeader: ReceiptModel(
        receiptId: widget.initialDraft.receiptId,
        userId: auth.currentUser!.userId,
        merchant: merchant,
        purchaseDate: _selectedDate,
        currency: _sym,
        currencyCode: _selectedCurrency,
        subtotal: _currentSubtotal,
        taxAmount: _currentTax,
        discountAmount: _currentDiscount,
        totalAmount: total,
        rawOcrText: widget.initialDraft.rawText,
        createdAt: DateTime.now(),
      ),
      lines: requests,
      userId: auth.currentUser!.userId,
      vanity: vanityProv,
      receipts: receiptProv,
      alreadyAddedLineIds: {
        for (final l in _lineItems)
          if (l.isAddedToInventory) l.id,
      },
      householdId: household?.currentHousehold?.householdId,
    );

    if (!mounted) return;

    // Record each line's actual outcome on its own card.
    final byLine = {for (final r in report.lines) r.lineId: r};
    setState(() {
      for (final line in _lineItems) {
        final r = byLine[line.id];
        if (r == null) continue;
        line.lastOutcome = r.outcome;
        line.lastError = r.error;
      }
      _isSaving = false;
    });

    final allGood = report.isComplete && report.notSyncedCount == 0 && report.receiptSyncWarning == null;
    if (report.isComplete) {
      _showSnack(report.message, allGood ? AppTheme.statusGreen : AppTheme.statusAmber);
      // Tell the caller (scanner screen) the receipt was saved so it can close too.
      Navigator.of(context).pop(true);
    } else {
      // Stay here so failed parts can be retried; succeeded items are not written again.
      setState(() => _lastReport = report);
      _showSnack(report.message, AppTheme.statusRed);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Unfiltered: the dashboard's search/category filter must not hide shelf items here.
    final activeVanityItems = context.watch<VanityProvider>().allActiveItems;
    final retryMode = _lastReport != null;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Review Receipt'),
        actions: [
          if (_isSaving)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryRose),
                ),
              ),
            )
          else
            TextButton.icon(
              onPressed: _confirmAndSave,
              icon: Icon(retryMode ? Icons.refresh_rounded : Icons.check_rounded, color: AppTheme.primaryRose),
              label: Text(
                retryMode ? 'Retry' : 'Confirm',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primaryRose),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Result of the last (incomplete) save attempt
            if (_lastReport != null) ...[
              Container(
                key: const Key('receipt-save-report'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _lastReport!.message,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textDark, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        onPressed: _isSaving ? null : _confirmAndSave,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Retry failed items'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Date Ambiguity Banner
            if (_isDateAmbiguous) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.statusAmberBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: AppTheme.statusAmber, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Ambiguous Date Detected',
                          style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textDark, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'The date could be parsed as ${DateFormat('yyyy-MM-dd').format(_selectedDate)} or '
                      '${_alternateDate != null ? DateFormat('yyyy-MM-dd').format(_alternateDate!) : 'alternate format'}. '
                      'Please verify the day and month.',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textDark),
                    ),
                    if (_alternateDate != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            final temp = _selectedDate;
                            _selectedDate = _alternateDate!;
                            _alternateDate = temp;
                          });
                        },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text('Switch to ${DateFormat('yyyy-MM-dd').format(_alternateDate!)}'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Parser warnings (currency/date assumptions, inconsistent line items, ...)
            if (_parserWarnings.isNotEmpty) ...[
              Container(
                key: const Key('receipt-parser-warnings'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.statusAmberBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Please check before saving',
                      style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textDark, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    for (final w in _parserWarnings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $w', style: const TextStyle(fontSize: 12, color: AppTheme.textDark)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Total Mismatch Warning Banner
            if (_hasTotalMismatch) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.statusAmberBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AppTheme.statusAmber, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Note: Subtotal ($_sym${_currentSubtotal.toStringAsFixed(2)}) + '
                        'Tax ($_sym${_currentTax.toStringAsFixed(2)}) - '
                        'Discount ($_sym${_currentDiscount.toStringAsFixed(2)}) = '
                        '$_sym${_computedExpectedTotal.toStringAsFixed(2)}, '
                        'which differs from Total ($_sym${_currentTotal.toStringAsFixed(2)}). '
                        'You can adjust amounts or keep recorded total.',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textDark),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Merchant, Date & Currency Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Receipt Details',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _merchantController,
                    decoration: const InputDecoration(
                      labelText: 'Merchant / Store Name',
                      prefixIcon: Icon(Icons.store_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: _pickDate,
                          borderRadius: BorderRadius.circular(12),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Purchase Date',
                              prefixIcon: Icon(Icons.calendar_today_rounded),
                            ),
                            child: Text(
                              DateFormat('yyyy-MM-dd').format(_selectedDate),
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: DropdownButtonFormField<String>(
                          key: const Key('receipt-currency'),
                          initialValue: _selectedCurrency,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Currency'),
                          // Compact selected value; full names in the open menu.
                          selectedItemBuilder: (context) => Currencies.supported
                              .map((c) => Text('${c.symbol} ${c.code}', overflow: TextOverflow.ellipsis))
                              .toList(),
                          items: Currencies.supported
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c.code,
                                  child: Text(c.label, overflow: TextOverflow.ellipsis),
                                ),
                              )
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _selectedCurrency = val;
                                _currencyNote = null;
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  if (_currencyNote != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _currencyNote!,
                      key: const Key('receipt-currency-note'),
                      style: const TextStyle(fontSize: 12, color: AppTheme.statusAmber, fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Financial Summary Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Financial Summary',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _subtotalController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: 'Subtotal', prefixText: '$_sym '),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _taxController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: 'Tax', prefixText: '$_sym '),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _discountController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: 'Discount', prefixText: '-$_sym '),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _totalController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primaryRose),
                          decoration: InputDecoration(labelText: 'Total Paid', prefixText: '$_sym '),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Line items header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Purchased Items (${_lineItems.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                ),
                TextButton.icon(
                  onPressed: _addLineItem,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Item'),
                ),
              ],
            ),
            const Text(
              'Every line is saved with the receipt. Only lines set to "+ Add as new item to shelf" '
              '(or matched to a shelf item) go to your Vanity Inventory; "Keep on receipt only" does not. '
              'You can also add products later from Receipt History.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.35),
            ),
            if (_lineItems.any((l) => l.action == LineItemAction.ignore && !l.isAddedToInventory))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('add-all-to-inventory'),
                  onPressed: () => setState(() {
                    for (final l in _lineItems) {
                      if (l.action == LineItemAction.ignore && !l.isAddedToInventory) {
                        l.action = LineItemAction.createNew;
                      }
                    }
                  }),
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
                  label: const Text('Add all to Vanity Inventory'),
                ),
              ),
            const SizedBox(height: 8),

            // Line items list
            if (_lineItems.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFF1ECE8)),
                ),
                child: const Center(
                  child: Text(
                    'No product lines were recognized on this receipt. Tap "Add Item" to enter purchased '
                    'products, or save the receipt total on its own.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _lineItems.length,
                separatorBuilder: (context, index) => const SizedBox(height: 12),
                itemBuilder: (ctx, index) {
                  final line = _lineItems[index];
                  return _buildLineItemCard(line, index, activeVanityItems);
                },
              ),

            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isSaving ? null : _confirmAndSave,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _isSaving
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(
                      retryMode ? 'Retry failed items' : 'Confirm & Save Receipt',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildLineItemCard(LineItemDraft line, int index, List<VanityItemModel> activeVanityItems) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: line.action == LineItemAction.ignore
              ? const Color(0xFFF1ECE8)
              : AppTheme.primaryRose.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.needsReview || line.lastOutcome != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (line.needsReview && !line.isAddedToInventory)
                    _chip('Check this line: OCR was unsure', AppTheme.statusAmber, AppTheme.statusAmberBg),
                  if (line.lastOutcome != null) _outcomeChip(line),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('line-name-${line.id}'),
                  controller: line.nameController,
                  decoration: InputDecoration(
                    labelText: 'Product / Description',
                    isDense: true,
                    errorText: _showValidation ? line.nameError : null,
                  ),
                  onChanged: (_) => setState(line.refreshSuggestion),
                ),
              ),
              IconButton(
                key: Key('line-remove-${line.id}'),
                icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.textMuted, size: 20),
                onPressed: () => _removeLineItem(index),
                // Removes a misread line (e.g. a cardholder name or a size fragment). The
                // receipt's subtotal/tax/total fields are separate and are not changed.
                tooltip: 'Remove incorrect OCR line (not a product)',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: TextField(
                  key: Key('line-qty-${line.id}'),
                  controller: line.quantityController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Qty',
                    isDense: true,
                    errorText: _showValidation ? line.quantityError : null,
                    errorMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: Key('line-price-${line.id}'),
                  controller: line.priceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Unit Price',
                    prefixText: '$_sym ',
                    isDense: true,
                    errorText: _showValidation ? line.priceError : null,
                    errorMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Line Total', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                  Text(
                    '$_sym${line.lineTotal.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppTheme.textDark),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),

          // Inventory action picker
          Row(
            children: [
              const Text(
                'Shelf Action: ',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textMuted),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: DropdownButton<LineItemAction>(
                  key: Key('line-action-${line.id}'),
                  value: line.action,
                  isDense: true,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(
                      value: LineItemAction.ignore,
                      child: Text('Keep on receipt only', style: TextStyle(fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: LineItemAction.matchExisting,
                      child: Text(
                        'Match existing shelf item',
                        style: TextStyle(fontSize: 12, color: Color(0xFF7E22CE)),
                      ),
                    ),
                    DropdownMenuItem(
                      value: LineItemAction.createNew,
                      child: Text(
                        '+ Add as new item to shelf',
                        style: TextStyle(fontSize: 12, color: AppTheme.primaryRose),
                      ),
                    ),
                  ],
                  // Locked once the item is in the inventory, so a retry can't orphan it.
                  onChanged: line.isAddedToInventory
                      ? null
                      : (val) {
                          if (val != null) setState(() => line.action = val);
                        },
                ),
              ),
            ],
          ),

          _buildLineMatches(line),

          // Match to existing item
          if (line.action == LineItemAction.matchExisting) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue:
                  line.matchedVanityItemId != null &&
                      activeVanityItems.any((it) => it.vanityItemId == line.matchedVanityItemId)
                  ? line.matchedVanityItemId
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Select existing vanity product',
                isDense: true,
                errorText: _showValidation ? line.matchError : null,
              ),
              items: activeVanityItems.map((item) {
                final brand = item.product?.brand ?? '';
                final name = item.product?.name ?? 'Unknown';
                final priceStr = item.price != null ? ' ($_sym${item.price!.toStringAsFixed(2)})' : '';
                return DropdownMenuItem(
                  value: item.vanityItemId,
                  child: Text(
                    '$brand $name$priceStr',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                );
              }).toList(),
              onChanged: (val) {
                setState(() => line.matchedVanityItemId = val);
              },
            ),
            // Price protection safeguard checkbox
            const SizedBox(height: 6),
            // Own Material so the tile's ink isn't hidden by the card's decoration.
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'Update shelf product price to $_sym${line.unitPrice.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                ),
                subtitle: const Text(
                  'Safeguard: unchecked preserves current shelf price; receipt records this historical purchase.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                value: line.updateShelfPrice,
                onChanged: (val) {
                  setState(() => line.updateShelfPrice = val ?? false);
                },
              ),
            ),
          ],

          // Create new product
          if (line.action == LineItemAction.createNew) ...[
            const SizedBox(height: 8),
            TextField(
              key: Key('line-brand-${line.id}'),
              controller: line.brandController,
              enabled: !line.isAddedToInventory,
              decoration: const InputDecoration(
                labelText: 'Brand (optional)',
                hintText: 'Leave empty if not on the receipt',
                isDense: true,
              ),
              onChanged: (_) => setState(line.refreshSuggestion), // re-check duplicates and category
            ),
            if (context.read<HouseholdProvider?>()?.hasHousehold == true) ...[
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                key: Key('line-dest-${line.id}'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.lock_outline_rounded, size: 16), label: Text('Personal')),
                  ButtonSegment(value: true, icon: Icon(Icons.people_alt_outlined, size: 16), label: Text('Shared household')),
                ],
                selected: {line.shareWithHousehold},
                onSelectionChanged: line.isAddedToInventory
                    ? null
                    : (s) => setState(() => line.shareWithHousehold = s.first),
              ),
            ],
            const SizedBox(height: 4),
            const Text(
              'Added as unopened. Mark it as opened from your shelf to start PAO expiry tracking.',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ],

          // Category: shown before anything is added, for every line that may become a
          // shelf item (a linked line keeps the shelf item's own category).
          if (line.action != LineItemAction.matchExisting) _buildCategoryField(line),
        ],
      ),
    );
  }

  Widget _buildCategoryField(LineItemDraft line) {
    final categories = context.read<VanityProvider>().categories;
    final value = categories.any((c) => c.categoryId == line.categoryId) ? line.categoryId : null;
    final s = line.suggestion;
    final String hint;
    final Color hintColor;
    if (line.categoryChosenByUser) {
      hint = line.categoryId == null ? 'Left uncategorized by you' : 'Chosen by you';
      hintColor = AppTheme.textMuted;
    } else if (s == null) {
      hint = 'Not recognised from the name: choose a category (or leave it uncategorized)';
      hintColor = AppTheme.statusAmber;
    } else {
      hint = '${s.explanation}. Change it if it is wrong.';
      hintColor = s.weak ? AppTheme.statusAmber : AppTheme.textMuted;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String?>(
            key: Key('line-category-${line.id}-${line.categoryId}'),
            initialValue: value,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Category', isDense: true),
            hint: const Text('Uncategorized: choose', style: TextStyle(fontSize: 13)),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Uncategorized', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
              ),
              for (final c in categories)
                DropdownMenuItem<String?>(
                  value: c.categoryId,
                  child: Text(c.name, style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: line.isAddedToInventory ? null : (val) => setState(() => line.chooseCategory(val)),
          ),
          const SizedBox(height: 3),
          Text(hint, key: Key('line-category-hint-${line.id}'), style: TextStyle(fontSize: 11, color: hintColor)),
        ],
      ),
    );
  }

  /// Inline duplicate information for one line (updates as the name/brand change).
  Widget _buildLineMatches(LineItemDraft line) {
    final matches = _matchesFor(line);
    if (matches.isEmpty) return const SizedBox.shrink();
    final ownLinkable = matches.where((m) => m.isPersonal && m.matchType != DuplicateMatchType.sameNameDifferentSize);
    return Container(
      key: Key('line-matches-${line.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppTheme.statusAmberBg, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in matches.take(3))
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${m.strengthLabel}: ${[m.item.product?.brand, m.item.product?.name, m.sizeLabel].where((s) => s != null && s.isNotEmpty).join(' ')}'
                    ' - ${m.whoseLabel}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
                TextButton(
                  key: Key('line-view-${line.id}-${m.item.vanityItemId}'),
                  onPressed: () => DuplicateAlertDialog.viewExisting(context, m),
                  child: const Text('View Existing Item', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          if (ownLinkable.isNotEmpty && line.action != LineItemAction.matchExisting && !line.isAddedToInventory)
            TextButton.icon(
              key: Key('line-link-${line.id}'),
              onPressed: () => setState(() {
                line.action = LineItemAction.matchExisting;
                line.matchedVanityItemId = ownLinkable.first.item.vanityItemId;
              }),
              icon: const Icon(Icons.link_rounded, size: 16),
              label: const Text('This is the purchase of my existing item: link it', style: TextStyle(fontSize: 11.5)),
            ),
          if (line.action == LineItemAction.createNew && !line.isAddedToInventory)
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                key: Key('line-dup-ack-${line.id}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: line.duplicateAcknowledged,
                onChanged: (v) => setState(() => line.duplicateAcknowledged = v ?? false),
                title: const Text('I bought another unit: add it as a separate item', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _outcomeChip(LineItemDraft line) {
    switch (line.lastOutcome!) {
      case LineOutcome.added:
        return _chip('✓ Added to Vanity Inventory', AppTheme.statusGreen, AppTheme.statusGreenBg);
      case LineOutcome.addedNotSynced:
        return _chip('Added on this device (not synced)', AppTheme.statusAmber, AppTheme.statusAmberBg);
      case LineOutcome.linkedExisting:
        return _chip('✓ Linked to shelf item', AppTheme.statusGreen, AppTheme.statusGreenBg);
      case LineOutcome.keptOnReceipt:
        return _chip('Kept on receipt only', AppTheme.textMuted, const Color(0xFFF1F5F9));
      case LineOutcome.failed:
        return _chip('✗ Not added: ${line.lastError ?? 'error'}', AppTheme.statusRed, const Color(0xFFFEE2E2));
    }
  }
}
