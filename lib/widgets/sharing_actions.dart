import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vanity_item_model.dart';
import '../providers/auth_provider.dart';
import '../providers/household_provider.dart';
import '../providers/vanity_provider.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';

/// Share / stop sharing one of the signed-in user's own items, with a message that
/// reflects what was actually saved. Used by Product Details and Household Sharing so
/// both behave the same. Only visibility changes; the item is never copied or deleted.
Future<void> changeSharingWithFeedback(BuildContext context, VanityItemModel item, bool share) async {
  final messenger = ScaffoldMessenger.of(context);
  final household = context.read<HouseholdProvider>();
  final vanity = context.read<VanityProvider>();
  final userId = context.read<AuthProvider>().currentUser?.userId ?? '';
  final name = item.product?.name ?? 'Product';
  String text;
  Color color;
  try {
    await household.setItemSharing(vanity: vanity, item: item, share: share, currentUserId: userId);
    text = share ? '👥 $name is now shared with your household.' : '🔒 $name is private again (still on your shelf).';
    color = share ? AppTheme.statusGreen : AppTheme.statusAmber;
  } on VanitySyncException catch (e) {
    text = '${share ? 'Shared' : 'Made private'} on this device. ${e.message}';
    color = AppTheme.statusAmber;
  } catch (e) {
    text = 'Sharing not changed: ${e.toString().replaceFirst('Exception: ', '')}';
    color = AppTheme.statusRed;
  }
  if (!messenger.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
}
