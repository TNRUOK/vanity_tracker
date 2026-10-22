// Barcode validation + product lookup repair (2026-10-19). HTTP is MOCKED; no live API.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanity_tracker/models/category_model.dart';
import 'package:vanity_tracker/services/product_lookup_service.dart';
import 'package:vanity_tracker/utils/barcode_utils.dart';

/// Open*Facts-like server: [byHost] maps a host fragment to barcode -> (status, body).
MockClient server(Map<String, Map<String, (int, Map<String, dynamic>)>> byHost, {List<Uri>? log, Duration? delay}) {
  return MockClient((req) async {
    log?.add(req.url);
    if (delay != null) await Future<void>.delayed(delay);
    final code = RegExp(r'/product/(\d+)\.json$').firstMatch(req.url.path)?.group(1);
    for (final e in byHost.entries) {
      if (req.url.host.contains(e.key) && code != null && e.value.containsKey(code)) {
        final (status, body) = e.value[code]!;
        return http.Response(jsonEncode(body), status);
      }
    }
    if (req.url.host.contains('upcitemdb')) return http.Response(jsonEncode({'code': 'OK', 'items': []}), 200);
    return http.Response(jsonEncode({'code': code, 'status': 0, 'status_verbose': 'product not found'}), 404);
  });
}

Map<String, dynamic> found(String code, String name, String brand, {Map<String, dynamic> extra = const {}}) => {
      'code': code,
      'status': 1,
      'product': {'code': code, 'product_name': name, 'brands': brand, ...extra},
    };

Future<ProductLookupResult> lookup(http.Client c, String code, {bool anyway = false}) =>
    http.runWithClient(() => ProductLookupService.lookupBarcode(code, allowInvalidCheckDigit: anyway), () => c);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Validation before any lookup', () {
    test('the reported 8809643068098 fails EAN-13 validation (the check digit would be 3)', () {
      final c = BarcodeUtils.check('8809643068098');
      expect(c.format, RetailFormat.ean13);
      expect(c.checkDigitValid, isFalse);
      // Only to document the arithmetic: the app never suggests this "fix".
      expect(BarcodeUtils.hasValidCheckDigit('8809643068093'), isTrue);
    });

    test('EAN-13, UPC-A, EAN-8, GTIN-14 valid and invalid', () {
      expect(BarcodeUtils.check('3337875597180').checkDigitValid, isTrue);
      expect(BarcodeUtils.check('3337875597181').checkDigitValid, isFalse);
      expect(BarcodeUtils.check('041554420616').format, RetailFormat.upcA);
      expect(BarcodeUtils.check('041554420616').checkDigitValid, isTrue);
      expect(BarcodeUtils.check('041554420617').checkDigitValid, isFalse);
      expect(BarcodeUtils.check('96385074').format, RetailFormat.ean8);
      expect(BarcodeUtils.check('10012345678902').format, RetailFormat.gtin14);
      expect(BarcodeUtils.check('10012345678902').checkDigitValid, isTrue);
    });

    test('UPC-E is expanded to UPC-A and validated with the UPC-A check digit', () {
      expect(BarcodeUtils.expandUpcE('04252614'), '042100005264'); // GS1 example
      expect(BarcodeUtils.expandUpcE('01234505'), '012000003455'); // last data digit 0: XX0 0000 XXX
      expect(BarcodeUtils.expandUpcE('92345678'), isNull, reason: 'number system must be 0 or 1');
      final scanned = BarcodeUtils.check('04252614', format: RetailFormat.upcE);
      expect(scanned.format, RetailFormat.upcE);
      expect(scanned.lookupDigits, '042100005264');
      expect(scanned.checkDigitValid, isTrue);
      // Typed without a format: not a valid EAN-8, but a valid UPC-E -> identified as UPC-E.
      expect(BarcodeUtils.check('04252614').format, RetailFormat.upcE);
      expect(scanned.raw, '04252614', reason: 'the raw value is preserved');
    });

    test('whitespace/dashes are harmless; digits are never changed; leading zeros compare equal', () {
      expect(BarcodeUtils.check(' 3337 8755-97180 ').lookupDigits, '3337875597180');
      expect(BarcodeUtils.check('333787559718O').isRetailBarcode, isFalse, reason: 'letter O is not turned into 0');
      expect(BarcodeUtils.sameProduct('041554420616', '0041554420616'), isTrue);
      expect(BarcodeUtils.sameProduct('041554420616', '041554420617'), isFalse);
    });

    test('scan gate skips misreads (bad check digit) and keeps scanning', () {
      final gate = BarcodeScanGate();
      expect(gate.acceptReads([(value: '3337875597181', format: RetailFormat.ean13)]), isNull);
      expect(gate.isBusy, isFalse);
      expect(gate.lastRejected!.raw, '3337875597181');
      final ok = gate.acceptReads([(value: '04252614', format: RetailFormat.upcE)]);
      expect(ok!.lookupDigits, '042100005264');
      expect(gate.acceptReads([(value: '3337875597180', format: RetailFormat.ean13)]), isNull, reason: 'one per scan');
    });

    test('an invalid check digit is NOT looked up; the user may search anyway', () async {
      final calls = <Uri>[];
      final r = await lookup(server({}, log: calls), '8809643068098');
      expect(r.status, LookupStatus.invalidCheckDigit);
      expect(r.found, isFalse);
      expect(calls, isEmpty);
      expect(r.errorMessage, contains('not a valid EAN-13'));
      expect(r.errorMessage, contains('does not guess'));
      expect(r.errorMessage, isNot(contains('8809643068093')), reason: 'no fabricated correction');

      final anyway = await lookup(server({}, log: calls), '8809643068098', anyway: true);
      expect(calls, isNotEmpty);
      expect(anyway.status, LookupStatus.notFound);
      expect(anyway.errorMessage, contains('searched exactly as entered'));
    });

    test('every barcode in the offline sample catalog is a valid GS1 code', () {
      expect(ProductLookupService.catalogBarcodes, isNotEmpty);
      for (final code in ProductLookupService.catalogBarcodes) {
        expect(BarcodeUtils.check(code).checkDigitValid, isTrue, reason: code);
      }
      expect(ProductLookupService.catalogBarcodes, isNot(contains('8809643068098')));
    });

    test('non-barcodes are rejected without a lookup', () async {
      final calls = <Uri>[];
      final r = await lookup(server({}, log: calls), 'ABC-123');
      expect(r.status, LookupStatus.invalidFormat);
      expect(calls, isEmpty);
    });
  });

  group('Lookup outcomes are distinguished', () {
    test('success from Open Beauty Facts with category provenance', () async {
      final r = await lookup(
        server({
          'openbeautyfacts': {
            '3337875597180': (200, found('3337875597180', 'Hydrating Cleanser', 'CeraVe', extra: {
              'quantity': '236ml',
              'categories_hierarchy': ['en:face-care', 'en:face-cleansers'],
            })),
          },
        }),
        '3337875597180',
      );
      expect(r.status, LookupStatus.found);
      expect(r.product!.categoryId, 'cleanser');
      expect(r.product!.categorySource, CategorySource.productDatabase);
      expect(r.attempts.single.outcome, AttemptOutcome.found);
    });

    test('a valid but unlisted barcode is "not found", never "invalid"', () async {
      final r = await lookup(server({}), '3337875597388');
      expect(r.status, LookupStatus.notFound);
      expect(r.checkDigitInvalid, isFalse);
      expect(r.errorMessage, contains('is valid, but no product record was found'));
      expect(r.attempts.every((a) => a.outcome == AttemptOutcome.notFound), isTrue);
    });

    test('a server error or rate limit is not reported as "not found"', () async {
      final err = MockClient((req) async => req.url.host.contains('openbeautyfacts')
          ? http.Response('<html>500 Internal Server Error</html>', 500)
          : http.Response(jsonEncode({'status': 0}), 404));
      final r = await lookup(err, '3337875597388');
      expect(r.status, LookupStatus.unavailable);
      expect(r.errorMessage, contains('Open Beauty Facts: server error'));
      expect(r.networkError, isFalse);

      final limited = MockClient((req) async => http.Response('{"status":"error"}', 429));
      final l = await lookup(limited, '3337875597388');
      expect(l.status, LookupStatus.unavailable);
      expect(l.attempts.first.outcome, AttemptOutcome.rateLimited);
    });

    test('timeout and offline are reported separately', () async {
      final slow = MockClient((_) async => throw TimeoutException('slow'));
      // (A barcode outside the offline sample catalog, which would otherwise be offered.)
      final t = await lookup(slow, '3000000000007');
      expect(t.status, LookupStatus.timeout);
      expect(t.errorMessage, contains('did not answer in time'));
      final offline = MockClient((_) async => throw http.ClientException('Failed host lookup'));
      final o = await lookup(offline, '3000000000007');
      expect(o.status, LookupStatus.offline);
      expect(o.networkError, isTrue);
    });

    test('a record for a different barcode is rejected and the next source is tried', () async {
      final r = await lookup(
        server({
          'openbeautyfacts': {'3337875597388': (200, found('9999999999994', 'Wrong Product', 'X'))},
          'openproductsfacts': {'3337875597388': (200, found('3337875597388', 'CeraVe Hydraterende Crème', 'CeraVe'))},
        }),
        '3337875597388',
      );
      expect(r.status, LookupStatus.found);
      expect(r.source, 'Open Products Facts');
      expect(r.product!.name, 'CeraVe Hydraterende Crème');
      expect(r.attempts.first.outcome, AttemptOutcome.rejected);
    });

    test('UPC-A record returned with its 13-digit code is accepted (same product)', () async {
      final r = await lookup(
        server({
          'openbeautyfacts': {
            '041554420616': (200, found('0041554420616', 'Lash Sensational Washable Mascara', 'Maybelline')),
          },
        }),
        '041554420616',
      );
      expect(r.status, LookupStatus.found);
      expect(r.product!.brand, 'Maybelline');
    });

    test('a UPC-E code is looked up by its UPC-A expansion', () async {
      final calls = <Uri>[];
      await lookup(server({}, log: calls), '04252614');
      expect(calls.first.path, endsWith('/042100005264.json'));
    });

    test('incomplete records are found but flagged for the user to complete', () async {
      final r = await lookup(
        server({'openbeautyfacts': {'3337875597388': (200, {'status': 1, 'product': {'code': '3337875597388', 'quantity': '50 ml'}})}}),
        '3337875597388',
      );
      expect(r.found, isTrue);
      expect(r.hasMissingDetails, isTrue);
    });

    test('concurrent lookups of the same barcode share one set of requests; repeats use the cache', () async {
      final calls = <Uri>[];
      final client = server({
        'openbeautyfacts': {'3337875597180': (200, found('3337875597180', 'Hydrating Cleanser', 'CeraVe'))},
      }, log: calls, delay: const Duration(milliseconds: 20));
      await http.runWithClient(() async {
        final rs = await Future.wait(List.generate(5, (_) => ProductLookupService.lookupBarcode('3337875597180')));
        expect(rs.every((r) => r.found), isTrue);
        expect(calls, hasLength(1));
        final again = await ProductLookupService.lookupBarcode('3337875597180');
        expect(again.fromCache, isTrue);
        expect(calls, hasLength(1));
      }, () => client);
    });
  });

  group('Search by name', () {
    test('parses candidates, drops records without barcode or name', () async {
      final calls = <Uri>[];
      final c = MockClient((req) async {
        calls.add(req.url);
        return http.Response(
          jsonEncode({
            'count': 3,
            'products': [
              {'code': '3337875598996', 'product_name': 'moisturising cream', 'brands': 'CeraVe', 'quantity': '177'},
              {'code': '', 'product_name': 'No barcode'},
              {'code': '3337875597470'},
            ],
          }),
          200,
        );
      });
      final r = await http.runWithClient(() => ProductLookupService.searchByName('cerave moisturising cream'), () => c);
      expect(r.candidates.single.barcode, '3337875598996');
      expect(r.candidates.single.brand, 'CeraVe');
      expect(calls.single.host, 'world.openbeautyfacts.org');
      expect(calls.single.queryParameters['search_terms'], 'cerave moisturising cream');
    });

    test('errors and short queries are explained; nothing is invented', () async {
      expect((await ProductLookupService.searchByName('ab')).errorMessage, contains('at least 3'));
      final offline = MockClient((_) async => throw http.ClientException('offline'));
      final o = await http.runWithClient(() => ProductLookupService.searchByName('cerave'), () => offline);
      expect(o.candidates, isEmpty);
      expect(o.errorMessage, contains('Could not reach'));
      final empty = MockClient((_) async => http.Response(jsonEncode({'count': 0, 'products': []}), 200));
      final e = await http.runWithClient(() => ProductLookupService.searchByName('zzzz'), () => empty);
      expect(e.errorMessage, contains('No products matched'));
    });
  });
}
