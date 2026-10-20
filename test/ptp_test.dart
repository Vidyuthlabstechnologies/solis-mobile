import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/services/codesets/ptp.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';

ServiceLine _line(String code, [List<String> mods = const []]) => ServiceLine(code: code, description: code, modifiers: mods);

List<String> _titles(List<ServiceLine> lines) => ClaimScrubber.ptpIssues(lines).map((i) => i.title).toList();

void main() {
  tearDown(ReferenceData.clear);

  group('NCCI procedure pairs', () {
    setUp(() => ReferenceData.inject(ptpTable: Ptp.parse('20610\t76942' '1,99213' '1\n20100\t36591' '0\n')));

    test('no table means no pair checks', () {
      ReferenceData.clear();
      expect(_titles([_line('20610'), _line('99213')]), isEmpty);
    });

    test('modifier indicator 0: never billed together', () {
      expect(_titles([_line('20100'), _line('36591', ['59'])]), ['Billed together: 20100 includes 36591']);
    });

    test('modifier indicator 1: needs an NCCI modifier on either line', () {
      expect(_titles([_line('20610'), _line('99213')]), ['Needs a modifier: 99213 with 20610']);
      expect(_titles([_line('20610'), _line('99213', ['25'])]), isEmpty);
      expect(_titles([_line('20610'), _line('76942', ['XU'])]), isEmpty);
    });

    test('unrelated codes pass', () {
      expect(_titles([_line('20610'), _line('99214')]), isEmpty);
    });
  });

  // Runs only on the founder's computer, where the licensed CMS table was
  // built into local_data/ (it is never bundled or committed).
  final local = File('local_data/ptp_practitioner.tsv.gz');
  test('real CMS PTP table (local only)', () {
    final ptp = Ptp.parse(String.fromCharCodes(gzip.decode(local.readAsBytesSync())));
    expect(ptp.column1Count, greaterThan(1000));
    expect(ptp.edit('20610', '99213')?.modifierIndicator, 1);
    expect(ptp.edit('20100', '36591')?.modifierIndicator, 0);
    expect(ptp.edit('99213', '20610'), isNull, reason: 'order matters: column 1 is the comprehensive code');
  }, skip: local.existsSync() ? false : 'local_data/ptp_practitioner.tsv.gz not built on this machine');
}
