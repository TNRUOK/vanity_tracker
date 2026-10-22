import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/household_provider.dart';
import 'providers/receipt_provider.dart';
import 'providers/vanity_provider.dart';
import 'providers/wishlist_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/main_navigation_scaffold.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Development/testing only: `--dart-define=VANITY_LOCAL_ONLY=true` builds an app that
  // never connects to Firebase and keeps all data in this browser/device, so workflows can
  // be exercised end to end without touching any real account. Off in normal builds.
  const localOnly = bool.fromEnvironment('VANITY_LOCAL_ONLY');

  // Initialize Firebase safely (runs in offline/mock mode if no config file provided yet)
  try {
    if (localOnly) {
      debugPrint('VANITY_LOCAL_ONLY: Firebase is not initialized; using local persistence only.');
    } else if (kIsWeb) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      debugPrint('Firebase initialized successfully for Web.');
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Firebase.initializeApp();
        debugPrint('Firebase initialized natively via google-services.json for Android.');
      } catch (nativeErr) {
        debugPrint('Firebase native Android init note ($nativeErr); retrying with DefaultFirebaseOptions...');
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.android,
        );
        debugPrint('Firebase initialized successfully via DefaultFirebaseOptions for Android.');
      }
    } else {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      debugPrint('Firebase initialized successfully for $defaultTargetPlatform.');
    }
  } catch (e, stack) {
    debugPrint(
      'WARNING: Firebase initialization failed ($e). Operating in local persistence mode.\n'
      'Reason: $e\nStack: $stack',
    );
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
        ChangeNotifierProvider(create: (_) => HouseholdProvider()),
        ChangeNotifierProvider(create: (_) => WishlistProvider()),
        ChangeNotifierProvider(create: (_) => ReceiptProvider()),
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
          context.read<HouseholdProvider>().loadHousehold(auth.currentUser!);
          context.read<WishlistProvider>().loadWishlist(
            auth.currentUser!.userId,
          );
          context.read<ReceiptProvider>().loadReceipts(
            auth.currentUser!.userId,
          );
        });
      }
      return const MainNavigationScaffold();
    }

    _initialLoaded = false;
    return const LoginScreen();
  }
}
