import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/vanity_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/main_navigation_scaffold.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase safely (runs in offline/mock mode if no config file provided yet)
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase not initialized via default options, running with local persistence: $e');
  }

  // Initialize Local Notifications
  try {
    final notifications = NotificationService();
    await notifications.initialize();
    await notifications.requestPermissions();
  } catch (e) {
    debugPrint('Notification service init error: $e');
  }

  // Initialize Database Caches & Seed Data
  await DatabaseService().initialize();

  runApp(const VanityTrackerApp());
}

class VanityTrackerApp extends StatelessWidget {
  const VanityTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..initialize()),
        ChangeNotifierProvider(create: (_) => VanityProvider()),
      ],
      child: MaterialApp(
        title: 'Vanity Tracker',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const AuthGate(),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _initialLoaded = false;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.isLoading && !_initialLoaded) {
      return const Scaffold(
        backgroundColor: Color(0xFFFDFBF9),
        body: Center(
          child: CircularProgressIndicator(color: AppTheme.primaryRose),
        ),
      );
    }

    if (auth.isAuthenticated) {
      if (!_initialLoaded) {
        _initialLoaded = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          context.read<VanityProvider>().loadItems(auth.currentUser!.userId);
        });
      }
      return const MainNavigationScaffold();
    }

    _initialLoaded = false;
    return const LoginScreen();
  }
}
