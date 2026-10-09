class NotificationItemModel {
  final String notificationId;
  final String vanityItemId;
  final DateTime notifyDate;
  final String type; // 'expiring_soon' or 'expired'
  final bool sent;

  const NotificationItemModel({
    required this.notificationId,
    required this.vanityItemId,
    required this.notifyDate,
    required this.type,
    this.sent = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'notification_id': notificationId,
      'vanity_item_id': vanityItemId,
      'notify_date': notifyDate.toIso8601String(),
      'type': type,
      'sent': sent,
    };
  }

  factory NotificationItemModel.fromMap(Map<String, dynamic> map, [String? id]) {
    return NotificationItemModel(
      notificationId: id ?? map['notification_id'] ?? '',
      vanityItemId: map['vanity_item_id'] ?? '',
      notifyDate: DateTime.tryParse(map['notify_date'] ?? '') ?? DateTime.now(),
      type: map['type'] ?? 'expiring_soon',
      sent: map['sent'] ?? false,
    );
  }
}
