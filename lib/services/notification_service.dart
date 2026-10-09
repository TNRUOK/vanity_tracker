import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../models/vanity_item_model.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      tz.initializeTimeZones();
    } catch (e) {
      debugPrint('Timezone init error: $e');
    }

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const WindowsInitializationSettings windowsSettings = WindowsInitializationSettings(
      appName: 'Vanity Tracker',
      appUserModelId: 'com.vanitytracker.app',
      guid: '9a9e32f0-10ab-4841-863a-237691654e38',
    );

    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      windows: windowsSettings,
    );

    _initialized = true;
    try {
      await _notificationsPlugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint('Notification payload clicked: ${response.payload}');
        },
      );
    } catch (e) {
      debugPrint('Failed to initialize local notifications: $e');
    }
  }

  Future<void> requestPermissions() async {
    try {
      final androidImplementation = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImplementation?.requestNotificationsPermission();

      final iosImplementation = _notificationsPlugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await iosImplementation?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e) {
      debugPrint('Request permissions error: $e');
    }
  }

  /// Schedules 30-day warning and expired-day notifications for a vanity item
  Future<void> scheduleExpiryNotifications(VanityItemModel item) async {
    if (item.expiryDate == null || item.openedDate == null) return;
    final productName = item.product?.name ?? 'Cosmetic Product';
    final brandName = item.product?.brand ?? '';
    final titlePrefix = brandName.isNotEmpty ? '$brandName $productName' : productName;

    final expiryDate = item.expiryDate!;
    final thirtyDaysBefore = expiryDate.subtract(const Duration(days: 30));
    final now = DateTime.now();

    final baseId = item.vanityItemId.hashCode.abs() % 100000;
    final warningId = baseId * 2;
    final expiredId = baseId * 2 + 1;

    // 1. Schedule 30-day warning if in future
    if (thirtyDaysBefore.isAfter(now)) {
      await _scheduleSingleNotification(
        id: warningId,
        title: '⚠️ Expiring Soon: $titlePrefix',
        body: 'This product will expire in 30 days (PAO limit). Consider finishing it up!',
        scheduledDate: thirtyDaysBefore,
        payload: item.vanityItemId,
      );
    }

    // 2. Schedule Expiry notification if in future
    if (expiryDate.isAfter(now)) {
      await _scheduleSingleNotification(
        id: expiredId,
        title: '🛑 Expired: $titlePrefix',
        body: 'This product has reached its Period After Opening (PAO) expiry date today.',
        scheduledDate: expiryDate,
        payload: item.vanityItemId,
      );
    }
  }

  Future<void> _scheduleSingleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
  }) async {
    try {
      if (!_initialized) {
        await initialize();
      }

      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'vanity_expiry_channel',
        'Vanity Expiry Reminders',
        channelDescription: 'Alerts when skincare or cosmetic products are expiring or expired',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      tz.TZDateTime tzDateTime;
      try {
        tzDateTime = tz.TZDateTime.from(scheduledDate, tz.local);
      } catch (_) {
        tz.initializeTimeZones();
        tzDateTime = tz.TZDateTime.from(scheduledDate, tz.local);
      }

      await _notificationsPlugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tzDateTime,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
      debugPrint('Scheduled notification $id for $scheduledDate');
    } catch (e) {
      debugPrint('Error scheduling notification: $e');
    }
  }

  /// Cancels notifications for an item (e.g. when finished or deleted)
  Future<void> cancelItemNotifications(String vanityItemId) async {
    if (!_initialized) return;
    try {
      final baseId = vanityItemId.hashCode.abs() % 100000;
      await _notificationsPlugin.cancel(id: baseId * 2);
      await _notificationsPlugin.cancel(id: baseId * 2 + 1);
    } catch (e) {
      debugPrint('Error cancelling notification: $e');
    }
  }
}
