import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/household_invitation_model.dart';
import 'package:vanity_tracker/models/household_model.dart';
import 'package:vanity_tracker/models/product_model.dart';
import 'package:vanity_tracker/models/user_model.dart';
import 'package:vanity_tracker/models/vanity_item_model.dart';
import 'package:vanity_tracker/providers/household_provider.dart';
import 'package:vanity_tracker/providers/vanity_provider.dart';
import 'package:vanity_tracker/services/database_service.dart';
import 'package:vanity_tracker/services/household_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService().initialize();
    HouseholdService().clearLocalMemory();
  });

  group('HouseholdModel & HouseholdInvitationModel Tests', () {
    test('HouseholdModel correctly detects owner and members', () {
      final household = HouseholdModel(
        householdId: 'hh_123',
        name: 'Baker St Loft',
        createdBy: 'user_alice',
        createdAt: DateTime(2026, 1, 1),
        memberUids: ['user_alice', 'user_bob'],
        memberEmails: {
          'user_alice': 'alice@example.com',
          'user_bob': 'bob@example.com',
        },
      );

      expect(household.isOwner('user_alice'), isTrue);
      expect(household.isOwner('user_bob'), isFalse);
      expect(household.isMember('user_alice'), isTrue);
      expect(household.isMember('user_bob'), isTrue);
      expect(household.isMember('user_charlie'), isFalse);

      final serialized = household.toMap();
      final deserialized = HouseholdModel.fromMap(serialized, 'hh_123');
      expect(deserialized.name, 'Baker St Loft');
      expect(deserialized.memberUids.length, 2);
    });

    test('HouseholdInvitationModel strictly validates recipient and expiration', () {
      final now = DateTime.now();
      final validInvitation = HouseholdInvitationModel(
        invitationId: 'inv_1',
        householdId: 'hh_123',
        householdName: 'Baker St Loft',
        invitedEmail: 'target@example.com',
        invitedByUid: 'user_alice',
        invitedByName: 'Alice',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 7)),
        status: InvitationStatus.pending,
      );

      // Correct recipient
      expect(validInvitation.canBeAcceptedBy('target@example.com'), isTrue);
      expect(validInvitation.canBeAcceptedBy('TARGET@EXAMPLE.COM'), isTrue);
      // Imposter recipient rejected
      expect(validInvitation.canBeAcceptedBy('attacker@example.com'), isFalse);
      expect(validInvitation.isExpired, isFalse);
      expect(validInvitation.isValidPending, isTrue);

      // Expired invitation cannot be accepted
      final expiredInvitation = validInvitation.copyWith(
        expiresAt: now.subtract(const Duration(days: 1)),
      );
      expect(expiredInvitation.isExpired, isTrue);
      expect(expiredInvitation.isValidPending, isFalse);
      expect(expiredInvitation.canBeAcceptedBy('target@example.com'), isFalse);

      // Declined/Revoked invitation cannot be accepted
      final revokedInvitation = validInvitation.copyWith(status: InvitationStatus.revoked);
      expect(revokedInvitation.isValidPending, isFalse);
      expect(revokedInvitation.canBeAcceptedBy('target@example.com'), isFalse);
    });

    test('HouseholdInvitationModel serializes and displays honest EmailDeliveryStatus', () {
      final now = DateTime.now();
      final invQueued = HouseholdInvitationModel(
        invitationId: 'inv_queued',
        householdId: 'hh_123',
        householdName: 'Baker St Loft',
        invitedEmail: 'friend@example.com',
        invitedByUid: 'user_alice',
        invitedByName: 'Alice',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 7)),
        emailDeliveryStatus: EmailDeliveryStatus.queued,
      );

      expect(invQueued.emailDeliveryStatusLabel, 'Queued for Delivery');
      final mapQueued = invQueued.toMap();
      expect(mapQueued['email_delivery_status'], 'queued');

      final fromMapQueued = HouseholdInvitationModel.fromMap(mapQueued, 'inv_queued');
      expect(fromMapQueued.emailDeliveryStatus, EmailDeliveryStatus.queued);

      // Sent state
      final invSent = invQueued.copyWith(emailDeliveryStatus: EmailDeliveryStatus.sent);
      expect(invSent.emailDeliveryStatusLabel, 'Email Sent');

      // Failed state with error
      final invFailed = invQueued.copyWith(
        emailDeliveryStatus: EmailDeliveryStatus.failed,
        emailDeliveryError: 'SMTP server refused connection',
      );
      expect(invFailed.emailDeliveryStatusLabel, 'Email Queue Failed');
      expect(invFailed.emailDeliveryError, 'SMTP server refused connection');

      // Not configured (in-app fallback)
      final invNotConfig = invQueued.copyWith(emailDeliveryStatus: EmailDeliveryStatus.notConfigured);
      expect(invNotConfig.emailDeliveryStatusLabel, 'In-App Only');
    });
  });

  group('HouseholdService Authorization & Lifecycle Tests', () {
    const alice = UserModel(
      userId: 'user_alice',
      email: 'alice@example.com',
      name: 'Alice',
    );

    const bob = UserModel(
      userId: 'user_bob',
      email: 'bob@example.com',
      name: 'Bob',
    );

    const attacker = UserModel(
      userId: 'user_attacker',
      email: 'attacker@example.com',
      name: 'Attacker',
    );

    test('Create household initializes creator as owner and initial sole member', () async {
      final service = HouseholdService();
      final hh = await service.createHousehold(name: 'Sunny Villa', creator: alice);

      expect(hh.name, 'Sunny Villa');
      expect(hh.createdBy, 'user_alice');
      expect(hh.memberUids, ['user_alice']);
      expect(hh.memberEmails['user_alice'], 'alice@example.com');
      expect(hh.isOwner('user_alice'), isTrue);
    });

    test('Invitations must be sent by a member and validate recipient email', () async {
      final service = HouseholdService();
      final hh = await service.createHousehold(name: 'Sunny Villa', creator: alice);

      // Attacker is not a member and cannot send invitations
      expect(
        () => service.sendInvitation(
          household: hh,
          sender: attacker,
          recipientEmail: 'someone@example.com',
        ),
        throwsA(isA<Exception>()),
      );

      // Owner can send an invitation
      final invite = await service.sendInvitation(
        household: hh,
        sender: alice,
        recipientEmail: 'bob@example.com',
      );

      expect(invite.householdId, hh.householdId);
      expect(invite.invitedEmail, 'bob@example.com');
      expect(invite.status, InvitationStatus.pending);

      // Cannot self-invite
      expect(
        () => service.sendInvitation(
          household: hh,
          sender: alice,
          recipientEmail: 'alice@example.com',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('Accept invitation verifies recipient email and rejects unauthorized users', () async {
      final service = HouseholdService();
      final hh = await service.createHousehold(name: 'Sunny Villa', creator: alice);

      final invite = await service.sendInvitation(
        household: hh,
        sender: alice,
        recipientEmail: 'bob@example.com',
      );

      // Attacker attempts to accept Bob's invitation
      expect(
        () => service.acceptInvitation(invitationId: invite.invitationId, user: attacker),
        throwsA(isA<Exception>()),
      );

      // Bob accepts Bob's invitation
      final updatedHh = await service.acceptInvitation(
        invitationId: invite.invitationId,
        user: bob,
      );

      expect(updatedHh.isMember('user_bob'), isTrue);
      expect(updatedHh.memberEmails['user_bob'], 'bob@example.com');
      expect(updatedHh.memberUids.length, 2);
    });

    test('Leaving household revokes access and automatically unshares inventory', () async {
      final service = HouseholdService();
      final hh = await service.createHousehold(name: 'Sunny Villa', creator: alice);

      final invite = await service.sendInvitation(
        household: hh,
        sender: alice,
        recipientEmail: 'bob@example.com',
      );
      await service.acceptInvitation(invitationId: invite.invitationId, user: bob);

      // Bob adds a shared item
      final db = DatabaseService();
      const bobItem = VanityItemModel(
        vanityItemId: 'item_bob_1',
        productId: 'prod_1',
        userId: 'user_bob',
        isSharedWithHousehold: true,
        sharedHouseholdId: 'hh_123',
      );
      await db.addVanityItem(bobItem);

      // Re-link bobItem to current household id
      final actualBobItem = bobItem.copyWith(sharedHouseholdId: hh.householdId);
      await db.updateVanityItem(actualBobItem);

      // Alice sees Bob's shared item
      final sharedBefore = await service.getSharedHouseholdItems(
        householdId: hh.householdId,
        currentUserId: alice.userId,
      );
      expect(sharedBefore.any((i) => i.vanityItemId == 'item_bob_1'), isTrue);

      // Bob leaves household
      await service.leaveHousehold(householdId: hh.householdId, user: bob);

      // Alice no longer sees Bob's item
      final sharedAfter = await service.getSharedHouseholdItems(
        householdId: hh.householdId,
        currentUserId: alice.userId,
      );
      expect(sharedAfter.any((i) => i.vanityItemId == 'item_bob_1'), isFalse);

      // Bob's item has been stripped of sharedHouseholdId
      final updatedBobItems = await db.getVanityItems(bob.userId);
      final checkBobItem = updatedBobItems.firstWhere((i) => i.vanityItemId == 'item_bob_1');
      expect(checkBobItem.isSharedWithHousehold, isFalse);
      expect(checkBobItem.sharedHouseholdId, isNull);
    });
  });

  group('Inventory Privacy & Reversible Sharing Tests', () {
    test('Personal inventory items are private by default', () {
      const item = VanityItemModel(
        vanityItemId: 'item_101',
        productId: 'prod_101',
        userId: 'user_alice',
      );

      expect(item.isSharedWithHousehold, isFalse);
      expect(item.sharedHouseholdId, isNull);
    });

    test('Only item owner can toggle sharing', () async {
      final service = HouseholdService();
      const item = VanityItemModel(
        vanityItemId: 'item_alice_1',
        productId: 'prod_101',
        userId: 'user_alice',
      );
      await DatabaseService().addVanityItem(item);

      // Bob cannot toggle Alice's item
      expect(
        () => service.toggleItemSharing(
          item: item,
          share: true,
          householdId: 'hh_123',
          currentUserId: 'user_bob',
        ),
        throwsA(isA<Exception>()),
      );

      // Alice can share her item
      final sharedItem = await service.toggleItemSharing(
        item: item,
        share: true,
        householdId: 'hh_123',
        currentUserId: 'user_alice',
      );
      expect(sharedItem.isSharedWithHousehold, isTrue);
      expect(sharedItem.sharedHouseholdId, 'hh_123');

      // Alice can unshare her item
      final unsharedItem = await service.toggleItemSharing(
        item: sharedItem,
        share: false,
        householdId: null,
        currentUserId: 'user_alice',
      );
      expect(unsharedItem.isSharedWithHousehold, isFalse);
      expect(unsharedItem.sharedHouseholdId, isNull);
    });
  });

  group('Household Duplicate Detection Tests', () {
    final vanityProv = VanityProvider();

    final roommateProduct = ProductModel(
      productId: 'p_2',
      barcode: '987654321098',
      name: 'Hydrating Facial Cleanser',
      brand: 'CeraVe',
      categoryId: 'cleanser',
      paoMonths: 12,
      createdAt: DateTime.now(),
    );

    final roommateSharedItem = VanityItemModel(
      vanityItemId: 'item_roommate_1',
      productId: 'p_2',
      userId: 'user_bob',
      product: roommateProduct,
      status: 'active',
      isSharedWithHousehold: true,
      sharedHouseholdId: 'hh_123',
    );

    test('Exact barcode duplicate detected on personal and household items', () {
      final matches = vanityProv.checkHouseholdDuplicates(
        barcode: '987654321098',
        name: 'Different Name But Same Barcode',
        brand: 'Any Brand',
        sharedHouseholdItems: [roommateSharedItem],
        memberEmails: {'user_bob': 'bob@example.com'},
      );

      expect(matches.length, 1);
      final match = matches.first;
      expect(match.source, DuplicateSource.householdShared);
      expect(match.matchType, DuplicateMatchType.exactBarcode);
      expect(match.ownerEmail, 'bob@example.com');
      expect(match.isHousehold, isTrue);
    });

    test('Normalized brand and product name duplicate detected', () {
      final matches = vanityProv.checkHouseholdDuplicates(
        barcode: null,
        name: '  hydrating  facial  cleanser!  ',
        brand: 'CERAVE',
        sharedHouseholdItems: [roommateSharedItem],
        memberEmails: {'user_bob': 'bob@example.com'},
      );

      expect(matches.length, 1);
      final match = matches.first;
      expect(match.matchType, DuplicateMatchType.normalizedBrandAndName);
      expect(match.source, DuplicateSource.householdShared);
    });

    test('Substrings and different products of same brand are NOT flagged as duplicates', () {
      // Different cleanser from same brand
      final matches = vanityProv.checkHouseholdDuplicates(
        barcode: '555555555555',
        name: 'Foaming Facial Cleanser',
        brand: 'CeraVe',
        sharedHouseholdItems: [roommateSharedItem],
      );

      expect(matches, isEmpty);
    });

    test('Finished items and self-excluded items are ignored', () {
      final finishedItem = roommateSharedItem.copyWith(
        status: 'finished',
        finishedDate: DateTime.now(),
      );

      final matches = vanityProv.checkHouseholdDuplicates(
        barcode: '987654321098',
        name: 'Hydrating Facial Cleanser',
        brand: 'CeraVe',
        sharedHouseholdItems: [finishedItem],
      );

      expect(matches, isEmpty);

      // Self-excluded (e.g. during item edit)
      final selfMatches = vanityProv.checkHouseholdDuplicates(
        barcode: '987654321098',
        excludeItemId: 'item_roommate_1',
        sharedHouseholdItems: [roommateSharedItem],
      );

      expect(selfMatches, isEmpty);
    });
  });

  group('Session Isolation & Cache Purge Tests', () {
    test('Signing out purges HouseholdProvider in-memory state', () async {
      final provider = HouseholdProvider();
      const alice = UserModel(
        userId: 'user_alice',
        email: 'alice@example.com',
        name: 'Alice',
      );

      await provider.createHousehold('Alice Haven', alice);
      expect(provider.hasHousehold, isTrue);
      expect(provider.currentHousehold?.name, 'Alice Haven');

      // Wipe session
      provider.clear();

      expect(provider.hasHousehold, isFalse);
      expect(provider.currentHousehold, isNull);
      expect(provider.sharedItems, isEmpty);
      expect(provider.incomingInvitations, isEmpty);
      expect(provider.outgoingInvitations, isEmpty);
      expect(provider.memberEmails, isEmpty);
    });
  });
}
