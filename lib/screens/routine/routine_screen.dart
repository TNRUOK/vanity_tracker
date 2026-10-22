import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/vanity_item_model.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ingredient_conflict_card.dart';
import '../../widgets/vanity_item_card.dart';
import '../product/product_detail_screen.dart';

class RoutineScreen extends StatefulWidget {
  const RoutineScreen({super.key});

  @override
  State<RoutineScreen> createState() => _RoutineScreenState();
}

class _RoutineScreenState extends State<RoutineScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vanityProv = context.watch<VanityProvider>();

    final amItems = vanityProv.amRoutineItems;
    final pmItems = vanityProv.pmRoutineItems;
    final weeklyItems = vanityProv.weeklyRoutineItems;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Beauty & Skincare Routines'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryRose,
          labelColor: AppTheme.primaryRose,
          unselectedLabelColor: AppTheme.textMuted,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          tabs: [
            Tab(
              icon: const Icon(Icons.wb_sunny_rounded, size: 20),
              text: 'Morning (${amItems.length})',
            ),
            Tab(
              icon: const Icon(Icons.nightlight_round, size: 20),
              text: 'Evening (${pmItems.length})',
            ),
            Tab(
              icon: const Icon(Icons.calendar_today_rounded, size: 18),
              text: 'Weekly (${weeklyItems.length})',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildRoutineList(
            context,
            items: amItems,
            routineTitle: 'Morning Routine (AM)',
            icon: Icons.wb_sunny_rounded,
            accentColor: const Color(0xFFE07A5F),
            emptyMessage: 'No products in your Morning Routine yet.\nOpen a product on your shelf and tap "Add to Routine".',
          ),
          _buildRoutineList(
            context,
            items: pmItems,
            routineTitle: 'Evening Routine (PM)',
            icon: Icons.nightlight_round,
            accentColor: const Color(0xFF3D405B),
            emptyMessage: 'No products in your Evening Routine yet.\nOpen a product on your shelf and tap "Add to Routine".',
          ),
          _buildRoutineList(
            context,
            items: weeklyItems,
            routineTitle: 'Weekly Treatments',
            icon: Icons.calendar_today_rounded,
            accentColor: AppTheme.primaryRose,
            emptyMessage: 'No Weekly Treatments yet.\nOpen a mask, scrub or peel on your shelf and tap "Add to Routine".',
          ),
        ],
      ),
    );
  }

  Widget _buildRoutineList(
    BuildContext context, {
    required List<VanityItemModel> items,
    required String routineTitle,
    required IconData icon,
    required Color accentColor,
    required String emptyMessage,
  }) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 48, color: accentColor),
              ),
              const SizedBox(height: 20),
              Text(
                routineTitle,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textDark),
              ),
              const SizedBox(height: 10),
              Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: AppTheme.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(icon, size: 18, color: accentColor),
                const SizedBox(width: 8),
                Text(
                  '$routineTitle • ${items.length} Step${items.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          );
        }

        if (index == 1) {
          return IngredientConflictCard(
            items: items,
            routineName: routineTitle,
            onIngredientsUpdated: () {
              setState(() {});
            },
          );
        }

        final item = items[index - 2];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Stack(
            children: [
              VanityItemCard(
                item: item,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProductDetailScreen(vanityItemId: item.vanityItemId),
                    ),
                  );
                },
              ),
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Step $index',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
