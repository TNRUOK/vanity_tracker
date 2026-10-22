import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/wishlist_item_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/providers/wishlist_provider.dart';
import 'package:vanity_tracker/screens/backup/backup_restore_screen.dart';
import 'package:vanity_tracker/screens/dashboard/vanity_dashboard_screen.dart';
import 'package:vanity_tracker/screens/guide/pao_guide_screen.dart';
import 'package:vanity_tracker/screens/history/empties_screen.dart';
import 'package:vanity_tracker/screens/household/household_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_history_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_review_screen.dart';
import 'package:vanity_tracker/screens/receipt/receipt_scanner_screen.dart';
import 'package:vanity_tracker/screens/wishlist/wishlist_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';

void main() {
  late VanityProvider vanity;
  late WishlistProvider wishlist;
  late ReceiptProvider receipts;
  late HouseholdProvider household;
  late AuthProvider auth;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    vanity = VanityProvider();
    wishlist = WishlistProvider();
    receipts = ReceiptProvider();
    household = HouseholdProvider();
    auth = AuthProvider();
    await auth.useDemoAccount();
  });

  Widget buildTestApp(Widget home) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<VanityProvider>.value(value: vanity),
        ChangeNotifierProvider<WishlistProvider>.value(value: wishlist),
        ChangeNotifierProvider<ReceiptProvider>.value(value: receipts),
        ChangeNotifierProvider<HouseholdProvider>.value(value: household),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ],
      child: MaterialApp(home: home),
    );
  }

  group('Dashboard Always-Visible Navigation', () {
    testWidgets('all 6 quick action cards and sign-out button are present with no PopupMenuButton', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      // Verify no PopupMenuButton exists on dashboard
      expect(find.byType(PopupMenuButton<String>), findsNothing);

      // Verify Sign Out button in header
      expect(find.byTooltip('Sign Out'), findsOneWidget);

      // Verify all 6 quick-action cards are visible
      expect(find.text('Wishlist'), findsOneWidget);
      expect(find.text('Scan Receipt'), findsOneWidget);
      expect(find.text('Receipt History'), findsOneWidget);
      expect(find.text('Household'), findsOneWidget);
      expect(find.text('PAO Guide'), findsOneWidget);
      expect(find.text('Backup / Restore'), findsOneWidget);
    });

    testWidgets('Wishlist quick action navigates to WishlistScreen', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Wishlist'));
      await tester.pumpAndSettle();

      expect(find.byType(WishlistScreen), findsOneWidget);
    });

    testWidgets('Scan Receipt quick action navigates to ReceiptScannerScreen', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Scan Receipt'));
      await tester.pumpAndSettle();

      expect(find.byType(ReceiptScannerScreen), findsOneWidget);
    });

    testWidgets('Receipt History quick action navigates to ReceiptHistoryScreen', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Receipt History'));
      await tester.pumpAndSettle();

      expect(find.byType(ReceiptHistoryScreen), findsOneWidget);
    });

    testWidgets('Household quick action navigates to HouseholdScreen', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Household'));
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdScreen), findsOneWidget);
    });

    testWidgets('PAO Guide quick action navigates to PaoGuideScreen', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('PAO Guide'));
      await tester.tap(find.text('PAO Guide'));
      await tester.pumpAndSettle();

      expect(find.byType(PaoGuideScreen), findsOneWidget);
    });

    testWidgets('Backup / Restore quick action navigates to BackupRestoreScreen', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Backup / Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup / Restore'));
      await tester.pumpAndSettle();

      expect(find.byType(BackupRestoreScreen), findsOneWidget);
    });

    testWidgets('Sign Out button opens confirmation dialog and confirms', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const VanityDashboardScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign Out'));
      await tester.pumpAndSettle();

      expect(find.text('Are you sure you want to sign out?'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Sign Out'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Out'));
      await tester.pumpAndSettle();

      expect(auth.isAuthenticated, isFalse);
    });
  });

  group('WishlistScreen Always-Visible Inline Actions', () {
    testWidgets('displays inline Edit and Delete buttons with confirmation dialog', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Add a test wishlist item
      await wishlist.addItem(
        WishlistItemModel(
          wishlistId: 'w_test_1',
          userId: 'demo_user',
          name: 'Hydrating Essence',
          brand: 'GlowLab',
          categoryId: 'serum',
          notes: 'Cruelty-free',
          targetPrice: 28.0,
          createdAt: DateTime(2026, 10, 1),
        ),
      );

      await tester.pumpWidget(buildTestApp(const WishlistScreen()));
      await tester.pumpAndSettle();

      // No three-dot popup menu
      expect(find.byType(PopupMenuButton<String>), findsNothing);

      // Inline Edit and Delete buttons are present
      expect(find.byTooltip('Edit details'), findsOneWidget);
      expect(find.byTooltip('Remove from wishlist'), findsOneWidget);

      // Tap delete button -> triggers confirmation dialog
      await tester.tap(find.byTooltip('Remove from wishlist'));
      await tester.pumpAndSettle();

      expect(find.text('Remove from Wishlist'), findsOneWidget);
      expect(find.textContaining('Are you sure you want to remove "Hydrating Essence"'), findsOneWidget);

      // Cancel keeps item
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(wishlist.items, hasLength(1));

      // Tap delete button -> confirm deletion
      await tester.tap(find.byTooltip('Remove from wishlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(wishlist.items, isEmpty);
    });
  });

  group('EmptiesScreen Always-Visible Inline Actions', () {
    testWidgets('displays inline Restore button with confirmation dialog', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = ProductModel(
        productId: 'p_empty_1',
        barcode: '',
        name: 'Barrier Cream',
        brand: 'Ceramide Co',
        categoryId: 'moisturizer',
        categorySource: CategorySource.user,
        paoMonths: 6,
        paoSource: PaoSource.user,
        createdAt: DateTime(2026, 8, 1),
      );

      final item = await vanity.addItem(
        product: p,
        userId: 'demo_user',
        openedDate: DateTime(2026, 8, 1),
      );

      // Finish item to move to empties
      await vanity.markAsFinished(
        item.vanityItemId,
        wouldRepurchase: true,
        finishedDate: DateTime(2026, 10, 1),
      );

      await tester.pumpWidget(buildTestApp(const EmptiesScreen()));
      await tester.pumpAndSettle();

      // No three-dot popup menu
      expect(find.byType(PopupMenuButton<String>), findsNothing);

      // Inline Restore button is present
      expect(find.byTooltip('Restore to Vanity'), findsOneWidget);

      // Tap restore button -> shows confirmation dialog
      await tester.tap(find.byTooltip('Restore to Vanity'));
      await tester.pumpAndSettle();

      expect(find.text('Restore Product'), findsOneWidget);
      expect(find.textContaining('Restore "Barrier Cream" back to your active Vanity Shelf?'), findsOneWidget);

      // Cancel leaves item in empties
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(vanity.empties, hasLength(1));

      // Confirm restores item
      await tester.tap(find.byTooltip('Restore to Vanity'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(vanity.empties, isEmpty);
      expect(vanity.activeItems, hasLength(1));
    });
  });

  group('ReceiptScannerScreen Dual-Mode Scanning (Image & Barcode)', () {
    testWidgets('shows both Receipt Image and Barcode Scanner tabs and allows barcode receipt building',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(const ReceiptScannerScreen()));
      await tester.pumpAndSettle();

      // Verify both tabs exist in AppBar
      expect(find.text('Receipt Image (OCR)'), findsOneWidget);
      expect(find.text('Barcode Scanner'), findsOneWidget);

      // Tab 0 has image scanner controls
      expect(find.text('Select Receipt Image'), findsOneWidget);

      // Switch to Barcode Scanner Tab
      await tester.tap(find.text('Barcode Scanner'));
      await tester.pumpAndSettle();

      // Verify Barcode Scanner controls
      expect(find.byKey(const Key('receipt-barcode-input')), findsOneWidget);
      expect(find.byKey(const Key('add-barcode-item-button')), findsOneWidget);

      // Enter a barcode and add item
      await tester.enterText(find.byKey(const Key('receipt-barcode-input')), '3337875597180');
      await tester.tap(find.byKey(const Key('add-barcode-item-button')));
      await tester.pumpAndSettle();

      // Scanned item appears in list
      expect(find.textContaining('3337875597180'), findsWidgets);
      expect(find.byKey(const Key('proceed-to-receipt-review-button')), findsOneWidget);

      // Dismiss snackbar so button is unobstructed
      ScaffoldMessenger.of(tester.element(find.byType(ReceiptScannerScreen))).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      // Proceed to review
      await tester.tap(find.byKey(const Key('proceed-to-receipt-review-button')));
      await tester.pumpAndSettle();

      // Verify ReceiptReviewScreen is opened with the item
      expect(find.byType(ReceiptReviewScreen), findsOneWidget);
    });
  });
}

