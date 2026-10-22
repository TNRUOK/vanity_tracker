import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/receipt_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../providers/wishlist_provider.dart';
import '../../services/backup_restore_service.dart';
import '../../services/backup_service.dart';
import '../../theme/app_theme.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _importController = TextEditingController();

  // Export
  BackupSnapshot? _snapshot;
  String? _exportError;
  bool _isPreparing = false;
  bool _isSavingFile = false;
  bool _acceptPartial = false;
  String? _lastSaveMessage;

  // Import
  bool _isImporting = false;
  bool _isPickingFile = false;
  String? _loadedFileName;
  String? _importStatus;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _importController.dispose();
    super.dispose();
  }

  String get _userId => context.read<AuthProvider>().currentUser?.userId ?? '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Backup & Restore'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryRose,
          labelColor: AppTheme.primaryRose,
          unselectedLabelColor: AppTheme.textMuted,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          tabs: const [
            Tab(icon: Icon(Icons.file_upload_outlined, size: 20), text: 'Export Backup'),
            Tab(icon: Icon(Icons.file_download_outlined, size: 20), text: 'Import Backup'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildExportTab(context), _buildImportTab(context)],
      ),
    );
  }

  // ─────────────────────────────── EXPORT ───────────────────────────────

  Future<void> _prepareExport() async {
    setState(() {
      _isPreparing = true;
      _exportError = null;
      _lastSaveMessage = null;
      _acceptPartial = false;
    });
    try {
      final snap = await BackupExportService.collect(
        userId: _userId,
        currencySymbol: context.read<VanityProvider>().currencySymbol,
      );
      if (!mounted) return;
      setState(() => _snapshot = snap);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exportError = 'Could not read your data: ${e.toString().replaceFirst(RegExp(r'^\w*(Error|Exception): '), '')}');
    } finally {
      if (mounted) setState(() => _isPreparing = false);
    }
  }

  Future<void> _saveExport() async {
    final snap = _snapshot!;
    setState(() {
      _isSavingFile = true;
      _lastSaveMessage = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = BackupExportService.buildVerifiedJson(snap, userId: _userId);
      final outcome = await BackupService.saveBackup(json);
      if (!mounted) return;
      if (outcome.cancelled) {
        setState(() => _lastSaveMessage = 'Saving was cancelled. No file was saved.');
        return;
      }
      final msg = outcome.isBrowserDownload
          ? 'Download started: ${outcome.fileName} (${snap.totalRecords} records). Your browser saves it to '
              '${outcome.location}. Keep it somewhere private: it contains your personal data.'
          : 'Backup saved: ${outcome.fileName} (${snap.totalRecords} records) to ${outcome.location}. '
              'Keep it somewhere private: it contains your personal data.';
      setState(() => _lastSaveMessage = (snap.isComplete ? '' : 'PARTIAL backup. ') + msg);
      messenger.showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.statusGreen));
    } catch (e) {
      if (!mounted) return;
      final msg = 'The backup was NOT saved: ${e.toString().replaceFirst(RegExp(r'^\w*(Error|Exception): '), '')}';
      setState(() => _lastSaveMessage = msg);
      messenger.showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.statusRed));
    } finally {
      if (mounted) setState(() => _isSavingFile = false);
    }
  }

  Widget _buildExportTab(BuildContext context) {
    final snap = _snapshot;
    final canSave = snap != null && (snap.isComplete || _acceptPartial) && !_isSavingFile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            children: [
              const Row(
                children: [
                  Icon(Icons.shield_outlined, color: AppTheme.statusGreen, size: 22),
                  SizedBox(width: 8),
                  Text('Export a complete backup', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Includes all your products (with PAO, opening dates, ingredients, routines, empties and repurchase notes), '
                'receipts with their line items and product links, and your wishlist. '
                'File: vanity_tracker_backup_YYYY-MM-DD.json (format version ${BackupService.currentSchemaVersion}).',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted, height: 1.4),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const ValueKey('backup-prepare'),
                onPressed: _isPreparing ? null : _prepareExport,
                icon: _isPreparing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.fact_check_outlined, size: 18),
                label: Text(snap == null ? 'Prepare Backup' : 'Read My Data Again'),
              ),
              if (_exportError != null) ...[
                const SizedBox(height: 8),
                Text(_exportError!, style: const TextStyle(color: AppTheme.statusRed, fontSize: 12.5)),
              ],
              if (snap != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${snap.items.length} products · ${snap.receipts.length} receipts · ${snap.wishlist.length} wishlist items',
                  key: const ValueKey('backup-counts'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (snap.deviceOnlyCount > 0)
                  Text(
                    '${snap.deviceOnlyCount} of these are saved only on this device (not synced yet); they are included.',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
                if (snap.totalRecords == 0)
                  const Text('You have no data yet; the backup will be empty.', style: TextStyle(fontSize: 12)),
                if (!snap.isComplete) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(10)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Not everything could be read:', style: TextStyle(fontWeight: FontWeight.w700)),
                        for (final o in snap.omissions) Text('• $o', style: const TextStyle(fontSize: 12)),
                        CheckboxListTile(
                          key: const ValueKey('backup-accept-partial'),
                          contentPadding: EdgeInsets.zero,
                          value: _acceptPartial,
                          onChanged: (v) => setState(() => _acceptPartial = v ?? false),
                          title: const Text(
                            'Export anyway as a PARTIAL backup (marked as partial in the file)',
                            style: TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  key: const ValueKey('backup-save'),
                  onPressed: canSave ? _saveExport : null,
                  icon: _isSavingFile
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_alt_rounded, size: 18),
                  label: const Text('Save Backup File', style: TextStyle(fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryRose,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: canSave
                      ? () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            final json = BackupExportService.buildVerifiedJson(snap, userId: _userId);
                            await Clipboard.setData(ClipboardData(text: json));
                            messenger.showSnackBar(const SnackBar(content: Text('Backup JSON copied to the clipboard.')));
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(content: Text('Not copied: $e'), backgroundColor: AppTheme.statusRed));
                          }
                        }
                      : null,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy Backup JSON to Clipboard'),
                ),
              ],
              if (_lastSaveMessage != null) ...[
                const SizedBox(height: 10),
                Text(_lastSaveMessage!, key: const ValueKey('backup-save-message'), style: const TextStyle(fontSize: 12.5)),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _card(
            children: [
              const Text('Not included in a backup', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final e in BackupService.excludedData) Text('• $e', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────── IMPORT ───────────────────────────────

  Widget _buildImportTab(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            children: [
              const Row(
                children: [
                  Icon(Icons.file_download_outlined, color: AppTheme.primaryRose, size: 22),
                  SizedBox(width: 8),
                  Text('Restore from a backup', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Restoring merges the backup into your account: nothing is deleted, and you see exactly what will be '
                'added, skipped or kept before anything is written.',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                key: const ValueKey('backup-pick'),
                onPressed: _isPickingFile || _isImporting
                    ? null
                    : () async {
                        setState(() {
                          _isPickingFile = true;
                          _importStatus = null;
                        });
                        try {
                          final picked = await BackupService.pickBackupFile();
                          if (picked == null) {
                            setState(() => _importStatus = 'No file selected.');
                            return;
                          }
                          _importController.text = picked.content;
                          final sizeKb = (picked.fileSizeBytes / 1024).toStringAsFixed(1);
                          setState(() {
                            _loadedFileName = '${picked.fileName} ($sizeKb KB)';
                            _isPickingFile = false; // the file is read; the preview takes over
                          });
                          if (context.mounted) await _inspectAndRestore(context);
                        } catch (e) {
                          setState(() => _importStatus = 'Could not read the file: ${e.toString().replaceAll('FormatException: ', '')}');
                        } finally {
                          if (mounted) setState(() => _isPickingFile = false);
                        }
                      },
                icon: _isPickingFile
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.file_open_rounded, size: 18),
                label: const Text('Select Backup File (.json)', style: TextStyle(fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryRose,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              if (_loadedFileName != null) ...[
                const SizedBox(height: 8),
                Text('Loaded: $_loadedFileName', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 18),
              const Text('Or paste the backup JSON', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('backup-paste'),
                controller: _importController,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  hintText: '{ "format": "vanity-tracker-backup", ... }',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste_rounded, color: AppTheme.primaryRose),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        _importController.text = data!.text!;
                        setState(() => _loadedFileName = 'Pasted from clipboard');
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const ValueKey('backup-preview'),
                onPressed: _isImporting ? null : () => _inspectAndRestore(context),
                icon: _isImporting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.preview_rounded, size: 18),
                label: const Text('Check & Preview Restore'),
              ),
              if (_importStatus != null) ...[
                const SizedBox(height: 10),
                Text(_importStatus!, key: const ValueKey('backup-import-status'), style: const TextStyle(fontSize: 12.5)),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _card(
            children: const [
              Text('Good to know', style: TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(height: 6),
              Text('• Importing the same file twice does not create copies.', style: TextStyle(fontSize: 12)),
              Text(
                '• Restoring into a different account does not give access to the original account\'s household '
                'or shared products; sharing is switched off on restored products.',
                style: TextStyle(fontSize: 12),
              ),
              Text('• If something fails, import the same file again: only the missing records are written.',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _inspectAndRestore(BuildContext context) async {
    final raw = _importController.text.trim();
    final result = BackupService.validateBackup(raw, const []);
    if (!result.isValid) {
      final reason = (result.errorMessage ?? 'the backup could not be validated').replaceFirst(RegExp(r'\.$'), '');
      setState(() => _importStatus = 'Not restored: $reason. Your data was not changed.');
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Invalid backup file'),
          content: Text('${result.errorMessage ?? 'Failed to validate backup data.'}\n\nNothing was changed.'),
          actions: [ElevatedButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
        ),
      );
      return;
    }

    final userId = _userId;
    final vanityProv = context.read<VanityProvider>();
    final receiptProv = context.read<ReceiptProvider>();
    final wishlistProv = context.read<WishlistProvider>();
    setState(() => _isImporting = true);
    try {
      // What the account holds right now (not just what screens have loaded).
      final current = await BackupExportService.collect(userId: userId, currencySymbol: vanityProv.currencySymbol);
      if (!current.isComplete) {
        setState(() => _importStatus =
            'Not restored: your current data could not be read (${current.omissions.join(' ')}). '
            'Without it, existing records could be overwritten. Connect to the internet and try again.');
        return;
      }
      if (!context.mounted) return;

      var replaceConflicts = false;
      var importDuplicates = false;
      RestorePlan makePlan() => BackupRestoreService.plan(
            backup: result,
            targetUserId: userId,
            currentItems: current.items,
            currentReceipts: current.receipts,
            currentWishlist: current.wishlist,
            replaceConflicts: replaceConflicts,
            importPossibleDuplicates: importDuplicates,
          );

      final confirmed = await showDialog<RestorePlan>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            final plan = makePlan();
            Widget row(String label, String value, {Color? color}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: Text(label, style: const TextStyle(fontSize: 13))),
                      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
                    ],
                  ),
                );
            String perType(RestoreAction a) =>
                '${plan.count(a, 'Product')} / ${plan.count(a, 'Receipt')} / ${plan.count(a, 'Wishlist item')}';
            return AlertDialog(
              title: const Text('Restore preview'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Backup format v${result.schemaVersion}'
                      '${result.exportedAt != null ? ', exported ${result.exportedAt!.split('T').first}' : ''}.',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (!result.complete)
                      Text('This is a PARTIAL backup: ${result.omissions.join(' ')}',
                          style: const TextStyle(fontSize: 12, color: AppTheme.statusRed)),
                    const Divider(),
                    const Text('Products / Receipts / Wishlist', style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted)),
                    row('New (will be added)', perType(RestoreAction.create), color: AppTheme.statusGreen),
                    row('Already present (skipped)', perType(RestoreAction.skipIdentical)),
                    row('Different version present', '${plan.conflicts}', color: plan.conflicts > 0 ? AppTheme.statusAmber : null),
                    row('Possible duplicates (skipped)', perType(RestoreAction.possibleDuplicate)),
                    if (plan.invalidReasons.isNotEmpty)
                      row('Unreadable in the file', '${plan.invalidReasons.length}', color: AppTheme.statusRed),
                    for (final r in plan.invalidReasons.take(5))
                      Text('• $r', style: const TextStyle(fontSize: 11.5, color: AppTheme.statusRed)),
                    if (plan.invalidReasons.length > 5) Text('• ... and ${plan.invalidReasons.length - 5} more'),
                    if (plan.unresolvedLinks > 0)
                      Text('${plan.unresolvedLinks} receipt line(s) link to a product that is not in this backup.',
                          style: const TextStyle(fontSize: 11.5)),
                    if (plan.crossAccount)
                      const Text(
                        'This backup is from a different account: records get new ids for your account and household '
                        'sharing is switched off on them.',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    if (result.currencySymbol != null && result.currencySymbol != vanityProv.currencySymbol)
                      Text(
                        'The backup used currency ${result.currencySymbol}; your setting (${vanityProv.currencySymbol}) is not changed. '
                        'Receipts keep their own currency.',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    if (plan.conflicts > 0)
                      SwitchListTile(
                        key: const ValueKey('restore-replace-conflicts'),
                        contentPadding: EdgeInsets.zero,
                        value: replaceConflicts,
                        onChanged: (v) => setDialogState(() => replaceConflicts = v),
                        title: const Text('Replace the different versions with the backup copy', style: TextStyle(fontSize: 12.5)),
                        subtitle: const Text('Off: your current versions are kept.', style: TextStyle(fontSize: 11)),
                      ),
                    if (plan.count(RestoreAction.possibleDuplicate) > 0 || importDuplicates)
                      SwitchListTile(
                        key: const ValueKey('restore-import-duplicates'),
                        contentPadding: EdgeInsets.zero,
                        value: importDuplicates,
                        onChanged: (v) => setDialogState(() => importDuplicates = v),
                        title: const Text('Also add the possible duplicates', style: TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                ElevatedButton(
                  key: const ValueKey('restore-confirm'),
                  onPressed: plan.toWrite == 0 ? null : () => Navigator.of(ctx).pop(plan),
                  child: Text(plan.toWrite == 0 ? 'Nothing to restore' : 'Restore ${plan.toWrite} record${plan.toWrite == 1 ? '' : 's'}'),
                ),
              ],
            );
          },
        ),
      );
      if (confirmed == null) {
        setState(() => _importStatus = 'Restore cancelled. Nothing was changed.');
        return;
      }

      final report = await BackupRestoreService.execute(
        confirmed,
        vanity: vanityProv,
        receipts: receiptProv,
        wishlist: wishlistProv,
      );
      if (!mounted) return;
      setState(() => _importStatus = (report.isComplete ? 'Restore finished: ' : 'Restore PARTLY finished: ') + report.summary);
      if (!context.mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(report.isComplete ? 'Restore finished' : 'Restore partly finished'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(report.summary, key: const ValueKey('restore-summary')),
                Text('Verified afterwards: ${report.verified} of ${report.written} written records.',
                    style: const TextStyle(fontSize: 12)),
                for (final f in report.results.where((r) => r.outcome == RestoreOutcome.failed))
                  Text('• ${f.entry.type} "${f.entry.label}" failed: ${f.error}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.statusRed)),
              ],
            ),
          ),
          actions: [ElevatedButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _importStatus = 'Restore error: $e');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFF1ECE8)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}
