import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/services/batch_ocr_service.dart';

BatchOcrResult parse(String t) => BatchOcrService.parsePackagingText(t);
String? day(ParsedDateCandidate? d) => d == null ? null : '${d.date.year}-${d.date.month.toString().padLeft(2, '0')}-${d.date.day.toString().padLeft(2, '0')}';

/// "2027-10-17", "2027-10|month", "ambiguous" or null, as used in corpus.json.
String? describe(List<ParsedDateCandidate> list) {
  if (list.isEmpty) return null;
  final d = list.first;
  if (d.isAmbiguous) return 'ambiguous';
  final ym = '${d.date.year}-${d.date.month.toString().padLeft(2, '0')}';
  return d.precision == DatePrecision.month ? '$ym|month' : '$ym-${d.date.day.toString().padLeft(2, '0')}';
}

void main() {
  group('Batch / lot codes', () {
    test('labels: LOT, BATCH, LOT:, L:, B.NO, Batch No.', () {
      expect(parse('LOT A7K29').suggestedBatchCode, 'A7K29');
      expect(parse('BATCH 4021A').suggestedBatchCode, '4021A');
      expect(parse('LOT: B23').suggestedBatchCode, 'B23');
      expect(parse('L: 7K129').suggestedBatchCode, '7K129');
      expect(parse('L 3B118').suggestedBatchCode, '3B118');
      expect(parse('B.NO K42').suggestedBatchCode, 'K42');
      expect(parse('Batch No. 4021A').suggestedBatchCode, '4021A');
      expect(parse('LOT NO: 21-0457').suggestedBatchCode, '21-0457');
      expect(parse('BATCH 40213').suggestedBatchCode, '40213', reason: 'digit-only codes are fine after a label');
    });

    test('label words inside other words are not labels', () {
      expect(parse('BODY LOTION 200ML').batchCandidates, isEmpty); // "LOT" in "LOTION"
      expect(parse('EXPERT PRODUCT 2026').expiryCandidates, isEmpty); // "EXP" in "EXPERT"
      expect(parse('BB Cream SPF 50').expiryCandidates, isEmpty); // "BB" without a date
      expect(parse('BLOTTING PAPER').batchCandidates, isEmpty);
    });

    test('the label itself is never returned as the code', () {
      final r = parse('BATCH NO. 4021A');
      expect(r.allBatchCodeCandidates, ['4021A']);
    });

    test('a retail barcode, PAO, size, SPF or date near the label is not the code', () {
      expect(parse('8801234567893\nBATCH NO. 4021A').allBatchCodeCandidates, ['4021A']);
      expect(parse('LOT 0123456789012').batchCandidates, isEmpty);
      expect(parse('12M   50ml\nLOT B23   EXP 05/2026').allBatchCodeCandidates, ['B23']);
      expect(parse('SPF50 PA++++').batchCandidates, isEmpty);
      expect(parse('LOT 10/2027').batchCandidates, isEmpty);
    });

    test('unlabeled code-like tokens are offered, never filled in', () {
      final r = parse('Hydrating Toner\nK42 09/2028');
      expect(r.suggestedBatchCode, isNull);
      expect(r.batchCandidates.single.code, 'K42');
      expect(r.batchCandidates.single.isLabeled, isFalse);
    });

    test('marketing text yields no code (old parser returned "GEL")', () {
      final r = parse('Hydrating Gel Cream\nwith Hyaluronic Acid\nDermatologist tested');
      expect(r.batchCandidates, isEmpty);
      expect(r.hasAnyDetection, isFalse);
    });

    test('two different labeled codes are both offered, neither filled in', () {
      final r = parse('LOT A12\nLOT B34');
      expect(r.suggestedBatchCode, isNull);
      expect(r.allBatchCodeCandidates, ['A12', 'B34']);
    });

    test('look-alike characters are flagged, never changed', () {
      final c = parse('LOT 0B8I1').batchCandidates.single;
      expect(c.code, '0B8I1');
      expect(c.hasLookalikeCharacters, isTrue);
      expect(parse('LOT 4762').batchCandidates.single.hasLookalikeCharacters, isFalse);
    });

    test('codes are kept as printed across lines', () {
      expect(parse('BATCH\n4021A').suggestedBatchCode, '4021A');
    });
  });

  group('Manufacturing and expiry dates', () {
    test('labels: MFG, MFD, Manufactured, DOM; EXP, Expiry, Best Before, BBE, Use by', () {
      expect(day(parse('MFG 2024-10-17').suggestedMfgDate), '2024-10-17');
      expect(day(parse('MFD: 17/10/2024').suggestedMfgDate), '2024-10-17');
      expect(day(parse('Manufactured on 17 Oct 2024').suggestedMfgDate), '2024-10-17');
      expect(day(parse('DOM 17.10.2024').suggestedMfgDate), '2024-10-17');
      expect(day(parse('EXP 2027-10-17').suggestedExpiryDate), '2027-10-17');
      expect(day(parse('Expiry: 17/10/2027').suggestedExpiryDate), '2027-10-17');
      expect(day(parse('Best Before 17 Oct 2027').suggestedExpiryDate), '2027-10-17');
      expect(day(parse('BBE 17-OCT-2027').suggestedExpiryDate), '2027-10-17');
      expect(day(parse('Use by 2027-10-17').suggestedExpiryDate), '2027-10-17');
    });

    test('textual and compact formats', () {
      expect(day(parse('EXP OCT 17, 2027').suggestedExpiryDate), '2027-10-17');
      expect(day(parse('EXP 20271017').suggestedExpiryDate), '2027-10-17');
      expect(day(parse('EXP 17 October 2027').suggestedExpiryDate), '2027-10-17');
    });

    test('month/year dates keep month precision (no invented day)', () {
      for (final t in ['EXP 10/2027', 'EXP 10-2027', 'EXP 3/2027', 'EXP OCT 2027', 'EXP 2027 OCT', 'EXP 2027-10', 'EXP 10/27']) {
        final d = parse(t).suggestedExpiryDate;
        expect(d, isNotNull, reason: t);
        expect(d!.precision, DatePrecision.month, reason: t);
        expect(d.date.day, 1, reason: t);
        expect(d.formattedDisplay, contains('month only'), reason: t);
      }
      expect(parse('MFD 2026-10').suggestedMfgDate!.precision, DatePrecision.month);
      expect(parse('EXP 10/27').suggestedExpiryDate!.ambiguityNote, contains('2-digit year'));
    });

    test('labels on their own line take the date from the next line', () {
      final r = parse('MFD\n2025-02\nEXP\n2028-02');
      expect(describe(r.mfgCandidates), '2025-02|month');
      expect(describe(r.expiryCandidates), '2028-02|month');
    });

    test('both dates on one line go to their own fields (not by order)', () {
      final r = parse('EXP 10/2029 MFG 10/2026');
      expect(describe(r.mfgCandidates), '2026-10|month');
      expect(describe(r.expiryCandidates), '2029-10|month');
    });

    test('ambiguous day/month keeps both readings and is flagged', () {
      final d = parse('EXP 04/05/2027').suggestedExpiryDate!;
      expect(d.isAmbiguous, isTrue);
      expect({d.date, d.alternateDate}, {DateTime(2027, 5, 4), DateTime(2027, 4, 5)});
      expect(d.ambiguityNote, contains('Choose'));
      // Same day and month: not ambiguous.
      expect(parse('EXP 05/05/2027').suggestedExpiryDate!.isAmbiguous, isFalse);
      // One part above 12 decides the order.
      expect(day(parse('EXP 25/08/2026').suggestedExpiryDate), '2026-08-25');
      expect(day(parse('EXP 08/25/2026').suggestedExpiryDate), '2026-08-25');
    });

    test('impossible dates are rejected and explained', () {
      for (final t in ['EXP 31/04/2027', 'EXP 2027-02-30', 'EXP 2027.03.34', 'EXP 13/13/2027']) {
        final r = parse(t);
        expect(r.expiryCandidates, isEmpty, reason: t);
        expect(r.notes.single, contains('not a valid date'), reason: t);
      }
      // A misread day must not turn into a different month/year (old parser read 2034-03).
      expect(parse('EXP 2027.03.34').unlabeledDates, isEmpty);
    });

    test('PAO and sizes are not dates; PAO OCR never fills the printed expiry', () {
      expect(parse('EXP 12M 50ml').expiryCandidates, isEmpty);
      expect(parse('12M\n50ml\n6M').hasAnyDetection, isFalse);
      expect(parse('Use within 12 months').expiryCandidates, isEmpty);
    });

    test('unlabeled dates are offered for the user to assign, never assigned', () {
      final r = parse('Hydrating Serum\n2027-10-17');
      expect(r.suggestedExpiryDate, isNull);
      expect(r.suggestedMfgDate, isNull);
      expect(day(r.unlabeledDates.single), '2027-10-17');
    });

    test('missing and empty text stay missing (no current date is filled in)', () {
      for (final t in ['', '   ', '\n\n', 'LOT', 'EXP', 'MFG:']) {
        final r = parse(t);
        expect(r.suggestedBatchCode, isNull, reason: t);
        expect(r.suggestedMfgDate, isNull, reason: t);
        expect(r.suggestedExpiryDate, isNull, reason: t);
      }
    });

    test('two different labeled expiry dates: both offered, none filled', () {
      final r = parse('EXP 2027-10-17\nEXP 2028-01-01');
      expect(r.suggestedExpiryDate, isNull);
      expect(r.expiryCandidates, hasLength(2));
    });
  });

  group('Several OCR readings of one image', () {
    test('agreeing readings merge; a reading with a misread date does not win', () {
      final r = BatchOcrService.parsePasses([
        (label: 'as captured', text: '= IINLY\nEXP 2027.03.34'),
        (label: 'enhanced', text: '= TIN ZY\nEXP 2027-03-31'),
      ]);
      expect(day(r.suggestedExpiryDate), '2027-03-31');
      expect(r.rawText, contains('[as captured]'));
      expect(r.rawText, contains('[enhanced]'));
    });

    test('disagreeing labeled values are all offered', () {
      final r = BatchOcrService.parsePasses([
        (label: 'a', text: 'LOT A7K29'),
        (label: 'b', text: 'LOT A7K2S'),
      ]);
      expect(r.suggestedBatchCode, isNull);
      expect(r.allBatchCodeCandidates, ['A7K29', 'A7K2S']);
    });
  });

  group('Corpus: real Tesseract output for synthetic labels (test/fixtures/packaging_ocr)', () {
    final corpus = jsonDecode(File('test/fixtures/packaging_ocr/corpus.json').readAsStringSync()) as Map<String, dynamic>;
    for (final c in (corpus['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final r = BatchOcrService.parsePasses([
          (label: 'as captured', text: (c['ocr']['original'] ?? '') as String),
          (label: 'enhanced', text: (c['ocr']['enhanced_js'] ?? '') as String),
        ]);
        final e = c['expected'] as Map<String, dynamic>;
        expect(r.suggestedBatchCode, e['batch_code'], reason: 'batch');
        expect(describe(r.mfgCandidates), e['manufacturing'], reason: 'manufacturing');
        expect(describe(r.expiryCandidates), e['expiry'], reason: 'expiry');
        if (e['batch_code'] == null && c['known_limitation'] == null) {
          expect(r.labeledBatchCandidates, isEmpty, reason: 'no labeled code should be invented');
        }
      });
    }
  });
}
