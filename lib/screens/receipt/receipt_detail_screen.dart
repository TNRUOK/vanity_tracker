import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/category_model.dart';
import '../../models/receipt_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/receipt_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../services/category_classifier.dart';
import '../../services/receipt_inventory_service.dart';
import '../../services/receipt_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/duplicate_alert_dialog.dart';
import '../../widgets/receipt_duplicate_dialog.dart';

/// One saved receipt: its stored details and product lines, and the place to add
/// selected products to the Vanity Inventory after the receipt was saved.
class ReceiptDetailScreen extends StatefulWidget {
  final String receiptId;
  const ReceiptDetailScreen({super.key, required this.receiptId});

  @override
  State<ReceiptDetailScreen> createState() => _ReceiptDetailScreenState();
}

class _LineEdit {
  final TextEditingController name;
  final TextEditingController brand = TextEditingController();
  String? categoryId; // null = uncategorized
  CategorySuggestion? suggestion;
  bool categoryChosenByUser = false;
  bool selected = false;
  bool shareWithHousehold = false; // destination of the new item (owner stays the user)
  bool duplicateAcknowledged = false; // "I bought another unit" confirmed inline
  _LineEdit(String description) : name = TextEditingController(text: description) {
    refreshSuggestion();
  }

  void refreshSuggestion() {
    if (categoryChosenByUser) return;
    suggestion = CategoryClassifier.fromName('${brand.text} ${name.text}');
    categoryId = suggestion?.categoryId;
  }

  CategorySource get categorySource =>
      categoryChosenByUser ? CategorySource.user : (suggestion?.source ?? CategorySource.unknown);
  void dispose() {
    name.dispose();
    brand.dispose();
  }
}

class _ReceiptDetailScreenState extends State<ReceiptDetailScreen> {
  final Map<String, _LineEdit> _edits = {};
  bool _busy = false;
  bool _addInFlight = false;
  bool _showValidation = false;
  ReceiptSaveReport? _lastReport;

  @override
  void dispose() {
    for (final e in _edits.values) {
      e.dispose();
    }
    super.dispose();
  }

  _LineEdit _editFor(ReceiptItemModel item) => _edits.putIfAbsent(item.itemId, () => _LineEdit(item.description));

  /// The line's inventory item, if it still exists on the shelf.
  bool _isOnShelf(ReceiptItemModel item, VanityProvider vanity) =>
      item.matchedVanityItemId != null && vanity.allItems.any((v) => v.vanityItemId == item.matchedVanityItemId);

  Future<void> _addSelected(ReceiptModel receipt) async {
    // Synchronous double-tap guard; also covers the time the duplicate warning is open.
    if (_busy || _addInFlight) return;
    _addInFlight = true;
    try {
      await _addSelectedOnce(receipt);
    } finally {
      _addInFlight = false;
    }
  }

  Future<void> _addSelectedOnce(ReceiptModel receipt) async {
    final vanity = context.read<VanityProvider>();
    final receipts = context.read<ReceiptProvider>();
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;

    var selected = receipt.items.where((i) => _editFor(i).selected && !_isOnShelf(i, vanity)).toList();
    if (selected.isEmpty) return;
    if (selected.any((i) => _editFor(i).name.text.trim().isEmpty)) {
      setState(() => _showValidation = true);
      return;
    }

    // Duplicate-product check (own items + household items shared with this user).
    final household = context.read<HouseholdProvider?>();
    final dupes = ReceiptDuplicateCheck.find(
      receiptId: receipt.receiptId,
      lines: [
        for (final i in selected)
          if (!_editFor(i).duplicateAcknowledged)
            (lineId: i.itemId, description: _editFor(i).name.text.trim(), brand: _editFor(i).brand.text.trim()),
      ],
      allLineIds: receipt.items.map((i) => i.itemId),
      vanity: vanity,
      sharedHouseholdItems: household?.sharedItems ?? const [],
      memberEmails: household?.memberEmails ?? const {},
    );
    if (dupes.isNotEmpty) {
      final choice = await ReceiptDuplicateCheck.show(context, dupes);
      if (!mounted || choice == ReceiptDuplicateChoice.cancel) return;
      final ids = dupes.map((d) => d.lineId).toSet();
      if (choice == ReceiptDuplicateChoice.keepOnReceipt) {
        selected = selected.where((i) => !ids.contains(i.itemId)).toList();
        setState(() {
          for (final id in ids) {
            _edits[id]?.selected = false;
          }
        });
        if (selected.isEmpty) return;
      } else {
        for (final id in ids) {
          _edits[id]?.duplicateAcknowledged = true;
        }
      }
    }

    setState(() => _busy = true);
    final requests = <ReceiptLineRequest>[
      for (final item in receipt.items)
        if (selected.contains(item))
          ReceiptLineRequest(
            lineId: item.itemId,
            description: _editFor(item).name.text.trim(),
            quantity: item.quantity,
            unitPrice: item.unitPrice,
            storedLineTotal: item.totalPrice,
            action: LineItemAction.createNew,
            brand: _editFor(item).brand.text,
            categoryId: _editFor(item).categoryId,
            categorySource: _editFor(item).categorySource,
            shareWithHousehold: _editFor(item).shareWithHousehold,
          )
        else if (item.matchedVanityItemId != null)
          // Keep existing links exactly as they are (no write).
          ReceiptLineRequest(
            lineId: item.itemId,
            description: item.description,
            quantity: item.quantity,
            unitPrice: item.unitPrice,
            storedLineTotal: item.totalPrice,
            action: LineItemAction.matchExisting,
            matchedVanityItemId: item.matchedVanityItemId,
          )
        else
          ReceiptLineRequest(
            lineId: item.itemId,
            description: item.description,
            quantity: item.quantity,
            unitPrice: item.unitPrice,
            storedLineTotal: item.totalPrice,
          ),
    ];

    final report = await ReceiptInventoryService.saveReceiptAndInventory(
      receiptHeader: receipt,
      lines: requests,
      userId: user.userId,
      vanity: vanity,
      receipts: receipts,
      householdId: household?.currentHousehold?.householdId,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastReport = report;
      for (final r in report.lines) {
        if (r.isAddedToInventory) _edits[r.lineId]?.selected = false;
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(report.message),
          backgroundColor: report.isComplete && report.notSyncedCount == 0 && report.receiptSyncWarning == null
              ? AppTheme.statusGreen
              : (report.isComplete ? AppTheme.statusAmber : AppTheme.statusRed),
          duration: const Duration(seconds: 5),
        ),
      );
  }

  Future<void> _confirmDelete(ReceiptModel receipt) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this receipt?'),
        content: const Text(
          'The receipt and its spending will be removed. Products you already added to your Vanity '
          'Inventory stay on your shelf.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusRed),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await context.read<ReceiptProvider>().deleteReceipt(receipt.receiptId, user.userId);
      messenger.showSnackBar(const SnackBar(content: Text('Receipt deleted.')));
      navigator.pop();
    } on ReceiptSyncException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.statusAmber));
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e'), backgroundColor: AppTheme.statusRed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final receipt = context.watch<ReceiptProvider>().receiptById(widget.receiptId);
    final vanity = context.watch<VanityProvider>();
    final user = context.watch<AuthProvider>().currentUser;

    if (receipt == null || user == null || receipt.userId != user.userId) {
      return Scaffold(
        appBar: AppBar(title: const Text('Receipt')),
        body: const Center(child: Text('This receipt is not available for your account.')),
      );
    }

    final cur = receipt.currency;
    final linesSum = receipt.items.fold(0.0, (s, i) => s + i.totalPrice);
    final expected = receipt.subtotal > 0
        ? receipt.subtotal
        : receipt.totalAmount - receipt.taxAmount + receipt.discountAmount;
    final mismatch = receipt.items.isNotEmpty && (linesSum - expected).abs() > 0.02;
    final selectable = receipt.items.where((i) => !_isOnShelf(i, vanity)).toList();
    final selectedCount = selectable.where((i) => _editFor(i).selected).length;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: Text(receipt.merchant, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Delete receipt',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _busy ? null : () => _confirmDelete(receipt),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(receipt.merchant, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  'Purchased ${DateFormat.yMMMd().format(receipt.purchaseDate)} · Saved ${DateFormat.yMMMd().format(receipt.createdAt)}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
                const Divider(height: 20),
                _row('Subtotal', '$cur${receipt.subtotal.toStringAsFixed(2)}'),
                _row('Tax', '$cur${receipt.taxAmount.toStringAsFixed(2)}'),
                if (receipt.discountAmount > 0) _row('Discount', '-$cur${receipt.discountAmount.toStringAsFixed(2)}'),
                _row('Total paid', '$cur${receipt.totalAmount.toStringAsFixed(2)}', bold: true),
                const SizedBox(height: 6),
                Text(
                  'Currency: $cur (amounts are kept in this currency, never converted).',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          if (mismatch)
            _banner(
              'The saved product lines add up to $cur${linesSum.toStringAsFixed(2)}, which does not match this '
              'receipt\'s amounts ($cur${expected.toStringAsFixed(2)} before tax). Some lines may not be products, '
              'or the total may have been misread. If the total is wrong, delete this receipt and scan it again.',
              key: const Key('receipt-detail-mismatch'),
            ),
          if (_lastReport != null && !_lastReport!.isComplete)
            _banner(_lastReport!.message, color: const Color(0xFFFEE2E2)),
          const SizedBox(height: 8),
          Text(
            'Products on this receipt (${receipt.items.length})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tick the products you want on your shelf. Receipt-only lines stay on the receipt; '
            'spending is counted once, from the receipt total.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 8),
          if (receipt.items.isEmpty)
            _card(
              const Text(
                'No product lines were saved with this receipt, only its total. The original product '
                'names and prices cannot be recovered; scan the paper receipt again to add products.',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
              ),
            )
          else
            for (final item in receipt.items) _lineTile(receipt, item, vanity),
          if (receipt.rawOcrText != null && receipt.rawOcrText!.trim().isNotEmpty)
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(top: 8),
              child: ExpansionTile(
                title: const Text('Scanned text (as read by OCR)', style: TextStyle(fontSize: 13)),
                subtitle: const Text('The receipt image itself is not stored.', style: TextStyle(fontSize: 11)),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      receipt.rawOcrText!,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: selectable.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ElevatedButton.icon(
                  key: const Key('add-selected-to-inventory'),
                  onPressed: _busy || selectedCount == 0 ? null : () => _addSelected(receipt),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add_task_rounded),
                  label: Text(
                    _lastReport != null && !_lastReport!.isComplete
                        ? 'Retry failed items'
                        : 'Add Selected Products to Vanity Inventory ($selectedCount)',
                  ),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            ),
    );
  }

  /// Inline duplicate information for a selected line (same matcher as everywhere else).
  Widget _lineMatches(ReceiptModel receipt, ReceiptItemModel item, _LineEdit edit, VanityProvider vanity) {
    final household = context.read<HouseholdProvider?>();
    final matches = ReceiptDuplicateCheck.find(
      receiptId: receipt.receiptId,
      lines: [(lineId: item.itemId, description: edit.name.text.trim(), brand: edit.brand.text.trim())],
      allLineIds: receipt.items.map((i) => i.itemId),
      vanity: vanity,
      sharedHouseholdItems: household?.sharedItems ?? const [],
      memberEmails: household?.memberEmails ?? const {},
    );
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      key: Key('detail-matches-${item.itemId}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppTheme.statusAmberBg, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in matches.single.matches.take(3))
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
                  onPressed: () => DuplicateAlertDialog.viewExisting(context, m),
                  child: const Text('View Existing Item', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              key: Key('detail-dup-ack-${item.itemId}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: edit.duplicateAcknowledged,
              onChanged: _busy ? null : (v) => setState(() => edit.duplicateAcknowledged = v ?? false),
              title: const Text('I bought another unit: add it as a separate item', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineTile(ReceiptModel receipt, ReceiptItemModel item, VanityProvider vanity) {
    final cur = receipt.currency;
    final onShelf = _isOnShelf(item, vanity);
    final wasLinked = item.matchedVanityItemId != null;
    final edit = _editFor(item);
    final failed = _lastReport?.lines
        .where((l) => l.lineId == item.itemId && l.outcome == LineOutcome.failed)
        .firstOrNull;

    return Card(
      key: Key('receipt-line-${item.itemId}'),
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: edit.selected ? AppTheme.primaryRose.withValues(alpha: 0.4) : const Color(0xFFF1ECE8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: onShelf ? true : edit.selected,
                  onChanged: onShelf || _busy ? null : (v) => setState(() => edit.selected = v ?? false),
                ),
                Expanded(
                  child: Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${item.quantity} × $cur${item.unitPrice.toStringAsFixed(2)}\n$cur${item.totalPrice.toStringAsFixed(2)}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                onShelf
                    ? '✓ In Vanity Inventory'
                    : wasLinked
                    ? 'Was added before, but is no longer on your shelf'
                    : failed != null
                    ? '✗ Not added: ${failed.error ?? 'error'}'
                    : 'Receipt only',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: onShelf ? AppTheme.statusGreen : (failed != null ? AppTheme.statusRed : AppTheme.textMuted),
                ),
              ),
            ),
            if (edit.selected && !onShelf) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Column(
                  children: [
                    TextField(
                      controller: edit.name,
                      onChanged: (_) => setState(edit.refreshSuggestion), // re-check duplicates and category
                      decoration: InputDecoration(
                        labelText: 'Product name',
                        isDense: true,
                        errorText: _showValidation && edit.name.text.trim().isEmpty ? 'Enter a product name' : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: edit.brand,
                      onChanged: (_) => setState(edit.refreshSuggestion),
                      decoration: const InputDecoration(labelText: 'Brand (optional)', isDense: true),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      key: Key('detail-category-${item.itemId}-${edit.categoryId}'),
                      initialValue: vanity.categories.any((c) => c.categoryId == edit.categoryId) ? edit.categoryId : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Category', isDense: true),
                      hint: const Text('Uncategorized: choose', style: TextStyle(fontSize: 13)),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Uncategorized', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                        ),
                        for (final c in vanity.categories)
                          DropdownMenuItem<String?>(
                            value: c.categoryId,
                            child: Text(c.name, style: const TextStyle(fontSize: 13)),
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        edit.categoryId = v;
                        edit.categoryChosenByUser = true;
                      }),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        edit.categoryChosenByUser
                            ? 'Chosen by you'
                            : (edit.suggestion != null
                                  ? '${edit.suggestion!.explanation}. Change it if it is wrong.'
                                  : 'Not recognised from the name: choose a category'),
                        style: TextStyle(
                          fontSize: 11,
                          color: edit.categoryChosenByUser || (edit.suggestion != null && !edit.suggestion!.weak)
                              ? AppTheme.textMuted
                              : AppTheme.statusAmber,
                        ),
                      ),
                    ),
                    if (context.read<HouseholdProvider?>()?.hasHousehold == true) ...[
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        key: Key('detail-dest-${item.itemId}'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: false, icon: Icon(Icons.lock_outline_rounded, size: 16), label: Text('Personal')),
                          ButtonSegment(value: true, icon: Icon(Icons.people_alt_outlined, size: 16), label: Text('Shared household')),
                        ],
                        selected: {edit.shareWithHousehold},
                        onSelectionChanged: _busy ? null : (s) => setState(() => edit.shareWithHousehold = s.first),
                      ),
                    ],
                    _lineMatches(receipt, item, edit, vanity),
                    const SizedBox(height: 4),
                    const Text(
                      'Added as unopened (no opening date or expiry is set).',
                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFF1ECE8)),
    ),
    child: child,
  );

  Widget _banner(String text, {Key? key, Color color = AppTheme.statusAmberBg}) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
    child: Text(text, style: const TextStyle(fontSize: 12, color: AppTheme.textDark)),
  );

  Widget _row(String label, String value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
        Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
      ],
    ),
  );
}
