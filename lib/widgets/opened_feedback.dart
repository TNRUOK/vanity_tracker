import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../providers/vanity_provider.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';

/// How long the "marked as opened" confirmation (with Undo) stays on screen.
const openedFeedbackDuration = Duration(seconds: 5);

/// Marks an item as opened and, only after the change was saved, shows a confirmation
/// with Undo that dismisses itself after [openedFeedbackDuration].
///
/// Since Flutter 3.29, a SnackBar with an action defaults to `persist: true` and ignores
/// its duration; the old messages therefore never went away. Here `persist` is false.
/// Dismissal is purely visual: it never changes the saved opening date. The timer belongs
/// to the app's ScaffoldMessenger (cancelled when it is disposed), and the Undo callback
/// uses the provider, not a widget context, so it cannot act on a disposed screen.
/// Undo only reverts the opening this message announced: if the item was changed again
/// in the meantime (e.g. opened on another date), the stale Undo does nothing.
Future<void> markOpenedWithFeedback(
  ScaffoldMessengerState messenger,
  VanityProvider vanity,
  String vanityItemId, {
  DateTime? openedDate,
}) async {
  String? syncNote;
  try {
    await vanity.markAsOpened(vanityItemId, openedDate: openedDate, throwOnSyncFailure: true);
  } on VanitySyncException catch (e) {
    syncNote = e.message; // saved on this device, not synced yet
  } catch (e) {
    if (!messenger.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Not marked as opened: ${e.toString().replaceFirst(RegExp(r'^\w*(Error|Exception): '), '')}'),
        backgroundColor: AppTheme.statusRed,
      ));
    return;
  }

  final saved = vanity.allItems.where((i) => i.vanityItemId == vanityItemId).firstOrNull;
  final savedOpened = saved?.openedDate;
  if (saved == null || savedOpened == null) return; // nothing was saved: no success message
  if (!messenger.mounted) return;
  final fmt = DateFormat('MMM d, yyyy');
  final expiry = saved.expiryDate;
  final when = openedDate == null ? 'Marked as opened today' : 'Marked as opened on ${fmt.format(savedOpened)}';
  final text = '$when. '
      '${expiry != null ? 'PAO expiry: ${fmt.format(expiry)}.' : 'Set the PAO to calculate an expiry.'}'
      '${syncNote != null ? ' $syncNote' : ''}';

  messenger
    ..hideCurrentSnackBar() // a newer confirmation replaces an older one (and its Undo)
    ..showSnackBar(SnackBar(
      key: ValueKey('opened-feedback-$vanityItemId-${savedOpened.toIso8601String()}'),
      content: Text(text),
      backgroundColor: syncNote == null ? AppTheme.statusGreen : AppTheme.statusAmber,
      duration: openedFeedbackDuration,
      persist: false,
      action: SnackBarAction(
        label: 'Undo',
        textColor: Colors.white,
        onPressed: () => _undoOpening(messenger, vanity, vanityItemId, savedOpened),
      ),
    ));
}

Future<void> _undoOpening(
  ScaffoldMessengerState messenger,
  VanityProvider vanity,
  String vanityItemId,
  DateTime announcedOpened,
) async {
  final current = vanity.allItems.where((i) => i.vanityItemId == vanityItemId).firstOrNull;
  if (current?.openedDate != announcedOpened) return; // stale: the item changed since
  String text = 'Opening undone. The product is unopened again.';
  try {
    await vanity.markAsUnopened(vanityItemId, throwOnSyncFailure: true);
  } on VanitySyncException catch (e) {
    text = '$text ${e.message}';
  } catch (e) {
    text = 'Could not undo: $e';
  }
  if (!messenger.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}
