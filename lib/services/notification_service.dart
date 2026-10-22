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
  bool _pluginAvailable = false;

  /// Tests only: when set, schedule/cancel requests are recorded here
  /// (`schedule:<itemId>:<expiry ISO>` / `cancel:<itemId>`).
  @visibleForTesting
  static List<String>? debugLog;

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      tz.initializeTimeZones();
      _resolveLocalLocation();
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
      final success = await _notificationsPlugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint('Notification payload clicked: ${response.payload}');
        },
      );
      _pluginAvailable = success ?? true;
    } catch (e) {
      _pluginAvailable = false;
      debugPrint('Local notifications not supported or available in this environment: $e');
    }
  }

  tz.Location _resolveLocalLocation() {
    try {
      final now = DateTime.now();
      final name = now.timeZoneName;

      // 1. Check if direct name exists in timezone database
      if (tz.timeZoneDatabase.locations.containsKey(name)) {
        final loc = tz.getLocation(name);
        tz.setLocalLocation(loc);
        return loc;
      }

      // 2. Match by current UTC offset
      final targetOffset = now.timeZoneOffset;
      for (final loc in tz.timeZoneDatabase.locations.values) {
        if (loc.currentTimeZone.offset == targetOffset) {
          tz.setLocalLocation(loc);
          return loc;
        }
      }
    } catch (e) {
      debugPrint('Local timezone detection error: $e');
    }

    // 3. Fallback to UTC only when device timezone cannot be detected
    try {
      final utc = tz.getLocation('UTC');
      tz.setLocalLocation(utc);
      return utc;
    } catch (_) {
      return tz.UTC;
    }
  }

  tz.Location _getLocalLocation() {
    try {
      return tz.local;
    } catch (_) {
      return _resolveLocalLocation();
    }
  }

  Future<void> requestPermissions() async {
    if (!_pluginAvailable) return;
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

  /// Schedules 30-day, 7-day warning, and expired-day notifications for a vanity item
  Future<void> scheduleExpiryNotifications(VanityItemModel item) async {
    final expiryDate = item.effectiveExpiryDate;
    if (expiryDate == null) return;
    if (item.status == 'finished') return;

    // Cancel old notifications first to avoid stale notifications if dates shifted
    await cancelItemNotifications(item.vanityItemId);
    debugLog?.add('schedule:${item.vanityItemId}:${expiryDate.toIso8601String()}');

    final productName = item.product?.name ?? 'Cosmetic Product';
    final brandName = item.product?.brand ?? '';
    final titlePrefix = brandName.isNotEmpty ? '$brandName $productName' : productName;

    final thirtyDaysBefore = expiryDate.subtract(const Duration(days: 30));
    final sevenDaysBefore = expiryDate.subtract(const Duration(days: 7));
    final now = DateTime.now();

    final baseId = item.vanityItemId.hashCode.abs() % 100000;
    final warning30Id = baseId * 3;
    final warning7Id = baseId * 3 + 1;
    final expiredId = baseId * 3 + 2;

    // 1. Schedule 30-day warning if in future
    if (thirtyDaysBefore.isAfter(now)) {
      await _scheduleSingleNotification(
        id: warning30Id,
        title: '⚠️ Expiring Soon: $titlePrefix',
        body: 'This product will expire in 30 days. Consider finishing it up!',
        scheduledDate: thirtyDaysBefore,
        payload: item.vanityItemId,
      );
    }

    // 2. Schedule 7-day warning if in future
    if (sevenDaysBefore.isAfter(now)) {
      await _scheduleSingleNotification(
        id: warning7Id,
        title: '⏳ Expiring in 7 Days: $titlePrefix',
        body: 'Only 1 week left before this product reaches its expiry date.',
        scheduledDate: sevenDaysBefore,
        payload: item.vanityItemId,
      );
    }

    // 3. Schedule Expiry notification if in future
    if (expiryDate.isAfter(now)) {
      await _scheduleSingleNotification(
        id: expiredId,
        title: '🛑 Expired: $titlePrefix',
        body: 'This product has reached its expiry date today.',
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
      if (!_pluginAvailable) return;

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

      final location = _getLocalLocation();
      final tzDateTime = tz.TZDateTime.from(scheduledDate, location);

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
    debugLog?.add('cancel:$vanityItemId');
    if (!_initialized) {
      await initialize();
    }
    if (!_pluginAvailable) return;

    try {
      final baseId = vanityItemId.hashCode.abs() % 100000;
      await _notificationsPlugin.cancel(id: baseId * 3);
      await _notificationsPlugin.cancel(id: baseId * 3 + 1);
      await _notificationsPlugin.cancel(id: baseId * 3 + 2);
      // Also cancel legacy IDs (baseId * 2, baseId * 2 + 1)
      await _notificationsPlugin.cancel(id: baseId * 2);
      await _notificationsPlugin.cancel(id: baseId * 2 + 1);
    } catch (e) {
      debugPrint('Error cancelling notification: $e');
    }
  }
}
