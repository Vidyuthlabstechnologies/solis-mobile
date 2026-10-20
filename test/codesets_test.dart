// Checks the official code-set assets in assets/codes/ and the Dart catalogs
// that read them. Loads the real gzip files from disk.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';

void main() {
  // Default catalog under test: FY2027, in effect from 2026-10-01.
  late IcdCatalog icd;
  late IcdCatalog icd2026;
  late IcdIndex index;
  late HcpcsCatalog hcpcs;
  late FeeSchedule pfs;
  late Mue mue;
  late Ptp ptp;

  setUpAll(() async {
    CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes'));
    icd = await IcdCatalog.forFiscalYear(2027);
    icd2026 = await IcdCatalog.forFiscalYear(2026);
    index = await IcdIndex.forFiscalYear(2027);
    hcpcs = await HcpcsCatalog.load();
    pfs = await FeeSchedule.load();
    mue = await Mue.load();
    ptp = await Ptp.load();
  });

  group('ICD-10-CM editions by date of service', () {
    test('fiscal year switches on October 1', () {
      expect(IcdEditions.fiscalYearFor(DateTime(2026, 9, 30)), 2026);
      expect(IcdEditions.fiscalYearFor(DateTime(2026, 10, 1)), 2027);
      expect(IcdEditions.fiscalYearFor(DateTime(2025, 10, 1)), 2026);
      expect(IcdEditions.covers(DateTime(2027, 10, 1)), isFalse);
      expect(IcdEditions.resolve(DateTime(2027, 10, 1)), 2027);
      expect(IcdEditions.resolve(DateTime(2024, 1, 1)), 2026);
    });

    test('forDate picks the right cached edition', () async {
      final before = await IcdCatalog.forDate(DateTime(2026, 9, 30));
      final after = await IcdCatalog.forDate(DateTime(2026, 10, 1));
      expect(before.fiscalYear, 2026);
      expect(after.fiscalYear, 2027);
      expect(identical(before, icd2026), isTrue);
      expect(identical(after, icd), isTrue);
      final idx = await IcdIndex.forDate(DateTime(2026, 9, 30));
      expect(idx.fiscalYear, 2026);
    });

    test('load() returns the edition for today', () async {
      final today = await IcdCatalog.load();
      expect(today.fiscalYear, IcdEditions.resolve(DateTime.now()));
    });

    test('codes added in FY2027', () {
      // C78.31 Secondary malignant neoplasm of larynx is new for FY2027.
      expect(icd2026.isValid('C78.31'), isFalse);
      expect(icd.isBillable('C78.31'), isTrue);
    });

    test('codes deleted or expanded in FY2027', () {
      // S23.420A was deleted for FY2027.
      expect(icd2026.isBillable('S23.420A'), isTrue);
      expect(icd.isValid('S23.420A'), isFalse);
      // I42.0 dilated cardiomyopathy was billable in FY2026 and became a
      // header in FY2027 (expanded to I42.00, I42.01, I42.09).
      expect(icd2026.isBillable('I42.0'), isTrue);
      expect(icd.isValid('I42.0'), isTrue);
      expect(icd.isBillable('I42.0'), isFalse);
      expect(icd.isBillable('I42.00'), isTrue);
    });

    test('FY2026 still validates the original checks', () {
      expect(icd2026.isBillable('I21.19'), isTrue);
      expect(icd2026.isBillable('M54.5'), isFalse);
      expect(icd2026.isBillable('M54.50'), isTrue);
    });
  });

  group('ICD-10-CM catalog', () {
    test('loads the full tabular list', () {
      expect(icd.length, greaterThan(90000));
    });

    test('I21.19 is billable, I21.1 is a header', () {
      expect(icd.isBillable('I21.19'), isTrue);
      expect(icd.isValid('I21.1'), isTrue);
      expect(icd.isBillable('I21.1'), isFalse);
    });

    test('R51.9 is valid with or without the dot', () {
      expect(icd.isValid('R51.9'), isTrue);
      expect(icd.isBillable('r519'), isTrue);
      expect(icd.description('R51.9'), 'Headache, unspecified');
    });

    test('M54.5 is not billable but M54.50 is', () {
      expect(icd.isBillable('M54.5'), isFalse);
      expect(icd.isBillable('M54.50'), isTrue);
      expect(
        icd.billableChildren('M54.5').map((e) => e.code),
        containsAll(<String>['M54.50', 'M54.51', 'M54.59']),
      );
    });

    test('E11.42 description', () {
      expect(
        icd.description('E11.42'),
        'Type 2 diabetes mellitus with diabetic polyneuropathy',
      );
    });

    test('unknown codes are invalid', () {
      expect(icd.isValid('Z99.999'), isFalse);
      expect(icd.lookup('XYZ'), isNull);
    });

    test('search ranks code prefix first, then description words', () {
      final byCode = icd.search('I21.1', limit: 5);
      expect(byCode.first.code, 'I21.1');
      expect(byCode.skip(1).every((e) => e.code.startsWith('I21.1')), isTrue);
      final byWords = icd.search('chest pain', limit: 10);
      expect(byWords.map((e) => e.code), contains('R07.9'));
      expect(byWords.first.billable, isTrue);
    });
  });

  group('ICD-10-CM alphabetic index', () {
    test('suggests R07.9 for chest pain', () {
      final s = index.suggest('Patient presents with chest pain since morning');
      expect(s, isNotEmpty);
      expect(s.first.code, 'R07.9');
      expect(s.first.path, 'Pain|chest');
    });

    test('prefers the more specific subterm', () {
      final s = index.suggest('atypical chest pain');
      expect(s.first.code, 'R07.89');
    });

    test('is conservative for generic words and negation', () {
      expect(index.suggest('pain'), isEmpty);
      expect(index.suggest('the patient has some pain'), isEmpty);
      expect(index.suggest('denies chest pain'), isEmpty);
      expect(
        index.suggest('No fever. Chest pain on exertion').map((s) => s.code),
        contains('R07.9'),
      );
    });

    test('suggested codes exist in the catalog', () {
      for (final s in index.suggest('headache and pneumonia')) {
        expect(icd.isValid(s.code), isTrue, reason: s.toString());
      }
    });
  });

  group('HCPCS Level II', () {
    test('G0101 present', () {
      final e = hcpcs.lookup('G0101');
      expect(e, isNotNull);
      expect(e!.longDescription.toLowerCase(), contains('cancer screening'));
      expect(hcpcs.search('G010').first.code, startsWith('G010'));
    });

    test('contains no CPT codes', () {
      expect(hcpcs.lookup('99214'), isNull);
    });
  });

  group('Physician fee schedule 2026', () {
    test('conversion factors', () {
      expect(FeeSchedule.conversionFactor2026, 33.4009);
      expect(FeeSchedule.conversionFactor2026QualifyingApm, 33.5675);
    });

    test('99214 non-facility amount is in a sane range', () {
      final amount = pfs.medicareAmount('99214')!;
      expect(amount, inInclusiveRange(100, 200));
      final facility = pfs.medicareAmount('99214', facility: true)!;
      expect(facility, lessThan(amount));
      expect(pfs.lookup('99214')!.globalDays, 'XXX');
      // Preventive visits are status N: listed RVUs, no Medicare payment.
      expect(pfs.medicareAmount('99396'), isNull);
      expect(pfs.medicareAmount('99396', includeNonPayable: true), isNotNull);
    });

    test('asset carries no CPT descriptors', () {
      final raw = CodeSetLoader.decode(
        File('assets/codes/pfs_rvu.tsv.gz').readAsBytesSync(),
      );
      final first99214 = raw
          .split('\n')
          .firstWhere((l) => l.startsWith('99214\t'));
      // code, status, two RVU totals, global days, work RVU, PC/TC, bilateral.
      expect(first99214.split('\t').length, 8);
      expect(first99214.split('\t').skip(1).every((c) => RegExp(r'^[A-Z0-9.]*$').hasMatch(c)), isTrue);
      expect(first99214.toLowerCase(), isNot(contains('office')));
    });
  });

  group('MUE practitioner', () {
    // The CMS Q4 2026 (effective 2026-10-01) practitioner table lists
    // 99214 with 2 units and MAI 3; 99215 has 1 unit.
    test('99214 and 99215 units', () {
      expect(mue.maxUnits('99214'), 2);
      expect(mue.adjudicationIndicator('99214'), 3);
      expect(mue.maxUnits('99215'), 1);
      expect(mue.exceeds('99215', 2), isTrue);
    });
  });

  group('PTP practitioner', () {
    test('availability matches the bundled asset', () {
      final bundled = File('assets/codes/ptp_practitioner.tsv.gz').existsSync();
      expect(ptp.available, bundled);
      if (!bundled) {
        expect(ptp.edit('99214', '36415'), isNull);
      }
    });

    test('parses compact rows', () {
      final t = Ptp.parse('AAAA1\tBBBB10,CCCC21\n');
      expect(t.edit('AAAA1', 'BBBB1')!.modifierIndicator, 0);
      expect(t.edit('AAAA1', 'CCCC2')!.modifierAllowed, isTrue);
      expect(t.edit('AAAA1', 'DDDD3'), isNull);
      expect(t.conflicts('CCCC2', 'AAAA1'), isTrue);
    });
  });

  group('memory source', () {
    test('parses raw strings', () async {
      CodeSetLoader.useSource(
        MemoryCodeSetSource({CodeSetFiles.icd10cm(2027): 'A00\t0\tCholera\n'}),
      );
      final small = await IcdCatalog.forFiscalYear(2027);
      expect(small.length, 1);
      expect(small.fiscalYear, 2027);
      expect(small.isBillable('A00'), isFalse);
      CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes'));
    });
  });
}
