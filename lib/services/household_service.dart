import 'dart:convert';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/household_invitation_model.dart';
import '../models/household_model.dart';
import '../models/product_model.dart';
import '../models/user_model.dart';
import '../models/vanity_item_model.dart';
import 'database_service.dart';
import 'invitation_email_client.dart';

/// The account's e-mail address is not verified, so invitations cannot be used yet.
class EmailNotVerifiedException implements Exception {
  final String email;
  const EmailNotVerifiedException(this.email);

  @override
  String toString() =>
      'Please verify your e-mail address ($email) first: open the link we sent you, then tap '
      '"I\'ve verified my e-mail" and try again. Your invitation stays waiting for you.';
}

/// Generates a clean 6-character room code prefixed with VAN- (e.g. VAN-7892).
String generateHouseholdRoomCode() {
  const chars = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  final rand = math.Random.secure();
  final code = List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
  return 'VAN-$code';
}

/// The one field-level update a departing member may make to a household document: only
/// their own member entries change (and, when the owner leaves, `created_by` moves to a
/// remaining member). All other fields, e.g. `last_join_invitation_id`, are left untouched.
/// Values are tagged so the Firestore layer can map them to field transforms.
Map<String, Object> householdLeaveUpdate(HouseholdModel household, String leavingUserId) {
  final remaining = household.memberUids.where((u) => u != leavingUserId).toList();
  final transfersOwnership = household.isOwner(leavingUserId) && remaining.isNotEmpty;
  return {
    'member_uids': const ArrayRemoveMarker(),
    'member_emails.$leavingUserId': const DeleteFieldMarker(),
    if (transfersOwnership) 'created_by': remaining.first,
  };
}

class ArrayRemoveMarker {
  const ArrayRemoveMarker();
}

class DeleteFieldMarker {
  const DeleteFieldMarker();
}

class HouseholdService {
  static final HouseholdService _instance = HouseholdService._internal();
  factory HouseholdService() => _instance;
  HouseholdService._internal();

  final _uuid = const Uuid();
  // Only with a signed-in Firebase account (see DatabaseService.cloudSessionActive).
  bool get isFirebaseAvailable => DatabaseService.cloudSessionActive;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  static const invitationValidity = Duration(days: 7);
  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// Test hook: replaces the backend email sender (and enables it without Firebase).
  @visibleForTesting
  InvitationEmailSender? debugEmailSender;
  InvitationEmailSender? _backendSender;

  /// The email sender in use, or null when emails cannot be sent (offline/local mode:
  /// the backend validates invitations against Firestore, so it needs Firebase).
  InvitationEmailSender? get _emailSender {
    if (debugEmailSender != null) return debugEmailSender;
    if (!isFirebaseAvailable) return null;
    return _backendSender ??= BackendInvitationEmailSender();
  }

  // Local caches for offline / test / fallback environments
  final Map<String, HouseholdModel> _localHouseholds = {};
  final Map<String, HouseholdInvitationModel> _localInvitations = {};

  Future<void> initialize() async {
    await _loadLocalCache();
  }

  static String normalizeEmail(String email) => email.trim().toLowerCase();

  static String _describeFirestoreError(Object e) {
    if (e is FirebaseException) {
      if (e.code == 'permission-denied') {
        return 'Permission denied by Firestore security rules.';
      }
      if (e.code == 'unavailable') {
        return 'Firestore is unreachable. Check your internet connection.';
      }
      return 'Firestore error (${e.code}): ${e.message ?? ''}'.trim();
    }
    return e.toString().replaceAll('Exception: ', '');
  }

  // =========================================================================
  // HOUSEHOLD CREATION & RETRIEVAL
  // =========================================================================

  /// Create a new household. Creator is automatically the owner.
  Future<HouseholdModel> createHousehold({
    required String name,
    required UserModel creator,
  }) async {
    if (creator.userId.isEmpty) {
      throw Exception('Unauthorized: Valid authenticated user required to create a household.');
    }

    final householdId = 'hh_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';
    final roomCode = generateHouseholdRoomCode();
    final newHousehold = HouseholdModel(
      householdId: householdId,
      name: name.trim().isNotEmpty ? name.trim() : 'My Household',
      createdBy: creator.userId,
      createdAt: DateTime.now(),
      memberUids: [creator.userId],
      memberEmails: {creator.userId: normalizeEmail(creator.email)},
      roomCode: roomCode,
    );

    if (isFirebaseAvailable) {
      try {
        final batch = _firestore.batch();
        batch.set(
          _firestore.collection('households').doc(householdId),
          newHousehold.toMap(),
        );
        batch.set(
          _firestore.collection('household_room_codes').doc(roomCode),
          {
            'room_code': roomCode,
            'household_id': householdId,
            'household_name': newHousehold.name,
            'created_by': creator.userId,
            'created_at': DateTime.now().toIso8601String(),
            'is_active': true,
          },
        );
        batch.set(
          _firestore.collection('users').doc(creator.userId),
          {'household_id': householdId},
          SetOptions(merge: true),
        );
        await batch.commit();
      } catch (e) {
        debugPrint('Firestore createHousehold error: $e');
        throw Exception('Could not create household: ${_describeFirestoreError(e)}');
      }
    }

    _localHouseholds[householdId] = newHousehold;
    await _saveLocalCache();
    return newHousehold;
  }

  /// Retrieve household by ID with strict membership authorization check.
  Future<HouseholdModel?> getHousehold(
    String householdId, {
    required String currentUserId,
  }) async {
    if (householdId.isEmpty || currentUserId.isEmpty) return null;

    HouseholdModel? household;

    if (isFirebaseAvailable) {
      try {
        final doc = await _firestore.collection('households').doc(householdId).get();
        if (doc.exists && doc.data() != null) {
          household = HouseholdModel.fromMap(doc.data()!, doc.id);
        }
      } on FirebaseException catch (e) {
        // Security rules deny reads to non-members; treat as "no access".
        if (e.code == 'permission-denied') return null;
        debugPrint('Firestore getHousehold error: $e');
        throw Exception('Could not load household: ${_describeFirestoreError(e)}');
      }
    } else {
      household = _localHouseholds[householdId];
    }

    if (household == null) return null;

    // Strict Authorization check: caller must be an authorized member
    if (!household.isMember(currentUserId)) {
      debugPrint('Security warning: user $currentUserId is not an authorized member of household $householdId');
      throw Exception('Unauthorized: You are not an authorized member of this household.');
    }

    // If household has no room code yet and current user is owner, generate and save one
    if (household.roomCode.isEmpty && household.isOwner(currentUserId)) {
      final code = generateHouseholdRoomCode();
      household = household.copyWith(roomCode: code);
      if (isFirebaseAvailable) {
        _firestore.collection('households').doc(householdId).update({'room_code': code}).catchError((_) {});
        _firestore.collection('household_room_codes').doc(code).set({
          'room_code': code,
          'household_id': householdId,
          'household_name': household.name,
          'created_by': currentUserId,
          'created_at': DateTime.now().toIso8601String(),
          'is_active': true,
        }).catchError((_) {});
      }
      _localHouseholds[householdId] = household;
    }

    return household;
  }

  /// Finds the household the user belongs to. The signed-in [UserModel] usually has no
  /// householdId, so this checks users/{uid}.household_id and then falls back to a
  /// membership query, so a household survives app restarts and screen reloads.
  Future<HouseholdModel?> findHouseholdForUser(UserModel user) async {
    if (user.userId.isEmpty) return null;

    Future<HouseholdModel?> tryId(String? id) async {
      if (id == null || id.isEmpty) return null;
      try {
        return await getHousehold(id, currentUserId: user.userId);
      } catch (e) {
        if (e.toString().contains('Unauthorized')) return null;
        rethrow;
      }
    }

    final direct = await tryId(user.householdId);
    if (direct != null) return direct;

    if (isFirebaseAvailable) {
      try {
        final userDoc = await _firestore.collection('users').doc(user.userId).get();
        final fromUserDoc = await tryId(userDoc.data()?['household_id']?.toString());
        if (fromUserDoc != null) return fromUserDoc;

        final query = await _firestore
            .collection('households')
            .where('member_uids', arrayContains: user.userId)
            .limit(1)
            .get();
        if (query.docs.isEmpty) return null;
        final hh = HouseholdModel.fromMap(query.docs.first.data(), query.docs.first.id);
        // Repair the pointer for next time (best effort).
        _firestore
            .collection('users')
            .doc(user.userId)
            .set({'household_id': hh.householdId}, SetOptions(merge: true))
            .catchError((Object e) => debugPrint('Could not repair household pointer: $e'));
        return hh;
      } on FirebaseException catch (e) {
        debugPrint('Firestore findHouseholdForUser error: $e');
        throw Exception('Could not load your household: ${_describeFirestoreError(e)}');
      }
    }

    for (final hh in _localHouseholds.values) {
      if (hh.isMember(user.userId)) return hh;
    }
    return null;
  }

  // =========================================================================
  // INVITATIONS WORKFLOW
  // =========================================================================

  /// Create an invitation bound to the recipient's email address and ask the backend
  /// to email it. The returned model's [EmailDeliveryStatus] reflects what actually
  /// happened: `sent` only when Gmail's SMTP server accepted the message.
  Future<HouseholdInvitationModel> sendInvitation({
    required HouseholdModel household,
    required UserModel sender,
    required String recipientEmail,
  }) async {
    final normalizedRecipient = normalizeEmail(recipientEmail);

    // 1. Authorization check: sender must be a member AND the household owner
    if (!household.isMember(sender.userId)) {
      throw Exception('Unauthorized: Only household members can invite others.');
    }
    if (!household.isOwner(sender.userId)) {
      throw Exception('Unauthorized: Only the household owner can send invitations.');
    }

    // 2. Email validation
    if (normalizedRecipient.length > 254 || !_emailRegex.hasMatch(normalizedRecipient)) {
      throw Exception('Invalid email address format.');
    }

    // 3. Disallow self-invitation
    if (normalizedRecipient == normalizeEmail(sender.email)) {
      throw Exception('Cannot invite yourself to a household.');
    }

    // 4. Disallow inviting an existing member
    if (household.memberEmails.values.any((e) => normalizeEmail(e) == normalizedRecipient)) {
      throw Exception('User with this email is already a member of this household.');
    }

    // 5. Check duplicate active pending invitation
    final existingOutgoing = await getOutgoingInvitations(household.householdId, currentUserId: sender.userId);
    final hasPending = existingOutgoing.any(
      (inv) => inv.invitedEmail == normalizedRecipient && inv.isValidPending,
    );
    if (hasPending) {
      throw Exception('A pending invitation has already been sent to this email. Use "Resend email" on it instead.');
    }

    final invitationId = 'inv_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';
    final emailSender = _emailSender;
    final now = DateTime.now();

    var invitation = HouseholdInvitationModel(
      invitationId: invitationId,
      householdId: household.householdId,
      householdName: household.name,
      invitedEmail: normalizedRecipient,
      invitedByUid: sender.userId,
      invitedByName: sender.name,
      createdAt: now,
      expiresAt: now.add(invitationValidity),
      status: InvitationStatus.pending,
      emailDeliveryStatus: emailSender != null ? EmailDeliveryStatus.queued : EmailDeliveryStatus.notConfigured,
      emailDeliveryError: emailSender != null ? null : 'Email delivery needs Firebase and the local invitation server.',
    );

    // 6. Persist the invitation first; it is the source of truth for in-app acceptance.
    if (isFirebaseAvailable) {
      try {
        await _firestore
            .collection('household_invitations')
            .doc(invitationId)
            .set(invitation.toMap());
      } catch (e) {
        debugPrint('Firestore sendInvitation error: $e');
        throw Exception('Could not save the invitation: ${_describeFirestoreError(e)}');
      }
    }
    _localInvitations[invitationId] = invitation;
    await _saveLocalCache();

    // 7. Ask the trusted backend to email it (it re-validates everything server-side).
    if (emailSender != null) {
      invitation = await _deliverEmail(invitation, emailSender, resend: false);
    }
    return invitation;
  }

  /// Retry the email for an existing pending invitation (inviter only).
  Future<HouseholdInvitationModel> resendInvitationEmail({
    required HouseholdInvitationModel invitation,
    required UserModel user,
  }) async {
    if (invitation.invitedByUid != user.userId) {
      throw Exception('Unauthorized: Only the person who sent this invitation can resend it.');
    }
    if (!invitation.isValidPending) {
      throw Exception('Only pending, unexpired invitations can be emailed.');
    }
    final emailSender = _emailSender;
    if (emailSender == null) {
      throw Exception('Email delivery is unavailable in offline mode. The recipient can still accept in-app.');
    }
    return _deliverEmail(invitation, emailSender, resend: true);
  }

  Future<HouseholdInvitationModel> _deliverEmail(
    HouseholdInvitationModel invitation,
    InvitationEmailSender emailSender, {
    required bool resend,
  }) async {
    InvitationEmailResult result;
    try {
      result = await emailSender.sendInvitationEmail(invitation.invitationId, resend: resend);
    } catch (e) {
      result = InvitationEmailResult(status: EmailDeliveryStatus.failed, error: e.toString());
    }

    final updated = result.status == EmailDeliveryStatus.sent
        ? invitation.copyWith(
            emailDeliveryStatus: EmailDeliveryStatus.sent,
            clearEmailDeliveryError: true,
            emailProviderResponse: result.providerResponse,
          )
        : invitation.copyWith(
            emailDeliveryStatus: result.status ?? invitation.emailDeliveryStatus,
            emailDeliveryError: result.error,
          );

    // The backend records its own outcome. If it could not be reached at all, record the
    // failure ourselves so the invitation doesn't stay "queued" forever.
    if (isFirebaseAvailable &&
        result.status == EmailDeliveryStatus.failed &&
        (result.error ?? '').contains('Could not reach')) {
      try {
        await _firestore.collection('household_invitations').doc(invitation.invitationId).update({
          'email_delivery_status': EmailDeliveryStatus.failed.name,
          'email_delivery_error': result.error,
        });
      } catch (e) {
        debugPrint('Could not record email failure: $e');
      }
    }

    _localInvitations[invitation.invitationId] = updated;
    await _saveLocalCache();
    return updated;
  }

  /// Re-read an invitation to pick up the delivery status recorded by the backend.
  Future<HouseholdInvitationModel> checkInvitationDeliveryStatus(HouseholdInvitationModel invitation) async {
    if (!isFirebaseAvailable) return invitation;
    try {
      final doc = await _firestore.collection('household_invitations').doc(invitation.invitationId).get();
      if (!doc.exists || doc.data() == null) return invitation;
      final fresh = HouseholdInvitationModel.fromMap(doc.data()!, doc.id);
      _localInvitations[fresh.invitationId] = fresh;
      return fresh;
    } catch (e) {
      debugPrint('Error checking delivery status: $e');
      return invitation;
    }
  }

  /// Get active pending invitations for the authenticated user's email.
  /// Throws when Firestore cannot be queried so the UI can show the error.
  Future<List<HouseholdInvitationModel>> getIncomingInvitations(String userEmail) async {
    final normalizedEmail = normalizeEmail(userEmail);
    if (normalizedEmail.isEmpty) return [];

    if (isFirebaseAvailable) {
      try {
        final query = await _firestore
            .collection('household_invitations')
            .where('invited_email', isEqualTo: normalizedEmail)
            .where('status', isEqualTo: 'pending')
            .get();

        return query.docs
            .map((d) => HouseholdInvitationModel.fromMap(d.data(), d.id))
            .where((inv) => inv.isValidPending)
            .toList();
      } catch (e) {
        debugPrint('Firestore getIncomingInvitations error: $e');
        throw Exception('Could not load your invitations: ${_describeFirestoreError(e)}');
      }
    }

    return _localInvitations.values
        .where((inv) => inv.invitedEmail == normalizedEmail && inv.isValidPending)
        .toList();
  }

  /// Get invitations sent from a household (for owner/members to inspect/revoke).
  Future<List<HouseholdInvitationModel>> getOutgoingInvitations(
    String householdId, {
    required String currentUserId,
  }) async {
    if (householdId.isEmpty) return [];

    if (isFirebaseAvailable) {
      try {
        final query = await _firestore
            .collection('household_invitations')
            .where('household_id', isEqualTo: householdId)
            .get();

        return query.docs
            .map((d) => HouseholdInvitationModel.fromMap(d.data(), d.id))
            .toList();
      } catch (e) {
        debugPrint('Firestore getOutgoingInvitations error: $e');
        throw Exception('Could not load sent invitations: ${_describeFirestoreError(e)}');
      }
    }

    return _localInvitations.values
        .where((inv) => inv.householdId == householdId)
        .toList();
  }

  Future<HouseholdInvitationModel?> _fetchInvitation(String invitationId) async {
    if (!isFirebaseAvailable) return _localInvitations[invitationId];
    try {
      final doc = await _firestore.collection('household_invitations').doc(invitationId).get();
      if (!doc.exists || doc.data() == null) return null;
      return HouseholdInvitationModel.fromMap(doc.data()!, doc.id);
    } catch (e) {
      debugPrint('Firestore invitation fetch error: $e');
      throw Exception('Could not load the invitation: ${_describeFirestoreError(e)}');
    }
  }

  /// Accept an invitation with recipient email and validity checks.
  /// Accepting the same invitation twice is harmless and does not duplicate membership.
  /// The account's e-mail must be verified: the invitation is bound to that address, and
  /// the Firestore rules refuse unverified accounts. Nothing is read or written otherwise,
  /// so the invitation stays pending.
  Future<HouseholdModel> acceptInvitation({
    required String invitationId,
    required UserModel user,
  }) async {
    if (!user.emailVerified) throw EmailNotVerifiedException(user.email);
    final invitation = await _fetchInvitation(invitationId);
    if (invitation == null) {
      throw Exception('Invitation not found.');
    }

    // Recipient Email authorization check (before revealing anything else)
    if (normalizeEmail(user.email) != invitation.invitedEmail) {
      throw Exception('Unauthorized: This invitation was issued for ${invitation.invitedEmail}, but you are signed in as ${user.email}.');
    }

    // Repeated acceptance: already accepted and already a member -> idempotent success.
    if (invitation.status == InvitationStatus.accepted) {
      final existing = await getHousehold(invitation.householdId, currentUserId: user.userId)
          .catchError((Object _) => null);
      if (existing != null && existing.isMember(user.userId)) return existing;
    }

    if (invitation.status != InvitationStatus.pending) {
      throw Exception('Invitation is no longer pending (${invitation.status.name}).');
    }
    if (invitation.isExpired) {
      throw Exception('Invitation has expired. Ask the household owner to send a new one.');
    }
    if (!invitation.canBeAcceptedBy(user.email)) {
      throw Exception('Unauthorized: This invitation cannot be accepted by this account.');
    }

    // One household per user.
    final current = await findHouseholdForUser(user);
    if (current != null && current.householdId != invitation.householdId) {
      throw Exception('You are already in "${current.name}". Leave it before joining another household.');
    }

    final email = normalizeEmail(user.email);
    final respondedAt = DateTime.now().toIso8601String();

    if (isFirebaseAvailable) {
      try {
        // The recipient cannot read the household before joining, so membership is added
        // with field transforms (no read needed). arrayUnion keeps membership unique.
        final batch = _firestore.batch();
        batch.update(_firestore.collection('household_invitations').doc(invitationId), {
          'status': InvitationStatus.accepted.name,
          'responded_at': respondedAt,
          'accepted_by_uid': user.userId,
        });
        batch.update(_firestore.collection('households').doc(invitation.householdId), {
          'member_uids': FieldValue.arrayUnion([user.userId]),
          'member_emails.${user.userId}': email,
          'last_join_invitation_id': invitationId,
        });
        batch.set(
          _firestore.collection('users').doc(user.userId),
          {'household_id': invitation.householdId},
          SetOptions(merge: true),
        );
        await batch.commit();
      } on FirebaseException catch (e) {
        debugPrint('Firestore acceptInvitation commit error: $e');
        if (e.code == 'not-found') throw Exception('Household no longer exists.');
        throw Exception('Could not join the household: ${_describeFirestoreError(e)}');
      }

      final joined = await getHousehold(invitation.householdId, currentUserId: user.userId);
      if (joined == null) throw Exception('Joined, but the household could not be loaded. Pull to refresh.');
      _localHouseholds[joined.householdId] = joined;
      _localInvitations[invitationId] = invitation.copyWith(status: InvitationStatus.accepted);
      await _saveLocalCache();
      return joined;
    }

    final household = _localHouseholds[invitation.householdId];
    if (household == null) {
      throw Exception('Household no longer exists.');
    }
    final updatedUids = List<String>.from(household.memberUids);
    if (!updatedUids.contains(user.userId)) updatedUids.add(user.userId);
    final updatedEmails = Map<String, String>.from(household.memberEmails)..[user.userId] = email;
    final updatedHousehold = household.copyWith(memberUids: updatedUids, memberEmails: updatedEmails);

    _localHouseholds[household.householdId] = updatedHousehold;
    _localInvitations[invitationId] = invitation.copyWith(status: InvitationStatus.accepted);
    await _saveLocalCache();
    return updatedHousehold;
  }

  /// Decline an invitation (only recipient can decline).
  Future<void> declineInvitation({
    required String invitationId,
    required UserModel user,
  }) async {
    if (!user.emailVerified) throw EmailNotVerifiedException(user.email);
    final invitation = await _fetchInvitation(invitationId);
    if (invitation == null) throw Exception('Invitation not found.');

    if (normalizeEmail(user.email) != invitation.invitedEmail) {
      throw Exception('Unauthorized: You can only decline invitations sent to your email.');
    }
    if (invitation.status != InvitationStatus.pending) {
      throw Exception('Invitation is no longer pending (${invitation.status.name}).');
    }

    if (isFirebaseAvailable) {
      try {
        await _firestore.collection('household_invitations').doc(invitationId).update({
          'status': InvitationStatus.declined.name,
          'responded_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        throw Exception('Could not decline the invitation: ${_describeFirestoreError(e)}');
      }
    }
    _localInvitations[invitationId] = invitation.copyWith(status: InvitationStatus.declined);
    await _saveLocalCache();
  }

  /// Revoke an invitation (only household owner or sender can revoke).
  Future<void> revokeInvitation({
    required String invitationId,
    required UserModel authorizedUser,
  }) async {
    final invitation = await _fetchInvitation(invitationId);
    if (invitation == null) throw Exception('Invitation not found.');

    if (authorizedUser.userId != invitation.invitedByUid) {
      // Check if user is household owner
      HouseholdModel? hh;
      try {
        hh = await getHousehold(invitation.householdId, currentUserId: authorizedUser.userId);
      } catch (_) {
        hh = null;
      }
      if (hh == null || hh.createdBy != authorizedUser.userId) {
        throw Exception('Unauthorized: Only the inviter or household owner can revoke this invitation.');
      }
    }

    if (isFirebaseAvailable) {
      try {
        await _firestore.collection('household_invitations').doc(invitationId).update({
          'status': InvitationStatus.revoked.name,
          'responded_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        throw Exception('Could not revoke the invitation: ${_describeFirestoreError(e)}');
      }
    }
    _localInvitations[invitationId] = invitation.copyWith(status: InvitationStatus.revoked);
    await _saveLocalCache();
  }

  /// Leave a household. If owner leaves and other members remain, ownership transfers to next member.
  Future<void> leaveHousehold({
    required String householdId,
    required UserModel user,
  }) async {
    HouseholdModel? household;
    if (isFirebaseAvailable) {
      final doc = await _firestore.collection('households').doc(householdId).get();
      if (doc.exists && doc.data() != null) {
        household = HouseholdModel.fromMap(doc.data()!, doc.id);
      }
    } else {
      household = _localHouseholds[householdId];
    }

    if (household == null) return;

    if (!household.isMember(user.userId)) {
      throw Exception('Unauthorized: User is not a member of this household.');
    }

    final updatedUids = List<String>.from(household.memberUids)..remove(user.userId);
    final updatedEmails = Map<String, String>.from(household.memberEmails)..remove(user.userId);

    String newOwner = household.createdBy;
    if (household.isOwner(user.userId)) {
      newOwner = updatedUids.isNotEmpty ? updatedUids.first : '';
    }

    // Revoke sharing on all items owned by this user in this household (while still a member).
    await unshareAllItemsForUser(user.userId, householdId);

    if (updatedUids.isEmpty) {
      // Household is empty, delete it
      if (isFirebaseAvailable) {
        final batch = _firestore.batch();
        batch.delete(_firestore.collection('households').doc(householdId));
        if (household.roomCode.isNotEmpty) {
          batch.delete(_firestore.collection('household_room_codes').doc(household.roomCode));
        }
        await batch.commit();
      }
      _localHouseholds.remove(householdId);
    } else {
      final updatedHousehold = household.copyWith(
        createdBy: newOwner,
        memberUids: updatedUids,
        memberEmails: updatedEmails,
      );
      if (isFirebaseAvailable) {
        // Field-level update: rewriting the whole document would drop fields the model does
        // not carry (e.g. last_join_invitation_id), which the security rules reject for a
        // leaving member. Only the leaver's own entries (and, for the owner, created_by) change.
        await _firestore.collection('households').doc(householdId).update({
          for (final e in householdLeaveUpdate(household, user.userId).entries)
            e.key: switch (e.value) {
              ArrayRemoveMarker() => FieldValue.arrayRemove([user.userId]),
              DeleteFieldMarker() => FieldValue.delete(),
              final Object v => v,
            },
        });
      }
      _localHouseholds[householdId] = updatedHousehold;
    }

    // Clear household_id on user record
    if (isFirebaseAvailable) {
      await _firestore.collection('users').doc(user.userId).set({'household_id': FieldValue.delete()}, SetOptions(merge: true));
    }

    await _saveLocalCache();
  }

  /// Join a household directly using its room code (e.g. VAN-7892).
  Future<HouseholdModel> joinHouseholdByRoomCode({
    required String roomCode,
    required UserModel user,
  }) async {
    if (user.userId.isEmpty) {
      throw Exception('Sign in required to join a household.');
    }
    final cleanCode = roomCode.trim().toUpperCase();
    if (cleanCode.isEmpty) {
      throw Exception('Please enter a valid room code.');
    }

    // Check if user is already in a household
    final current = await findHouseholdForUser(user);
    if (current != null) {
      throw Exception('You are already in "${current.name}". Leave it before joining another household.');
    }

    final email = normalizeEmail(user.email);
    String targetHouseholdId = '';
    String targetHouseholdName = '';

    if (isFirebaseAvailable) {
      try {
        final codeDoc = await _firestore.collection('household_room_codes').doc(cleanCode).get();
        if (!codeDoc.exists || codeDoc.data() == null) {
          throw Exception('Room code "$cleanCode" not found. Please verify the code with the household owner.');
        }
        final data = codeDoc.data()!;
        if (data['is_active'] != true) {
          throw Exception('This room code is no longer active.');
        }
        targetHouseholdId = data['household_id']?.toString() ?? '';
        targetHouseholdName = data['household_name']?.toString() ?? 'Household';
        if (targetHouseholdId.isEmpty) {
          throw Exception('Invalid room code reference.');
        }

        // Add member via batch update
        final batch = _firestore.batch();
        batch.update(_firestore.collection('households').doc(targetHouseholdId), {
          'member_uids': FieldValue.arrayUnion([user.userId]),
          'member_emails.${user.userId}': email,
          'last_join_room_code': cleanCode,
        });
        batch.set(
          _firestore.collection('users').doc(user.userId),
          {'household_id': targetHouseholdId},
          SetOptions(merge: true),
        );
        await batch.commit();
      } on FirebaseException catch (e) {
        debugPrint('Firestore joinHouseholdByRoomCode error: $e');
        if (e.code == 'not-found') throw Exception('Household no longer exists.');
        throw Exception('Could not join household: ${_describeFirestoreError(e)}');
      }

      final joined = await getHousehold(targetHouseholdId, currentUserId: user.userId);
      if (joined == null) {
        throw Exception('Joined "$targetHouseholdName", but details could not be loaded. Pull to refresh.');
      }
      _localHouseholds[joined.householdId] = joined;
      await _saveLocalCache();
      return joined;
    }

    // Local / Offline fallback for tests
    HouseholdModel? localTarget;
    for (final hh in _localHouseholds.values) {
      if (hh.roomCode.toUpperCase() == cleanCode) {
        localTarget = hh;
        break;
      }
    }
    if (localTarget == null) {
      throw Exception('Room code "$cleanCode" not found. Please verify the code with the household owner.');
    }
    final updatedUids = List<String>.from(localTarget.memberUids);
    if (!updatedUids.contains(user.userId)) updatedUids.add(user.userId);
    final updatedEmails = Map<String, String>.from(localTarget.memberEmails)..[user.userId] = email;
    final updated = localTarget.copyWith(memberUids: updatedUids, memberEmails: updatedEmails);
    _localHouseholds[localTarget.householdId] = updated;
    await _saveLocalCache();
    return updated;
  }

  /// Regenerate the room code for a household (only the owner can do this).
  Future<String> regenerateRoomCode({
    required HouseholdModel household,
    required UserModel owner,
  }) async {
    if (!household.isOwner(owner.userId)) {
      throw Exception('Unauthorized: Only the household owner can regenerate the room code.');
    }
    final newCode = generateHouseholdRoomCode();
    final oldCode = household.roomCode;

    if (isFirebaseAvailable) {
      final batch = _firestore.batch();
      if (oldCode.isNotEmpty) {
        batch.delete(_firestore.collection('household_room_codes').doc(oldCode));
      }
      batch.set(_firestore.collection('household_room_codes').doc(newCode), {
        'room_code': newCode,
        'household_id': household.householdId,
        'household_name': household.name,
        'created_by': owner.userId,
        'created_at': DateTime.now().toIso8601String(),
        'is_active': true,
      });
      batch.update(_firestore.collection('households').doc(household.householdId), {
        'room_code': newCode,
      });
      await batch.commit();
    }

    final updated = household.copyWith(roomCode: newCode);
    _localHouseholds[household.householdId] = updated;
    await _saveLocalCache();
    return newCode;
  }

  /// Remove a member from the household (only the household owner can do this).
  Future<void> removeMember({
    required String householdId,
    required String memberUidToRemove,
    required UserModel owner,
  }) async {
    if (memberUidToRemove == owner.userId) {
      throw Exception('As owner, you cannot remove yourself. Use "Leave" to transfer ownership or delete the household.');
    }

    HouseholdModel? household;
    if (isFirebaseAvailable) {
      final doc = await _firestore.collection('households').doc(householdId).get();
      if (doc.exists && doc.data() != null) {
        household = HouseholdModel.fromMap(doc.data()!, doc.id);
      }
    } else {
      household = _localHouseholds[householdId];
    }

    if (household == null) throw Exception('Household not found.');

    if (!household.isOwner(owner.userId)) {
      throw Exception('Unauthorized: Only the household owner can remove members.');
    }

    if (!household.isMember(memberUidToRemove)) {
      throw Exception('User is not a member of this household.');
    }

    // Revoke sharing on all items owned by the removed user in this household
    await unshareAllItemsForUser(memberUidToRemove, householdId);

    final updatedUids = List<String>.from(household.memberUids)..remove(memberUidToRemove);
    final updatedEmails = Map<String, String>.from(household.memberEmails)..remove(memberUidToRemove);

    final updatedHousehold = household.copyWith(
      memberUids: updatedUids,
      memberEmails: updatedEmails,
    );

    if (isFirebaseAvailable) {
      final batch = _firestore.batch();
      batch.update(_firestore.collection('households').doc(householdId), {
        'member_uids': FieldValue.arrayRemove([memberUidToRemove]),
        'member_emails.$memberUidToRemove': FieldValue.delete(),
      });
      batch.set(
        _firestore.collection('users').doc(memberUidToRemove),
        {'household_id': FieldValue.delete()},
        SetOptions(merge: true),
      );
      await batch.commit();
    }

    _localHouseholds[householdId] = updatedHousehold;
    await _saveLocalCache();
  }

  // =========================================================================
  // SHARED ITEMS & PRIVACY BOUNDARIES
  // =========================================================================

  /// Fetch items explicitly shared by other household members.
  Future<List<VanityItemModel>> getSharedHouseholdItems({
    required String householdId,
    required String currentUserId,
  }) async {
    if (householdId.isEmpty || currentUserId.isEmpty) return [];

    // Verify current user is actually a member of the household
    final hh = await getHousehold(householdId, currentUserId: currentUserId);
    if (hh == null) return [];

    if (isFirebaseAvailable) {
      try {
        final query = await _firestore
            .collection('vanity_items')
            .where('shared_household_id', isEqualTo: householdId)
            .where('is_shared_with_household', isEqualTo: true)
            .get();

        final items = <VanityItemModel>[];
        for (var doc in query.docs) {
          final data = doc.data();
          if (data['user_id'] != currentUserId && data['status'] != 'finished') {
            ProductModel? product;
            if (data['product'] != null) {
              product = ProductModel.fromMap(Map<String, dynamic>.from(data['product']));
            } else if (data['product_id'] != null) {
              product = await DatabaseService().getProductById(data['product_id']);
            }
            items.add(VanityItemModel.fromMap(data, doc.id).copyWith(product: product));
          }
        }
        return items;
      } catch (e) {
        debugPrint('Firestore getSharedHouseholdItems error: $e');
        throw Exception('Could not load shared items: ${_describeFirestoreError(e)}');
      }
    }

    // Local fallback
    // Local vanity items stored in DatabaseService
    return DatabaseService().getAllCachedItems().where((item) {
      return item.isSharedWithHousehold &&
          item.sharedHouseholdId == householdId &&
          item.userId != currentUserId &&
          item.status != 'finished' &&
          item.finishedDate == null;
    }).toList();
  }

  /// Toggle item sharing status. Enforces that only the owner can share/unshare their item.
  Future<VanityItemModel> toggleItemSharing({
    required VanityItemModel item,
    required bool share,
    required String? householdId,
    required String currentUserId,
  }) async {
    if (item.userId != currentUserId) {
      throw Exception('Unauthorized: You can only change the sharing status of items you own.');
    }

    if (share && (householdId == null || householdId.isEmpty)) {
      throw Exception('Cannot share item without an active household.');
    }

    final updated = item.copyWith(
      isSharedWithHousehold: share,
      sharedHouseholdId: share ? householdId : null,
      clearSharedHouseholdId: !share,
    );

    return await DatabaseService().updateVanityItem(updated);
  }

  /// Unshare all items owned by a user when they leave a household
  Future<void> unshareAllItemsForUser(String userId, String householdId) async {
    final db = DatabaseService();
    final items = await db.getVanityItems(userId);
    for (final item in items) {
      if (item.sharedHouseholdId == householdId) {
        final unshared = item.copyWith(
          isSharedWithHousehold: false,
          clearSharedHouseholdId: true,
        );
        await db.updateVanityItem(unshared);
      }
    }
  }

  // =========================================================================
  // LOCAL CACHE SERIALIZATION
  // =========================================================================

  Future<void> _loadLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hhStr = prefs.getString('local_households');
      if (hhStr != null) {
        final Map<String, dynamic> map = jsonDecode(hhStr);
        _localHouseholds.clear();
        map.forEach((k, v) {
          _localHouseholds[k] = HouseholdModel.fromMap(Map<String, dynamic>.from(v), k);
        });
      }

      final invStr = prefs.getString('local_household_invitations');
      if (invStr != null) {
        final Map<String, dynamic> map = jsonDecode(invStr);
        _localInvitations.clear();
        map.forEach((k, v) {
          _localInvitations[k] = HouseholdInvitationModel.fromMap(Map<String, dynamic>.from(v), k);
        });
      }
    } catch (e) {
      debugPrint('Load local household cache error: $e');
    }
  }

  Future<void> _saveLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hhMap = _localHouseholds.map((k, v) => MapEntry(k, v.toMap()));
      await prefs.setString('local_households', jsonEncode(hhMap));

      final invMap = _localInvitations.map((k, v) => MapEntry(k, v.toMap()));
      await prefs.setString('local_household_invitations', jsonEncode(invMap));
    } catch (e) {
      debugPrint('Save local household cache error: $e');
    }
  }

  /// Clear in-memory caches on user sign out
  void clearLocalMemory() {
    _localHouseholds.clear();
    _localInvitations.clear();
  }
}
