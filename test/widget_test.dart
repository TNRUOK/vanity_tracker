import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/main.dart';
import 'package:vanity_tracker/screens/auth/login_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Vanity Tracker app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VanityTrackerApp());
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Vanity Tracker'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
  });
}
