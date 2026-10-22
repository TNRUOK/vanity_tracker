enum InvitationStatus {
  pending,
  accepted,
  declined,
  revoked,
  expired,
}

enum EmailDeliveryStatus {
  queued,
  sent,
  failed,
  notConfigured,
}

class HouseholdInvitationModel {
  final String invitationId;
  final String householdId;
  final String householdName;
  final String invitedEmail; // Normalized lowercase
  final String invitedByUid;
  final String invitedByName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final InvitationStatus status;
  final EmailDeliveryStatus emailDeliveryStatus;
  final String? emailDeliveryError;

  /// SMTP server response recorded by the backend when the email was accepted.
  final String? emailProviderResponse;
  final DateTime? emailSentAt;
  final int emailAttempts;

  const HouseholdInvitationModel({
    required this.invitationId,
    required this.householdId,
    required this.householdName,
    required this.invitedEmail,
    required this.invitedByUid,
    required this.invitedByName,
    required this.createdAt,
    required this.expiresAt,
    this.status = InvitationStatus.pending,
    this.emailDeliveryStatus = EmailDeliveryStatus.queued,
    this.emailDeliveryError,
    this.emailProviderResponse,
    this.emailSentAt,
    this.emailAttempts = 0,
  });

  /// Check if invitation has expired based on current time
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// True if invitation is in a pending state and not expired
  bool get isValidPending => status == InvitationStatus.pending && !isExpired;

  /// Check whether authenticated user's email matches the intended recipient
  bool canBeAcceptedBy(String userEmail) {
    if (!isValidPending) return false;
    return userEmail.trim().toLowerCase() == invitedEmail.trim().toLowerCase();
  }

  /// Friendly human-readable label for delivery status
  String get emailDeliveryStatusLabel {
    switch (emailDeliveryStatus) {
      case EmailDeliveryStatus.queued:
        return 'Queued for Delivery';
      case EmailDeliveryStatus.sent:
        return 'Email Sent';
      case EmailDeliveryStatus.failed:
        return 'Email Queue Failed';
      case EmailDeliveryStatus.notConfigured:
        return 'In-App Only';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'invitation_id': invitationId,
      'household_id': householdId,
      'household_name': householdName,
      'invited_email': invitedEmail.toLowerCase().trim(),
      'invited_by_uid': invitedByUid,
      'invited_by_name': invitedByName,
      'created_at': createdAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
      'status': status.name,
      'email_delivery_status': emailDeliveryStatus.name,
      'email_delivery_error': emailDeliveryError,
      // Numeric copy of the expiry so Firestore security rules can compare it with request.time.
      'expires_at_ms': expiresAt.millisecondsSinceEpoch,
    };
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toLocal();
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    // Firestore Timestamp (has toDate()) without importing cloud_firestore here.
    try {
      final d = (v as dynamic).toDate();
      if (d is DateTime) return d.toLocal();
    } catch (_) {}
    return DateTime.tryParse(v.toString())?.toLocal();
  }

  factory HouseholdInvitationModel.fromMap(Map<String, dynamic> map, [String? id]) {
    final statusStr = map['status'] ?? 'pending';
    final invStatus = InvitationStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => InvitationStatus.pending,
    );

    final emailStatusStr = map['email_delivery_status'] ?? 'queued';
    final deliveryStatus = EmailDeliveryStatus.values.firstWhere(
      (s) => s.name == emailStatusStr,
      orElse: () => EmailDeliveryStatus.queued,
    );

    return HouseholdInvitationModel(
      invitationId: id ?? map['invitation_id'] ?? '',
      householdId: map['household_id'] ?? '',
      householdName: map['household_name'] ?? 'Household',
      invitedEmail: (map['invited_email'] ?? '').toString().toLowerCase().trim(),
      invitedByUid: map['invited_by_uid'] ?? '',
      invitedByName: map['invited_by_name'] ?? '',
      createdAt: _parseDate(map['created_at']) ?? DateTime.now(),
      expiresAt: _parseDate(map['expires_at_ms']) ??
          _parseDate(map['expires_at']) ??
          DateTime.now().add(const Duration(days: 7)),
      status: invStatus,
      emailDeliveryStatus: deliveryStatus,
      emailDeliveryError: map['email_delivery_error']?.toString(),
      emailProviderResponse: map['email_provider_response']?.toString(),
      emailSentAt: _parseDate(map['email_sent_at']),
      emailAttempts: (map['email_attempts'] as num?)?.toInt() ?? 0,
    );
  }

  HouseholdInvitationModel copyWith({
    String? invitationId,
    String? householdId,
    String? householdName,
    String? invitedEmail,
    String? invitedByUid,
    String? invitedByName,
    DateTime? createdAt,
    DateTime? expiresAt,
    InvitationStatus? status,
    EmailDeliveryStatus? emailDeliveryStatus,
    String? emailDeliveryError,
    bool clearEmailDeliveryError = false,
    String? emailProviderResponse,
    DateTime? emailSentAt,
    int? emailAttempts,
  }) {
    return HouseholdInvitationModel(
      invitationId: invitationId ?? this.invitationId,
      householdId: householdId ?? this.householdId,
      householdName: householdName ?? this.householdName,
      invitedEmail: invitedEmail ?? this.invitedEmail,
      invitedByUid: invitedByUid ?? this.invitedByUid,
      invitedByName: invitedByName ?? this.invitedByName,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      status: status ?? this.status,
      emailDeliveryStatus: emailDeliveryStatus ?? this.emailDeliveryStatus,
      emailDeliveryError: clearEmailDeliveryError ? null : (emailDeliveryError ?? this.emailDeliveryError),
      emailProviderResponse: emailProviderResponse ?? this.emailProviderResponse,
      emailSentAt: emailSentAt ?? this.emailSentAt,
      emailAttempts: emailAttempts ?? this.emailAttempts,
    );
  }
}
