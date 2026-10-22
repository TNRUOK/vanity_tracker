import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/receipt_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/receipt_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import 'receipt_detail_screen.dart';
import 'receipt_scanner_screen.dart';

/// Lists the signed-in user's saved receipts (the same data Budget Stats counts).
class ReceiptHistoryScreen extends StatefulWidget {
  const ReceiptHistoryScreen({super.key});

  @override
  State<ReceiptHistoryScreen> createState() => _ReceiptHistoryScreenState();
}

class _ReceiptHistoryScreenState extends State<ReceiptHistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = context.read<AuthProvider>().currentUser;
      final receipts = context.read<ReceiptProvider>();
      if (user != null && !receipts.hasLoadedFor(user.userId) && !receipts.isLoading) {
        receipts.loadReceipts(user.userId);
      }
    });
  }

  Future<void> _reload() async {
    final user = context.read<AuthProvider>().currentUser;
    if (user != null) await context.read<ReceiptProvider>().loadReceipts(user.userId);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final receiptProv = context.watch<ReceiptProvider>();
    final vanity = context.watch<VanityProvider>();
    final shelfIds = vanity.allItems.map((i) => i.vanityItemId).toSet();
    final receipts = user == null
        ? const <ReceiptModel>[]
        : receiptProv.receipts.where((r) => r.userId == user.userId).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Receipt History'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Reload receipts', onPressed: _reload)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReceiptScannerScreen())),
        icon: const Icon(Icons.document_scanner_rounded),
        label: const Text('Scan a Receipt'),
      ),
      body: user == null
          ? const Center(child: Text('Please sign in to see your receipts.'))
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  if (receiptProv.errorMessage != null)
                    Container(
                      key: const Key('receipt-history-error'),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.statusAmberBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.cloud_off_rounded, color: AppTheme.statusAmber, size: 20),
                          const SizedBox(width: 10),
                          Expanded(child: Text(receiptProv.errorMessage!, style: const TextStyle(fontSize: 12))),
                          TextButton(onPressed: _reload, child: const Text('Retry')),
                        ],
                      ),
                    ),
                  if (receiptProv.isLoading && receipts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(child: CircularProgressIndicator(color: AppTheme.primaryRose)),
                    )
                  else if (receipts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Column(
                        children: [
                          Icon(Icons.receipt_long_outlined, size: 56, color: AppTheme.textMuted),
                          SizedBox(height: 12),
                          Text(
                            'No saved receipts yet',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Receipts you confirm after scanning appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    Text(
                      '${receipts.length} saved receipt${receipts.length == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 13, color: AppTheme.textMuted, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    for (final r in receipts) _ReceiptTile(receipt: r, shelfIds: shelfIds),
                  ],
                ],
              ),
            ),
    );
  }
}

class _ReceiptTile extends StatelessWidget {
  final ReceiptModel receipt;
  final Set<String> shelfIds;
  const _ReceiptTile({required this.receipt, required this.shelfIds});

  @override
  Widget build(BuildContext context) {
    final lines = receipt.items.length;
    final onShelf = receipt.items
        .where((i) => i.matchedVanityItemId != null && shelfIds.contains(i.matchedVanityItemId))
        .length;
    final subtitle = lines == 0
        ? 'Total only: no product lines were saved'
        : '$lines product line${lines == 1 ? '' : 's'} · $onShelf in Vanity Inventory';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFF1ECE8)),
      ),
      child: ListTile(
        key: Key('receipt-tile-${receipt.receiptId}'),
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFE6F4F1),
          child: Icon(Icons.receipt_long_rounded, color: Color(0xFF0D9488)),
        ),
        title: Text(
          receipt.merchant,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${DateFormat.yMMMd().format(receipt.purchaseDate)} · $subtitle',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Text(
          '${receipt.currency}${receipt.totalAmount.toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primaryRose),
        ),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => ReceiptDetailScreen(receiptId: receipt.receiptId))),
      ),
    );
  }
}
