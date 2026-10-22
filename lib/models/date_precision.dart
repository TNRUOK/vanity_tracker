import 'package:intl/intl.dart';

/// How much of a printed date is known. "EXP 10/2027" has no day: it is stored as the
/// first day of that month (the earliest reading, so reminders are never late) and is
/// always shown as "Oct 2027 (month only)". Stored next to the date as "month"; dates
/// saved before this existed have no value and are read as [day].
enum DatePrecision {
  day('day'),
  month('month');

  final String storageValue;
  const DatePrecision(this.storageValue);

  static DatePrecision fromStorage(Object? raw) => raw == 'month' ? month : day;
}

/// "2027-10-17", or "Oct 2027 (month only)".
String formatPackagingDate(DateTime date, DatePrecision precision) =>
    precision == DatePrecision.month
        ? '${DateFormat('MMM yyyy').format(date)} (month only)'
        : DateFormat('yyyy-MM-dd').format(date);