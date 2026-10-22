import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'dashboard/vanity_dashboard_screen.dart';
import 'history/empties_screen.dart';
import 'product/add_product_screen.dart';
import 'routine/routine_screen.dart';
import 'stats/stats_screen.dart';

class MainNavigationScaffold extends StatefulWidget {
  const MainNavigationScaffold({super.key});

  @override
  State<MainNavigationScaffold> createState() => _MainNavigationScaffoldState();
}

class _MainNavigationScaffoldState extends State<MainNavigationScaffold> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    VanityDashboardScreen(),
    RoutineScreen(),
    EmptiesScreen(),
    StatsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AddProductScreen(),
            ),
          );
        },
        backgroundColor: AppTheme.primaryRose,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 30),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
          },
          backgroundColor: Colors.white,
          indicatorColor: AppTheme.statusGreenBg,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.spa_outlined),
              selectedIcon: Icon(Icons.spa, color: AppTheme.primaryRose),
              label: 'Vanity Shelf',
            ),
            NavigationDestination(
              icon: Icon(Icons.schedule_outlined),
              selectedIcon: Icon(Icons.schedule_rounded, color: AppTheme.primaryRose),
              label: 'Routines',
            ),
            NavigationDestination(
              icon: Icon(Icons.recycling_outlined),
              selectedIcon: Icon(Icons.recycling, color: AppTheme.statusFinished),
              label: 'Empties',
            ),
            NavigationDestination(
              icon: Icon(Icons.pie_chart_outline_rounded),
              selectedIcon: Icon(Icons.pie_chart_rounded, color: AppTheme.accentPeach),
              label: 'Budget Stats',
            ),
          ],
        ),
      ),
    );
  }
}
