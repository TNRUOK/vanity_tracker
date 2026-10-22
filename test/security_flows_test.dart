// App-side behaviour that the proposed Firestore rules depend on: e-mail verification
// before invitations, the household-leave partial update, and no Firestore use without a
// Firebase sign-in. Local (non-Firebase) mode; the rules themselves are tested separately
// with security/run_rules_tests.js (and, before deployment, the Firestore emulator).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/household_invitation_model.dart';
import 'package:vanity_tracker/models/household_model.dart';
import 'package:vanity_tracker/models/user_model.dart';
import 'package:vanity_tracker/providers/auth_provider.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/receipt_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/screens/household/household_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/household_service.dart';

const alice = UserModel(userId: 'user_alice', name: 'Alice', email: 'alice@example.com');
const carolUnverified = UserModel(userId: 'user_carol', name: 'Carol', email: 'carol@example.com', emailVerified: false);
final carolVerified = carolUnverified.copyWith(emailVerified: true);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    HouseholdService().clearLocalMemory();
  });

  Future<(HouseholdModel, HouseholdInvitationModel)> invited() async {
    final service = HouseholdService();
    final hh = await service.createHousehold(name: 'Flat', creator: alice);
    final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: carolUnverified.email);
    return (hh, inv);
  }

  group('E-mail verification before invitations', () {
    test('an unverified invitee cannot accept or decline; the invitation stays pending', () async {
      final (hh, inv) = await invited();
      final service = HouseholdService();
      await expectLater(
        service.acceptInvitation(invitationId: inv.invitationId, user: carolUnverified),
        throwsA(isA<EmailNotVerifiedException>()),
      );
      await expectLater(
        service.declineInvitation(invitationId: inv.invitationId, user: carolUnverified),
        throwsA(isA<EmailNotVerifiedException>()),
      );
      final pending = await service.getIncomingInvitations(carolUnverified.email);
      expect(pending.single.status, InvitationStatus.pending);
      final household = await service.getHousehold(hh.householdId, currentUserId: alice.userId);
      expect(household!.memberUids, [alice.userId], reason: 'membership unchanged');
    });

    test('after verification the same invitation is accepted', () async {
      final (hh, inv) = await invited();
      final joined = await HouseholdService().acceptInvitation(invitationId: inv.invitationId, user: carolVerified);
      expect(joined.householdId, hh.householdId);
      expect(joined.memberUids, containsAll([alice.userId, carolVerified.userId]));
    });

    test('a verified account with a different e-mail still cannot accept', () async {
      final (_, inv) = await invited();
      const dave = UserModel(userId: 'user_dave', name: 'Dave', email: 'dave@example.com');
      await expectLater(
        HouseholdService().acceptInvitation(invitationId: inv.invitationId, user: dave),
        throwsA(predicate((e) => e.toString().contains('Unauthorized'))),
      );
    });

    test('the provider hides invitations for an unverified account and asks to verify', () async {
      await invited();
      final prov = HouseholdProvider();
      await prov.loadHousehold(carolUnverified);
      expect(prov.needsEmailVerification, isTrue);
      expect(prov.incomingInvitations, isEmpty);
      expect(prov.invitationsError, isNull);

      await prov.loadHousehold(carolVerified);
      expect(prov.needsEmailVerification, isFalse);
      expect(prov.incomingInvitations, hasLength(1));
    });

    testWidgets('the Household screen shows the verification banner with resend/refresh', (tester) async {
      final household = HouseholdProvider();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(create: (_) => _FixedAuth(carolUnverified)),
          ChangeNotifierProvider<HouseholdProvider>.value(value: household),
          ChangeNotifierProvider(create: (_) => VanityProvider()),
          ChangeNotifierProvider(create: (_) => ReceiptProvider()),
        ],
        child: const MaterialApp(home: HouseholdScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('verify-email-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('resend-verification')), findsOneWidget);
      expect(find.byKey(const ValueKey('refresh-verification')), findsOneWidget);
      expect(find.textContaining('stays pending'), findsOneWidget);
    });
  });

  group('Leaving a household', () {
    final hh = HouseholdModel(
      householdId: 'h1',
      name: 'Flat',
      createdBy: 'alice',
      createdAt: DateTime(2026, 10, 1),
      memberUids: const ['alice', 'bob'],
      memberEmails: const {'alice': 'alice@example.com', 'bob': 'bob@example.com'},
    );

    test('a member removes only their own entries (no full-document rewrite)', () {
      final update = householdLeaveUpdate(hh, 'bob');
      expect(update.keys.toSet(), {'member_uids', 'member_emails.bob'});
      expect(update['member_uids'], isA<ArrayRemoveMarker>());
      expect(update['member_emails.bob'], isA<DeleteFieldMarker>());
      expect(update.containsKey('created_by'), isFalse);
      expect(update.containsKey('name'), isFalse);
    });

    test('the owner leaving hands ownership to a remaining member', () {
      final update = householdLeaveUpdate(hh, 'alice');
      expect(update['created_by'], 'bob');
      expect(update.keys.toSet(), {'member_uids', 'member_emails.alice', 'created_by'});
    });
  });

  test('Firestore is not used without a Firebase sign-in (demo/local mode)', () {
    expect(DatabaseService.cloudSessionActive, isFalse);
    expect(DatabaseService().isFirebaseAvailable, isFalse);
    expect(HouseholdService().isFirebaseAvailable, isFalse);
  });
}

class _FixedAuth extends AuthProvider {
  final UserModel user;
  _FixedAuth(this.user);
  @override
  UserModel? get currentUser => user;
}
