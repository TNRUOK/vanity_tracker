class UserModel {
  final String userId;
  final String name;
  final String email;
  final String? householdId;

  /// Whether the account's e-mail address is verified (Firebase Auth). Household
  /// invitations can only be seen and accepted with a verified address, because the
  /// invitation is bound to that address. Local/demo accounts have no server rules and
  /// default to true.
  final bool emailVerified;

  const UserModel({
    required this.userId,
    required this.name,
    required this.email,
    this.householdId,
    this.emailVerified = true,
  });

  /// True when this is the local mock demo account (no active Firebase session).
  bool get isDemoAccount => email == 'vanity@demo.app' || userId == 'demo_user';

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'name': name,
      'email': email,
      'household_id': householdId,
      'email_verified': emailVerified,
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map, [String? id]) {
    return UserModel(
      userId: id ?? map['user_id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      householdId: map['household_id'],
      emailVerified: map['email_verified'] as bool? ?? true,
    );
  }

  UserModel copyWith({
    String? userId,
    String? name,
    String? email,
    String? householdId,
    bool clearHouseholdId = false,
    bool? emailVerified,
  }) {
    return UserModel(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      email: email ?? this.email,
      householdId: clearHouseholdId ? null : (householdId ?? this.householdId),
      emailVerified: emailVerified ?? this.emailVerified,
    );
  }
}
