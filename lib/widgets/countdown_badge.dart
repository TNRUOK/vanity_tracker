import 'package:flutter/material.dart';
import '../models/vanity_item_model.dart';
import '../theme/app_theme.dart';

class CountdownBadge extends StatelessWidget {
  final VanityItemModel item;
  final bool isCompact;

  const CountdownBadge({
    super.key,
    required this.item,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final status = item.computedStatus;
    final days = item.daysUntilExpiry;

    Color badgeColor;
    Color bgColor;
    String text;
    IconData icon;

    switch (status) {
      case VanityStatus.finished:
        badgeColor = AppTheme.statusFinished;
        bgColor = AppTheme.statusFinishedBg;
        text = 'Finished';
        icon = Icons.check_circle_outline;
        break;
      case VanityStatus.unopened:
        badgeColor = AppTheme.statusUnopened;
        bgColor = AppTheme.statusUnopenedBg;
        text = 'Unopened';
        icon = Icons.lock_outline;
        break;
      case VanityStatus.expired:
        badgeColor = AppTheme.statusRed;
        bgColor = AppTheme.statusRedBg;
        final expiredDays = days != null ? days.abs() : 0;
        text = expiredDays == 0 ? 'Expired Today' : 'Expired $expiredDays d ago';
        icon = Icons.warning_amber_rounded;
        break;
      case VanityStatus.expiringSoon:
        badgeColor = AppTheme.statusAmber;
        bgColor = AppTheme.statusAmberBg;
        text = '$days days left';
        icon = Icons.access_time_filled;
        break;
      case VanityStatus.active:
        badgeColor = AppTheme.statusGreen;
        bgColor = AppTheme.statusGreenBg;
        text = '$days days left';
        icon = Icons.spa_outlined;
        break;
    }

    if (isCompact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: badgeColor.withValues(alpha: 0.3), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: badgeColor),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                color: badgeColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: badgeColor.withValues(alpha: 0.35), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: badgeColor),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: badgeColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}
