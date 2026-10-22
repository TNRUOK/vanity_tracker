import 'package:flutter/foundation.dart';
import '../models/household_invitation_model.dart';
import '../models/household_model.dart';
import '../models/user_model.dart';
import '../models/vanity_item_model.dart';
import '../services/database_service.dart';
import '../services/household_service.dart';
import 'vanity_provider.dart';

class HouseholdProvider extends ChangeNotifier {
  final HouseholdService _service = HouseholdService();

  HouseholdModel? _currentHousehold;
  List<VanityItemModel> _sharedItems = [];
  List<HouseholdInvitationModel> _incomingInvitations = [];
  List<HouseholdInvitationModel> _outgoingInvitations = [];
  bool _isLoading = false;
  String? _errorMessage;
  String? _invitationsError;
  bool _isSharedDataAvailable = true;
  HouseholdInvitationModel? _lastSentInvitation;

  HouseholdModel? get currentHousehold => _currentHousehold;
  List<VanityItemModel> get sharedItems => _sharedItems;
  List<HouseholdInvitationModel> get incomingInvitations => _incomingInvitations;

  /// Pending (not accepted/declined/revoked/expired) invitations sent from this household.
  List<HouseholdInvitationModel> get outgoingInvitations => _outgoingInvitations;
  bool get hasHousehold => _currentHousehold != null;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Error loading incoming invitations (e.g. Firestore permission or network failure).
  String? get invitationsError => _invitationsError;
  bool get isSharedDataAvailable => _isSharedDataAvailable;

  /// The signed-in account's e-mail is not verified yet, so invitations are hidden.
  bool get needsEmailVerification => _needsEmailVerification;
  bool _needsEmailVerification = false;
  Map<String, String> get memberEmails => _currentHousehold?.memberEmails ?? {};

  /// The invitation created by the most recent successful [inviteMember] call,
  /// including its real email delivery outcome.
  HouseholdInvitationModel? get lastSentInvitation => _lastSentInvitation;

  static String _clean(Object e) => e.toString().replaceAll('Exception: ', '');

  /// Alias for loadHouseholdData
  Future<void> loadHousehold(UserModel user) => loadHouseholdData(user);

  /// Load household details, members, shared items, and pending invitations for current user
  Future<void> loadHouseholdData(UserModel user) async {
    _isLoading = true;
    _errorMessage = null;
    _invitationsError = null;
    notifyListeners();

    try {
      await _service.initialize();

      // 1. Load incoming invitations for this user's email. Invitations are bound to a
      // verified address: an unverified account is not shown them (the rules would refuse
      // the query anyway) and is asked to verify instead. Nothing is changed meanwhile.
      _needsEmailVerification = !user.emailVerified;
      if (_needsEmailVerification) {
        _incomingInvitations = [];
      } else if (user.email.isNotEmpty) {
        try {
          _incomingInvitations = await _service.getIncomingInvitations(user.email);
        } catch (e) {
          _incomingInvitations = [];
          _invitationsError = _clean(e);
        }
      } else {
        _incomingInvitations = [];
      }

      // 2. Find the user's household (UserModel from sign-in carries no householdId)
      _currentHousehold = await _service.findHouseholdForUser(user);

      if (_currentHousehold != null) {
        await _loadHouseholdDetails(user);
      } else {
        _sharedItems = [];
        _outgoingInvitations = [];
      }
    } catch (e) {
      _errorMessage = _clean(e);
      debugPrint('Error loading household data: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadHouseholdDetails(UserModel user) async {
    final hh = _currentHousehold!;
    try {
      _sharedItems = await _service.getSharedHouseholdItems(
        householdId: hh.householdId,
        currentUserId: user.userId,
      );
      _isSharedDataAvailable = true;
    } catch (e) {
      debugPrint('Failed to load shared items: $e');
      _sharedItems = [];
      _isSharedDataAvailable = false;
    }

    try {
      final all = await _service.getOutgoingInvitations(
        hh.householdId,
        currentUserId: user.userId,
      );
      _outgoingInvitations = all.where((i) => i.isValidPending).toList();
    } catch (e) {
      debugPrint('Failed to load outgoing invitations: $e');
      _outgoingInvitations = [];
      _errorMessage ??= _clean(e);
    }
  }

  /// Create a new household
  Future<bool> createHousehold(String name, UserModel user) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _currentHousehold = await _service.createHousehold(name: name, creator: user);
      _sharedItems = [];
      _outgoingInvitations = [];
      _isSharedDataAvailable = true;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _clean(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Create an invitation and request its email. Returns true when the invitation was
  /// saved; check [lastSentInvitation] for whether the email itself was sent.
  Future<bool> inviteMember(String email, UserModel user) async {
    if (_currentHousehold == null) return false;

    _isLoading = true;
    _errorMessage = null;
    _lastSentInvitation = null;
    notifyListeners();

    try {
      final invitation = await _service.sendInvitation(
        household: _currentHousehold!,
        sender: user,
        recipientEmail: email,
      );
      _lastSentInvitation = invitation;
      _outgoingInvitations.add(invitation);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _clean(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Retry sending the email for a pending invitation. Returns the updated invitation,
  /// or null with [errorMessage] set when the request could not be made.
  Future<HouseholdInvitationModel?> resendInvitationEmail(String invitationId, UserModel user) async {
    final index = _outgoingInvitations.indexWhere((i) => i.invitationId == invitationId);
    if (index < 0) return null;
    _errorMessage = null;
    try {
      final updated = await _service.resendInvitationEmail(
        invitation: _outgoingInvitations[index],
        user: user,
      );
      final i = _outgoingInvitations.indexWhere((x) => x.invitationId == invitationId);
      if (i >= 0) _outgoingInvitations[i] = updated;
      notifyListeners();
      return updated;
    } catch (e) {
      _errorMessage = _clean(e);
      notifyListeners();
      return null;
    }
  }

  /// Refresh delivery status for all outgoing invitations from the backend
  Future<void> refreshDeliveryStatuses() async {
    bool changed = false;
    for (int i = 0; i < _outgoingInvitations.length; i++) {
      final updated = await _service.checkInvitationDeliveryStatus(_outgoingInvitations[i]);
      if (updated.emailDeliveryStatus != _outgoingInvitations[i].emailDeliveryStatus) {
        _outgoingInvitations[i] = updated;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Accept incoming invitation
  Future<bool> acceptInvitation(String invitationId, UserModel user) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _currentHousehold = await _service.acceptInvitation(
        invitationId: invitationId,
        user: user,
      );
      _incomingInvitations.removeWhere((i) => i.invitationId == invitationId);
    } catch (e) {
      _errorMessage = _clean(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }

    // Membership succeeded; failures loading extra data must not report the join as failed.
    await _loadHouseholdDetails(user);
    _isLoading = false;
    notifyListeners();
    return true;
  }

  /// Decline incoming invitation
  Future<bool> declineInvitation(String invitationId, UserModel user) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _service.declineInvitation(invitationId: invitationId, user: user);
      _incomingInvitations.removeWhere((i) => i.invitationId == invitationId);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _clean(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Revoke outgoing invitation
  Future<bool> revokeInvitation(String invitationId, UserModel user) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _service.revokeInvitation(invitationId: invitationId, authorizedUser: user);
      _outgoingInvitations.removeWhere((i) => i.invitationId == invitationId);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _clean(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Leave current household
  Future<bool> leaveHousehold(UserModel user) async {
    if (_currentHousehold == null) return false;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _service.leaveHousehold(
        householdId: _currentHousehold!.householdId,
        user: user,
      );
      _currentHousehold = null;
      _sharedItems = [];
      _outgoingInvitations = [];
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _clean(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Toggle item sharing status with authorization check
  Future<VanityItemModel> toggleItemShare({
    required VanityItemModel item,
    required bool share,
    required UserModel user,
  }) async {
    final updated = await _service.toggleItemSharing(
      item: item,
      share: share,
      householdId: _currentHousehold?.householdId,
      currentUserId: user.userId,
    );
    notifyListeners();
    return updated;
  }

  /// Convenience method to toggle sharing by item ID.
  /// Prefer [setItemSharing], which checks the signed-in user (this method falls back to
  /// the item's own owner id when [userId] is omitted, so its owner check cannot fail).
  Future<void> toggleItemSharing(String vanityItemId, bool share, {String? userId}) async {
    final cached = DatabaseService().getAllCachedItems();
    final item = cached.firstWhere(
      (i) => i.vanityItemId == vanityItemId,
      orElse: () => const VanityItemModel(vanityItemId: '', productId: '', userId: ''),
    );
    if (item.vanityItemId.isNotEmpty) {
      await _service.toggleItemSharing(
        item: item,
        share: share,
        householdId: _currentHousehold?.householdId,
        currentUserId: userId ?? item.userId,
      );
      if (_currentHousehold != null) {
        try {
          _sharedItems = await _service.getSharedHouseholdItems(
            householdId: _currentHousehold!.householdId,
            currentUserId: userId ?? item.userId,
          );
          _isSharedDataAvailable = true;
        } catch (e) {
          _isSharedDataAvailable = false;
        }
      }
      notifyListeners();
    }
  }

  // ───────────── Personal vs shared (ownership never changes; only visibility) ─────────────

  /// Shared with Me: items other members explicitly shared with this household (loaded
  /// through the authorized household query; never anyone's private items).
  List<VanityItemModel> get sharedWithMe => _sharedItems;

  /// Shared by Me: the user's own active items currently shared with this household.
  /// [myItems] must be the user's unfiltered own items (VanityProvider.allActiveItems).
  List<VanityItemModel> sharedByMe(List<VanityItemModel> myItems) {
    final hh = _currentHousehold?.householdId;
    if (hh == null) return const [];
    return myItems.where((i) => i.isSharedWithHousehold && i.sharedHouseholdId == hh).toList();
  }

  /// My Personal Inventory: the user's own active items not shared with this household.
  List<VanityItemModel> privateItems(List<VanityItemModel> myItems) {
    final hh = _currentHousehold?.householdId;
    return myItems.where((i) => !(hh != null && i.isSharedWithHousehold && i.sharedHouseholdId == hh)).toList();
  }

  /// Share or stop sharing one of the user's OWN items. Only visibility changes: the
  /// owner, dates, PAO, price and receipt links stay as they are, nothing is copied or
  /// deleted. The write goes through [vanity] so every screen shows the same record.
  /// Throws for an item the user does not own, or sharing without a household, and
  /// rethrows [VanitySyncException] after saving on this device if the cloud write fails.
  Future<VanityItemModel> setItemSharing({
    required VanityProvider vanity,
    required VanityItemModel item,
    required bool share,
    required String currentUserId,
  }) async {
    if (currentUserId.isEmpty || item.userId != currentUserId) {
      throw Exception('You can only change the sharing of products you own.');
    }
    final hh = _currentHousehold?.householdId;
    if (share && hh == null) throw Exception('Join or create a household before sharing products.');
    final updated = item.copyWith(
      isSharedWithHousehold: share,
      sharedHouseholdId: share ? hh : null,
      clearSharedHouseholdId: !share,
    );
    try {
      await vanity.updateItem(updated, throwOnSyncFailure: true);
    } finally {
      notifyListeners();
    }
    return updated;
  }

  /// Wipe all in-memory state on sign-out to prevent data leakage across users
  void clear() {
    _currentHousehold = null;
    _sharedItems = [];
    _incomingInvitations = [];
    _outgoingInvitations = [];
    _isLoading = false;
    _errorMessage = null;
    _invitationsError = null;
    _lastSentInvitation = null;
    _isSharedDataAvailable = true;
    _needsEmailVerification = false;
    _service.clearLocalMemory();
    notifyListeners();
  }
}
