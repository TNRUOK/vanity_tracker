class HouseholdModel {
  final String householdId;
  final String name;
  final String createdBy; // Owner user ID
  final DateTime createdAt;
  final List<String> memberUids;
  final Map<String, String> memberEmails; // userId -> email/display name

  const HouseholdModel({
    required this.householdId,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    this.memberUids = const [],
    this.memberEmails = const {},
  });

  bool isOwner(String userId) => createdBy == userId;
  bool isMember(String userId) => memberUids.contains(userId);

  Map<String, dynamic> toMap() {
    return {
      'household_id': householdId,
      'name': name,
      'created_by': createdBy,
      'created_at': createdAt.toIso8601String(),
      'member_uids': memberUids,
      'member_emails': memberEmails,
    };
  }

  factory HouseholdModel.fromMap(Map<String, dynamic> map, [String? id]) {
    final membersList = (map['member_uids'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final emailMap = (map['member_emails'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {};

    return HouseholdModel(
      householdId: id ?? map['household_id'] ?? '',
      name: map['name'] ?? 'My Household',
      createdBy: map['created_by'] ?? '',
      createdAt: map['created_at'] != null ? DateTime.tryParse(map['created_at']) ?? DateTime.now() : DateTime.now(),
      memberUids: membersList,
      memberEmails: emailMap,
    );
  }

  HouseholdModel copyWith({
    String? householdId,
    String? name,
    String? createdBy,
    DateTime? createdAt,
    List<String>? memberUids,
    Map<String, String>? memberEmails,
  }) {
    return HouseholdModel(
      householdId: householdId ?? this.householdId,
      name: name ?? this.name,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      memberUids: memberUids ?? this.memberUids,
      memberEmails: memberEmails ?? this.memberEmails,
    );
  }
}
