import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/product_model.dart';
import '../models/vanity_item_model.dart';
import '../theme/app_theme.dart';
import '../utils/currency.dart';
import 'countdown_badge.dart';

class VanityItemCard extends StatelessWidget {
  final VanityItemModel item;
  final VoidCallback onTap;
  final VoidCallback? onMarkOpened;
  final VoidCallback? onMarkFinished;

  const VanityItemCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onMarkOpened,
    this.onMarkFinished,
  });

  @override
  Widget build(BuildContext context) {
    final product = item.product;
    final brand = product?.brand ?? 'Unknown Brand';
    final name = product?.name ?? 'Cosmetic Product';
    final pao = product?.knownPaoMonths;
    final paoSource = product?.paoSource ?? PaoSource.unknown;
    // Verified or database values are shown plainly; estimates are marked with "~".
    final paoBadge = pao == null
        ? 'PAO ?'
        : (paoSource.isVerified || paoSource == PaoSource.productDatabase ? '${pao}M PAO' : '~${pao}M PAO');
    final expiry = item.effectiveExpiryDate;
    final statusColor = AppTheme.getStatusColor(item.daysUntilExpiry, isUnopened: item.openedDate == null, isFinished: item.status == 'finished');

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: item.computedStatus == VanityStatus.expired
              ? AppTheme.statusRed.withValues(alpha: 0.35)
              : item.computedStatus == VanityStatus.expiringSoon
                  ? AppTheme.statusAmber.withValues(alpha: 0.35)
                  : const Color(0xFFF1ECE8),
          width: 1.2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Product Thumbnail or Icon Box
                    _buildProductThumbnail(product?.imageUrl, statusColor),
                    const SizedBox(width: 14),

                    // Title, Brand & Tags
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  brand.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                    color: AppTheme.textMuted,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (item.price != null && item.price! > 0)
                                Text(
                                  formatInCurrency(item.priceCurrency, item.price!),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textDark,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textDark,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),

                          // Metadata Badges (PAO & Volume)
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.av_timer, size: 12, color: AppTheme.textMuted),
                                    const SizedBox(width: 3),
                                    Text(
                                      paoBadge,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textDark,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (product?.volume != null && product!.volume!.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    product.volume!,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                              if (item.routineTags.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                ...item.routineTags.map((tag) => Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryRose.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      tag == 'AM' ? '☀️ AM' : (tag == 'PM' ? '🌙 PM' : '📅 $tag'),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primaryRose,
                                      ),
                                    ),
                                  ),
                                )),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                const SizedBox(height: 10),

                // Bottom Status Row / Action
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Expiry info or Opened info
                    if (item.openedDate != null) ...[
                      CountdownBadge(item: item, isCompact: false),
                      Text(
                        expiry != null ? 'Exp: ${DateFormat('MMM d, yyyy').format(expiry)}' : 'Expiry unknown (set PAO)',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ] else ...[
                      CountdownBadge(item: item, isCompact: false),
                      if (onMarkOpened != null)
                        ElevatedButton.icon(
                          onPressed: onMarkOpened,
                          icon: const Icon(Icons.lock_open_rounded, size: 14),
                          label: const Text('Opened Today', style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryRose,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ],
                ),

                // Expiry Progress Bar for opened active products
                if (item.openedDate != null && item.status != 'finished') ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: item.expiryProgress.clamp(0.0, 1.0),
                      backgroundColor: const Color(0xFFF1F5F9),
                      valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProductThumbnail(String? imageUrl, Color accentColor) {
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          imageUrl,
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildPlaceholderIcon(accentColor),
        ),
      );
    }
    return _buildPlaceholderIcon(accentColor);
  }

  Widget _buildPlaceholderIcon(Color accentColor) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
      ),
      child: Center(
        child: Icon(
          Icons.auto_awesome,
          color: accentColor,
          size: 26,
        ),
      ),
    );
  }
}
