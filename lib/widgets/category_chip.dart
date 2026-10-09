import 'package:flutter/material.dart';
import '../models/category_model.dart';
import '../theme/app_theme.dart';

class CategoryChip extends StatelessWidget {
  final CategoryModel category;
  final bool isSelected;
  final VoidCallback onSelected;

  const CategoryChip({
    super.key,
    required this.category,
    required this.isSelected,
    required this.onSelected,
  });

  static IconData getCategoryIcon(String iconName) {
    switch (iconName) {
      case 'water_drop':
        return Icons.water_drop_outlined;
      case 'wb_sunny':
        return Icons.wb_sunny_outlined;
      case 'visibility':
        return Icons.visibility_outlined;
      case 'brush':
        return Icons.brush_outlined;
      case 'favorite':
        return Icons.favorite_border;
      case 'spa':
        return Icons.spa_outlined;
      case 'soap':
        return Icons.clean_hands_outlined;
      case 'opacity':
        return Icons.opacity;
      case 'remove_red_eye':
        return Icons.remove_red_eye_outlined;
      case 'local_florist':
        return Icons.local_florist_outlined;
      default:
        return Icons.category_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: FilterChip(
        selected: isSelected,
        showCheckmark: false,
        avatar: Icon(
          getCategoryIcon(category.iconName),
          size: 16,
          color: isSelected ? Colors.white : AppTheme.textMuted,
        ),
        label: Text(
          category.categoryName,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? Colors.white : AppTheme.textDark,
          ),
        ),
        backgroundColor: Colors.white,
        selectedColor: AppTheme.primaryRose,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isSelected ? AppTheme.primaryRose : const Color(0xFFE2E8F0),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        onSelected: (_) => onSelected(),
      ),
    );
  }
}
