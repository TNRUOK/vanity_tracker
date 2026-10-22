import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/currency.dart';

/// Date-only key, "2024-01-12".
String rateDateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// A reference rate actually used for one conversion, with its provenance.
class RateQuote {
  final String from;
  final String to;

  /// 1 [from] = [rate] [to].
  final double rate;

  /// The date the rate was published for (on or before [requestedDate], never after).
  final DateTime rateDate;
  final DateTime requestedDate;
  final String source;
  final DateTime? retrievedAt;

  const RateQuote({
    required this.from,
    required this.to,
    required this.rate,
    required this.rateDate,
    required this.requestedDate,
    required this.source,
    this.retrievedAt,
  });

  /// True when no rate was published on the purchase date itself (weekend, holiday) and
  /// the latest earlier rate was used.
  bool get isEarlierDateFallback => _day(rateDate) != _day(requestedDate);

  Map<String, dynamic> toMap() => {
        'from': from,
        'to': to,
        'rate': rate,
        'rate_date': rateDateKey(rateDate),
        'requested_date': rateDateKey(requestedDate),
        'source': source,
        'retrieved_at': retrievedAt?.toIso8601String(),
      };
}

/// Outcome of looking up one rate: a [quote], or the reason there is none.
class RateResult {
  final RateQuote? quote;
  final String? unavailableReason;
  const RateResult.ok(RateQuote this.quote) : unavailableReason = null;
  const RateResult.unavailable(String this.unavailableReason) : quote = null;
  bool get isAvailable => quote != null;
}

class RateRequest {
  final String from;
  final String to;
  final DateTime date;
  RateRequest(this.from, this.to, DateTime date) : date = _day(date);

  @override
  bool operator ==(Object other) =>
      other is RateRequest && other.from == from && other.to == to && other.date == date;

  @override
  int get hashCode => Object.hash(from, to, date);
}

class RateFetchException implements Exception {
  final String message;
  RateFetchException(this.message);
  @override
  String toString() => message;
}

/// Daily ECB euro reference rates: date key -> (currency code -> units per 1 EUR).
abstract class EcbRateSource {
  String get label;
  Future<Map<String, Map<String, double>>> fetchEurRates({
    required DateTime from,
    required DateTime to,
    required Set<String> codes,
  });
}

/// ECB reference rates from the free Frankfurter API v2 (no key). Requested with base EUR
/// so the ECB's own published figures come back unrounded; cross rates are derived from
/// them. `providers=ecb` keeps every rate traceable to one official publication instead
/// of Frankfurter's blended multi-bank rate. Weekends/holidays have no row; callers use
/// the latest earlier row. Checked against the live API (2026-10-18): a range request
/// returns `[{"date","base","quote","rate"}, ...]`, an unknown currency returns 422.
class FrankfurterEcbSource implements EcbRateSource {
  static const baseUrl = 'https://api.frankfurter.dev/v2/rates';
  final http.Client? client;
  final Duration timeout;
  FrankfurterEcbSource({this.client, this.timeout = const Duration(seconds: 12)});

  @override
  String get label => 'European Central Bank reference rate (via Frankfurter)';

  @override
  Future<Map<String, Map<String, double>>> fetchEurRates({
    required DateTime from,
    required DateTime to,
    required Set<String> codes,
  }) async {
    final quotes = codes.where((c) => c != 'EUR').toList()..sort();
    if (quotes.isEmpty) return {};
    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'from': rateDateKey(from),
      'to': rateDateKey(to),
      'base': 'EUR',
      'quotes': quotes.join(','),
      'providers': 'ecb',
    });
    final http.Response res;
    try {
      final c = client;
      res = await (c != null ? c.get(uri) : http.get(uri)).timeout(timeout);
    } on TimeoutException {
      throw RateFetchException('The exchange-rate service did not respond (offline?).');
    } catch (e) {
      throw RateFetchException('The exchange-rate service could not be reached (offline?).');
    }
    if (res.statusCode != 200) {
      throw RateFetchException('The exchange-rate service returned an error (HTTP ${res.statusCode}).');
    }
    final Object? body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      throw RateFetchException('The exchange-rate service returned an unreadable response.');
    }
    if (body is! List) throw RateFetchException('The exchange-rate service returned an unexpected response.');
    final out = <String, Map<String, double>>{};
    final fromDay = _day(from), toDay = _day(to);
    for (final row in body) {
      if (row is! Map) continue;
      final date = DateTime.tryParse('${row['date']}');
      final rate = row['rate'];
      final quote = '${row['quote']}'.toUpperCase();
      // Rows that do not answer exactly this request are ignored rather than trusted.
      if (date == null || row['base'] != 'EUR' || !quotes.contains(quote)) continue;
      if (rate is! num || !rate.isFinite || rate <= 0) continue;
      if (_day(date).isBefore(fromDay) || _day(date).isAfter(toDay)) continue;
      (out[rateDateKey(date)] ??= {})[quote] = rate.toDouble();
    }
    return out;
  }
}

/// Historical exchange rates for spending figures, keyed by currency pair and date.
///
/// * The rate for a purchase is the latest ECB rate published on or before the purchase
///   date (at most [lookbackDays] earlier); a later rate is never used.
/// * Rates are cached on the device by date; past ECB rates are reused offline. A rate is
///   only taken from the cache when the cache is known to hold every published rate between
///   it and the purchase date (so a newer rate cannot have been missed).
/// * Concurrent and repeated requests for the same data share one network call.
class ExchangeRateService {
  static const lookbackDays = 10;
  static const _prefsKey = 'fx_ecb_eur_rates_v1';
  static final ecbFirstDate = DateTime(1999, 1, 4);

  final EcbRateSource source;
  final DateTime Function() _now;

  ExchangeRateService({EcbRateSource? source, DateTime Function()? now})
      : source = source ?? FrankfurterEcbSource(),
        _now = now ?? DateTime.now;

  static ExchangeRateService? _shared;
  static ExchangeRateService get shared => _shared ??= ExchangeRateService();
  @visibleForTesting
  static set shared(ExchangeRateService s) => _shared = s;

  final Map<String, Map<String, double>> _eur = {};
  final Map<String, String> _retrievedAt = {}; // date key -> ISO time first stored
  final Map<String, List<(DateTime, DateTime)>> _coverage = {}; // persisted, final days only
  final Map<String, List<(DateTime, DateTime)>> _sessionCoverage = {}; // incl. recent days
  final Map<String, Future<void>> _inFlight = {};
  bool _loaded = false;

  /// Number of network requests made (for tests and diagnostics).
  int fetchCount = 0;

  /// Message of the most recent failed fetch, or null after a successful one.
  String? lastError;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      (map['rates'] as Map<String, dynamic>? ?? {}).forEach((date, codes) {
        _eur[date] = {
          for (final e in (codes as Map<String, dynamic>).entries)
            if (e.value is num) e.key: (e.value as num).toDouble(),
        };
      });
      (map['retrieved_at'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _retrievedAt[k] = '$v');
      (map['coverage'] as Map<String, dynamic>? ?? {}).forEach((code, ranges) {
        for (final r in ranges as List) {
          final a = DateTime.tryParse('${r[0]}'), b = DateTime.tryParse('${r[1]}');
          if (a != null && b != null) (_coverage[code] ??= []).add((a, b));
        }
      });
    } catch (e) {
      debugPrint('Exchange-rate cache could not be read: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'rates': _eur,
          'retrieved_at': _retrievedAt,
          'coverage': {
            for (final e in _coverage.entries)
              e.key: [for (final r in e.value) [rateDateKey(r.$1), rateDateKey(r.$2)]],
          },
        }),
      );
    } catch (e) {
      debugPrint('Exchange-rate cache could not be saved: $e');
    }
  }

  bool _covered(String code, DateTime start, DateTime end) {
    if (code == 'EUR') return true;
    for (final list in [_coverage[code], _sessionCoverage[code]]) {
      for (final r in list ?? const <(DateTime, DateTime)>[]) {
        if (!r.$1.isAfter(start) && !r.$2.isBefore(end)) return true;
      }
    }
    return false;
  }

  double? _eurRate(String dateKey, String code) => code == 'EUR' ? 1.0 : _eur[dateKey]?[code];

  /// Resolves [r] from the cache only. Null means the cache cannot answer (fetch needed).
  RateResult? _fromCache(RateRequest r) {
    final pre = _precheck(r);
    if (pre != null) return pre;
    final earliest = r.date.subtract(const Duration(days: lookbackDays));
    for (var d = r.date; !d.isBefore(earliest); d = DateTime(d.year, d.month, d.day - 1)) {
      final key = rateDateKey(d);
      final f = _eurRate(key, r.from), t = _eurRate(key, r.to);
      if (f != null && t != null) {
        if (!_covered(r.from, d, r.date) || !_covered(r.to, d, r.date)) return null;
        return RateResult.ok(RateQuote(
          from: r.from,
          to: r.to,
          rate: t / f,
          rateDate: d,
          requestedDate: r.date,
          source: source.label,
          retrievedAt: DateTime.tryParse(_retrievedAt[key] ?? ''),
        ));
      }
    }
    if (_covered(r.from, earliest, r.date) && _covered(r.to, earliest, r.date)) {
      return RateResult.unavailable(
        'No ECB rate for ${r.from}→${r.to} was published in the $lookbackDays days up to ${rateDateKey(r.date)}.',
      );
    }
    return null;
  }

  RateResult? _precheck(RateRequest r) {
    for (final c in [r.from, r.to]) {
      if (Currencies.byCode(c) == null) return RateResult.unavailable('$c is not a supported currency.');
    }
    if (r.date.isAfter(_day(_now()))) {
      return const RateResult.unavailable('The purchase date is in the future, so no rate exists yet.');
    }
    if (r.date.isBefore(ecbFirstDate)) {
      return RateResult.unavailable('ECB reference rates start on ${rateDateKey(ecbFirstDate)}.');
    }
    return null;
  }

  /// Cached answer for one conversion without any network access (null = not cached).
  Future<RateResult?> cached(String from, String to, DateTime date) async {
    await _load();
    return _fromCache(RateRequest(from, to, date));
  }

  /// Rates for all [requests]: from the cache where possible, otherwise with one network
  /// request covering every missing currency and date.
  Future<Map<RateRequest, RateResult>> resolveAll(Iterable<RateRequest> requests) async {
    await _load();
    final out = <RateRequest, RateResult>{};
    final missing = <RateRequest>[];
    for (final r in requests.toSet()) {
      final c = _fromCache(r);
      if (c != null) {
        out[r] = c;
      } else {
        missing.add(r);
      }
    }
    if (missing.isEmpty) return out;

    final codes = {for (final r in missing) ...[r.from, r.to]}..remove('EUR');
    var start = missing.map((r) => r.date).reduce((a, b) => a.isBefore(b) ? a : b);
    start = start.subtract(const Duration(days: lookbackDays));
    if (start.isBefore(ecbFirstDate)) start = ecbFirstDate;
    final end = missing.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b);
    final key = '${(codes.toList()..sort()).join(',')}|${rateDateKey(start)}|${rateDateKey(end)}';

    try {
      // Block body: returning the removed future from whenComplete would make it wait on itself.
      await (_inFlight[key] ??= _fetch(start, end, codes).whenComplete(() {
        _inFlight.remove(key);
      }));
    } on RateFetchException catch (e) {
      lastError = e.message;
    }
    for (final r in missing) {
      out[r] = _fromCache(r) ??
          RateResult.unavailable(
            lastError != null ? 'Rate not available: ${lastError!}' : 'Rate not available for ${rateDateKey(r.date)}.',
          );
    }
    return out;
  }

  Future<void> _fetch(DateTime start, DateTime end, Set<String> codes) async {
    fetchCount++;
    final rows = await source.fetchEurRates(from: start, to: end, codes: codes);
    lastError = null;
    final stamp = _now().toIso8601String();
    rows.forEach((date, rates) {
      (_eur[date] ??= {}).addAll(rates);
      _retrievedAt.putIfAbsent(date, () => stamp);
    });
    // The last couple of days may still receive their rate, so they are only treated as
    // complete for this session; older days are complete for good.
    final settled = _day(_now()).subtract(const Duration(days: 2));
    for (final c in codes) {
      (_sessionCoverage[c] ??= []).add((start, end));
      final finalEnd = end.isAfter(settled) ? settled : end;
      if (!finalEnd.isBefore(start)) (_coverage[c] ??= []).add((start, finalEnd));
    }
    await _save();
  }
}
