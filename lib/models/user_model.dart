class UserModel {
  final String userId;
  final String name;
  final String email;
  final String? householdId;

  const UserModel({
    required this.userId,
    required this.name,
    required this.email,
    this.householdId,
  });

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'name': name,
      'email': email,
      'household_id': householdId,
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map, [String? id]) {
    return UserModel(
      userId: id ?? map['user_id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      householdId: map['household_id'],
    );
  }
}
