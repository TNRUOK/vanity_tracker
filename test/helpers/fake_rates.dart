import 'package:vanity_tracker/services/exchange_rate_service.dart';

/// Fixed ECB-style table for deterministic tests: date key -> (code -> units per 1 EUR).
/// Only dates present in the table have a rate (like weekends/holidays in the real data).
class FixedEcbRateSource implements EcbRateSource {
  final Map<String, Map<String, double>> table;
  final List<({DateTime from, DateTime to, Set<String> codes})> calls = [];
  FixedEcbRateSource(this.table);

  @override
  String get label => 'Test ECB table';

  @override
  Future<Map<String, Map<String, double>>> fetchEurRates({
    required DateTime from,
    required DateTime to,
    required Set<String> codes,
  }) async {
    calls.add((from: from, to: to, codes: codes));
    final out = <String, Map<String, double>>{};
    table.forEach((date, rates) {
      final d = DateTime.parse(date);
      if (d.isBefore(from) || d.isAfter(to)) return;
      final picked = {for (final c in codes) if (rates[c] != null) c: rates[c]!};
      if (picked.isNotEmpty) out[date] = picked;
    });
    return out;
  }
}

/// Simulates no connection.
class OfflineRateSource implements EcbRateSource {
  int calls = 0;
  @override
  String get label => 'Offline';

  @override
  Future<Map<String, Map<String, double>>> fetchEurRates({
    required DateTime from,
    required DateTime to,
    required Set<String> codes,
  }) async {
    calls++;
    throw RateFetchException('The exchange-rate service could not be reached (offline?).');
  }
}
