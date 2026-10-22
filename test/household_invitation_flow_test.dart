// Invitation lifecycle regression tests. Email delivery is MOCKED here: these tests
// prove the app reports delivery honestly, not that Gmail delivered anything.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/household_invitation_model.dart';
import 'package:vanity_tracker/models/household_model.dart';
import 'package:vanity_tracker/models/user_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/screens/household/household_screen.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/household_service.dart';
import 'package:vanity_tracker/services/invitation_email_client.dart';

class FakeEmailSender implements InvitationEmailSender {
  FakeEmailSender(this.result);
  InvitationEmailResult result;
  final calls = <(String, bool)>[];

  @override
  Future<InvitationEmailResult> sendInvitationEmail(String invitationId, {bool resend = false}) async {
    calls.add((invitationId, resend));
    return result;
  }
}

const alice = UserModel(userId: 'user_alice', email: 'alice@example.com', name: 'Alice');
const bob = UserModel(userId: 'user_bob', email: 'Bob@Example.com', name: 'Bob');
const carol = UserModel(userId: 'user_carol', email: 'carol@example.com', name: 'Carol');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = HouseholdService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    service.clearLocalMemory();
    service.debugEmailSender = null;
    await service.initialize();
  });

  tearDown(() => service.debugEmailSender = null);

  group('Invitation creation', () {
    test('normalizes the recipient email and stores expiry for security rules', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: '  Bob@Example.COM ');
      expect(inv.invitedEmail, 'bob@example.com');
      expect(inv.toMap()['expires_at_ms'], inv.expiresAt.millisecondsSinceEpoch);
      expect(inv.expiresAt.difference(inv.createdAt).inDays, 7);
    });

    test('rejects invalid emails', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      for (final bad in ['', 'bob', 'bob@', 'a b@c.com']) {
        await expectLater(
          service.sendInvitation(household: hh, sender: alice, recipientEmail: bad),
          throwsA(isA<Exception>()),
        );
      }
    });

    test('only the owner can invite, even other members cannot', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      final joined = await service.acceptInvitation(invitationId: inv.invitationId, user: bob);
      await expectLater(
        service.sendInvitation(household: joined, sender: bob, recipientEmail: carol.email),
        throwsA(predicate((e) => e.toString().contains('owner'))),
      );
    });

    test('duplicate pending invitation for the same email is refused', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      await service.sendInvitation(household: hh, sender: alice, recipientEmail: 'bob@example.com');
      await expectLater(
        service.sendInvitation(household: hh, sender: alice, recipientEmail: 'BOB@example.com'),
        throwsA(predicate((e) => e.toString().contains('already been sent'))),
      );
    });

    test('without Firebase/backend the invitation is in-app only (never "sent")', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      expect(inv.emailDeliveryStatus, EmailDeliveryStatus.notConfigured);
      expect(inv.emailDeliveryStatusLabel, 'In-App Only');
    });
  });

  group('Email delivery states (mock sender)', () {
    test('sent only when the backend confirms SMTP acceptance', () async {
      final sender = FakeEmailSender(const InvitationEmailResult(
        status: EmailDeliveryStatus.sent,
        providerResponse: '250 2.0.0 OK',
      ));
      service.debugEmailSender = sender;
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      expect(sender.calls, [(inv.invitationId, false)]);
      expect(inv.emailDeliveryStatus, EmailDeliveryStatus.sent);
      expect(inv.emailProviderResponse, '250 2.0.0 OK');
      expect(invitationEmailOutcomeMessage(inv, created: true), contains('Email sent'));
    });

    test('failed delivery is reported as failed with the reason', () async {
      service.debugEmailSender = FakeEmailSender(const InvitationEmailResult(
        status: EmailDeliveryStatus.failed,
        error: 'Gmail rejected the login.',
      ));
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      expect(inv.emailDeliveryStatus, EmailDeliveryStatus.failed);
      expect(inv.emailDeliveryError, 'Gmail rejected the login.');
      final msg = invitationEmailOutcomeMessage(inv, created: true);
      expect(msg, contains('NOT sent'));
      expect(msg, isNot(contains('Email sent')));
      // The invitation itself still exists for in-app acceptance.
      expect(inv.isValidPending, isTrue);
    });

    test('missing email configuration is reported as notConfigured', () async {
      service.debugEmailSender = FakeEmailSender(const InvitationEmailResult(
        status: EmailDeliveryStatus.notConfigured,
        error: 'Email sending is not configured on the backend (missing GMAIL_APP_PASSWORD).',
      ));
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      expect(inv.emailDeliveryStatus, EmailDeliveryStatus.notConfigured);
      expect(invitationEmailOutcomeMessage(inv, created: true), contains('No email sent'));
    });

    test('sender exceptions become a failed status, not a crash', () async {
      service.debugEmailSender = _ThrowingSender();
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      expect(inv.emailDeliveryStatus, EmailDeliveryStatus.failed);
    });

    test('resend: only the inviter, passes resend=true, keeps status on cooldown', () async {
      final sender = FakeEmailSender(const InvitationEmailResult(status: EmailDeliveryStatus.failed, error: 'x'));
      service.debugEmailSender = sender;
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);

      await expectLater(
        service.resendInvitationEmail(invitation: inv, user: carol),
        throwsA(isA<Exception>()),
      );

      sender.result = const InvitationEmailResult(status: null, error: 'Please wait 30s');
      final cooled = await service.resendInvitationEmail(invitation: inv, user: alice);
      expect(sender.calls.last, (inv.invitationId, true));
      expect(cooled.emailDeliveryStatus, EmailDeliveryStatus.failed);
      expect(cooled.emailDeliveryError, 'Please wait 30s');

      sender.result = const InvitationEmailResult(status: EmailDeliveryStatus.sent, providerResponse: '250 OK');
      final sent = await service.resendInvitationEmail(invitation: inv, user: alice);
      expect(sent.emailDeliveryStatus, EmailDeliveryStatus.sent);
      expect(sent.emailDeliveryError, isNull);
    });
  });

  group('Recipient lookup and acceptance', () {
    test('recipient sees their pending invitation regardless of email case', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      final incoming = await service.getIncomingInvitations('  BOB@example.com');
      expect(incoming, hasLength(1));
      expect(incoming.single.householdName, 'Home');
      expect(await service.getIncomingInvitations(carol.email), isEmpty);
    });

    test('another user cannot accept by using the invitation id', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      await expectLater(
        service.acceptInvitation(invitationId: inv.invitationId, user: carol),
        throwsA(predicate((e) => e.toString().contains('Unauthorized'))),
      );
      expect((await service.getHousehold(hh.householdId, currentUserId: alice.userId))!.memberUids, [alice.userId]);
    });

    test('accepting updates membership; repeating it does not duplicate membership', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      final first = await service.acceptInvitation(invitationId: inv.invitationId, user: bob);
      final second = await service.acceptInvitation(invitationId: inv.invitationId, user: bob);
      expect(first.memberUids, [alice.userId, bob.userId]);
      expect(second.memberUids, [alice.userId, bob.userId]);
      expect(second.memberEmails[bob.userId], 'bob@example.com');
      expect(await service.getIncomingInvitations(bob.email), isEmpty);
    });

    test('declined and revoked invitations cannot be accepted', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv1 = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      await service.declineInvitation(invitationId: inv1.invitationId, user: bob);
      await expectLater(service.acceptInvitation(invitationId: inv1.invitationId, user: bob), throwsA(isA<Exception>()));

      final inv2 = await service.sendInvitation(household: hh, sender: alice, recipientEmail: carol.email);
      await service.revokeInvitation(invitationId: inv2.invitationId, authorizedUser: alice);
      await expectLater(service.acceptInvitation(invitationId: inv2.invitationId, user: carol), throwsA(isA<Exception>()));
    });

    test('missing invitation gives a clear error', () async {
      await expectLater(
        service.acceptInvitation(invitationId: 'inv_missing', user: bob),
        throwsA(predicate((e) => e.toString().contains('not found'))),
      );
    });

    test('expired invitations are hidden and cannot be accepted', () async {
      final hh = HouseholdModel(
        householdId: 'hh_old',
        name: 'Old',
        createdBy: alice.userId,
        createdAt: DateTime(2026, 1, 1),
        memberUids: [alice.userId],
        memberEmails: {alice.userId: alice.email},
      );
      final expired = HouseholdInvitationModel(
        invitationId: 'inv_expired',
        householdId: 'hh_old',
        householdName: 'Old',
        invitedEmail: 'bob@example.com',
        invitedByUid: alice.userId,
        invitedByName: 'Alice',
        createdAt: DateTime.now().subtract(const Duration(days: 10)),
        expiresAt: DateTime.now().subtract(const Duration(days: 3)),
      );
      SharedPreferences.setMockInitialValues({
        'local_households': jsonEncode({'hh_old': hh.toMap()}),
        'local_household_invitations': jsonEncode({'inv_expired': expired.toMap()}),
      });
      service.clearLocalMemory();
      await service.initialize();

      expect(await service.getIncomingInvitations(bob.email), isEmpty);
      await expectLater(
        service.acceptInvitation(invitationId: 'inv_expired', user: bob),
        throwsA(predicate((e) => e.toString().contains('expired'))),
      );
    });

    test('a user already in another household must leave first', () async {
      final hhA = await service.createHousehold(name: 'A', creator: alice);
      await service.createHousehold(name: 'B', creator: bob);
      final inv = await service.sendInvitation(household: hhA, sender: alice, recipientEmail: bob.email);
      await expectLater(
        service.acceptInvitation(invitationId: inv.invitationId, user: bob),
        throwsA(predicate((e) => e.toString().contains('Leave it'))),
      );
    });

    test('after acceptance, shared inventory is visible to the new member and vice versa', () async {
      final hh = await service.createHousehold(name: 'Home', creator: alice);
      final inv = await service.sendInvitation(household: hh, sender: alice, recipientEmail: bob.email);
      await service.acceptInvitation(invitationId: inv.invitationId, user: bob);

      await DatabaseService().addVanityItem(VanityItemModel(
        vanityItemId: 'alice_shared',
        productId: 'p1',
        userId: alice.userId,
        isSharedWithHousehold: true,
        sharedHouseholdId: hh.householdId,
      ));
      await DatabaseService().addVanityItem(const VanityItemModel(
        vanityItemId: 'alice_private',
        productId: 'p2',
        userId: 'user_alice',
      ));

      final bobSees = await service.getSharedHouseholdItems(householdId: hh.householdId, currentUserId: bob.userId);
      expect(bobSees.map((i) => i.vanityItemId), ['alice_shared']);

      // Non-members are refused.
      await expectLater(
        service.getSharedHouseholdItems(householdId: hh.householdId, currentUserId: carol.userId),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('HouseholdProvider', () {
    test('household is found again on reload even though UserModel has no householdId', () async {
      final provider = HouseholdProvider();
      expect(alice.householdId, isNull);
      await provider.createHousehold('Persisted', alice);

      final reloaded = HouseholdProvider();
      await reloaded.loadHouseholdData(alice);
      expect(reloaded.hasHousehold, isTrue);
      expect(reloaded.currentHousehold!.name, 'Persisted');
    });

    test('recipient loads pending invitations and joins; inviter sees only pending invitations', () async {
      final owner = HouseholdProvider();
      await owner.createHousehold('Home', alice);
      expect(await owner.inviteMember(bob.email, alice), isTrue);
      expect(owner.lastSentInvitation!.emailDeliveryStatus, EmailDeliveryStatus.notConfigured);

      final recipient = HouseholdProvider();
      await recipient.loadHouseholdData(bob);
      expect(recipient.incomingInvitations, hasLength(1));
      expect(recipient.hasHousehold, isFalse);

      expect(await recipient.acceptInvitation(recipient.incomingInvitations.single.invitationId, bob), isTrue);
      expect(recipient.hasHousehold, isTrue);
      expect(recipient.incomingInvitations, isEmpty);

      await owner.loadHouseholdData(alice);
      expect(owner.currentHousehold!.memberUids, contains(bob.userId));
      expect(owner.outgoingInvitations, isEmpty, reason: 'accepted invitations are not "pending"');
    });

    test('failures are exposed as errorMessage instead of being swallowed', () async {
      final provider = HouseholdProvider();
      await provider.createHousehold('Home', alice);
      expect(await provider.inviteMember('not-an-email', alice), isFalse);
      expect(provider.errorMessage, contains('Invalid email'));
      expect(await provider.acceptInvitation('inv_missing', bob), isFalse);
      expect(provider.errorMessage, contains('not found'));
    });
  });

  group('BackendInvitationEmailSender (mock HTTP)', () {
    BackendInvitationEmailSender senderWith(MockClient client, {String? token = 'tok'}) =>
        BackendInvitationEmailSender(client: client, idTokenProvider: () async => token, baseUrl: 'http://localhost:8787/');

    test('sends the bearer token and maps 200 to sent', () async {
      late http.Request captured;
      final s = senderWith(MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'emailStatus': 'sent', 'providerResponse': '250 OK'}), 200);
      }));
      final r = await s.sendInvitationEmail('inv_1', resend: true);
      expect(captured.url.toString(), 'http://localhost:8787/api/invitations/inv_1/send');
      expect(captured.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(captured.body), {'resend': true});
      expect(r.status, EmailDeliveryStatus.sent);
      expect(r.providerResponse, '250 OK');
    });

    test('maps notConfigured, failed, permission and cooldown responses', () async {
      Future<InvitationEmailResult> respond(int code, Map<String, dynamic> body) =>
          senderWith(MockClient((_) async => http.Response(jsonEncode(body), code))).sendInvitationEmail('inv_1');

      final nc = await respond(503, {'emailStatus': 'notConfigured', 'error': {'code': 'email-not-configured', 'message': 'missing GMAIL_APP_PASSWORD'}});
      expect(nc.status, EmailDeliveryStatus.notConfigured);
      expect(nc.error, contains('GMAIL_APP_PASSWORD'));

      final failed = await respond(502, {'emailStatus': 'failed', 'error': {'code': 'email-failed', 'message': 'Gmail rejected the login.'}});
      expect(failed.status, EmailDeliveryStatus.failed);

      final denied = await respond(403, {'error': {'code': 'permission-denied', 'message': 'Only the household owner can send invitations.'}});
      expect(denied.status, EmailDeliveryStatus.failed);
      expect(denied.error, contains('owner'));

      final cooldown = await respond(429, {'error': {'code': 'cooldown', 'message': 'Please wait 30s'}});
      expect(cooldown.status, isNull);
    });

    test('unreachable backend and missing sign-in are failures with guidance', () async {
      final down = senderWith(MockClient((_) async => throw http.ClientException('refused')));
      final r = await down.sendInvitationEmail('inv_1');
      expect(r.status, EmailDeliveryStatus.failed);
      expect(r.error, contains('Could not reach the invitation email server'));

      final noToken = senderWith(MockClient((_) async => http.Response('{}', 200)), token: null);
      expect((await noToken.sendInvitationEmail('inv_1')).status, EmailDeliveryStatus.failed);
    });

    test('a 200 without emailStatus "sent" is never reported as sent', () async {
      final s = senderWith(MockClient((_) async => http.Response('not json', 200)));
      expect((await s.sendInvitationEmail('inv_1')).status, isNot(EmailDeliveryStatus.sent));
    });
  });
}

class _ThrowingSender implements InvitationEmailSender {
  @override
  Future<InvitationEmailResult> sendInvitationEmail(String invitationId, {bool resend = false}) =>
      Future.error(Exception('boom'));
}
